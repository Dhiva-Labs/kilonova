//! Syncing an unlocked wallet in the background, and what it found.
//!
//! Full-mode wallets scan blocks from a node (`kn_sync::sync`); LWS-mode
//! wallets ask a light wallet server and check its answer
//! (`kn_sync::lws_sync`). Both fill the same state, so balance and history
//! do not care which mode produced them.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use flutter_rust_bridge::frb;
use kn_keys::WalletKeys;
use kn_store::{SyncMode as StoreSyncMode, UnlockedWallet};
use kn_sync::{
    Direction, LwsServer, NodeUrl, SyncError, SyncState, approximate_height, connect, lws_sync,
    sync,
};

use super::network::Network;
use super::nodes::{RUNTIME, current_node, lws_server};
use super::wallets::{Inner, OpenWallet, WalletError, store};
use crate::frb_generated::StreamSink;

/// How long to wait at the chain tip before looking for new blocks.
const FOLLOW_INTERVAL: Duration = Duration::from_secs(30);
/// How often to ask a light wallet server while it is still catching up.
const LWS_CATCH_UP_INTERVAL: Duration = Duration::from_secs(3);

/// Why sync stopped with an error.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncFailure {
    /// The node or server could not be reached or misbehaved; it retries on
    /// its own.
    NodeUnreachable,
    /// The selected node or server serves another network.
    WrongNetwork,
    /// The selected node address is invalid.
    BadNode,
    /// An LWS-mode wallet, but no light wallet server is set for its
    /// network.
    LwsServerNotSet,
    /// The owner has not yet agreed to share the view key with the server.
    LwsConsentNeeded,
    /// The server refused this wallet.
    LwsDenied,
    /// The server does not accept new wallets.
    LwsCreationRefused,
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
    /// Blocks scanned so far.
    pub scanned: u64,
    /// Blocks the node (or the server's node) has.
    pub tip: u64,
    /// The node or server being used, while connecting.
    pub node: Option<String>,
    pub failure: Option<SyncFailure>,
    /// LWS only: outputs the server reported that are not this wallet's
    /// and were ignored.
    pub rejected_outputs: u32,
    /// LWS only: the server is still importing history from before the
    /// wallet was registered.
    pub import_pending: bool,
}

impl SyncEvent {
    fn new(phase: SyncPhase) -> Self {
        Self {
            phase,
            scanned: 0,
            tip: 0,
            node: None,
            failure: None,
            rejected_outputs: 0,
            import_pending: false,
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
    /// Incoming payments waiting in the transaction pool; not in `total`.
    pub incoming: u64,
}

// Flat flags rather than enums with data keep the Dart side free of code
// generation.
#[allow(clippy::struct_excessive_bools)]
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
    /// Index of the first receiving subaddress in its account, if incoming.
    pub subaddress_index: Option<u32>,
    /// Outgoing and not yet seen in a block.
    pub pending: bool,
}

/// Sync state shared between the wallet and its background task.
pub(crate) struct SyncHandle {
    state: Mutex<SyncState>,
    tip: AtomicU64,
    /// Cancel flag of the current run. Starting a run cancels the previous
    /// one.
    current: Mutex<Arc<AtomicBool>>,
    /// Incremented per run; a run only writes state while it is current, so
    /// a cancelled run that is still finishing cannot overwrite a newer one.
    generation: AtomicU64,
    /// Set once a run reaches the chain tip; sending waits for it so it
    /// never builds on a stale view of the wallet.
    pub(crate) caught_up: AtomicBool,
}

impl SyncHandle {
    pub(crate) fn load(wallet: &UnlockedWallet) -> Self {
        let cached = store()
            .ok()
            .and_then(|s| s.load_cache(wallet).ok().flatten())
            .and_then(|bytes| SyncState::from_bytes(&bytes).ok());
        let state = cached.unwrap_or_else(|| starting_state(wallet));
        Self {
            tip: AtomicU64::new(state.next_height),
            state: Mutex::new(state),
            current: Mutex::new(Arc::new(AtomicBool::new(true))),
            generation: AtomicU64::new(0),
            caught_up: AtomicBool::new(false),
        }
    }

    /// Forgets everything scanned, for example after switching mode.
    pub(crate) fn reset(&self, inner: &Inner) {
        self.generation.fetch_add(1, Ordering::AcqRel);
        self.caught_up.store(false, Ordering::Relaxed);
        if let Ok(state) = inner.with(|w| Ok(starting_state(w))) {
            self.tip.store(state.next_height, Ordering::Relaxed);
            *self.lock_state() = state;
        }
    }

    pub(crate) fn stop(&self) {
        self.lock_current().store(true, Ordering::Relaxed);
    }

