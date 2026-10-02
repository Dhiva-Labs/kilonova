//! What a wallet knows about the chain: which outputs it owns, which of
//! those are spent, and how far it has scanned. Serialized into the
//! wallet's encrypted cache file.

use std::collections::{BTreeMap, VecDeque};

use monero_wallet::WalletOutput;
use serde::{Deserialize, Serialize};

/// Blocks a regular output waits before it can be spent.
pub const DEFAULT_LOCK_BLOCKS: u64 = 10;
/// Blocks a miner (coinbase) output waits before it can be spent.
pub const MINER_LOCK_BLOCKS: u64 = 60;
/// Block hashes kept for detecting reorganizations. Monero reorgs deeper
/// than this have not happened outside attacks.
const RECENT_BLOCKS: usize = 100;

/// An output this wallet received.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OwnedOutput {
    #[serde(with = "wallet_output_hex")]
    pub output: WalletOutput,
    /// Height of the block that contains it.
    pub height: u64,
    pub miner: bool,
    /// `None` for view-only wallets.
    #[serde(with = "opt_hex32")]
    pub key_image: Option<[u8; 32]>,
    pub spent: Option<Spend>,
}

impl OwnedOutput {
    #[must_use]
    pub fn amount(&self) -> u64 {
        self.output.commitment().amount
    }

    /// First height at which the output can be spent.
    #[must_use]
    pub fn unlock_height(&self) -> u64 {
        self.height.saturating_add(if self.miner {
            MINER_LOCK_BLOCKS
        } else {
            DEFAULT_LOCK_BLOCKS
        })
    }
}

/// Where an owned output was spent.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Spend {
    #[serde(with = "hex32")]
    pub tx: [u8; 32],
    /// Block height of the spend; for a pending spend, the height when it
    /// was sent.
    pub height: u64,
    /// Sent from this wallet but not yet seen in a block.
    #[serde(default)]
    pub pending: bool,
}

/// Blocks a sent transaction may stay unconfirmed before its inputs are
/// counted as unspent again. A transaction that has not been mined after
/// an hour has almost certainly been dropped.
pub const PENDING_EXPIRY_BLOCKS: u64 = 30;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Balance {
    /// Everything not known to be spent, in atomic units.
    pub total: u64,
    /// The part that can be spent now.
    pub unlocked: u64,
    /// Incoming in the transaction pool, not part of `total` until mined.
    pub incoming: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Direction {
    Incoming,
    Outgoing,
}

/// One transaction as the wallet sees it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HistoryEntry {
    pub tx: [u8; 32],
    pub height: u64,
    pub direction: Direction,
    /// Received amount for incoming; amount that left the wallet (spent
    /// minus change returned to it) for outgoing. Atomic units.
    pub amount: u64,
    /// Not yet in a block: sent from this wallet, or an incoming payment
    /// seen in the transaction pool.
    pub pending: bool,
    /// Account/index pairs that received funds in this transaction.
    pub subaddresses: Vec<(u32, u32)>,
    pub miner: bool,
}

/// A payment to this wallet seen in the node's transaction pool, not yet in
/// a block. Shown, never spent or counted as balance.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PoolPayment {
    #[serde(with = "hex32")]
    pub tx: [u8; 32],
    /// Atomic units.
    pub amount: u64,
    /// Account/index pairs that receive it.
    pub subaddresses: Vec<(u32, u32)>,
}

/// Everything sync has learned about one wallet.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncState {
    /// Next block to scan.
    pub next_height: u64,
    /// `(height, hash)` of the most recently scanned blocks, oldest first.
    #[serde(with = "recent_hex")]
    pub recent: VecDeque<(u64, [u8; 32])>,
    pub outputs: Vec<OwnedOutput>,
    /// Payments waiting in the transaction pool, as of the last sync.
    #[serde(default)]
    pub pool: Vec<PoolPayment>,
}

impl SyncState {
    /// A wallet that starts scanning at `height`.
    #[must_use]
    pub fn starting_at(height: u64) -> Self {
        Self {
            next_height: height,
            ..Self::default()
        }
    }

