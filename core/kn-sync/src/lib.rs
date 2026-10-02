//! Full-mode sync: Kilonova scans the chain itself against a monerod node.
//!
//! The node sees which blocks are fetched, never which outputs are the
//! wallet's: scanning and key-image checks happen here, with keys from
//! `kn-keys`. Uses monero-oxide's daemon client and scanner.

#![forbid(unsafe_code)]

mod lws;
mod node;
mod restore_height;
mod scan;
mod state;

pub use lws::{LwsFees, LwsInfo, LwsReport, LwsServer, RandomOutput, check_lws, lws_sync};
pub use node::{Http, NodeStatus, NodeUrl, bundled_nodes, connect};
pub use restore_height::approximate_height;
pub use scan::{Progress, SUBADDRESS_LOOKAHEAD, sync};
pub use state::{
    Balance, DEFAULT_LOCK_BLOCKS, Direction, HistoryEntry, MINER_LOCK_BLOCKS, OwnedOutput,
    PENDING_EXPIRY_BLOCKS, Spend, SyncState,
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
}

impl From<monero_interface::InterfaceError> for SyncError {
    fn from(e: monero_interface::InterfaceError) -> Self {
        Self::Node(e.to_string())
    }
}