    /// Stops the current run and keeps it from writing state again, so the
    /// caller can change the state; start sync afterwards.
    pub(crate) fn pause(&self) {
        self.stop();
        self.generation.fetch_add(1, Ordering::AcqRel);
    }

    /// The scanned state and the chain tip, if sync has reached the tip.
    pub(crate) fn caught_up_state(&self) -> Option<(SyncState, u64)> {
        let tip = self.tip.load(Ordering::Relaxed);
        let state = self.snapshot();
        (self.caught_up.load(Ordering::Relaxed) && state.next_height >= tip).then_some((state, tip))
    }

    /// Replaces the state and saves the encrypted cache.
    pub(crate) fn replace(&self, inner: &Inner, state: SyncState) {
        let bytes = state.to_bytes();
        *self.lock_state() = state;
        let _ = inner.with(|w| store()?.save_cache(w, &bytes).map_err(WalletError::from));
    }

    fn lock_state(&self) -> std::sync::MutexGuard<'_, SyncState> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn lock_current(&self) -> std::sync::MutexGuard<'_, Arc<AtomicBool>> {
        self.current
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn snapshot(&self) -> SyncState {
        self.lock_state().clone()
    }
}

/// Where scanning starts without a cache: the restore height, else the
/// Polyseed birthday, else genesis.
fn starting_state(wallet: &UnlockedWallet) -> SyncState {
    let start = wallet.data.restore_height.unwrap_or_else(|| {
        wallet
            .data
            .birthday
            .map_or(0, |b| approximate_height(wallet.entry.network, b))
    });
    SyncState::starting_at(start)
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
    /// [`OpenWallet::lock`]. Calling it again restarts sync.
    pub fn start_sync(&self, sink: StreamSink<SyncEvent>) {
        let inner = self.inner.clone();
        let cancel = Arc::new(AtomicBool::new(false));
        {
            let mut current = inner.sync.lock_current();
            current.store(true, Ordering::Relaxed);
            *current = cancel.clone();
        }
        let generation = inner.sync.generation.fetch_add(1, Ordering::AcqRel) + 1;
        RUNTIME.spawn(async move {
            let run = Run {
                inner: &inner,
                sink: &sink,
                cancel: &cancel,
                generation,
                failed: AtomicBool::new(false),
            };
            run.go().await;
            // After a failure the failure stays on screen, since it says
            // what to do next; "stopped" is only for a deliberate stop.
            if run.is_current() && !run.failed.load(Ordering::Relaxed) {
                let _ = sink.add(SyncEvent::new(SyncPhase::Stopped));
            }
        });
    }

    /// Stops background sync after the current step.
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
            incoming: b.incoming,
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
                    locked: h.direction == Direction::Incoming
                        && !h.pending
                        && tip < h.height + lock,
                    subaddress_index: h.subaddresses.first().map(|(_, index)| *index),
                    pending: h.pending,
                }
            })
            .collect()
    }
}

/// One background sync run.
struct Run<'a> {
    inner: &'a Inner,
    sink: &'a StreamSink<SyncEvent>,
    cancel: &'a AtomicBool,
    generation: u64,
    /// Set when the run ends because of a failure it reported.
    failed: AtomicBool,
}

/// What a run needs from the wallet, copied out so the wallet lock is not
/// held while talking to the network.
struct Setup {
    network: kn_keys::Network,
    mode: StoreSyncMode,
    keys: WalletKeys,
    accounts: Vec<u32>,
    restore_height: u64,
    created_here: bool,
    lws_consent: Option<String>,
}

