//! Scanning blocks from a node into a wallet's [`SyncState`].

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};

use kn_keys::WalletKeys;
use monero_daemon_rpc::MoneroDaemon;
use monero_interface::{
    ProvidesBlockchain as _, ProvidesBlockchainMeta as _, ProvidesScannableBlocks as _,
    ProvidesTransactions as _, ScannableBlock,
};
use monero_wallet::{Scanner, address::SubaddressIndex, transaction::Input};

use crate::{
    SyncError,
    node::Http,
    state::{OwnedOutput, PoolPayment, Spend, SyncState},
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
/// is watched with [`SUBADDRESS_LOOKAHEAD`] more. `on_batch` is called with
/// the state after every batch, which is the moment to save it. Setting
/// `cancel` stops after the current batch; the state is consistent at every
/// batch boundary.
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
    mut on_batch: impl FnMut(&SyncState, Progress),
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
    let mut by_output_key = output_key_index(state);

    loop {
        if cancel.load(Ordering::Relaxed) {
            return Err(SyncError::Cancelled);
        }
        let tip = to_u64(daemon.latest_block_number().await?)? + 1;
        if rewind_if_reorganized(daemon, state).await? {
            owned = key_image_index(state);
            by_output_key = output_key_index(state);
        }
        on_batch(
            state,
            Progress {
                scanned: state.next_height,
                tip,
            },
        );
        if state.next_height >= tip {
            state.expire_pending(tip);
            // The pool is a convenience: a node that will not show it does
            // not stop sync.
            let _ = scan_pool(daemon, &mut scanner, state, &owned, tip).await;
            return Ok(());
        }
        let end = (state.next_height + BATCH).min(tip) - 1;
        let blocks = daemon
            .contiguous_scannable_blocks(to_usize(state.next_height)?..=to_usize(end)?)
            .await?;
        for block in blocks {
            let height = state.next_height;
            scan_block(
                &mut scanner,
                keys,
                state,
                &mut owned,
                &mut by_output_key,
                height,
                block,
            )?;
        }
    }
}

fn scan_block(
    scanner: &mut Scanner,
    keys: &WalletKeys,
    state: &mut SyncState,
    owned: &mut HashMap<[u8; 32], usize>,
    by_output_key: &mut HashMap<[u8; 32], usize>,
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
                    pending: false,
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
        let key_image = keys
            .key_image(output.key(), output.key_offset())
            .or_else(|| state.known_key_image(&output.key().compress().to_bytes()));
        let new = OwnedOutput {
            miner: output.transaction() == miner_tx,
            output,
            height,
            key_image,
            spent: None,
        };
        // Two outputs with the same one-time key share one key image, so
        // only one of them can ever be spent (the "burning bug"). Keep the
        // larger, as Monero's own wallet does, so the balance never counts
        // money that cannot be spent.
        let key = new.output.key().compress().to_bytes();
        if let Some(&i) = by_output_key.get(&key) {
            let existing = &state.outputs[i];
            if existing.spent.is_none() && new.amount() > existing.amount() {
                state.outputs[i] = new;
            }
            continue;
        }
        if let Some(ki) = key_image {
            owned.insert(ki, state.outputs.len());
        }
        by_output_key.insert(key, state.outputs.len());
        state.outputs.push(new);
    }
    state.record_block(height, hash);
    Ok(())
}

/// Most pool transactions looked at per sync. Mainnet pools rarely hold
/// more; beyond this the wallet waits for the payment to be mined.
const POOL_LIMIT: usize = 500;

/// Records payments to this wallet in the node's transaction pool, and
/// marks outputs that pool transactions spend (sent from another device
/// with the same seed) as pending spends.
async fn scan_pool(
    daemon: &MoneroDaemon<Http>,
    scanner: &mut Scanner,
    state: &mut SyncState,
    owned: &HashMap<[u8; 32], usize>,
    tip: u64,
) -> Result<(), SyncError> {
    #[derive(serde::Deserialize)]
    struct Hashes {
        #[serde(default)]
        tx_hashes: Vec<String>,
    }
    let reply = daemon
        .rpc_call("get_transaction_pool_hashes", None, 1 << 20)
        .await?;
    let hashes: Vec<[u8; 32]> = serde_json::from_str::<Hashes>(&reply)
        .map_err(|e| SyncError::Node(format!("pool: {e}")))?
        .tx_hashes
        .iter()
        .filter_map(|h| hex::decode(h).ok()?.try_into().ok())
        .take(POOL_LIMIT)
        .collect();
    if hashes.is_empty() {
        state.pool.clear();
        return Ok(());
    }
    let transactions = daemon
        .pruned_transactions(&hashes)
        .await
        .map_err(|e| SyncError::Node(format!("pool: {e:?}")))?;
    for (tx, hash) in transactions.iter().zip(&hashes) {
        let spent: Vec<[u8; 32]> = tx
            .prefix()
            .inputs
            .iter()
            .filter_map(|input| match input {
                Input::ToKey { key_image, .. } => Some(key_image.to_bytes()),
                Input::Gen(_) => None,
            })
            .filter(|ki| owned.contains_key(ki))
            .collect();
        state.mark_pending(&spent, *hash, tip);
    }

    // The scanner only reads blocks, so the pool transactions ride in the
    // latest block in place of its own. Output positions on the chain are
    // unknown until mined, which is fine: these outputs are only shown.
    let mut carrier = daemon.scannable_block_by_number(to_usize(tip - 1)?).await?;
    carrier.block.transactions.clone_from(&hashes);
    carrier.transactions = transactions;
    carrier.output_index_for_first_ringct_output = Some(0);
    let found = scanner
        .scan(carrier)
        .map_err(|e| SyncError::Node(format!("pool could not be scanned: {e}")))?;

    let mut payments: Vec<PoolPayment> = Vec::new();
    for output in found.ignore_additional_timelock() {
        let tx = output.transaction();
        if !hashes.contains(&tx) {
            continue; // the carrier block's miner output
        }
        let index = output
            .subaddress()
            .map_or((0, 0), |s| (s.account(), s.address()));
        let amount = output.commitment().amount;
        let payment = if let Some(p) = payments.iter_mut().find(|p| p.tx == tx) {
            p
        } else {
            payments.push(PoolPayment {
                tx,
                amount: 0,
                subaddresses: Vec::new(),
                by_subaddress: Vec::new(),
            });
            payments.last_mut().expect("just pushed")
        };
        payment.amount = payment.amount.saturating_add(amount);
        if !payment.subaddresses.contains(&index) {
            payment.subaddresses.push(index);
        }
        match payment
            .by_subaddress
            .iter_mut()
            .find(|(at, _)| *at == index)
        {
            Some((_, sum)) => *sum = sum.saturating_add(amount),
            None => payment.by_subaddress.push((index, amount)),
        }
    }
    state.pool = payments;
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
fn output_key_index(state: &SyncState) -> HashMap<[u8; 32], usize> {
    state
        .outputs
        .iter()
        .enumerate()
        .map(|(i, o)| (o.output.key().compress().to_bytes(), i))
        .collect()
}

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
