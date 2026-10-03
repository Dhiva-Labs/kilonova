//! Background checks for incoming payments while the app is closed.
//!
//! A [`WatchState`] holds what a view-only wallet holds (the primary
//! address, the private view key and the public spend key) plus how far
//! it has looked and which payments it already announced. It never holds
//! the private spend key or the seed, so whoever reads it can see incoming
//! payments but cannot spend. The app keeps it encrypted with a key from
//! the device's secure hardware (Android Keystore) and hands it to
//! [`watch_full`] or [`watch_lws`] every 15 minutes or so.
//!
//! Full mode scans like a view-only wallet with [`crate::sync_with`]: it
//! finds incoming outputs and payments waiting in the pool, but not spends,
//! which is all a notification needs. LWS mode asks the light wallet server
//! the owner already shares the view key with, through [`crate::lws_sync`],
//! which checks every output against the wallet's keys.

use std::collections::{BTreeMap, VecDeque};
use std::fmt;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

use kn_keys::{Network, WalletKeys};
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

use crate::node::{Circuit, NodeUrl, Purpose, connect, probe_proxy};
use crate::scan::{SyncCache, sync_with};
use crate::state::SyncState;
use crate::{LwsServer, SyncError, lws_sync};

/// The watch state format this build reads and writes.
pub const WATCH_VERSION: u32 = 1;

/// Transactions remembered as announced. Older ones drop out first; by
/// then they are far below the scanned height and are not looked at again.
pub const NOTIFIED_LIMIT: usize = 200;

/// Block hashes kept to notice a reorganization between runs.
const RECENT_KEPT: usize = 10;

/// Blocks scanned per run at most; the next run carries on. About two
/// days of blocks.
pub const MAX_BLOCKS_PER_RUN: u64 = 1440;

/// A wallet further behind than this (about a week of blocks, say a phone
/// that was off) skips ahead to the last [`CATCH_UP_BLOCKS`]: older
/// payments show in the app, and notifying about them days late helps
/// nobody.
pub const MAX_BEHIND: u64 = 5040;

/// How far back a wallet that skipped ahead still looks: about a day.
pub const CATCH_UP_BLOCKS: u64 = 720;

/// How a watched wallet finds its payments.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum WatchMode {
    /// Scanning blocks from a node, view-only.
    Full,
    /// Asking a light wallet server.
    Lws,
}

/// Everything a background check needs for one wallet. See the module
/// documentation for what it may and may not contain.
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WatchState {
    pub version: u32,
    /// The wallet's id in the app; picks its proxy circuit. Not secret.
    pub wallet: String,
    #[serde(with = "network_name")]
    pub network: Network,
    pub mode: WatchMode,
    /// Primary address.
    pub address: String,
    /// Private view key, hex.
    #[serde(with = "secret_hex")]
    view_key: Zeroizing<String>,
    /// Public spend key, hex. Also inside the address; kept to check the
    /// two agree.
    pub spend_public: String,
    /// Subaddresses handed out per account, as in sync.
    pub accounts: Vec<u32>,
    /// Next block to look at (full mode), or the server's scanned height at
    /// the last look (LWS mode).
    pub next_height: u64,
    /// `(height, block hash hex)` of the newest scanned blocks, oldest
    /// first; full mode only.
    pub recent: Vec<(u64, String)>,
    /// Transactions already announced, oldest first, at most
    /// [`NOTIFIED_LIMIT`].
    pub notified: VecDeque<String>,
    /// The node (full mode) or the light wallet server the owner agreed to
    /// share the view key with (LWS mode).
    pub server: String,
}

impl fmt::Debug for WatchState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("WatchState")
            .field("wallet", &self.wallet)
            .field("network", &self.network)
            .field("mode", &self.mode)
            .field("next_height", &self.next_height)
            .finish_non_exhaustive()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum WatchError {
    #[error("this watch state was written by another version (format {0})")]
    UnsupportedVersion(u32),
    #[error("not a watch state")]
    Malformed,
    #[error("the watch state's keys do not match its address")]
    KeyMismatch,
}

