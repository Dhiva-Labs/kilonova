//! Sending: choosing which outputs to spend, building the transaction with
//! monero-oxide, signing it through `kn-keys`, and publishing it.
//!
//! The flow is two steps so the user can confirm what they are about to
//! send: [`prepare`] builds and signs a transaction and reports its fee and
//! amounts without publishing anything; [`publish`] sends that exact
//! transaction and marks its inputs as pending in the wallet's state.

#![forbid(unsafe_code)]

pub mod cold;

use kn_keys::{Network, WalletKeys};
use kn_sync::{Http, LwsServer, OwnedOutput, SyncState};
use monero_daemon_rpc::MoneroDaemon;
use monero_interface::{FeePriority, ProvidesFeeRates as _, PublishTransaction as _};
use monero_wallet::OutputWithDecoys;
use monero_wallet::address::{MoneroAddress, Network as MoneroNetwork};
use monero_wallet::ed25519::{CompressedPoint, Point, Scalar};
use monero_wallet::extra::Extra;
use monero_wallet::interface::FeeRate;
use monero_wallet::ringct::RctType;
use monero_wallet::ringct::clsag::Decoys;
use monero_wallet::send::{Change, SendError, SignableTransaction, TransactionKeys};
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

/// Highest fee rate accepted from a node or light wallet server, in atomic
/// units per byte of weight: about 2,500 times mainnet's normal rate, so a
/// lying server cannot make a transaction pay an absurd fee. Regtest chains
/// suggest higher rates than mainnet; their normal rate stays below this.
pub const MAX_FEE_PER_WEIGHT: u64 = 50_000_000;

/// Fee rounding (quantization) masks larger than this are refused; Monero's
/// is 10,000.
pub(crate) const MAX_FEE_MASK: u64 = 10_000;

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
    #[error("the node or server suggested a fee far above normal; choose another")]
    FeeTooHigh,
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
    /// Recipients and what each receives, as requested.
    pub destinations: Vec<(String, u64)>,
    /// How many of this wallet's addresses the spent coins arrived on; see
    /// [`linked_addresses`].
    pub linked_addresses: usize,
    /// The transaction's secret key(s) as hex, the format other wallets'
    /// "check transaction key" expects: the main key, then any additional
    /// keys in output order. With it and a recipient's address, anyone can
    /// prove that recipient was paid. `None` if it could not be confirmed
    /// against the transaction.
    pub tx_key: Option<Zeroizing<String>>,
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

/// Which coins a transaction may use.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Selection {
    /// One-time output keys never to spend: the owner's frozen coins.
    pub exclude: Vec<[u8; 32]>,
    /// If set, spend only these coins (the owner picked them).
    pub only: Option<Vec<[u8; 32]>>,
}

impl Selection {
    fn allows(&self, output: &OwnedOutput) -> bool {
        let key = output.output.key().compress().to_bytes();
        !self.exclude.contains(&key) && self.only.as_ref().is_none_or(|only| only.contains(&key))
    }
}

/// How many different addresses of this wallet the given coins arrived
/// on. Spending coins from several together lets whoever paid those
/// addresses see they belong to one wallet.
#[must_use]
pub fn linked_addresses(coins: &[&OwnedOutput]) -> usize {
    let mut seen: Vec<(u32, u32)> = Vec::new();
    for c in coins {
        let at = c
            .output
            .subaddress()
            .map_or((0, 0), |s| (s.account(), s.address()));
        if !seen.contains(&at) {
            seen.push(at);
        }
    }
    seen.len()
}

/// Outputs that can be spent at chain height `tip`, largest first.
#[must_use]
pub fn spendable(state: &SyncState, tip: u64) -> Vec<&OwnedOutput> {
    spendable_selected(state, tip, &Selection::default())
}

/// [`spendable`], limited by `selection`.
#[must_use]
pub fn spendable_selected<'a>(
    state: &'a SyncState,
    tip: u64,
    selection: &Selection,
) -> Vec<&'a OwnedOutput> {
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
                && selection.allows(o)
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
    let selection = Selection::default();
    prepare_selected(
        backend, keys, network, state, tip, request, priority, &selection,
    )
    .await
}

