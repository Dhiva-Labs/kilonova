//! Syncing an unlocked wallet in the background, and what it found.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use flutter_rust_bridge::frb;
use kn_store::{SyncMode as StoreSyncMode, UnlockedWallet};
use kn_sync::{Direction, SyncError, SyncState, approximate_height, connect, sync};

use super::network::Network;
use super::nodes::{RUNTIME, current_node};
use super::wallets::{OpenWallet, WalletError, store};
use crate::frb_generated::StreamSink;

/// How long to wait at the chain tip before looking for new blocks.
const FOLLOW_INTERVAL: Duration = Duration::from_secs(30);

/// Why sync stopped with an error.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncFailure {
    /// The node could not be reached or misbehaved; it retries on its own.
    NodeUnreachable,
    /// The selected node serves another network.
    WrongNetwork,
    /// The selected node address is invalid.
    BadNode,
    /// Light wallet server sync is not available yet.
    LwsNotAvailable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncPhase {
    Connecting,
    Scanning,
    Synced,
    Failed,
    Stopped,
}

/// A progress report from a running sync. Flat rather than an enum with
/// data, which keeps the Dart side free of code generation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyncEvent {
    pub phase: SyncPhase,
    /// Next block to scan.
    pub scanned: u64,
    /// Blocks the node has.
    pub tip: u64,
    /// The node being used, while connecting.
    pub node: Option<String>,
    pub failure: Option<SyncFailure>,
}

impl SyncEvent {
    fn new(phase: SyncPhase) -> Self {
        Self {
            phase,
            scanned: 0,
            tip: 0,
            node: None,
            failure: None,
        }
    }