/// A payment a check found, not announced before.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Arrival {
    pub tx: [u8; 32],
    /// Atomic units received in this transaction.
    pub amount: u64,
    /// Waiting in the pool, not in a block yet.
    pub pending: bool,
}

/// What one check found.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WatchReport {
    pub arrivals: Vec<Arrival>,
    /// False when the run stopped at its limit and the next one goes on.
    pub caught_up: bool,
}

/// When a run stops: after this many blocks or at this moment, whichever
/// comes first.
#[derive(Clone, Copy, Debug)]
pub struct WatchLimits {
    pub max_blocks: u64,
    pub deadline: Instant,
}

impl WatchState {
    /// The watch state for a wallet with `keys`, carrying on from what its
    /// sync has already seen (`sync`), so payments the app already shows
    /// are not announced again. Takes the view key only; a view-only copy
    /// of `keys` is all it keeps.
    #[must_use]
    pub fn new(
        wallet: &str,
        network: Network,
        mode: WatchMode,
        keys: &WalletKeys,
        accounts: &[u32],
        sync: &SyncState,
        server: &str,
    ) -> Self {
        let mut known: Vec<(u64, [u8; 32])> = sync
            .outputs
            .iter()
            .map(|o| (o.height, o.output.transaction()))
            .collect();
        known.sort_unstable();
        known.dedup_by_key(|(_, tx)| *tx);
        let mut state = Self {
            version: WATCH_VERSION,
            wallet: wallet.to_owned(),
            network,
            mode,
            address: keys.primary_address(network),
            view_key: keys.secret_view_key_hex(),
            spend_public: hex::encode(keys.view_pair().spend().compress().to_bytes()),
            accounts: accounts.to_vec(),
            next_height: sync.next_height,
            recent: Vec::new(),
            notified: VecDeque::new(),
            server: server.to_owned(),
        };
        state.keep_recent(&sync.recent);
        for (_, tx) in known {
            state.remember(&tx);
        }
        for payment in &sync.pool {
            state.remember(&payment.tx);
        }
        state
    }

    /// Serialized, in a buffer wiped when dropped.
    ///
    /// # Panics
    ///
    /// Never: every field serializes.
    #[must_use]
    pub fn to_bytes(&self) -> Zeroizing<Vec<u8>> {
        Zeroizing::new(serde_json::to_vec(self).expect("watch state always serializes"))
    }

    /// Reads what [`WatchState::to_bytes`] wrote.
    ///
    /// # Errors
    ///
    /// [`WatchError::UnsupportedVersion`] for another format version,
    /// [`WatchError::Malformed`] for anything else that is not a watch
    /// state, [`WatchError::KeyMismatch`] if the keys do not belong to the
    /// address.
    pub fn from_bytes(bytes: &[u8]) -> Result<Self, WatchError> {
        #[derive(Deserialize)]
        struct Version {
            version: u32,
        }
        let version = serde_json::from_slice::<Version>(bytes)
            .map_err(|_| WatchError::Malformed)?
            .version;
        if version != WATCH_VERSION {
            return Err(WatchError::UnsupportedVersion(version));
        }
        let state: Self = serde_json::from_slice(bytes).map_err(|_| WatchError::Malformed)?;
        state.keys()?;
        Ok(state)
    }

    /// The view-only keys this state holds.
    ///
    /// # Errors
    ///
    /// [`WatchError::KeyMismatch`] if the view key or public spend key do
    /// not belong to the address.
    pub fn keys(&self) -> Result<WalletKeys, WatchError> {
        let keys = WalletKeys::view_only(self.network, &self.address, &self.view_key)
            .map_err(|_| WatchError::KeyMismatch)?;
        let spend = hex::encode(keys.view_pair().spend().compress().to_bytes());
        if spend != self.spend_public {
            return Err(WatchError::KeyMismatch);
        }
        Ok(keys)
    }

