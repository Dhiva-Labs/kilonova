//! Cover lookups: whenever the wallet asks a node for one transaction (the
//! light wallet server cross-check, payment proofs), the request carries
//! [`LOOKUP_BATCH`] hashes, the real one at a uniformly random position and
//! the rest real transactions from blocks near it. The node sees a batch of
//! ordinary transactions from the same stretch of chain and cannot tell
//! which one the wallet cared about. Answers for the cover hashes are
//! dropped unread.

use std::collections::HashMap;
use std::ops::RangeInclusive;

use monero_daemon_rpc::MoneroDaemon;
use monero_interface::ProvidesBlockchainMeta as _;
use monero_wallet::transaction::Transaction;
use serde::Deserialize;
use serde_json::json;

use crate::ProofError;
use crate::node::Http;
use crate::random::{index, uniform};

/// Hashes in every lookup request: one real, the rest cover.
pub const LOOKUP_BATCH: usize = 8;

/// Blocks in the window cover hashes come from. The real transaction's
/// block sits at a random place in it, so its height does not stand out.
pub const COVER_WINDOW: u64 = 20;

/// Random draws per lookup before settling for fewer cover hashes, which
/// only happens on a chain with almost no transactions.
const MAX_DRAWS: usize = 256;

/// A transaction a node handed over, checked against the hash asked for.
#[derive(Clone, Debug)]
pub struct LookedUp {
    pub transaction: Transaction,
    /// Height of its block; `None` while in the pool.
    pub height: Option<u64>,
    pub in_pool: bool,
}

/// Looks up transactions with cover, caching the chain tip and the blocks
/// it read cover hashes from, so a run of lookups costs few extra requests.
/// Make one per run (a sync's cross-check, one proof check).
#[derive(Default)]
pub struct CoverLookups {
    tip: Option<u64>,
    blocks: HashMap<u64, Vec<[u8; 32]>>,
}

impl CoverLookups {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Fetches `tx` from `daemon` inside a batch of cover hashes. `height`
    /// is where the wallet believes it was mined, if it knows; cover then
    /// comes from around that height, otherwise from the latest blocks.
    ///
    /// # Errors
    ///
    /// [`ProofError::UnknownTransaction`] if the node does not have it,
    /// [`ProofError::Node`] if the node cannot be asked or hands over a
    /// different transaction.
    pub async fn fetch(
        &mut self,
        daemon: &MoneroDaemon<Http>,
        tx: [u8; 32],
        height: Option<u64>,
    ) -> Result<LookedUp, ProofError> {
        let mut batch = self.covers(daemon, tx, height).await?;
        let position = index(batch.len() + 1);
        batch.insert(position, tx);
        request(daemon, &batch, tx).await
    }

    async fn tip(&mut self, daemon: &MoneroDaemon<Http>) -> Result<u64, ProofError> {
        if let Some(tip) = self.tip {
            return Ok(tip);
        }
        let tip = daemon
            .latest_block_number()
            .await
            .map_err(|e| ProofError::Node(e.to_string()))?;
        let tip = u64::try_from(tip).map_err(|_| ProofError::Node("height out of range".into()))?;
        self.tip = Some(tip);
        Ok(tip)
    }

    /// Up to `LOOKUP_BATCH - 1` distinct transaction hashes, other than
    /// `real`, from random blocks of the window around `height`.
    async fn covers(
        &mut self,
        daemon: &MoneroDaemon<Http>,
        real: [u8; 32],
        height: Option<u64>,
    ) -> Result<Vec<[u8; 32]>, ProofError> {
        let tip = self.tip(daemon).await?;
        let window = window(height, tip, uniform(COVER_WINDOW));
        let mut chosen: Vec<[u8; 32]> = Vec::with_capacity(LOOKUP_BATCH);
        for _ in 0..MAX_DRAWS {
            if chosen.len() == LOOKUP_BATCH - 1 {
                break;
            }
            let at = window.start() + uniform(window.end() - window.start() + 1);
            let candidates: Vec<[u8; 32]> = self
                .block_transactions(daemon, at)
                .await?
                .iter()
                .filter(|h| **h != real && !chosen.contains(h))
                .copied()
                .collect();
            if !candidates.is_empty() {
                chosen.push(candidates[index(candidates.len())]);
            }
        }
        Ok(chosen)
    }

