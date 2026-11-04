//! Full-mode sync: Kilonova scans the chain itself against a monerod node.
//!
//! The node sees which blocks are fetched, never which outputs are the
//! wallet's: scanning and key-image checks happen here, with keys from
//! `kn-keys`. Uses monero-oxide's daemon client and scanner.
//!
//! The `native` feature (on by default) adds the HTTP client, Tor, TLS
//! pinning, light wallet servers and the rest of the networking. Without
//! it the crate is the scanner and wallet state alone, generic over the
//! transport, which is what the browser extension builds.

#![forbid(unsafe_code)]

mod blocks;
#[cfg(feature = "native")]
mod cover;
#[cfg(feature = "native")]
mod crosscheck;
#[cfg(feature = "native")]
mod discover;
#[cfg(feature = "native")]
mod lws;
mod node;
#[cfg(feature = "native")]
mod opinion;
#[cfg(feature = "native")]
mod price;
#[cfg(feature = "native")]
mod proof;
#[cfg(feature = "native")]
pub mod push;
#[cfg(feature = "native")]
mod random;
mod restore_height;
mod scan;
mod state;
#[cfg(feature = "native")]
mod tls;
#[cfg(feature = "native")]
mod watch;

#[cfg(feature = "native")]
pub use cover::{COVER_WINDOW, CoverLookups, LOOKUP_BATCH, LookedUp};
#[cfg(feature = "native")]
pub use crosscheck::{CROSS_CHECK_LIMIT, CrossCheck, cross_check};
#[cfg(feature = "native")]
pub use discover::{FoundNode, discover, discover_at, local_ipv4};
#[cfg(all(feature = "native", feature = "fuzzing"))]
pub use lws::fuzzing;
#[cfg(feature = "native")]
pub use lws::{LwsFees, LwsInfo, LwsReport, LwsServer, RandomOutput, check_lws, lws_sync};
#[cfg(feature = "native")]
pub use node::{
    Circuit, Http, ProxyUrl, Purpose, broadcast_nodes, check_proxy, connect, other_node,
    probe_proxy, proxy, set_broadcast_nodes_for_tests, set_proxy,
};
pub use node::{NodeStatus, NodeUrl, ServerPairing, bundled_nodes, node_status};
/// The node client sync and sending use.
#[cfg(feature = "native")]
pub type MoneroDaemonHttp = monero_daemon_rpc::MoneroDaemon<Http>;
#[cfg(feature = "native")]
pub use opinion::{OPINION_DEPTH, Opinion, second_opinion};
#[cfg(feature = "native")]
pub use price::{PRICE_CURRENCIES, PRICE_SOURCE, xmr_price};
#[cfg(feature = "native")]
pub use proof::{ProofError, ProofResult, check_tx_key};
pub use restore_height::approximate_height;
pub use scan::{Progress, SUBADDRESS_LOOKAHEAD, SyncCache, sync, sync_with};
pub use state::{
    Balance, DEFAULT_LOCK_BLOCKS, Direction, HistoryEntry, MINER_LOCK_BLOCKS, OwnedOutput,
    PENDING_EXPIRY_BLOCKS, PoolPayment, Spend, SyncState,
};
#[cfg(feature = "native")]
pub use tls::{CertificateInfo, Fingerprint, fingerprint, server_certificate, set_pins};
#[cfg(feature = "native")]
pub use watch::{
    Arrival, CATCH_UP_BLOCKS, MAX_BEHIND, MAX_BLOCKS_PER_RUN, NOTIFIED_LIMIT, WATCH_VERSION,
    WatchError, WatchLimits, WatchMode, WatchReport, WatchState, watch_full, watch_lws,
};

#[derive(Debug, thiserror::Error)]
pub enum SyncError {
    #[error("not a valid node address; use host:port or http(s)://host:port")]
    BadNodeUrl,
    #[error("this node serves a different Monero network")]
    WrongNetwork,
    #[error("node error: {0}")]
    Node(String),
    #[error("sync was cancelled")]
    Cancelled,
    #[error("the light wallet server refused this wallet")]
    LwsDenied,
    #[error("the light wallet server does not accept new wallets")]
    LwsCreationRefused,
    #[error("not a valid proxy; use host:port or socks5h://host:port")]
    BadProxyUrl,
    #[error("onion addresses need a Tor proxy")]
    NeedsProxy,
    #[error(
        "a light wallet server receives the view key, so it must use https (or be an onion or local address)"
    )]
    InsecureLws,
}

impl From<monero_interface::InterfaceError> for SyncError {
    fn from(e: monero_interface::InterfaceError) -> Self {
        Self::Node(e.to_string())
    }
}
