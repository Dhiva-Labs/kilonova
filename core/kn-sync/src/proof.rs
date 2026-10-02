//! Checking a payment proof: given a transaction, its secret key (as a
//! sender shares it) and an address, how much did that address receive?
//! The same question monero-wallet-rpc's `check_tx_key` answers, answered
//! here from a node, so a recipient can verify a payment without the
//! sender's wallet.

use curve25519_dalek::{EdwardsPoint, Scalar as DalekScalar, constants::ED25519_BASEPOINT_TABLE};
use kn_keys::Network;
use monero_daemon_rpc::MoneroDaemon;
use monero_interface::ProvidesBlockchainMeta as _;
use monero_wallet::address::{MoneroAddress, Network as MoneroNetwork};
use monero_wallet::ed25519::{Commitment, CompressedPoint, Scalar};
use monero_wallet::io::VarInt;
use monero_wallet::primitives::keccak256;
use monero_wallet::ringct::EncryptedAmount;
use monero_wallet::transaction::Transaction;
use serde::Deserialize;
use serde_json::json;

use crate::SyncError;
use crate::node::Http;

/// What a payment proof shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ProofResult {
    /// Atomic units the address received in the transaction.
    pub received: u64,
    /// Outputs of the transaction that went to the address.
    pub outputs: u32,
    /// Still in the transaction pool.
    pub in_pool: bool,
    /// Blocks on top of it, counting its own; zero while in the pool.
    pub confirmations: u64,
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum ProofError {
    #[error("not a valid address for this network")]
    BadAddress,
    #[error("not a transaction key")]
    BadKey,
    #[error("the node does not know this transaction")]
    UnknownTransaction,
    #[error("the transaction key does not belong to this transaction")]
    KeyMismatch,
    #[error("{0}")]
    Node(String),
}

impl From<SyncError> for ProofError {
    fn from(e: SyncError) -> Self {
        Self::Node(e.to_string())
    }
}

/// Checks a transaction key against `address` for transaction `tx_hash`.
///
/// `tx_key_hex` is the main key followed by any additional keys, 64 hex
/// characters each, as Kilonova and monero-wallet-rpc show it. Amounts are
/// only counted when they open the output's commitment, so a node cannot
/// make a proof show more than was paid.
///
/// # Errors
///
/// See [`ProofError`].
pub async fn check_tx_key(
    daemon: &MoneroDaemon<Http>,
    network: Network,
    tx_hash: [u8; 32],
    tx_key_hex: &str,
    address: &str,
) -> Result<ProofResult, ProofError> {
    let address = MoneroAddress::from_str(MoneroNetwork::from(network), address.trim())
        .map_err(|_| ProofError::BadAddress)?;
    let keys = parse_keys(tx_key_hex)?;
    let fetched = fetch(daemon, tx_hash).await?;
    let tip = daemon
        .latest_block_number()
        .await
        .map_err(|e| ProofError::Node(e.to_string()))?;
    let (received, outputs) = scan(&fetched.transaction, &keys, &address)?;
    let confirmations = match fetched.height {
        Some(h) if !fetched.in_pool => u64::try_from(tip).unwrap_or(u64::MAX).saturating_sub(h) + 1,
        _ => 0,
    };
    Ok(ProofResult {
        received,
        outputs,
        in_pool: fetched.in_pool,
        confirmations,
    })
}

fn parse_keys(hex_text: &str) -> Result<Vec<DalekScalar>, ProofError> {
    let text = hex_text.trim();
    if text.is_empty() || !text.len().is_multiple_of(64) {
        return Err(ProofError::BadKey);
    }
    text.as_bytes()
        .chunks(64)
        .map(|chunk| {
            let bytes: [u8; 32] = hex::decode(chunk)
                .map_err(|_| ProofError::BadKey)?
                .try_into()
                .map_err(|_| ProofError::BadKey)?;
            Option::<DalekScalar>::from(DalekScalar::from_canonical_bytes(bytes))
                .ok_or(ProofError::BadKey)
        })
        .collect()
}

pub(crate) struct Fetched {
    pub(crate) transaction: Transaction,
    pub(crate) height: Option<u64>,
    pub(crate) in_pool: bool,
}