    /// The hashes of every transaction in block `height`, miner one
    /// included, read once per run.
    async fn block_transactions(
        &mut self,
        daemon: &MoneroDaemon<Http>,
        height: u64,
    ) -> Result<&[[u8; 32]], ProofError> {
        #[derive(Deserialize)]
        struct Block {
            #[serde(default)]
            miner_tx_hash: String,
            #[serde(default)]
            tx_hashes: Vec<String>,
        }
        if let std::collections::hash_map::Entry::Vacant(slot) = self.blocks.entry(height) {
            let raw = daemon
                .json_rpc_call(
                    "get_block",
                    Some(json!({"height": height}).to_string()),
                    1 << 20,
                )
                .await
                .map_err(|e| ProofError::Node(e.to_string()))?;
            let block: Block =
                serde_json::from_str(&raw).map_err(|e| ProofError::Node(format!("block: {e}")))?;
            let hashes = std::iter::once(&block.miner_tx_hash)
                .chain(&block.tx_hashes)
                .filter_map(|h| hex::decode(h).ok()?.try_into().ok())
                .collect();
            slot.insert(hashes);
        }
        Ok(&self.blocks[&height])
    }
}

/// [`COVER_WINDOW`] blocks containing `height`, which sits `offset` blocks
/// from the start (shifted to stay inside the chain), or the latest blocks
/// when the height is unknown or beyond the tip.
fn window(height: Option<u64>, tip: u64, offset: u64) -> RangeInclusive<u64> {
    let last_blocks = tip.saturating_sub(COVER_WINDOW - 1)..=tip;
    let Some(height) = height.filter(|h| *h <= tip) else {
        return last_blocks;
    };
    let start = height.saturating_sub(offset);
    let end = start + COVER_WINDOW - 1;
    if end > tip { last_blocks } else { start..=end }
}

/// Asks for `batch` and returns only `wanted`; every other answer is
/// dropped without being parsed.
async fn request(
    daemon: &MoneroDaemon<Http>,
    batch: &[[u8; 32]],
    wanted: [u8; 32],
) -> Result<LookedUp, ProofError> {
    #[derive(Deserialize)]
    struct Entry {
        #[serde(default)]
        tx_hash: Option<String>,
        #[serde(default)]
        as_hex: String,
        // monerod sends some transactions (miner ones among them) split
        // in two with `as_hex` empty; together they are the whole blob.
        #[serde(default)]
        pruned_as_hex: String,
        #[serde(default)]
        prunable_as_hex: String,
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
    let hashes: Vec<String> = batch.iter().map(hex::encode).collect();
    let params = json!({"txs_hashes": hashes, "decode_as_json": false});
    let reply = daemon
        .rpc_call(
            "get_transactions",
            Some(params.to_string()),
            LOOKUP_BATCH << 20,
        )
        .await
        .map_err(|e| ProofError::Node(e.to_string()))?;
    let reply: Reply =
        serde_json::from_str(&reply).map_err(|e| ProofError::Node(format!("transactions: {e}")))?;
    let wanted_hex = hex::encode(wanted);
    for entry in reply.txs {
        let claimed = match entry.tx_hash.as_deref() {
            Some(h) if h.eq_ignore_ascii_case(&wanted_hex) => true,
            // A cover answer: dropped.
            Some(_) => continue,
            // monerod always names each answer; one that does not is
            // only used if it hashes to the wanted transaction.
            None => false,
        };
        let blob = if entry.as_hex.is_empty() {
            format!("{}{}", entry.pruned_as_hex, entry.prunable_as_hex)
        } else {
            entry.as_hex
        };
        let parsed = hex::decode(&blob)
            .ok()
            .and_then(|raw| Transaction::read(&mut raw.as_slice()).ok());
        match parsed {
            Some(transaction) if transaction.hash() == wanted => {
                return Ok(LookedUp {
                    transaction,
                    height: entry.block_height.filter(|_| !entry.in_pool),
                    in_pool: entry.in_pool,
                });
            }
            // The node must hand over the transaction that was asked for.
            Some(_) if claimed => {
                return Err(ProofError::Node(
                    "the node returned a different transaction".into(),
                ));
            }
            None if claimed => return Err(ProofError::UnknownTransaction),
            _ => {}
        }
    }
    Err(ProofError::UnknownTransaction)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_window_holds_the_height_wherever_it_sits() {
        for offset in 0..COVER_WINDOW {
            let w = window(Some(500), 10_000, offset);
            assert!(w.contains(&500));
            assert_eq!(w.end() - w.start() + 1, COVER_WINDOW);
            assert_eq!(500 - w.start(), offset);
        }
        // Near the tip, unknown or beyond it: the latest blocks.
        assert_eq!(window(Some(9_995), 10_000, 0), 9_981..=10_000);
        assert_eq!(window(None, 10_000, 3), 9_981..=10_000);
        assert_eq!(window(Some(20_000), 10_000, 3), 9_981..=10_000);
        // Near genesis.
        assert_eq!(window(Some(2), 10_000, 7), 0..=19);
        assert_eq!(window(None, 5, 0), 0..=5);
    }
}
