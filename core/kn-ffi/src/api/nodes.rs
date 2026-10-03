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

use kn_sync::{
    NodeUrl, ProxyUrl, SyncError, bundled_nodes, check_lws, check_proxy, connect,
    server_certificate, set_pins, set_proxy,
};
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
    /// Not a valid proxy address.
    BadProxy,
    /// An onion address without a Tor proxy set.
    NeedsTor,
    /// The server's certificate is not from a public authority (or not the
    /// one pinned). See [`server_certificate_info`].
    UntrustedCertificate,
    /// A light wallet server on plain http elsewhere than this device.
    InsecureLws,
    /// Looking on the local network would bypass the proxy the owner set.
    ProxyOn,
}

impl From<SyncError> for NodeError {
    fn from(e: SyncError) -> Self {
        match e {
            SyncError::BadNodeUrl => Self::BadUrl,
            SyncError::WrongNetwork => Self::WrongNetwork,
            SyncError::BadProxyUrl => Self::BadProxy,
            SyncError::NeedsProxy => Self::NeedsTor,
            SyncError::InsecureLws => Self::InsecureLws,
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
    /// Trusted through a pinned certificate.
    pub pinned: bool,
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
    let entry = settings
        .networks
        .entry(key(network).to_owned())
        .or_default();
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
        .networks
        .get(key(network))
        .map(|n| n.custom.clone())
        .unwrap_or_default();
    let mut out: Vec<NodeChoice> = custom
        .into_iter()
        .map(|url| NodeChoice {
            selected: url == selected.as_str(),
            pinned: settings.pins.contains_key(&url),
            url,
            bundled: false,
        })
        .collect();
    out.extend(
        bundled_nodes(network.into())
            .into_iter()
            .map(|url| NodeChoice {
                selected: url == selected,
                pinned: settings.pins.contains_key(url.as_str()),
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
    let entry = settings
        .networks
        .entry(key(network).to_owned())
        .or_default();
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
    let entry = settings
        .networks
        .entry(key(network).to_owned())
        .or_default();
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
    let entry = settings
        .networks
        .entry(key(network).to_owned())
        .or_default();
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
    let (_, status) = RUNTIME
        .block_on(connect(&url, network.into()))
        .map_err(|e| explain(&url, e))?;
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
    Ok(load()?
        .networks
        .get(key(network))
        .and_then(|n| n.lws.clone()))
}

/// Sets the light wallet server for `network`. Returns the normalized URL.
///
/// # Errors
///
/// [`NodeError::BadUrl`] for anything that is not `host:port` or an
/// http(s) URL.
pub fn set_lws_server(network: Network, url: String) -> Result<String, NodeError> {
    // `host:port` means https here: the server receives the view key.
    let parsed = NodeUrl::parse_https_default(&url)?;
    if !parsed.is_private_channel() {
        return Err(NodeError::InsecureLws);
    }
    let url = parsed.as_str().to_owned();
    let mut settings = load()?;
    settings
        .networks
        .entry(key(network).to_owned())
        .or_default()
        .lws = Some(url.clone());
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
    settings
        .networks
        .entry(key(network).to_owned())
        .or_default()
        .lws = None;
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
    let url = NodeUrl::parse_https_default(&url)?;
    let info = RUNTIME
        .block_on(check_lws(&url, network.into()))
        .map_err(|e| explain(&url, e))?;
    Ok(LwsHealth {
        height: info.height,
        server_type: info.server_type,
    })
}

/// Turns a failed check into [`NodeError::UntrustedCertificate`] when the
/// reason is an https server whose certificate nobody vouches for.
fn explain(url: &NodeUrl, e: SyncError) -> NodeError {
    let error = NodeError::from(e);
    if error != NodeError::Unreachable || !url.as_str().starts_with("https://") {
        return error;
    }
    match RUNTIME.block_on(server_certificate(url)) {
        Ok(info) if !info.publicly_trusted => NodeError::UntrustedCertificate,
        _ => error,
    }
}

/// A server's certificate, for the user to compare before trusting it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CertificateDetails {
    /// SHA-256 of the certificate, as colon-separated hex pairs.
    pub fingerprint: String,
    /// Issued by a public authority, so no pin is needed.
    pub publicly_trusted: bool,
    /// The pinned fingerprint for this address, if any.
    pub pinned: Option<String>,
}

/// Reads the certificate an https node or server presents, without sending
/// it anything.
///
/// # Errors
///
/// [`NodeError::BadUrl`] for an http address, [`NodeError::Unreachable`]
/// if no certificate could be read.
pub fn server_certificate_info(url: String) -> Result<CertificateDetails, NodeError> {
    let url = NodeUrl::parse(&url)?;
    let info = RUNTIME.block_on(server_certificate(&url))?;
    Ok(CertificateDetails {
        fingerprint: colon_hex(&info.fingerprint),
        publicly_trusted: info.publicly_trusted,
        pinned: load()?.pins.get(url.as_str()).cloned(),
    })
}

/// Trusts `url` for the certificate with `fingerprint` (as returned by
/// [`server_certificate_info`]) and nothing else.
///
/// # Errors
///
/// [`NodeError::BadUrl`] for a bad address or fingerprint.
pub fn trust_certificate(url: String, fingerprint: String) -> Result<(), NodeError> {
    let url = NodeUrl::parse(&url)?;
    let pin = parse_fingerprint(&fingerprint).ok_or(NodeError::BadUrl)?;
    let mut settings = load()?;
    settings
        .pins
        .insert(url.as_str().to_owned(), colon_hex(&pin));
    save(&settings)?;
    apply_saved_pins(&settings);
    Ok(())
}

/// Removes the pinned certificate for `url`.
///
/// # Errors
///
/// Fails if the settings cannot be saved.
pub fn forget_certificate(url: String) -> Result<(), NodeError> {
    let url = NodeUrl::parse(&url)?;
    let mut settings = load()?;
    settings.pins.remove(url.as_str());
    save(&settings)?;
    apply_saved_pins(&settings);
    Ok(())
}

fn colon_hex(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|b| format!("{b:02X}"))
        .collect::<Vec<_>>()
        .join(":")
}

fn parse_fingerprint(text: &str) -> Option<[u8; 32]> {
    let hex: String = text.chars().filter(char::is_ascii_hexdigit).collect();
    let bytes: Vec<u8> = (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(hex.get(i..i + 2)?, 16).ok())
        .collect::<Option<_>>()?;
    bytes.try_into().ok()
}

fn apply_saved_pins(settings: &crate::node_settings::Settings) {
    set_pins(
        settings
            .pins
            .iter()
            .filter_map(|(url, pin)| Some((NodeUrl::parse(url).ok()?, parse_fingerprint(pin)?))),
    );
}

/// What pairing with a self-hosted server set.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerPaired {
    pub network: Network,
    /// The node now selected for that network, if the code named one.
    pub node: Option<String>,
    /// The light wallet server now set, if the code named one.
    pub lws: Option<String>,
    /// The addresses are onion services and no Tor proxy is set yet.
    pub needs_tor: bool,
}

/// Uses the node and light wallet server a self-hosted server's pairing
/// code names (see `tools/selfhost`).
///
/// # Errors
///
/// [`NodeError::BadUrl`] for anything that is not a pairing code.
pub fn pair_with_server(code: String) -> Result<ServerPaired, NodeError> {
    let pairing = kn_sync::ServerPairing::parse(&code)?;
    let network: Network = pairing.network.into();
    if let Some(node) = &pairing.node {
        add_node(network, node.as_str().to_owned())?;
        select_node(network, node.as_str().to_owned())?;
    }
    if let Some(lws) = &pairing.lws {
        set_lws_server(network, lws.as_str().to_owned())?;
    }
    let onion = pairing.node.as_ref().is_some_and(NodeUrl::is_onion)
        || pairing.lws.as_ref().is_some_and(NodeUrl::is_onion);
    Ok(ServerPaired {
        network,
        node: pairing.node.map(|n| n.as_str().to_owned()),
        lws: pairing.lws.map(|n| n.as_str().to_owned()),
        needs_tor: onion && load()?.proxy.is_none(),
    })
}

/// A node found on the local network.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalNode {
    pub url: String,
    pub height: u64,
    pub synced: bool,
}

/// Looks for nodes serving `network` on this machine and the local network
/// (the standard RPC ports on the local /24). Takes a few seconds.
///
/// # Errors
///
/// [`NodeError::ProxyOn`] while a proxy is set: the scan cannot go through
/// it, and would show the local network what the owner is looking for.
pub fn find_local_nodes(network: Network) -> Result<Vec<LocalNode>, NodeError> {
    if load()?.proxy.is_some() {
        return Err(NodeError::ProxyOn);
    }
    let found = RUNTIME.block_on(kn_sync::discover(Some(network.into())));
    Ok(found
        .into_iter()
        .map(|n| LocalNode {
            url: n.url.as_str().to_owned(),
            height: n.height,
            synced: n.synced,
        })
        .collect())
}

/// The SOCKS5 proxy (for example Tor) all traffic goes through, if any.
///
/// # Errors
///
/// Fails if the settings cannot be read.
pub fn network_proxy() -> Result<Option<String>, NodeError> {
    Ok(load()?.proxy)
}

/// Sends all traffic through `url` from now on, or directly with `None`,
/// and remembers the choice. Returns the normalized address. Restart sync
/// afterwards.
///
/// # Errors
///
/// [`NodeError::BadProxy`] for an invalid address.
pub fn set_network_proxy(url: Option<String>) -> Result<Option<String>, NodeError> {
    let parsed = url.as_deref().map(ProxyUrl::parse).transpose()?;
    let mut settings = load()?;
    settings.proxy = parsed.as_ref().map(|p| p.as_str().to_owned());
    save(&settings)?;
    set_proxy(parsed);
    Ok(settings.proxy)
}

/// Checks that a SOCKS5 proxy answers at `url`, without sending anything
/// through it.
///
/// # Errors
///
/// [`NodeError::BadProxy`] or [`NodeError::Unreachable`].
pub fn check_network_proxy(url: String) -> Result<String, NodeError> {
    let parsed = ProxyUrl::parse(&url)?;
    RUNTIME.block_on(check_proxy(&parsed))?;
    Ok(parsed.as_str().to_owned())
}

/// Applies the saved proxy and pinned certificates. Called once the store
/// is open.
pub(crate) fn apply_saved_network_settings() {
    let settings = load().unwrap_or_default();
    set_proxy(
        settings
            .proxy
            .as_deref()
            .and_then(|p| ProxyUrl::parse(p).ok()),
    );
    apply_saved_pins(&settings);
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
            "https://lws.example:8443"
        );
        assert_eq!(
            set_lws_server(Network::Stagenet, "http://lws.example:8443".into()),
            Err(NodeError::InsecureLws)
        );
        assert_eq!(
            set_lws_server(Network::Stagenet, "http://127.0.0.1:8443".into()).unwrap(),
            "http://127.0.0.1:8443"
        );
        assert_eq!(
            lws_server(Network::Stagenet).unwrap().as_deref(),
            Some("http://127.0.0.1:8443")
        );
        assert_eq!(lws_server(Network::Testnet).unwrap(), None);
        clear_lws_server(Network::Stagenet).unwrap();
        assert_eq!(lws_server(Network::Stagenet).unwrap(), None);