/// [`prepare`], spending only coins `selection` allows.
///
/// # Errors
///
/// See [`TxError`].
// The parameters are what building a transaction needs; grouping them into
// a struct would only move the list.
#[allow(clippy::too_many_arguments)]
pub async fn prepare_selected(
    backend: Backend<'_>,
    keys: &WalletKeys,
    network: Network,
    state: &SyncState,
    tip: u64,
    request: &Request,
    priority: Priority,
    selection: &Selection,
) -> Result<Prepared, TxError> {
    if keys.is_view_only() {
        return Err(TxError::ViewOnly);
    }
    let available = spendable_selected(state, tip, selection);
    let built = build(backend, keys, network, &available, tip, request, priority).await?;
    let linked = linked_addresses(&built.used);
    let mut prepared = finish(keys, built.signable, &built.used, built.amount)?;
    prepared.linked_addresses = linked;
    Ok(prepared)
}

/// A transaction built but not signed, for a cold wallet to sign.
pub struct Unsigned {
    /// monero-oxide's `SignableTransaction`, serialized.
    pub signable: Vec<u8>,
    /// Paid to others, atomic units.
    pub amount: u64,
    pub fee: u64,
    /// Returned to this wallet.
    pub change: u64,
    /// Recipients and what each receives, as requested.
    pub destinations: Vec<(String, u64)>,
    /// One-time keys of the outputs it spends.
    pub inputs: Vec<[u8; 32]>,
    /// See [`linked_addresses`].
    pub linked_addresses: usize,
}

/// Builds a transaction for `request` without signing it, so a view-only
/// wallet can hand it to the cold wallet that holds the spend key. Only
/// outputs whose key images the cold wallet has supplied are spent, so the
/// watching wallet never builds on coins it cannot tell are already spent.
///
/// # Errors
///
/// See [`TxError`].
pub async fn prepare_unsigned(
    backend: Backend<'_>,
    keys: &WalletKeys,
    network: Network,
    state: &SyncState,
    tip: u64,
    request: &Request,
    priority: Priority,
) -> Result<Unsigned, TxError> {
    let selection = Selection::default();
    prepare_unsigned_selected(
        backend, keys, network, state, tip, request, priority, &selection,
    )
    .await
}

/// [`prepare_unsigned`], spending only coins `selection` allows.
///
/// # Errors
///
/// See [`TxError`].
#[allow(clippy::too_many_arguments)]
pub async fn prepare_unsigned_selected(
    backend: Backend<'_>,
    keys: &WalletKeys,
    network: Network,
    state: &SyncState,
    tip: u64,
    request: &Request,
    priority: Priority,
    selection: &Selection,
) -> Result<Unsigned, TxError> {
    let available = spendable_selected(state, tip, selection);
    let built = build(backend, keys, network, &available, tip, request, priority).await?;
    let input_total = built
        .used
        .iter()
        .fold(0u64, |sum, o| sum.saturating_add(o.amount()));
    let fee = built.signable.transaction.necessary_fee();
    Ok(Unsigned {
        amount: built.amount,
        fee,
        change: input_total.saturating_sub(built.amount.saturating_add(fee)),
        destinations: built
            .signable
            .payments
            .iter()
            .map(|(address, amount)| (address.to_string(), *amount))
            .collect(),
        inputs: built
            .used
            .iter()
            .map(|o| o.output.key().compress().to_bytes())
            .collect(),
        linked_addresses: linked_addresses(&built.used),
        signable: built.signable.transaction.serialize(),
    })
}

/// A transaction ready to sign and the outputs it spends.
struct Built<'a> {
    signable: Signable,
    used: Vec<&'a OwnedOutput>,
    amount: u64,
}