    pub(crate) fn record_block(&mut self, height: u64, hash: [u8; 32]) {
        self.recent.push_back((height, hash));
        while self.recent.len() > RECENT_BLOCKS {
            self.recent.pop_front();
        }
        self.next_height = height + 1;
    }

    /// Forgets everything from `height` on, after a reorganization.
    pub(crate) fn rewind_to(&mut self, height: u64) {
        self.outputs.retain(|o| o.height < height);
        for output in &mut self.outputs {
            if output.spent.is_some_and(|s| s.height >= height) {
                output.spent = None;
            }
        }
        self.recent.retain(|(h, _)| *h < height);
        self.next_height = height;
    }

    /// Marks the outputs with these key images as spent by `tx`, which was
    /// just sent and is not in a block yet.
    pub fn mark_pending(&mut self, key_images: &[[u8; 32]], tx: [u8; 32], tip: u64) {
        for o in &mut self.outputs {
            if o.spent.is_none() && o.key_image.is_some_and(|ki| key_images.contains(&ki)) {
                o.spent = Some(Spend {
                    tx,
                    height: tip,
                    pending: true,
                });
            }
        }
    }

    /// Counts outputs as unspent again if the transaction that was to spend
    /// them has stayed unconfirmed for [`PENDING_EXPIRY_BLOCKS`].
    pub fn expire_pending(&mut self, tip: u64) {
        for o in &mut self.outputs {
            if o.spent
                .is_some_and(|s| s.pending && tip > s.height + PENDING_EXPIRY_BLOCKS)
            {
                o.spent = None;
            }
        }
    }

    /// Pending spends by key image, to carry across a rebuild of the output
    /// list (LWS mode replaces it on every sync).
    pub(crate) fn pending_spends(&self) -> Vec<([u8; 32], Spend)> {
        self.outputs
            .iter()
            .filter_map(|o| match (o.key_image, o.spent) {
                (Some(ki), Some(s)) if s.pending => Some((ki, s)),
                _ => None,
            })
            .collect()
    }

    /// Balance as of chain height `tip` (the number of blocks).
    #[must_use]
    pub fn balance(&self, tip: u64) -> Balance {
        let mut balance = Balance::default();
        for o in self.outputs.iter().filter(|o| o.spent.is_none()) {
            balance.total += o.amount();
            if tip >= o.unlock_height() {
                balance.unlocked += o.amount();
            }
        }
        balance.incoming = self.pool.iter().map(|p| p.amount).sum();
        balance
    }

    /// Transactions, newest first.
    #[must_use]
    pub fn history(&self) -> Vec<HistoryEntry> {
        // Received per transaction.
        let mut received: BTreeMap<[u8; 32], HistoryEntry> = BTreeMap::new();
        for o in &self.outputs {
            let entry = received
                .entry(o.output.transaction())
                .or_insert_with(|| HistoryEntry {
                    tx: o.output.transaction(),
                    height: o.height,
                    direction: Direction::Incoming,
                    amount: 0,
                    pending: false,
                    subaddresses: Vec::new(),
                    miner: o.miner,
                });
            entry.amount += o.amount();
            let index = o
                .output
                .subaddress()
                .map_or((0, 0), |s| (s.account(), s.address()));
            if !entry.subaddresses.contains(&index) {
                entry.subaddresses.push(index);
            }
        }
        // Spent per transaction.
        let mut spent: BTreeMap<[u8; 32], (u64, u64, bool)> = BTreeMap::new();
        for o in &self.outputs {
            if let Some(s) = o.spent {
                let e = spent.entry(s.tx).or_insert((s.height, 0, s.pending));
                e.1 += o.amount();
            }
        }
        // Payments still in the pool; change of this wallet's own pending
        // transactions arrives the same way.
        let mut pool: BTreeMap<[u8; 32], &PoolPayment> =
            self.pool.iter().map(|p| (p.tx, p)).collect();
        let mut history: Vec<HistoryEntry> = Vec::new();
        for (tx, (height, amount_spent, pending)) in spent {
            // Change comes back as outputs of the spending transaction.
            let change = received
                .remove(&tx)
                .map(|r| r.amount)
                .or_else(|| pool.remove(&tx).map(|p| p.amount))
                .unwrap_or(0);
            history.push(HistoryEntry {
                tx,
                height,
                direction: Direction::Outgoing,
                amount: amount_spent.saturating_sub(change),
                pending,
                subaddresses: Vec::new(),
                miner: false,
            });
        }
        history.extend(received.into_values());
        history.extend(
            pool.into_values()
                .filter(|p| !self.outputs.iter().any(|o| o.output.transaction() == p.tx))
                .map(|p| HistoryEntry {
                    tx: p.tx,
                    height: self.next_height,
                    direction: Direction::Incoming,
                    amount: p.amount,
                    pending: true,
                    subaddresses: p.subaddresses.clone(),
                    miner: false,
                }),
        );
        history.sort_by(|a, b| b.height.cmp(&a.height).then(a.tx.cmp(&b.tx)));
        history
    }