    fn keep_recent(&mut self, recent: &VecDeque<(u64, [u8; 32])>) {
        let skip = recent.len().saturating_sub(RECENT_KEPT);
        self.recent = recent
            .iter()
            .skip(skip)
            .map(|(height, hash)| (*height, hex::encode(hash)))
            .collect();
    }

    fn was_notified(&self, tx: &[u8; 32]) -> bool {
        let tx = hex::encode(tx);
        self.notified.iter().any(|t| *t == tx)
    }

    /// Records `tx` as announced, dropping the oldest beyond
    /// [`NOTIFIED_LIMIT`].
    pub fn remember(&mut self, tx: &[u8; 32]) {
        if self.was_notified(tx) {
            return;
        }
        self.notified.push_back(hex::encode(tx));
        while self.notified.len() > NOTIFIED_LIMIT {
            self.notified.pop_front();
        }
    }

    /// The scan state to start from: the recent block hashes, so a
    /// reorganization since the last run is noticed.
    fn scan_state(&self) -> SyncState {
        let mut scan = SyncState::starting_at(self.next_height);
        scan.recent = self
            .recent
            .iter()
            .filter_map(|(height, hash)| Some((*height, hex::decode(hash).ok()?.try_into().ok()?)))
            .collect();
        scan
    }

    /// Takes the new payments out of `found`, newest last, and remembers
    /// them.
    fn announce(&mut self, found: BTreeMap<[u8; 32], Arrival>) -> Vec<Arrival> {
        let mut fresh: Vec<Arrival> = found
            .into_values()
            .filter(|a| !self.was_notified(&a.tx))
            .collect();
        fresh.sort_by_key(|a| a.pending);
        for arrival in &fresh {
            self.remember(&arrival.tx);
        }
        fresh
    }
}

/// Incoming payments in `scan` by transaction: outputs in blocks (miner
/// rewards left out, as in the app's notifications) and payments in the
/// pool.
fn arrivals(scan: &SyncState, pending_from: u64) -> BTreeMap<[u8; 32], Arrival> {
    let mut found: BTreeMap<[u8; 32], Arrival> = BTreeMap::new();
    for output in scan.outputs.iter().filter(|o| !o.miner) {
        let tx = output.output.transaction();
        let arrival = found.entry(tx).or_insert(Arrival {
            tx,
            amount: 0,
            pending: false,
        });
        arrival.amount = arrival.amount.saturating_add(output.amount());
        arrival.pending |= output.height == 0 || output.height >= pending_from;
    }
    for payment in &scan.pool {
        found.entry(payment.tx).or_insert(Arrival {
            tx: payment.tx,
            amount: payment.amount,
            pending: true,
        });
    }
    found
}

/// Looks for payments to `state`'s wallet in blocks from `node`, as a
/// view-only wallet, up to `limits`, and moves `state` on. A node that
/// fails leaves `state` as it was.
///
/// # Errors
///
/// Node errors and [`SyncError::WrongNetwork`]; a watch state whose keys
/// do not match its address gives [`SyncError::Node`].
pub async fn watch_full(
    state: &mut WatchState,
    node: &NodeUrl,
    limits: WatchLimits,
) -> Result<WatchReport, SyncError> {
    let keys = state.keys().map_err(|e| SyncError::Node(e.to_string()))?;
    let circuit = Circuit::new(&state.wallet, Purpose::Sync);
    let (daemon, status) = connect(node, state.network, &circuit).await?;
    let mut scan = state.scan_state();
    if status.height > scan.next_height.saturating_add(MAX_BEHIND) {
        scan = SyncState::starting_at(status.height - CATCH_UP_BLOCKS);
    }
    let start = scan.next_height;
    let cancel = AtomicBool::new(false);
    let result = sync_with(
        &daemon,
        &mut SyncCache::default(),
        &keys,
        &state.accounts,
        &mut scan,
        &cancel,
        |scanned, _| {
            if scanned.next_height.saturating_sub(start) >= limits.max_blocks
                || Instant::now() >= limits.deadline
            {
                cancel.store(true, Ordering::Relaxed);
            }
        },
    )
    .await;
    let caught_up = match result {
        Ok(()) => true,
        // Stopped at the limit; what was scanned so far is consistent.
        Err(SyncError::Cancelled) => false,
        Err(e) => return Err(e),
    };
    let found = arrivals(&scan, u64::MAX);
    state.next_height = scan.next_height;
    state.keep_recent(&scan.recent);
    Ok(WatchReport {
        arrivals: state.announce(found),
        caught_up,
    })
}

