//! Storage for node choices; the API is in `api::nodes`. Kept outside
//! `api` so the bridge generator does not export these internals.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::api::network::Network;
use crate::api::nodes::NodeError;
use crate::api::wallets::store;

const SETTINGS: &str = "nodes";

#[derive(Default, Serialize, Deserialize)]
pub(crate) struct PerNetwork {
    pub(crate) selected: Option<String>,
    pub(crate) custom: Vec<String>,
    /// The light wallet server for LWS-mode wallets. There is no default:
    /// it receives view keys, so only the user chooses it.
    #[serde(default)]
    pub(crate) lws: Option<String>,
}

#[derive(Default, Serialize, Deserialize)]
pub(crate) struct Settings {
    #[serde(flatten)]
    pub(crate) networks: BTreeMap<String, PerNetwork>,
    /// SOCKS5 proxy for all traffic, as `socks5h://host:port`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) proxy: Option<String>,
}

pub(crate) fn key(network: Network) -> &'static str {
    match network {
        Network::Mainnet => "mainnet",
        Network::Stagenet => "stagenet",
        Network::Testnet => "testnet",
    }
}

pub(crate) fn load() -> Result<Settings, NodeError> {
    let bytes = store()
        .map_err(|_| NodeError::NotInitialized)?
        .read_settings(SETTINGS)
        .map_err(|_| NodeError::Storage)?;
    // A damaged settings file falls back to defaults rather than blocking
    // sync; it holds nothing that cannot be chosen again.
    Ok(bytes
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default())
}

pub(crate) fn save(settings: &Settings) -> Result<(), NodeError> {
    let bytes = serde_json::to_vec_pretty(settings).map_err(|_| NodeError::Storage)?;
    store()
        .map_err(|_| NodeError::NotInitialized)?
        .write_settings(SETTINGS, &bytes)
        .map_err(|_| NodeError::Storage)
}