impl Run<'_> {
    fn is_current(&self) -> bool {
        self.inner.sync.generation.load(Ordering::Acquire) == self.generation
    }

    fn stopped(&self) -> bool {
        self.cancel.load(Ordering::Relaxed) || !self.is_current()
    }

    fn emit(&self, event: SyncEvent) {
        self.failed
            .store(event.phase == SyncPhase::Failed, Ordering::Relaxed);
        if self.is_current() {
            if event.phase == SyncPhase::Synced {
                self.inner.sync.caught_up.store(true, Ordering::Relaxed);
            }
            let _ = self.sink.add(event);
        }
    }

    /// Stores progress (and the encrypted cache) if this run is current.
    fn record(&self, state: &SyncState, tip: u64) {
        if !self.is_current() {
            return;
        }
        self.inner.sync.tip.store(tip, Ordering::Relaxed);
        *self.inner.sync.lock_state() = state.clone();
        // A lost cache only costs a rescan, so a failed save is not worth
        // stopping for.
        let _ = self.inner.with(|w| {
            store()?
                .save_cache(w, &state.to_bytes())
                .map_err(WalletError::from)
        });
    }

    async fn go(&self) {
        let Ok(setup) = self.inner.with(|w| {
            Ok(Setup {
                network: w.entry.network,
                mode: w.entry.mode,
                keys: w.keys.clone(),
                accounts: w.data.next_subaddress.clone(),
                restore_height: starting_state(w).next_height,
                created_here: w.data.created_here,
                lws_consent: w.data.lws_consent.clone(),
            })
        }) else {
            return;
        };
        while !self.stopped() {
            let wait = match setup.mode {
                StoreSyncMode::Full => self.full_round(&setup).await,
                StoreSyncMode::Lws => self.lws_round(&setup).await,
            };
            let Some(wait) = wait else { return };
            // Check for a cancel every second while waiting.
            for _ in 0..wait.as_secs() {
                if self.stopped() {
                    return;
                }
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        }
    }

    /// One full-mode pass to the tip. Returns how long to wait before the
    /// next, or `None` to stop.
    async fn full_round(&self, setup: &Setup) -> Option<Duration> {
        let Ok(node) = current_node(setup.network.into()) else {
            self.emit(SyncEvent::failed(SyncFailure::BadNode));
            return None;
        };
        self.emit(SyncEvent {
            node: Some(node.as_str().to_owned()),
            ..SyncEvent::new(SyncPhase::Connecting)
        });
        let result = async {
            let (daemon, _) = connect(&node, setup.network).await?;
            let mut state = self.inner.sync.snapshot();
            sync(
                &daemon,
                &setup.keys,
                &setup.accounts,
                &mut state,
                self.cancel,
                |state, progress| {
                    self.record(state, progress.tip);
                    self.emit(SyncEvent {
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
                let tip = self.inner.sync.tip.load(Ordering::Relaxed);
                self.emit(SyncEvent {
                    scanned: tip,
                    tip,
                    ..SyncEvent::new(SyncPhase::Synced)
                });
                Some(FOLLOW_INTERVAL)
            }
            Err(e) => self.fail(&e),
        }
    }

    /// One request round to the light wallet server.
    async fn lws_round(&self, setup: &Setup) -> Option<Duration> {
        let Ok(Some(server_url)) = lws_server(setup.network.into()) else {
            self.emit(SyncEvent::failed(SyncFailure::LwsServerNotSet));
            return None;
        };
        // The view key goes to the server only with the owner's agreement
        // for this exact server.
        if setup.lws_consent.as_deref() != Some(server_url.as_str()) {
            self.emit(SyncEvent {
                node: Some(server_url),
                ..SyncEvent::failed(SyncFailure::LwsConsentNeeded)
            });
            return None;
        }
        let Ok(url) = NodeUrl::parse(&server_url) else {
            self.emit(SyncEvent::failed(SyncFailure::BadNode));
            return None;
        };
        self.emit(SyncEvent {
            node: Some(server_url.clone()),
            ..SyncEvent::new(SyncPhase::Connecting)
        });
        let mut state = self.inner.sync.snapshot();
        let result = async {
            let server = LwsServer::new(&url)?;
            lws_sync(
                &server,
                &setup.keys,
                setup.network,
                &setup.accounts,
                setup.restore_height,
                setup.created_here,
                &mut state,
            )
            .await
        }
        .await;
        match result {
            Ok(report) => {
                self.record(&state, report.tip);
                let caught_up = report.scanned >= report.tip;
                self.emit(SyncEvent {
                    scanned: report.scanned,
                    tip: report.tip,
                    rejected_outputs: report.rejected_outputs,
                    import_pending: report.import_pending,
                    ..SyncEvent::new(if caught_up {
                        SyncPhase::Synced
                    } else {
                        SyncPhase::Scanning
                    })
                });
                Some(if caught_up {
                    FOLLOW_INTERVAL
                } else {
                    LWS_CATCH_UP_INTERVAL
                })
            }
            Err(e) => self.fail(&e),
        }
    }

    /// Reports `e`; network trouble is retried, configuration problems stop.
    fn fail(&self, e: &SyncError) -> Option<Duration> {
        let failure = match e {
            SyncError::Cancelled => return None,
            SyncError::Node(_) => SyncFailure::NodeUnreachable,
            SyncError::WrongNetwork => SyncFailure::WrongNetwork,
            SyncError::BadNodeUrl => SyncFailure::BadNode,
            SyncError::LwsDenied => SyncFailure::LwsDenied,
            SyncError::LwsCreationRefused => SyncFailure::LwsCreationRefused,
        };
        self.emit(SyncEvent::failed(failure));
        (failure == SyncFailure::NodeUnreachable).then_some(FOLLOW_INTERVAL)
    }
}

pub(crate) fn hex_string(bytes: &[u8; 32]) -> String {
    use std::fmt::Write as _;
    bytes.iter().fold(String::with_capacity(64), |mut s, b| {
        let _ = write!(s, "{b:02x}");
        s
    })
}