        // One proxy for everything, normalized to resolve names remotely.
        assert_eq!(network_proxy().unwrap(), None);
        assert_eq!(
            set_network_proxy(Some("127.0.0.1:9050".into())).unwrap(),
            Some("socks5h://127.0.0.1:9050".into())
        );
        assert_eq!(
            network_proxy().unwrap().as_deref(),
            Some("socks5h://127.0.0.1:9050")
        );
        assert_eq!(
            set_network_proxy(Some("http://x:1".into())),
            Err(NodeError::BadProxy)
        );
        assert_eq!(set_network_proxy(None).unwrap(), None);
        assert_eq!(network_proxy().unwrap(), None);
        // The other settings survive.
        assert_eq!(nodes(Network::Testnet).unwrap(), after);

        // Pairing with a self-hosted server sets both, and asks for Tor.
        let onion = "ciczdlujjvdfuvwndzmqpefmndzxelyh3cbip4eqwet6it3tmuwgh2ad.onion";
        let paired = pair_with_server(format!(
            "kilonova-server:?network=stagenet&node=http%3A%2F%2F{onion}%3A18089&lws=http%3A%2F%2F{onion}%3A8443"
        ))
        .unwrap();
        assert!(paired.needs_tor);
        assert_eq!(
            lws_server(Network::Stagenet).unwrap(),
            Some(format!("http://{onion}:8443"))
        );
        assert!(
            nodes(Network::Stagenet)
                .unwrap()
                .iter()
                .any(|n| n.selected && n.url == format!("http://{onion}:18089"))
        );
        assert_eq!(
            pair_with_server("monero:4abc".into()),
            Err(NodeError::BadUrl)
        );
    }
}
