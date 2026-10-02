//! Scanning blocks from a node into a wallet's [`SyncState`].

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};

use kn_keys::WalletKeys;
use monero_daemon_rpc::MoneroDaemon;
use monero_interface::{
    ProvidesBlockchain as _, ProvidesBlockchainMeta as _, ProvidesScannableBlocks as _,
    ScannableBlock,
};
use monero_wallet::{Scanner, address::SubaddressIndex, transaction::Input};

use crate::{
    SyncError,
    node::Http,
    state::{OwnedOutput, Spend, SyncState},
};

/// Blocks fetched per request. Small enough that progress moves and a
/// cancel is noticed quickly, large enough to keep request overhead low.
const BATCH: u64 = 50;

/// Subaddresses watched beyond the highest one handed out, so payments to
/// addresses created on another device are still found.
pub const SUBADDRESS_LOOKAHEAD: u32 = 50;

/// Where a sync is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Progress {
    /// Next block to scan.
    pub scanned: u64,
    /// Number of blocks the node has.
    pub tip: u64,
}

/// Scans `daemon`'s chain from `state.next_height` to its tip.
///
/// `accounts[i]` is how many subaddresses account `i` has handed out; each
/// is watched with [`SUBADDRESS_LOOKAHEAD`] more. `progress` is called after
/// every batch. Setting `cancel` stops after the current batch; the state is
/// consistent at every batch boundary.
///
/// # Errors
///
/// [`SyncError::Cancelled`] if cancelled, otherwise node errors. `state`
/// keeps everything scanned before the error.
pub async fn sync(
    daemon: &MoneroDaemon<Http>,
    keys: &WalletKeys,
    accounts: &[u32],
    state: &mut SyncState,
    cancel: &AtomicBool,
    mut progress: impl FnMut(Progress),
) -> Result<(), SyncError> {
    let mut scanner = Scanner::new(keys.view_pair());
    for (account, handed_out) in accounts.iter().enumerate() {
        let account =
            u32::try_from(account).map_err(|_| SyncError::Node("too many accounts".into()))?;
        for index in 0..handed_out.saturating_add(SUBADDRESS_LOOKAHEAD) {
            if let Some(sub) = SubaddressIndex::new(account, index) {
                scanner.register_subaddress(sub);
            }
        }
    }

    let mut owned = key_image_index(state);

    loop {
        if cancel.load(Ordering::Relaxed) {
            return Err(SyncError::Cancelled);
        }
        let tip = to_u64(daemon.latest_block_number().await?)? + 1;
        if rewind_if_reorganized(daemon, state).await? {
            owned = key_image_index(state);
        }
        progress(Progress {
            scanned: state.next_height,
            tip,
        });
        if state.next_height >= tip {
            return Ok(());
        }
        let end = (state.next_height + BATCH).min(tip) - 1;
        let blocks = daemon
            .contiguous_scannable_blocks(to_usize(state.next_height)?..=to_usize(end)?)
            .await?;
        for block in blocks {
            let height = state.next_height;
            scan_block(&mut scanner, keys, state, &mut owned, height, block)?;
        }
    }
}

fn scan_block(
    scanner: &mut Scanner,
    keys: &WalletKeys,
    state: &mut SyncState,
    owned: &mut HashMap<[u8; 32], usize>,
    height: u64,
    block: ScannableBlock,
) -> Result<(), SyncError> {
    let hash = block.block.hash();
    let miner_tx = block.block.miner_transaction().hash();

    // Spends first: an input in this block can only spend an output from an
    // earlier block.
    // Pruned transactions do not carry their hash; the block lists the
    // hashes in the same order.
    for (tx, tx_hash) in block.transactions.iter().zip(&block.block.transactions) {
        for input in &tx.prefix().inputs {
            if let Input::ToKey { key_image, .. } = input
                && let Some(&i) = owned.get(&key_image.to_bytes())
            {
                state.outputs[i].spent = Some(Spend {
                    tx: *tx_hash,
                    height,
                });
            }
        }
    }

    let found = scanner
        .scan(block)
        .map_err(|e| SyncError::Node(format!("block {height} could not be scanned: {e}")))?;
    // Additionally timelocked outputs are kept and shown; spending rules for
    // them come with sending.
    for output in found.ignore_additional_timelock() {
        let key_image = keys.key_image(output.key(), output.key_offset());
        if let Some(ki) = key_image {
            owned.insert(ki, state.outputs.len());
        }
        state.outputs.push(OwnedOutput {
            miner: output.transaction() == miner_tx,
            output,
            height,
            key_image,
            spent: None,
        });
    }
    state.record_block(height, hash);
    Ok(())
}

/// Compares the newest remembered block with the node's chain and rewinds
/// to the last common block if they differ. Returns whether it rewound.
async fn rewind_if_reorganized(
    daemon: &MoneroDaemon<Http>,
    state: &mut SyncState,
) -> Result<bool, SyncError> {
    let mut rewound = false;
    while let Some(&(height, hash)) = state.recent.back() {
        if daemon.block_hash(to_usize(height)?).await? == hash {
            break;
        }
        state.rewind_to(height);
        rewound = true;
    }
    Ok(rewound)
}

/// Owned outputs by key image, pointing into `state.outputs`.
fn key_image_index(state: &SyncState) -> HashMap<[u8; 32], usize> {
    state
        .outputs
        .iter()
        .enumerate()
        .filter_map(|(i, o)| o.key_image.map(|ki| (ki, i)))
        .collect()
}

fn to_u64(n: usize) -> Result<u64, SyncError> {
    u64::try_from(n).map_err(|_| SyncError::Node("height out of range".into()))
}

fn to_usize(n: u64) -> Result<usize, SyncError> {
    usize::try_from(n).map_err(|_| SyncError::Node("height out of range".into()))
}