async fn build<'a>(
    backend: Backend<'_>,
    keys: &WalletKeys,
    network: Network,
    available: &'a [&'a OwnedOutput],
    tip: u64,
    request: &Request,
    priority: Priority,
) -> Result<Built<'a>, TxError> {
    let fee_rate = fee_rate(backend, keys, network, priority).await?;
    let total_available = available
        .iter()
        .fold(0u64, |sum, o| sum.saturating_add(o.amount()));
    // monero-oxide wants the number of the latest block (its index), while
    // `tip` counts blocks.
    let block_number = usize::try_from(tip.saturating_sub(1))
        .map_err(|_| TxError::Build("height out of range".into()))?;

    let ctx = Context {
        backend,
        keys,
        fee_rate,
        block_number,
        available,
        total_available,
    };
    match request {
        Request::Pay(payments) => pay(&ctx, parse_payments(payments, network)?).await,
        Request::SweepAll(address) => sweep(&ctx, &parse_address(address, network)?).await,
    }
}

/// What building a transaction needs, shared by paying and sweeping.
struct Context<'a, 'o> {
    backend: Backend<'a>,
    keys: &'a WalletKeys,
    fee_rate: FeeRate,
    block_number: usize,
    /// Spendable outputs, largest first.
    available: &'o [&'o OwnedOutput],
    total_available: u64,
}

/// Pays `payments`: enough of the largest outputs for the amount, then one
/// more at a time until the fee is covered too.
async fn pay<'o>(
    ctx: &Context<'_, 'o>,
    payments: Vec<(MoneroAddress, u64)>,
) -> Result<Built<'o>, TxError> {
    let wanted = payments
        .iter()
        .try_fold(0u64, |sum, (_, amount)| sum.checked_add(*amount))
        .ok_or(TxError::InsufficientFunds {
            available: ctx.total_available,
            needed: u64::MAX,
        })?;
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
            Ok(signable) => {
                return Ok(Built {
                    signable,
                    used: ctx.available[..used].to_vec(),
                    amount: wanted,
                });
            }
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
async fn sweep<'o>(ctx: &Context<'_, 'o>, address: &MoneroAddress) -> Result<Built<'o>, TxError> {
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
            Ok(signable) => {
                return Ok(Built {
                    signable,
                    used: ctx.available.to_vec(),
                    amount,
                });
            }
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
    broadcast(backend, &prepared.transaction).await?;
    state.mark_pending(&prepared.spends, prepared.hash, tip);
    Ok(())
}

/// Publishes a transaction a cold wallet signed, after checking it spends
/// only this wallet's unspent outputs. Its inputs count as spent at once.
///
/// # Errors
///
/// [`TxError::Build`] if it spends anything else, otherwise as [`publish`].
pub async fn publish_signed(
    backend: Backend<'_>,
    signed: &cold::Signed,
    state: &mut SyncState,
    tip: u64,
) -> Result<(), TxError> {
    cold::check_signed(state, signed)?;
    broadcast(backend, &signed.transaction).await?;
    state.mark_pending(&signed.spends(), signed.hash, tip);
    Ok(())
}

async fn broadcast(backend: Backend<'_>, transaction: &Transaction) -> Result<(), TxError> {
    match backend {
        Backend::Node(daemon) => {
            daemon
                .publish_transaction(transaction)
                .await
                .map_err(|e| match e {
                    monero_interface::PublishTransactionError::TransactionRejected(why) => {
                        TxError::Rejected(why)
                    }
                    other @ monero_interface::PublishTransactionError::InterfaceError(_) => {
                        TxError::Node(other.to_string())
                    }
                })
        }
        Backend::Lws(server) => server
            .submit(&transaction.serialize())
            .await
            .map_err(|e| TxError::Rejected(e.to_string())),
    }
}