pub(crate) async fn fetch(
    daemon: &MoneroDaemon<Http>,
    tx_hash: [u8; 32],
) -> Result<Fetched, ProofError> {
    #[derive(Deserialize)]
    struct Entry {
        as_hex: String,
        #[serde(default)]
        block_height: Option<u64>,
        #[serde(default)]
        in_pool: bool,
    }
    #[derive(Deserialize)]
    struct Reply {
        #[serde(default)]
        txs: Vec<Entry>,
    }
    let params = json!({"txs_hashes": [hex::encode(tx_hash)], "decode_as_json": false});
    let reply = daemon
        .rpc_call("get_transactions", Some(params.to_string()), 4 << 20)
        .await
        .map_err(|e| ProofError::Node(e.to_string()))?;
    let reply: Reply =
        serde_json::from_str(&reply).map_err(|e| ProofError::Node(format!("transactions: {e}")))?;
    let entry = reply
        .txs
        .into_iter()
        .next()
        .ok_or(ProofError::UnknownTransaction)?;
    let raw = hex::decode(&entry.as_hex).map_err(|_| ProofError::UnknownTransaction)?;
    let transaction =
        Transaction::read(&mut raw.as_slice()).map_err(|_| ProofError::UnknownTransaction)?;
    // The node must hand over the transaction that was asked for.
    if transaction.hash() != tx_hash {
        return Err(ProofError::Node(
            "the node returned a different transaction".into(),
        ));
    }
    Ok(Fetched {
        transaction,
        height: entry.block_height.filter(|_| !entry.in_pool),
        in_pool: entry.in_pool,
    })
}

/// Sums what `address` received, trying for output `i` the additional key
/// `i` if the transaction has them, else the main key.
fn scan(
    transaction: &Transaction,
    keys: &[DalekScalar],
    address: &MoneroAddress,
) -> Result<(u64, u32), ProofError> {
    let view: EdwardsPoint = address.view().into();
    let spend: EdwardsPoint = address.spend().into();
    let outputs = &transaction.prefix().outputs;
    let proofs = match transaction {
        Transaction::V2 {
            proofs: Some(p), ..
        } => Some(p),
        _ => None,
    };
    if keys.len() > 1 && keys.len() - 1 != outputs.len() {
        return Err(ProofError::KeyMismatch);
    }
    let mut received = 0u64;
    let mut count = 0u32;
    for (i, output) in outputs.iter().enumerate() {
        // Each output may use its own additional key or the main key; try
        // both, as wallet2 does.
        let candidates = [keys.get(i + 1).filter(|_| keys.len() > 1), Some(&keys[0])];
        let Some(shared) = candidates.into_iter().flatten().find_map(|key| {
            let derivation = (key * view).mul_by_cofactor().compress().to_bytes();
            let mut input = derivation.to_vec();
            VarInt::write(&i, &mut input).expect("writing to a Vec cannot fail");
            let shared = Scalar::hash(&input);
            let shared_dalek: DalekScalar = shared.into();
            let expected = &shared_dalek * ED25519_BASEPOINT_TABLE + spend;
            (output.key.to_bytes() == expected.compress().to_bytes()).then_some(shared)
        }) else {
            continue;
        };
        let amount = match (output.amount, proofs) {
            // Miner and pre-RingCT outputs carry their amount openly.
            (Some(amount), _) => Some(amount),
            (None, Some(p)) => decrypt(
                shared,
                p.base.encrypted_amounts.get(i),
                p.base.commitments.get(i).map(CompressedPoint::to_bytes),
            ),
            (None, None) => None,
        };
        if let Some(amount) = amount {
            received = received.saturating_add(amount);
            count += 1;
        }
    }
    Ok((received, count))
}

/// The amount of an output, if it opens the output's commitment.
fn decrypt(
    shared: Scalar,
    encrypted: Option<&EncryptedAmount>,
    commitment: Option<[u8; 32]>,
) -> Option<u64> {
    let commitment = commitment?;
    let shared_bytes = <[u8; 32]>::from(shared);
    let (mask, amount) = match encrypted? {
        EncryptedAmount::Compact { amount } => {
            let mut mask_input = b"commitment_mask".to_vec();
            mask_input.extend_from_slice(&shared_bytes);
            let mut amount_input = b"amount".to_vec();
            amount_input.extend_from_slice(&shared_bytes);
            let pad = keccak256(&amount_input);
            let mut pad8 = [0u8; 8];
            pad8.copy_from_slice(&pad[..8]);
            (
                Scalar::hash(&mask_input),
                u64::from_le_bytes(*amount) ^ u64::from_le_bytes(pad8),
            )
        }
        EncryptedAmount::Original { mask, amount } => {
            let mask_secret = Scalar::hash(shared_bytes);
            let amount_secret = Scalar::hash(<[u8; 32]>::from(mask_secret));
            let mask_secret: DalekScalar = mask_secret.into();
            let amount_secret: DalekScalar = amount_secret.into();
            let mask = DalekScalar::from_bytes_mod_order(*mask) - mask_secret;
            let amount = DalekScalar::from_bytes_mod_order(*amount) - amount_secret;
            let mut amount8 = [0u8; 8];
            amount8.copy_from_slice(&amount.to_bytes()[..8]);
            (Scalar::from(mask), u64::from_le_bytes(amount8))
        }
    };
    let opened = Commitment::new(mask, amount).commit().compress().to_bytes();
    (opened == commitment).then_some(amount)
}