    /// Serializes for the encrypted cache file.
    ///
    /// # Panics
    ///
    /// Never: every field serializes.
    #[must_use]
    pub fn to_bytes(&self) -> Vec<u8> {
        serde_json::to_vec(self).expect("sync state always serializes")
    }

    /// # Errors
    ///
    /// Fails if `bytes` is not a cache written by [`SyncState::to_bytes`].
    pub fn from_bytes(bytes: &[u8]) -> Result<Self, serde_json::Error> {
        serde_json::from_slice(bytes)
    }
}

mod hex32 {
    use serde::{Deserialize, Deserializer, Serializer, de::Error};

    #[allow(clippy::trivially_copy_pass_by_ref)] // serde's `with` signature
    pub fn serialize<S: Serializer>(v: &[u8; 32], s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&hex::encode(v))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<[u8; 32], D::Error> {
        let s = String::deserialize(d)?;
        hex::decode(s)
            .ok()
            .and_then(|v| v.try_into().ok())
            .ok_or_else(|| D::Error::custom("expected 32 hex bytes"))
    }
}

mod opt_hex32 {
    use serde::{Deserialize, Deserializer, Serializer};

    #[allow(clippy::ref_option)] // serde's `with` signature
    pub fn serialize<S: Serializer>(v: &Option<[u8; 32]>, s: S) -> Result<S::Ok, S::Error> {
        match v {
            Some(v) => super::hex32::serialize(v, s),
            None => s.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<[u8; 32]>, D::Error> {
        let s: Option<String> = Option::deserialize(d)?;
        s.map(|s| {
            hex::decode(s)
                .ok()
                .and_then(|v| v.try_into().ok())
                .ok_or_else(|| serde::de::Error::custom("expected 32 hex bytes"))
        })
        .transpose()
    }
}

mod recent_hex {
    use std::collections::VecDeque;

    use serde::{Deserialize, Deserializer, Serialize, Serializer};

    pub fn serialize<S: Serializer>(
        v: &VecDeque<(u64, [u8; 32])>,
        s: S,
    ) -> Result<S::Ok, S::Error> {
        v.iter()
            .map(|(h, hash)| (*h, hex::encode(hash)))
            .collect::<Vec<_>>()
            .serialize(s)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(
        d: D,
    ) -> Result<VecDeque<(u64, [u8; 32])>, D::Error> {
        let v: Vec<(u64, String)> = Vec::deserialize(d)?;
        v.into_iter()
            .map(|(h, s)| {
                hex::decode(s)
                    .ok()
                    .and_then(|b| b.try_into().ok())
                    .map(|b| (h, b))
                    .ok_or_else(|| serde::de::Error::custom("expected 32 hex bytes"))
            })
            .collect()
    }
}

mod wallet_output_hex {
    use monero_wallet::WalletOutput;
    use serde::{Deserialize, Deserializer, Serializer, de::Error};

    pub fn serialize<S: Serializer>(v: &WalletOutput, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&hex::encode(v.serialize()))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<WalletOutput, D::Error> {
        let bytes = hex::decode(String::deserialize(d)?).map_err(D::Error::custom)?;
        WalletOutput::read(&mut bytes.as_slice()).map_err(D::Error::custom)
    }
}
