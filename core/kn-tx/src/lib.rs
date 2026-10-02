//! Sending: choosing which outputs to spend, building the transaction with
//! monero-oxide, signing it through `kn-keys`, and publishing it.
//!
//! The flow is two steps so the user can confirm what they are about to
//! send: [`prepare`] builds and signs a transaction and reports its fee and
//! amounts without publishing anything; [`publish`] sends that exact
//! transaction and marks its inputs as pending in the wallet's state.

#![forbid(unsafe_code)]

use kn_keys::{Network, WalletKeys};
use kn_sync::{Http, LwsServer, OwnedOutput, SyncState};
use monero_daemon_rpc::MoneroDaemon;
use monero_interface::{FeePriority, ProvidesFeeRates as _, PublishTransaction as _};
use monero_wallet::OutputWithDecoys;
use monero_wallet::address::{MoneroAddress, Network as MoneroNetwork};
use monero_wallet::ed25519::{CompressedPoint, Point};
use monero_wallet::interface::FeeRate;
use monero_wallet::ringct::RctType;
use monero_wallet::ringct::clsag::Decoys;
use monero_wallet::send::{Change, SendError, SignableTransaction};
use monero_wallet::transaction::{Input, Timelock, Transaction};
use rand_core::{OsRng, RngCore};
use zeroize::Zeroizing;

/// Ring size in force on the Monero network.
const RING_LEN: u8 = 16;

/// The most inputs one transaction may spend; beyond this it risks
/// exceeding the network's size limit.
pub const MAX_INPUTS: usize = 100;

/// Monero allows up to 16 outputs; one is kept for change.
pub const MAX_PAYMENTS: usize = 15;

/// Where decoys, fee rates and broadcasting come from: the wallet's node in
/// full mode, its light wallet server in LWS mode.
#[derive(Clone, Copy)]
pub enum Backend<'a> {
    Node(&'a MoneroDaemon<Http>),
    Lws(&'a LwsServer),
}

/// The fee priority levels wallets and nodes agree on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Priority {
    Low,
    Normal,
    High,
    Urgent,
}

impl From<Priority> for FeePriority {
    fn from(p: Priority) -> Self {
        match p {
            Priority::Low => FeePriority::Unimportant,
            Priority::Normal => FeePriority::Normal,
            Priority::High => FeePriority::Elevated,
            Priority::Urgent => FeePriority::Priority,
        }
    }
}

/// What to send.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Request {
    /// Pay each address the given amount (atomic units); change returns to
    /// the wallet.
    Pay(Vec<(String, u64)>),
    /// Send everything spendable to one address, minus the fee.
    SweepAll(String),
}

#[derive(Debug, thiserror::Error)]
pub enum TxError {
    #[error("{0} is not a valid address for this network")]
    BadAddress(String),
    #[error("an amount must be more than zero")]
    ZeroAmount,
    #[error("one transaction can pay at most {MAX_PAYMENTS} addresses")]
    TooManyPayments,
    #[error("not enough unlocked funds: {available} available, {needed} needed including the fee")]
    InsufficientFunds { available: u64, needed: u64 },
    #[error("this would spend more than {MAX_INPUTS} outputs; send a smaller amount first")]
    TooManyInputs,
    #[error("view-only wallets cannot send")]
    ViewOnly,
    #[error("the node could not provide what sending needs: {0}")]
    Node(String),
    #[error("the network rejected the transaction: {0}")]
    Rejected(String),
    #[error("the transaction could not be built: {0}")]
    Build(String),
}

/// A signed transaction, not yet published.
pub struct Prepared {
    transaction: Transaction,
    /// The transaction id.
    pub hash: [u8; 32],
    /// Paid to others, atomic units.
    pub amount: u64,
    pub fee: u64,
    /// Returned to this wallet.
    pub change: u64,
    /// Key images of the outputs it spends.
    pub spends: Vec<[u8; 32]>,
}

impl std::fmt::Debug for Prepared {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Prepared")
            .field("hash", &self.hash)
            .field("amount", &self.amount)
            .field("fee", &self.fee)
            .finish_non_exhaustive()
    }
}

/// Outputs that can be spent at chain height `tip`, largest first.
#[must_use]
pub fn spendable(state: &SyncState, tip: u64) -> Vec<&OwnedOutput> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    let mut outputs: Vec<&OwnedOutput> = state
        .outputs
        .iter()
        .filter(|o| {
            o.spent.is_none()
                && o.key_image.is_some()
                && tip >= o.unlock_height()
                && timelock_passed(o.output.additional_timelock(), tip, now)
        })
        .collect();
    outputs.sort_by_key(|o| std::cmp::Reverse(o.amount()));
    outputs
}

