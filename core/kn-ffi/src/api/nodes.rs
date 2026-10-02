//! Which Monero node each network syncs from: the bundled public nodes,
//! nodes the user added, and the one selected.
//!
//! Stored as plain JSON next to the wallets. Node addresses are not secret,
//! though a user's own node may point at their home; the file stays in the
//! app's private directory, which is excluded from backups.
//!
//! Arguments are owned because `flutter_rust_bridge` hands them over that way.
#![allow(clippy::needless_pass_by_value)]

use std::sync::LazyLock;

use kn_sync::{NodeUrl, SyncError, bundled_nodes, check_lws, connect};
use rand_core::{OsRng, RngCore};

use super::network::Network;
use crate::node_settings::{key, load, save};

/// One runtime for all network I/O, so blocking calls from Dart's worker
/// threads and the background sync share connections and timers.
pub(crate) static RUNTIME: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_name("kn-net")
        .enable_all()
        .build()
        .expect("the network runtime starts")
});

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NodeError {
    BadUrl,
    WrongNetwork,
    Unreachable,
    Storage,
    NotInitialized,
}

impl From<SyncError> for NodeError {
    fn from(e: SyncError) -> Self {
        match e {
            SyncError::BadNodeUrl => Self::BadUrl,
            SyncError::WrongNetwork => Self::WrongNetwork,
            SyncError::Node(_)
            | SyncError::Cancelled
            | SyncError::LwsDenied
            | SyncError::LwsCreationRefused => Self::Unreachable,
        }
    }
}

/// A node as listed in settings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NodeChoice {
    pub url: String,
    /// Shipped with the app (run by a third party) rather than added by
    /// the user.
    pub bundled: bool,
    pub selected: bool,
}

/// What a node reported when checked.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NodeHealth {
    pub height: u64,
    pub synced: bool,
}

/// The node `network` syncs from. On first use one of the bundled nodes is
/// picked at random and remembered, so users spread across them.
pub(crate) fn current_node(network: Network) -> Result<NodeUrl, NodeError> {
    let mut settings = load()?;
    let entry = settings.entry(key(network).to_owned()).or_default();
    if let Some(url) = &entry.selected
        && let Ok(url) = NodeUrl::parse(url)
    {
        return Ok(url);
    }
    let bundled = bundled_nodes(network.into());
    let pick = usize::try_from(OsRng.next_u32()).unwrap_or(0) % bundled.len();
    let url = bundled[pick].clone();
    entry.selected = Some(url.as_str().to_owned());
    save(&settings)?;
    Ok(url)
}

/// Bundled and user-added nodes for `network`, with the selected one marked.
///
/// # Errors
///
/// Fails if the settings cannot be read.
pub fn nodes(network: Network) -> Result<Vec<NodeChoice>, NodeError> {
    let selected = current_node(network)?;
    let settings = load()?;
    let custom = settings
        .get(key(network))
        .map(|n| n.custom.clone())
        .unwrap_or_default();
    let mut out: Vec<NodeChoice> = custom
        .into_iter()
        .map(|url| NodeChoice {
            selected: url == selected.as_str(),
            url,
            bundled: false,
        })
        .collect();
    out.extend(
        bundled_nodes(network.into())
            .into_iter()
            .map(|url| NodeChoice {
                selected: url == selected,
                url: url.as_str().to_owned(),
                bundled: true,
            }),
    );
    Ok(out)
}

/// Adds a node the user trusts and selects it. Returns the normalized URL.
///
/// # Errors
///
/// [`NodeError::BadUrl`] for anything that is not `host:port` or an
/// http(s) URL.
pub fn add_node(network: Network, url: String) -> Result<String, NodeError> {
    let url = NodeUrl::parse(&url)?.as_str().to_owned();
    let mut settings = load()?;
    let entry = settings.entry(key(network).to_owned()).or_default();
    if !entry.custom.contains(&url) {
        entry.custom.push(url.clone());
    }
    entry.selected = Some(url.clone());
    save(&settings)?;
    Ok(url)
}

/// Removes a user-added node. If it was selected, a bundled node is picked
/// next time.
///
/// # Errors
///
/// Fails if the settings cannot be written.
pub fn remove_node(network: Network, url: String) -> Result<(), NodeError> {
    let mut settings = load()?;
    let entry = settings.entry(key(network).to_owned()).or_default();
    entry.custom.retain(|u| *u != url);
    if entry.selected.as_deref() == Some(url.as_str()) {
        entry.selected = None;
    }
    save(&settings)
}

