//! Confirming a light wallet server's payments with a node. The server
//! holds the view key and could report a payment that never happened; the
//! wallet already checks each output opens with its own keys, but the
//! output's key and commitment come from the server too. Fetching the
//! transaction from an independent node and comparing closes that gap.
//!
//! Each lookup goes out in a batch of real transactions from around the
//! same height (`cover.rs`), so the node cannot tell which one the wallet
//! asked about. On by default; best over Tor.

use monero_daemon_rpc::MoneroDaemon;

use crate::cover::CoverLookups;
use crate::node::Http;
use crate::state::{OwnedOutput, SyncState};
use crate::{ProofError, SyncError};

/// Most transactions looked up per sync, so a wallet with a long history
/// catches up over several syncs instead of in one burst.
pub const CROSS_CHECK_LIMIT: usize = 25;

/// What one round of confirming found.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CrossCheck {
    /// Transactions newly confirmed by the node.
    pub confirmed: u32,
    /// Transactions the node contradicts: missing, or with different
    /// outputs. Their outputs are dropped from the wallet.
    pub contradicted: u32,
    /// Transactions still waiting to be looked up.
    pub remaining: u32,
}

/// Looks up transactions whose payments are not yet confirmed and records
/// the verdicts in `state`; outputs the node contradicts are removed.
///
/// # Errors
///
/// [`SyncError::Node`] if the node cannot be asked; nothing is recorded
/// for transactions not reached.
pub async fn cross_check(
    daemon: &MoneroDaemon<Http>,
    state: &mut SyncState,
) -> Result<CrossCheck, SyncError> {
    let mut pending: Vec<[u8; 32]> = Vec::new();
    for o in &state.outputs {
        let tx = o.output.transaction();
        if state.cross_check_verdict(&tx).is_none() && !pending.contains(&tx) {
            pending.push(tx);
        }
    }
    let mut report = CrossCheck {
        remaining: u32::try_from(pending.len().saturating_sub(CROSS_CHECK_LIMIT))
            .unwrap_or(u32::MAX),
        ..CrossCheck::default()
    };
    let mut lookups = CoverLookups::new();
    for tx in pending.into_iter().take(CROSS_CHECK_LIMIT) {
        let ours: Vec<&OwnedOutput> = state
            .outputs
            .iter()
            .filter(|o| o.output.transaction() == tx)
            .collect();
        let height = ours.first().map(|o| o.height);
        let agrees = match lookups.fetch(daemon, tx, height).await {
            Ok(fetched) => ours.iter().all(|o| matches(&fetched.transaction, o)),
            Err(ProofError::UnknownTransaction) => false,
            Err(e) => return Err(SyncError::Node(e.to_string())),
        };
        state.record_cross_check(tx, agrees);
        if agrees {
            report.confirmed += 1;
        } else {
            report.contradicted += 1;
        }
    }
    state.drop_contradicted();
    Ok(report)
}

/// Whether the transaction on chain has this output: same one-time key at
/// the same position, and the same amount (open for miner outputs, the same
/// commitment for `RingCT` ones).
fn matches(transaction: &monero_wallet::transaction::Transaction, ours: &OwnedOutput) -> bool {
    let Ok(index) = usize::try_from(ours.output.index_in_transaction()) else {
        return false;
    };
    let Some(output) = transaction.prefix().outputs.get(index) else {
        return false;
    };
    if output.key.to_bytes() != ours.output.key().compress().to_bytes() {
        return false;
    }
    match (output.amount, transaction) {
        (Some(amount), _) => amount == ours.amount(),
        (
            None,
            monero_wallet::transaction::Transaction::V2 {
                proofs: Some(proofs),
                ..
            },
        ) => proofs.base.commitments.get(index).is_some_and(|c| {
            c.to_bytes() == ours.output.commitment().commit().compress().to_bytes()
        }),
        _ => false,
    }
}