/// Builds and signs a transaction for `request` without publishing it.
///
/// Inputs are the fewest, largest spendable outputs that cover the amount
/// and fee; change goes to the wallet's primary address. Decoys are chosen
/// by monero-oxide from the node's output distribution.
///
/// # Errors
///
/// See [`TxError`]; nothing is sent in any case.
pub async fn prepare(
    backend: Backend<'_>,
    keys: &WalletKeys,
    network: Network,
    state: &SyncState,
    tip: u64,
    request: &Request,
    priority: Priority,
) -> Result<Prepared, TxError> {
    if keys.is_view_only() {
        return Err(TxError::ViewOnly);
    }
    let fee_rate = fee_rate(backend, keys, network, priority).await?;
    let available = spendable(state, tip);
    let total_available: u64 = available.iter().map(|o| o.amount()).sum();
    // monero-oxide wants the number of the latest block (its index), while
    // `tip` counts blocks.
    let block_number = usize::try_from(tip.saturating_sub(1))
        .map_err(|_| TxError::Build("height out of range".into()))?;

    let ctx = Context {
        backend,
        keys,
        fee_rate,
        block_number,
        available: &available,
        total_available,
    };
    match request {
        Request::Pay(payments) => pay(&ctx, parse_payments(payments, network)?).await,
        Request::SweepAll(address) => sweep(&ctx, &parse_address(address, network)?).await,
    }
}

/// What building a transaction needs, shared by paying and sweeping.
struct Context<'a> {
    backend: Backend<'a>,
    keys: &'a WalletKeys,
    fee_rate: FeeRate,
    block_number: usize,
    /// Spendable outputs, largest first.
    available: &'a [&'a OwnedOutput],
    total_available: u64,
}

/// Pays `payments`: enough of the largest outputs for the amount, then one
/// more at a time until the fee is covered too.
async fn pay(ctx: &Context<'_>, payments: Vec<(MoneroAddress, u64)>) -> Result<Prepared, TxError> {
    let wanted: u64 = payments.iter().map(|(_, amount)| amount).sum();
    let mut used = needed_inputs(ctx.available, wanted);
    if used > ctx.available.len() {
        return Err(TxError::InsufficientFunds {
            available: ctx.total_available,
            needed: wanted,
        });
    }
    let mut inputs = Vec::with_capacity(used + 1);
    for output in &ctx.available[..used] {
        inputs.push(with_decoys(ctx, output).await?);
    }
    loop {
        if used > MAX_INPUTS {
            return Err(TxError::TooManyInputs);
        }
        match signable(ctx.keys, inputs.clone(), payments.clone(), ctx.fee_rate) {
            Ok(tx) => return finish(ctx.keys, tx, &ctx.available[..used], wanted),
            Err(SendError::NotEnoughFunds { .. }) if used < ctx.available.len() => {
                inputs.push(with_decoys(ctx, ctx.available[used]).await?);
                used += 1;
            }
            Err(SendError::NotEnoughFunds {
                outputs,
                necessary_fee,
                ..
            }) => {
                return Err(TxError::InsufficientFunds {
                    available: ctx.total_available,
                    needed: outputs + necessary_fee.unwrap_or(0),
                });
            }
            Err(e) => return Err(TxError::Build(e.to_string())),
        }
    }
}

/// Sends everything spendable to `address`. Asks for the full amount
/// first; the refusal reports the fee, and the payment becomes the rest.
/// The fee can shrink slightly with the smaller amount, so it settles
/// within a few passes.
async fn sweep(ctx: &Context<'_>, address: &MoneroAddress) -> Result<Prepared, TxError> {
    if ctx.available.is_empty() {
        return Err(TxError::InsufficientFunds {
            available: 0,
            needed: 1,
        });
    }
    if ctx.available.len() > MAX_INPUTS {
        return Err(TxError::TooManyInputs);
    }
    let mut inputs = Vec::with_capacity(ctx.available.len());
    for output in ctx.available {
        inputs.push(with_decoys(ctx, output).await?);
    }
    let mut amount = ctx.total_available;
    for _ in 0..3 {
        match signable(
            ctx.keys,
            inputs.clone(),
            vec![(*address, amount)],
            ctx.fee_rate,
        ) {
            Ok(tx) => return finish(ctx.keys, tx, ctx.available, amount),
            Err(SendError::NotEnoughFunds {
                inputs,
                necessary_fee: Some(fee),
                ..
            }) => {
                amount = inputs.checked_sub(fee).filter(|a| *a > 0).ok_or(
                    TxError::InsufficientFunds {
                        available: inputs,
                        needed: fee + 1,
                    },
                )?;
            }
            Err(e) => return Err(TxError::Build(e.to_string())),
        }
    }
    Err(TxError::Build("the fee did not settle".into()))
}