    fn failed(failure: SyncFailure) -> Self {
        Self {
            failure: Some(failure),
            ..Self::new(SyncPhase::Failed)
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WalletBalance {
    /// Atomic units (1 XMR = 10^12).
    pub total: u64,
    pub unlocked: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryItem {
    pub tx_hash: String,
    pub height: u64,
    pub incoming: bool,
    /// Atomic units.
    pub amount: u64,
    pub miner: bool,
    /// True while the received funds cannot be spent yet.
    pub locked: bool,
    /// Account and index of the first receiving subaddress, if incoming.
    pub subaddress_index: Option<u32>,
}

/// Sync state shared between the wallet and its background task.
pub(crate) struct SyncHandle {
    state: Mutex<SyncState>,
    tip: AtomicU64,
    running: AtomicBool,
    cancel: Arc<AtomicBool>,
}

impl SyncHandle {
    /// Loads the cached state, or starts from the wallet's restore height,
    /// its Polyseed birthday, or genesis, in that order.
    pub(crate) fn load(wallet: &UnlockedWallet) -> Self {
        let cached = store()
            .ok()
            .and_then(|s| s.load_cache(wallet).ok().flatten())
            .and_then(|bytes| SyncState::from_bytes(&bytes).ok());
        let state = cached.unwrap_or_else(|| {
            let start = wallet.data.restore_height.unwrap_or_else(|| {
                wallet
                    .data
                    .birthday
                    .map_or(0, |b| approximate_height(wallet.entry.network, b))
            });
            SyncState::starting_at(start)
        });
        Self {
            tip: AtomicU64::new(state.next_height),
            state: Mutex::new(state),
            running: AtomicBool::new(false),
            cancel: Arc::new(AtomicBool::new(false)),
        }
    }

    pub(crate) fn stop(&self) {
        self.cancel.store(true, Ordering::Relaxed);
    }

    fn snapshot(&self) -> SyncState {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }
}

/// A block height to record as the restore height of a wallet created now,
/// so a new wallet does not scan old blocks.
#[frb(sync)]
#[must_use]
pub fn restore_height_for_new_wallet(network: Network) -> u64 {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    approximate_height(network.into(), now)
}

impl OpenWallet {
    /// Starts syncing in the background and reports through `sink`. Keeps
    /// following new blocks until [`OpenWallet::stop_sync`] or
    /// [`OpenWallet::lock`]. Calling it while sync runs does nothing.
    pub fn start_sync(&self, sink: StreamSink<SyncEvent>) {
        let inner = self.inner.clone();
        if inner.sync.running.swap(true, Ordering::AcqRel) {
            return;
        }
        inner.sync.cancel.store(false, Ordering::Relaxed);
        RUNTIME.spawn(async move {
            run(&inner, &sink).await;
            inner.sync.running.store(false, Ordering::Release);
            let _ = sink.add(SyncEvent::new(SyncPhase::Stopped));
        });
    }

    /// Stops background sync after the current batch.
    #[frb(sync)]
    pub fn stop_sync(&self) {
        self.inner.sync.stop();
    }

    /// Balance from what has been scanned so far.
    #[frb(sync)]
    #[must_use]
    pub fn balance(&self) -> WalletBalance {
        let tip = self.inner.sync.tip.load(Ordering::Relaxed);
        let b = self.inner.sync.snapshot().balance(tip);
        WalletBalance {
            total: b.total,
            unlocked: b.unlocked,
        }
    }

    /// Transactions found so far, newest first.
    #[frb(sync)]
    #[must_use]
    pub fn history(&self) -> Vec<HistoryItem> {
        let tip = self.inner.sync.tip.load(Ordering::Relaxed);
        let state = self.inner.sync.snapshot();
        state
            .history()
            .into_iter()
            .map(|h| {
                let lock = if h.miner {
                    kn_sync::MINER_LOCK_BLOCKS
                } else {
                    kn_sync::DEFAULT_LOCK_BLOCKS
                };
                HistoryItem {
                    tx_hash: hex_string(&h.tx),
                    height: h.height,
                    incoming: h.direction == Direction::Incoming,
                    amount: h.amount,
                    miner: h.miner,
                    locked: h.direction == Direction::Incoming && tip < h.height + lock,
                    subaddress_index: h.subaddresses.first().map(|(_, index)| *index),
                }
            })
            .collect()
    }
}

async fn run(inner: &super::wallets::Inner, sink: &StreamSink<SyncEvent>) {
    let setup = inner.with(|w| {
        Ok((
            w.entry.network,
            w.entry.mode,
            w.keys.clone(),
            w.data.next_subaddress.clone(),
        ))
    });
    let Ok((network, mode, keys, accounts)) = setup else {
        return;
    };
    if mode == StoreSyncMode::Lws {
        let _ = sink.add(SyncEvent::failed(SyncFailure::LwsNotAvailable));
        return;
    }
    let cancel = inner.sync.cancel.clone();
    while !cancel.load(Ordering::Relaxed) {
        let Ok(node) = current_node(network.into()) else {
            let _ = sink.add(SyncEvent::failed(SyncFailure::BadNode));
            return;
        };
        let _ = sink.add(SyncEvent {
            node: Some(node.as_str().to_owned()),
            ..SyncEvent::new(SyncPhase::Connecting)
        });
        let result = async {
            let (daemon, _) = connect(&node, network).await?;
            let mut state = inner.sync.snapshot();
            sync(
                &daemon,
                &keys,
                &accounts,
                &mut state,
                &cancel,
                |state, progress| {
                    inner.sync.tip.store(progress.tip, Ordering::Relaxed);
                    *inner
                        .sync
                        .state
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner) = state.clone();
                    // A lost cache only costs a rescan, so a failed save is not
                    // worth stopping for.
                    let _ = inner.with(|w| {
                        store()?
                            .save_cache(w, &state.to_bytes())
                            .map_err(WalletError::from)
                    });
                    let _ = sink.add(SyncEvent {
                        scanned: progress.scanned,
                        tip: progress.tip,
                        ..SyncEvent::new(SyncPhase::Scanning)
                    });
                },
            )
            .await
        }
        .await;
        match result {
            Ok(()) => {
                let tip = inner.sync.tip.load(Ordering::Relaxed);
                let _ = sink.add(SyncEvent {
                    scanned: tip,
                    tip,
                    ..SyncEvent::new(SyncPhase::Synced)
                });
            }
            Err(SyncError::Cancelled) => return,
            Err(SyncError::WrongNetwork) => {
                let _ = sink.add(SyncEvent::failed(SyncFailure::WrongNetwork));
                return;
            }
            Err(SyncError::BadNodeUrl) => {
                let _ = sink.add(SyncEvent::failed(SyncFailure::BadNode));
                return;
            }
            Err(SyncError::Node(_)) => {
                let _ = sink.add(SyncEvent::failed(SyncFailure::NodeUnreachable));
            }
        }
        // Wait for new blocks (or retry after an error), checking for a
        // cancel every second.
        for _ in 0..FOLLOW_INTERVAL.as_secs() {
            if cancel.load(Ordering::Relaxed) {
                return;
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
    }
}

fn hex_string(bytes: &[u8; 32]) -> String {
    use std::fmt::Write as _;
    bytes.iter().fold(String::with_capacity(64), |mut s, b| {
        let _ = write!(s, "{b:02x}");
        s
    })
}