/// Asks the light wallet server at `server` (which already has the view
/// key) for `state`'s wallet's payments, keeping only outputs that open
/// with the wallet's keys, and moves `state` on. Only payments from the
/// last look's height on, or still waiting for a block, count as new.
///
/// # Errors
///
/// As [`lws_sync`], and [`SyncError::InsecureLws`] for a server the view
/// key may not be sent to.
pub async fn watch_lws(state: &mut WatchState, server: &NodeUrl) -> Result<WatchReport, SyncError> {
    let keys = state.keys().map_err(|e| SyncError::Node(e.to_string()))?;
    probe_proxy().await;
    let client = LwsServer::new(server, &Circuit::new(&state.wallet, Purpose::Sync))?;
    let mut scan = SyncState::default();
    // No restore height below the server's start: a check never asks the
    // server to import history.
    let report = lws_sync(
        &client,
        &keys,
        state.network,
        &state.accounts,
        u64::MAX,
        false,
        &mut scan,
    )
    .await?;
    let since = state.next_height;
    let mut found = arrivals(&scan, report.scanned);
    found.retain(|_, a| {
        a.pending || {
            scan.outputs
                .iter()
                .any(|o| o.output.transaction() == a.tx && o.height >= since)
        }
    });
    state.next_height = state.next_height.max(report.scanned);
    Ok(WatchReport {
        arrivals: state.announce(found),
        caught_up: report.scanned >= report.tip,
    })
}

mod network_name {
    use kn_keys::Network;
    use serde::{Deserialize, Deserializer, Serializer, de::Error};

    #[allow(clippy::trivially_copy_pass_by_ref)] // serde's `with` signature
    pub fn serialize<S: Serializer>(network: &Network, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(match network {
            Network::Mainnet => "mainnet",
            Network::Stagenet => "stagenet",
            Network::Testnet => "testnet",
        })
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Network, D::Error> {
        match String::deserialize(d)?.as_str() {
            "mainnet" => Ok(Network::Mainnet),
            "stagenet" => Ok(Network::Stagenet),
            "testnet" => Ok(Network::Testnet),
            _ => Err(D::Error::custom("unknown network")),
        }
    }
}

mod secret_hex {
    use serde::{Deserialize, Deserializer, Serializer};
    use zeroize::Zeroizing;

    pub fn serialize<S: Serializer>(v: &Zeroizing<String>, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(v)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Zeroizing<String>, D::Error> {
        Ok(Zeroizing::new(String::deserialize(d)?))
    }
}

#[cfg(test)]
mod tests {
    use kn_keys::SeedFormat;

    use super::*;

    fn state_for(keys: &WalletKeys) -> WatchState {
        WatchState::new(
            "w1",
            Network::Mainnet,
            WatchMode::Full,
            keys,
            &[3, 1],
            &SyncState::starting_at(1000),
            "http://127.0.0.1:18181",
        )
    }

