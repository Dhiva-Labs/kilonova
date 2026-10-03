//! Checking a payment proof someone sent: a transaction id, its transaction
//! key and the address it paid. Asks the selected node of that network,
//! through the proxy if one is set.
//!
//! Arguments are owned because `flutter_rust_bridge` hands them over that way.
#![allow(clippy::needless_pass_by_value)]

use kn_sync::{Circuit, ProofError, Purpose, check_tx_key, connect};

use super::network::Network;
use super::nodes::{RUNTIME, current_node};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProofFailure {
    BadAddress,
    BadTransactionId,
    BadKey,
    UnknownTransaction,
    KeyMismatch,
    Unreachable,
}

impl From<ProofError> for ProofFailure {
    fn from(e: ProofError) -> Self {
        match e {
            ProofError::BadAddress => Self::BadAddress,
            ProofError::BadKey => Self::BadKey,
            ProofError::UnknownTransaction => Self::UnknownTransaction,
            ProofError::KeyMismatch => Self::KeyMismatch,
            ProofError::Node(_) => Self::Unreachable,
        }
    }
}

/// What a checked proof shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PaymentCheck {
    /// Atomic units the address received.
    pub received: u64,
    pub outputs: u32,
    pub in_pool: bool,
    pub confirmations: u64,
}

/// Checks that `address` received a payment in transaction `tx_id`, using
/// the transaction key the sender shared.
///
/// # Errors
///
/// See [`ProofFailure`].
pub fn check_payment(
    network: Network,
    tx_id: String,
    tx_key: String,
    address: String,
) -> Result<PaymentCheck, ProofFailure> {
    let hash: [u8; 32] = hex::decode(tx_id.trim())
        .ok()
        .and_then(|b| b.try_into().ok())
        .ok_or(ProofFailure::BadTransactionId)?;
    let node = current_node(network).map_err(|_| ProofFailure::Unreachable)?;
    let result = RUNTIME.block_on(async {
        let (daemon, _) = connect(&node, network.into(), &Circuit::app(Purpose::Proof))
            .await
            .map_err(|_| ProofFailure::Unreachable)?;
        Ok::<_, ProofFailure>(check_tx_key(&daemon, network.into(), hash, &tx_key, &address).await?)
    })?;
    Ok(PaymentCheck {
        received: result.received,
        outputs: result.outputs,
        in_pool: result.in_pool,
        confirmations: result.confirmations,
    })
}