/// Publishes a prepared transaction and marks its inputs as pending in
/// `state`.
///
/// # Errors
///
/// [`TxError::Rejected`] if the node refuses it, [`TxError::Node`] if it
/// cannot be reached; `state` is unchanged in both cases.
pub async fn publish(
    backend: Backend<'_>,
    prepared: &Prepared,
    state: &mut SyncState,
    tip: u64,
) -> Result<(), TxError> {
    match backend {
        Backend::Node(daemon) => daemon
            .publish_transaction(&prepared.transaction)
            .await
            .map_err(|e| match e {
                monero_interface::PublishTransactionError::TransactionRejected(why) => {
                    TxError::Rejected(why)
                }
                other @ monero_interface::PublishTransactionError::InterfaceError(_) => {
                    TxError::Node(other.to_string())
                }
            })?,
        Backend::Lws(server) => server
            .submit(&prepared.transaction.serialize())
            .await
            .map_err(|e| TxError::Rejected(e.to_string()))?,
    }
    state.mark_pending(&prepared.spends, prepared.hash, tip);
    Ok(())
}

async fn fee_rate(
    backend: Backend<'_>,
    keys: &WalletKeys,
    network: Network,
    priority: Priority,
) -> Result<FeeRate, TxError> {
    match backend {
        Backend::Node(daemon) => daemon
            .fee_rate(priority.into(), u64::MAX)
            .await
            .map_err(|e| TxError::Node(e.to_string())),
        Backend::Lws(server) => {
            let fees = server
                .fees(keys, network)
                .await
                .map_err(|e| TxError::Node(e.to_string()))?;
            let index = match priority {
                Priority::Low => 0,
                Priority::Normal => 1,
                Priority::High => 2,
                Priority::Urgent => 3,
            }
            .min(fees.per_priority.len() - 1);
            FeeRate::new(fees.per_priority[index], fees.mask)
                .ok_or_else(|| TxError::Node("the server suggested an invalid fee".into()))
        }
    }
}

/// The serialized transaction, for broadcasting by other means.
#[must_use]
pub fn raw_transaction(prepared: &Prepared) -> Vec<u8> {
    prepared.transaction.serialize()
}

/// Whether a transaction's own unlock time has passed. Miner transactions
/// always carry one (their block height plus 60), which the 60-block rule
/// already covers; ordinary transactions rarely do.
fn timelock_passed(timelock: Timelock, tip: u64, now: u64) -> bool {
    match timelock {
        Timelock::None => true,
        Timelock::Block(block) => u64::try_from(block).is_ok_and(|b| tip >= b),
        Timelock::Time(time) => now >= time,
    }
}

/// What kind of address a valid address string is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AddressKind {
    Standard,
    Subaddress,
    /// A standard address with an embedded payment id.
    Integrated,
}

/// Checks that `address` is a valid address on `network`.
///
/// # Errors
///
/// [`TxError::BadAddress`] otherwise.
pub fn check_address(address: &str, network: Network) -> Result<AddressKind, TxError> {
    let address = parse_address(address, network)?;
    Ok(if address.is_subaddress() {
        AddressKind::Subaddress
    } else if address.payment_id().is_some() {
        AddressKind::Integrated
    } else {
        AddressKind::Standard
    })
}

fn parse_address(address: &str, network: Network) -> Result<MoneroAddress, TxError> {
    MoneroAddress::from_str(MoneroNetwork::from(network), address.trim())
        .map_err(|_| TxError::BadAddress(address.trim().to_owned()))
}

fn parse_payments(
    payments: &[(String, u64)],
    network: Network,
) -> Result<Vec<(MoneroAddress, u64)>, TxError> {
    if payments.is_empty() {
        return Err(TxError::ZeroAmount);
    }
    if payments.len() > MAX_PAYMENTS {
        return Err(TxError::TooManyPayments);
    }
    payments
        .iter()
        .map(|(address, amount)| {
            if *amount == 0 {
                return Err(TxError::ZeroAmount);
            }
            Ok((parse_address(address, network)?, *amount))
        })
        .collect()
}

/// How many of the largest outputs cover `wanted`, before fees.
fn needed_inputs(available: &[&OwnedOutput], wanted: u64) -> usize {
    let mut sum = 0u64;
    for (i, o) in available.iter().enumerate() {
        sum = sum.saturating_add(o.amount());
        if sum >= wanted {
            return i + 1;
        }
    }
    available.len() + 1
}