async fn fee_rate(
    backend: Backend<'_>,
    keys: &WalletKeys,
    network: Network,
    priority: Priority,
) -> Result<FeeRate, TxError> {
    match backend {
        Backend::Node(daemon) => daemon
            .fee_rate(priority.into(), MAX_FEE_PER_WEIGHT)
            .await
            .map_err(|e| match e {
                monero_interface::FeeError::InvalidFee => TxError::FeeTooHigh,
                other => TxError::Node(other.to_string()),
            }),
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
            let per_weight = fees.per_priority[index];
            if per_weight > MAX_FEE_PER_WEIGHT || fees.mask > MAX_FEE_MASK {
                return Err(TxError::FeeTooHigh);
            }
            FeeRate::new(per_weight, fees.mask)
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

async fn with_decoys(
    ctx: &Context<'_, '_>,
    output: &OwnedOutput,
) -> Result<OutputWithDecoys, TxError> {
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

/// A transaction ready to sign, with the secret keys monero-oxide will
/// derive for it.
struct Signable {
    transaction: SignableTransaction,
    payments: Vec<(MoneroAddress, u64)>,
    /// The main transaction key, then candidates for additional keys (one
    /// per output, in output order, when the transaction has them).
    key_candidates: Vec<Zeroizing<Scalar>>,
}

fn signable(
    keys: &WalletKeys,
    inputs: Vec<OutputWithDecoys>,
    payments: Vec<(MoneroAddress, u64)>,
    fee_rate: FeeRate,
) -> Result<Signable, SendError> {
    // Seeds the transaction's internal randomness; fresh per transaction, as
    // monero-oxide requires.
    let mut outgoing_view_key = Zeroizing::new([0u8; 32]);
    OsRng.fill_bytes(outgoing_view_key.as_mut());
    // monero-oxide draws the transaction keys from this seed and the inputs,
    // in this order: main key first, then one per output.
    let input_keys = inputs
        .iter()
        .map(|o| (o.key(), o.commitment().commit()))
        .collect();
    let key_candidates = TransactionKeys::new(&outgoing_view_key, input_keys)
        .take(payments.len() + 2)
        .collect();
    let transaction = SignableTransaction::new(
        RctType::ClsagBulletproofPlus,
        outgoing_view_key,
        inputs,
        payments.clone(),
        Change::new(keys.view_pair(), None),
        Vec::new(),
        fee_rate,
    )?;
    Ok(Signable {
        transaction,
        payments,
        key_candidates,
    })
}

/// The transaction key string for `transaction`, if the candidates produce
/// exactly the public keys in its extra field.
pub(crate) fn confirmed_tx_key(
    transaction: &Transaction,
    payments: &[(MoneroAddress, u64)],
    candidates: &[Zeroizing<Scalar>],
) -> Option<Zeroizing<String>> {
    use curve25519_dalek::constants::ED25519_BASEPOINT_TABLE;
    use curve25519_dalek::{EdwardsPoint, Scalar as DalekScalar};

    let extra = Extra::read(&mut transaction.prefix().extra.as_slice()).ok()?;
    let (main, additional) = extra.keys()?;
    let additional = additional.unwrap_or_default();
    let used = candidates.get(..=additional.len())?;
    // Each public key is the secret times G, or times the spend key of the
    // subaddress it pays.
    let opens = |secret: &Zeroizing<Scalar>, public: &Point| {
        let secret: DalekScalar = (**secret).into();
        let public: EdwardsPoint = (*public).into();
        &secret * ED25519_BASEPOINT_TABLE == public
            || payments
                .iter()
                .any(|(address, _)| secret * address.spend().into() == public)
    };
    if !opens(&used[0], main.first()?) {
        return None;
    }
    for public in &additional {
        if !used[1..].iter().any(|secret| opens(secret, public)) {
            return None;
        }
    }
    let mut out = Zeroizing::new(String::with_capacity(64 * used.len()));
    for secret in used {
        out.push_str(&hex::encode(<[u8; 32]>::from(**secret)));
    }
    Some(out)
}

fn finish(
    keys: &WalletKeys,
    signable: Signable,
    inputs: &[&OwnedOutput],
    amount: u64,
) -> Result<Prepared, TxError> {
    let Signable {
        transaction: signable,
        payments,
        key_candidates,
    } = signable;
    let fee = signable.necessary_fee();
    let input_total = inputs
        .iter()
        .fold(0u64, |sum, o| sum.saturating_add(o.amount()));
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
    let tx_key = confirmed_tx_key(&transaction, &payments, &key_candidates);
    Ok(Prepared {
        hash: transaction.hash(),
        amount,
        fee,
        change: input_total.saturating_sub(amount.saturating_add(fee)),
        spends,
        destinations: payments
            .iter()
            .map(|(address, amount)| (address.to_string(), *amount))
            .collect(),
        tx_key,
        linked_addresses: 1,
        transaction,
    })
}