    #[test]
    fn never_holds_the_spend_key_or_seed() {
        let (keys, mnemonic) = WalletKeys::generate(SeedFormat::Classic);
        let state = state_for(&keys);
        let bytes = state.to_bytes();
        let text = std::str::from_utf8(&bytes).unwrap();
        let spend = keys.secret_spend_key_hex().unwrap();
        assert!(!text.contains(spend.as_str()), "no private spend key");
        let words: Vec<&str> = mnemonic.words.split(' ').collect();
        for three in words.windows(3) {
            assert!(!text.contains(&three.join(" ")), "no seed words");
        }
        assert!(text.contains(keys.secret_view_key_hex().as_str()));

        let again = WatchState::from_bytes(&bytes).unwrap();
        let view_only = again.keys().unwrap();
        assert!(view_only.is_view_only());
        assert_eq!(
            view_only.primary_address(Network::Mainnet),
            keys.primary_address(Network::Mainnet)
        );
        assert_eq!(again.accounts, [3, 1]);
        assert_eq!(again.next_height, 1000);
        assert!(!format!("{again:?}").contains(keys.secret_view_key_hex().as_str()));
    }

    #[test]
    fn only_reads_its_own_version() {
        let (keys, _) = WalletKeys::generate(SeedFormat::Classic);
        let bytes = state_for(&keys).to_bytes();
        let mut value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        value["version"] = 2.into();
        assert_eq!(
            WatchState::from_bytes(&serde_json::to_vec(&value).unwrap()).unwrap_err(),
            WatchError::UnsupportedVersion(2)
        );
        assert_eq!(
            WatchState::from_bytes(b"{}").unwrap_err(),
            WatchError::Malformed
        );
        // A field this version does not know (say, a spend key) is refused.
        let mut value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        value["spend_key"] = "00".into();
        assert_eq!(
            WatchState::from_bytes(&serde_json::to_vec(&value).unwrap()).unwrap_err(),
            WatchError::Malformed
        );
        // Keys from another wallet do not pass for this address.
        let (other, _) = WalletKeys::generate(SeedFormat::Classic);
        let mut value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        value["view_key"] = other.secret_view_key_hex().as_str().into();
        assert_eq!(
            WatchState::from_bytes(&serde_json::to_vec(&value).unwrap()).unwrap_err(),
            WatchError::KeyMismatch
        );
    }

    #[test]
    fn the_notified_set_is_bounded_and_keeps_the_newest() {
        let (keys, _) = WalletKeys::generate(SeedFormat::Classic);
        let mut state = state_for(&keys);
        for i in 0..(NOTIFIED_LIMIT + 50) {
            let mut tx = [0u8; 32];
            tx[..8].copy_from_slice(&(i as u64).to_le_bytes());
            state.remember(&tx);
            state.remember(&tx);
        }
        assert_eq!(state.notified.len(), NOTIFIED_LIMIT);
        let mut newest = [0u8; 32];
        newest[..8].copy_from_slice(&((NOTIFIED_LIMIT + 49) as u64).to_le_bytes());
        assert!(state.was_notified(&newest));
        assert!(!state.was_notified(&[0u8; 32]), "the oldest dropped out");
        let again = WatchState::from_bytes(&state.to_bytes()).unwrap();
        assert_eq!(again.notified.len(), NOTIFIED_LIMIT);
    }

    #[test]
    fn announces_each_payment_once() {
        let (keys, _) = WalletKeys::generate(SeedFormat::Classic);
        let mut state = state_for(&keys);
        let pending = Arrival {
            tx: [7; 32],
            amount: 5,
            pending: true,
        };
        let first = state.announce(BTreeMap::from([([7; 32], pending.clone())]));
        assert_eq!(first, [pending]);
        // Mined later: already announced while it waited.
        let mined = Arrival {
            tx: [7; 32],
            amount: 5,
            pending: false,
        };
        assert!(
            state
                .announce(BTreeMap::from([([7; 32], mined)]))
                .is_empty()
        );
    }
}