/// Makes `url` the node `network` syncs from.
///
/// # Errors
///
/// [`NodeError::BadUrl`] if it is not a valid node address.
pub fn select_node(network: Network, url: String) -> Result<(), NodeError> {
    let parsed = NodeUrl::parse(&url)?;
    let url = parsed.as_str().to_owned();
    let bundled = bundled_nodes(network.into()).contains(&parsed);
    let mut settings = load()?;
    let entry = settings.entry(key(network).to_owned()).or_default();
    // An address that is neither bundled nor already added becomes the
    // user's own node, so the list always shows what is selected.
    if !bundled && !entry.custom.contains(&url) {
        entry.custom.push(url.clone());
    }
    entry.selected = Some(url);
    save(&settings)
}

/// Connects to `url` and checks it serves `network`.
///
/// # Errors
///
/// [`NodeError::WrongNetwork`] or [`NodeError::Unreachable`].
pub fn check_node(network: Network, url: String) -> Result<NodeHealth, NodeError> {
    let url = NodeUrl::parse(&url)?;
    let (_, status) = RUNTIME.block_on(connect(&url, network.into()))?;
    Ok(NodeHealth {
        height: status.height,
        synced: status.height + 10 >= status.target_height,
    })
}

/// The light wallet server LWS-mode wallets on `network` use, if one is
/// set. Kilonova never picks one.
///
/// # Errors
///
/// Fails if the settings cannot be read.
pub fn lws_server(network: Network) -> Result<Option<String>, NodeError> {
    Ok(load()?.get(key(network)).and_then(|n| n.lws.clone()))
}

/// Sets the light wallet server for `network`. Returns the normalized URL.
///
/// # Errors
///
/// [`NodeError::BadUrl`] for anything that is not `host:port` or an
/// http(s) URL.
pub fn set_lws_server(network: Network, url: String) -> Result<String, NodeError> {
    let url = NodeUrl::parse(&url)?.as_str().to_owned();
    let mut settings = load()?;
    settings.entry(key(network).to_owned()).or_default().lws = Some(url.clone());
    save(&settings)?;
    Ok(url)
}

/// Forgets the light wallet server for `network`.
///
/// # Errors
///
/// Fails if the settings cannot be written.
pub fn clear_lws_server(network: Network) -> Result<(), NodeError> {
    let mut settings = load()?;
    settings.entry(key(network).to_owned()).or_default().lws = None;
    save(&settings)
}

/// What a light wallet server reported when checked.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LwsHealth {
    pub height: u64,
    pub server_type: Option<String>,
}

/// Contacts a light wallet server and checks its network where it says.
/// Sends no keys.
///
/// # Errors
///
/// [`NodeError::WrongNetwork`] or [`NodeError::Unreachable`].
pub fn check_lws_server(network: Network, url: String) -> Result<LwsHealth, NodeError> {
    let url = NodeUrl::parse(&url)?;
    let info = RUNTIME.block_on(check_lws(&url, network.into()))?;
    Ok(LwsHealth {
        height: info.height,
        server_type: info.server_type,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn node_settings_round_trip() {
        crate::test_store::init();

        // First use picks a bundled node and remembers it.
        let first = nodes(Network::Testnet).unwrap();
        let picked: Vec<_> = first.iter().filter(|n| n.selected).collect();
        assert_eq!(picked.len(), 1);
        assert!(picked[0].bundled);
        assert_eq!(nodes(Network::Testnet).unwrap(), first);

        // Adding normalizes and selects.
        let added = add_node(Network::Testnet, "my.node.example:28081 ".into()).unwrap();
        assert_eq!(added, "http://my.node.example:28081");
        let list = nodes(Network::Testnet).unwrap();
        assert!(
            list.iter()
                .any(|n| n.url == added && n.selected && !n.bundled)
        );
        assert_eq!(
            add_node(Network::Testnet, "ftp://x".into()),
            Err(NodeError::BadUrl)
        );

        // Selecting an unlisted address lists it.
        select_node(Network::Testnet, "http://10.0.0.2:28089".into()).unwrap();
        assert!(
            nodes(Network::Testnet)
                .unwrap()
                .iter()
                .any(|n| n.url == "http://10.0.0.2:28089" && n.selected)
        );

        // Removing the selected node falls back to a bundled one.
        remove_node(Network::Testnet, "http://10.0.0.2:28089".into()).unwrap();
        let after = nodes(Network::Testnet).unwrap();
        assert!(after.iter().filter(|n| n.selected).all(|n| n.bundled));
        assert_eq!(after.iter().filter(|n| n.selected).count(), 1);

        // Light wallet servers have no default and are kept per network.
        assert_eq!(lws_server(Network::Stagenet).unwrap(), None);
        assert_eq!(
            set_lws_server(Network::Stagenet, "lws.example:8443".into()).unwrap(),
            "http://lws.example:8443"
        );
        assert_eq!(
            lws_server(Network::Stagenet).unwrap().as_deref(),
            Some("http://lws.example:8443")
        );
        assert_eq!(lws_server(Network::Testnet).unwrap(), None);
        clear_lws_server(Network::Stagenet).unwrap();
        assert_eq!(lws_server(Network::Stagenet).unwrap(), None);
    }
}
