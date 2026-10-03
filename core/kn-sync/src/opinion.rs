//! A second opinion on the node: a node that lies can feed a wallet a chain
//! of its own. Comparing one recent block with an independent node catches
//! that cheaply, without trusting either for anything else.

use kn_keys::Network;
use monero_daemon_rpc::MoneroDaemon;
use monero_interface::{ProvidesBlockchain as _, ProvidesBlockchainMeta as _};

use crate::SyncError;
use crate::node::{Http, NodeUrl, connect};

/// Blocks below the lower of the two tips that are compared, so normal
/// propagation delay and one-block reorganizations do not count.
pub const OPINION_DEPTH: usize = 10;

/// What comparing the wallet's node with an independent one found.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Opinion {
    /// Both nodes have the same block at the compared height.
    pub agrees: bool,
    /// Number of blocks each node has.
    pub ours: u64,
    pub theirs: u64,
}

/// Compares `ours` with the node at `reference` at a height both have.
///
/// # Errors
///
/// [`SyncError::Node`] if either node cannot answer; that is not a
/// disagreement.
pub async fn second_opinion(
    ours: &MoneroDaemon<Http>,
    reference: &NodeUrl,
    network: Network,
) -> Result<Opinion, SyncError> {
    let (theirs, _) = connect(reference, network).await?;
    let our_tip = ours.latest_block_number().await?;
    let their_tip = theirs.latest_block_number().await?;
    let Some(height) = our_tip.min(their_tip).checked_sub(OPINION_DEPTH) else {
        return Ok(Opinion {
            agrees: true,
            ours: u64::try_from(our_tip).unwrap_or(u64::MAX).saturating_add(1),
            theirs: u64::try_from(their_tip)
                .unwrap_or(u64::MAX)
                .saturating_add(1),
        });
    };
    let agrees = ours.block_hash(height).await? == theirs.block_hash(height).await?;
    Ok(Opinion {
        agrees,
        ours: u64::try_from(our_tip).unwrap_or(u64::MAX).saturating_add(1),
        theirs: u64::try_from(their_tip)
            .unwrap_or(u64::MAX)
            .saturating_add(1),
    })
}