async fn with_decoys(ctx: &Context<'_>, output: &OwnedOutput) -> Result<OutputWithDecoys, TxError> {
    match ctx.backend {
        Backend::Node(daemon) => OutputWithDecoys::new(
            &mut OsRng,
            daemon,
            RING_LEN,
            ctx.block_number,
            output.output.clone(),
        )
        .await
        .map_err(|e| TxError::Node(format!("choosing decoys: {e}"))),
        Backend::Lws(server) => {
            let candidates = server
                .random_outputs(1, RING_LEN)
                .await
                .map_err(|e| TxError::Node(format!("choosing decoys: {e}")))?
                .pop()
                .unwrap_or_default();
            lws_ring(output, &candidates)
        }
    }
}

/// Builds the ring for `output` from a light wallet server's candidates:
/// the real output plus `RING_LEN - 1` distinct others, by global index.
fn lws_ring(
    output: &OwnedOutput,
    candidates: &[kn_sync::RandomOutput],
) -> Result<OutputWithDecoys, TxError> {
    let bad = |why: &str| TxError::Node(format!("the server's decoys are unusable: {why}"));
    let real_index = output.output.index_on_blockchain();
    let mut members: Vec<(u64, [Point; 2])> = Vec::with_capacity(usize::from(RING_LEN));
    members.push((
        real_index,
        [output.output.key(), output.output.commitment().commit()],
    ));
    for candidate in candidates {
        if members.len() == usize::from(RING_LEN) {
            break;
        }
        if members.iter().any(|(i, _)| *i == candidate.global_index) {
            continue;
        }
        let key = CompressedPoint::from(candidate.public_key)
            .decompress()
            .ok_or_else(|| bad("invalid output key"))?;
        let commitment = CompressedPoint::from(candidate.commitment)
            .decompress()
            .ok_or_else(|| bad("invalid commitment"))?;
        members.push((candidate.global_index, [key, commitment]));
    }
    if members.len() < usize::from(RING_LEN) {
        return Err(bad("too few distinct outputs"));
    }
    members.sort_by_key(|(index, _)| *index);
    let signer = members
        .iter()
        .position(|(index, _)| *index == real_index)
        .and_then(|p| u8::try_from(p).ok())
        .ok_or_else(|| bad("ring lost the real output"))?;
    let mut offsets = Vec::with_capacity(members.len());
    let mut previous = 0;
    for (index, _) in &members {
        offsets.push(index - previous);
        previous = *index;
    }
    let ring = members.into_iter().map(|(_, pair)| pair).collect();
    let decoys = Decoys::new(offsets, signer, ring).ok_or_else(|| bad("invalid ring"))?;

    // monero-oxide builds an OutputWithDecoys only through its own decoy
    // selection or its serialization: the output's spend data (key, key
    // offset, commitment) followed by the decoys. The spend data sits after
    // the output's two ids (40 + 8 bytes) in WalletOutput's serialization.
    let serialized = output.output.serialize();
    let spend_data = serialized
        .get(48..48 + 32 + 32 + 32 + 8)
        .ok_or_else(|| bad("unexpected output layout"))?;
    let mut bytes = Zeroizing::new(spend_data.to_vec());
    decoys
        .write(&mut *bytes)
        .map_err(|_| bad("could not encode the ring"))?;
    OutputWithDecoys::read(&mut bytes.as_slice()).map_err(|_| bad("could not decode the ring"))
}

fn signable(
    keys: &WalletKeys,
    inputs: Vec<OutputWithDecoys>,
    payments: Vec<(MoneroAddress, u64)>,
    fee_rate: FeeRate,
) -> Result<SignableTransaction, SendError> {
    // Seeds the transaction's internal randomness; fresh per transaction, as
    // monero-oxide requires.
    let mut outgoing_view_key = Zeroizing::new([0u8; 32]);
    OsRng.fill_bytes(outgoing_view_key.as_mut());
    SignableTransaction::new(
        RctType::ClsagBulletproofPlus,
        outgoing_view_key,
        inputs,
        payments,
        Change::new(keys.view_pair(), None),
        Vec::new(),
        fee_rate,
    )
}

fn finish(
    keys: &WalletKeys,
    signable: SignableTransaction,
    inputs: &[&OwnedOutput],
    amount: u64,
) -> Result<Prepared, TxError> {
    let fee = signable.necessary_fee();
    let input_total: u64 = inputs.iter().map(|o| o.amount()).sum();
    let transaction = keys.sign(signable).map_err(|e| match e {
        kn_keys::KeyError::ViewOnly => TxError::ViewOnly,
        other => TxError::Build(other.to_string()),
    })?;
    let spends = transaction
        .prefix()
        .inputs
        .iter()
        .filter_map(|input| match input {
            Input::ToKey { key_image, .. } => Some(key_image.to_bytes()),
            Input::Gen(_) => None,
        })
        .collect();
    Ok(Prepared {
        hash: transaction.hash(),
        amount,
        fee,
        change: input_total.saturating_sub(amount + fee),
        spends,
        transaction,
    })
}
