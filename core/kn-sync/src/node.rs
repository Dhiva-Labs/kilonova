//! Talking to a monerod node: the HTTP transport monero-oxide drives, and
//! the bundled list of public nodes.

use std::sync::{Arc, PoisonError, RwLock};
use std::time::Duration;

use kn_keys::Network;
use monero_daemon_rpc::{HttpTransport, MoneroDaemon};
use monero_interface::{InterfaceError, ProvidesBlockchainMeta as _};
use serde::Deserialize;

use crate::SyncError;

/// A Monero node's RPC endpoint, as `http(s)://host:port`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NodeUrl(String);

impl NodeUrl {
    /// Accepts `host:port` (http is assumed) or a full `http(s)://` URL.
    ///
    /// # Errors
    ///
    /// [`SyncError::BadNodeUrl`] for anything else.
    pub fn parse(input: &str) -> Result<Self, SyncError> {
        let input = input.trim().trim_end_matches('/');
        let with_scheme = if input.contains("://") {
            input.to_owned()
        } else {
            format!("http://{input}")
        };
        let parsed = reqwest::Url::parse(&with_scheme).map_err(|_| SyncError::BadNodeUrl)?;
        let scheme_ok = matches!(parsed.scheme(), "http" | "https");
        if !scheme_ok
            || parsed.host_str().is_none()
            || parsed.path() != "/"
            || parsed.query().is_some()
            || !parsed.username().is_empty()
        {
            return Err(SyncError::BadNodeUrl);
        }
        Ok(Self(with_scheme))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// Like [`NodeUrl::parse`], but `host:port` means https: for light
    /// wallet servers, which receive the view key.
    ///
    /// # Errors
    ///
    /// [`SyncError::BadNodeUrl`] for anything but `host:port` or an http(s)
    /// URL.
    pub fn parse_https_default(input: &str) -> Result<Self, SyncError> {
        let trimmed = input.trim();
        if trimmed.contains("://") {
            Self::parse(trimmed)
        } else {
            Self::parse(&format!("https://{trimmed}"))
        }
    }

    fn host(&self) -> Option<String> {
        reqwest::Url::parse(&self.0)
            .ok()?
            .host_str()
            .map(|h| h.trim_end_matches('.').to_ascii_lowercase())
    }

    /// Whether this is a Tor onion service, reachable only through a proxy.
    #[must_use]
    pub fn is_onion(&self) -> bool {
        self.host()
            .is_some_and(|h| h.rsplit('.').next() == Some("onion"))
    }

    /// Whether traffic to this address is protected in transit: https, an
    /// onion service (encrypted by Tor), or this device itself.
    #[must_use]
    pub fn is_private_channel(&self) -> bool {
        if self.0.starts_with("https://") || self.is_onion() {
            return true;
        }
        self.host().is_some_and(|h| {
            let h = h.trim_start_matches('[').trim_end_matches(']');
            h == "localhost"
                || h.parse::<std::net::IpAddr>()
                    .is_ok_and(|ip| ip.is_loopback())
        })
    }
}

/// A SOCKS5 proxy such as Tor, as `socks5h://host:port`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProxyUrl(String);

impl ProxyUrl {
    /// Accepts `host:port` or a `socks5://` / `socks5h://` URL. Host names
    /// are always resolved by the proxy (`socks5h`), so DNS lookups do not
    /// leak around it.
    ///
    /// # Errors
    ///
    /// [`SyncError::BadProxyUrl`] for anything else.
    pub fn parse(input: &str) -> Result<Self, SyncError> {
        let input = input.trim().trim_end_matches('/');
        let rest = input
            .strip_prefix("socks5h://")
            .or_else(|| input.strip_prefix("socks5://"))
            .unwrap_or(input);
        if rest.contains("://") {
            return Err(SyncError::BadProxyUrl);
        }
        let url = format!("socks5h://{rest}");
        let parsed = reqwest::Url::parse(&url).map_err(|_| SyncError::BadProxyUrl)?;
        if parsed.host_str().is_none_or(str::is_empty)
            || parsed.port().is_none()
            || parsed.path() != "/" && !parsed.path().is_empty()
            || parsed.query().is_some()
        {
            return Err(SyncError::BadProxyUrl);
        }
        Ok(Self(url))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Checks that a SOCKS5 proxy answers at `proxy`, with the protocol's
/// greeting only: nothing is sent to any other host. Also learns whether
/// the proxy takes a username and password, which Tor uses to keep
/// connections with different credentials on different circuits.
///
/// # Errors
///
/// [`SyncError::Node`] if nothing answers or it is not a SOCKS5 proxy that
/// accepts connections without a password of its own.
pub async fn check_proxy(proxy: &ProxyUrl) -> Result<(), SyncError> {
    use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
    let url = reqwest::Url::parse(proxy.as_str()).map_err(|_| SyncError::BadProxyUrl)?;
    let host = url.host_str().ok_or(SyncError::BadProxyUrl)?;
    let port = url.port().ok_or(SyncError::BadProxyUrl)?;
    let unreachable = |e: std::io::Error| SyncError::Node(format!("proxy: {e}"));
    let exchange = async {
        let mut stream = tokio::net::TcpStream::connect((host, port))
            .await
            .map_err(unreachable)?;
        // Version 5, two methods offered: none, and username/password
        // (which Tor accepts with any values and uses only to isolate).
        stream.write_all(&[5, 2, 0, 2]).await.map_err(unreachable)?;
        let mut reply = [0u8; 2];
        stream.read_exact(&mut reply).await.map_err(unreachable)?;
        match reply {
            [5, 0] => Ok(false),
            [5, 2] => Ok(true),
            _ => Err(SyncError::Node(
                "not a SOCKS5 proxy without a password".into(),
            )),
        }
    };
    let isolates = tokio::time::timeout(Duration::from_secs(10), exchange)
        .await
        .map_err(|_| SyncError::Node("proxy did not answer".into()))??;
    let mut current = PROXY.write().unwrap_or_else(PoisonError::into_inner);
    if let Some(state) = current.as_mut()
        && state.url == *proxy
    {
        state.isolates = Some(isolates);
    }
    Ok(())
}

/// Learns whether the proxy set with [`set_proxy`] takes credentials, once
/// per proxy, if that is not known yet. A proxy that does not answer is
/// asked again next time.
pub async fn probe_proxy() {
    let unknown = PROXY
        .read()
        .unwrap_or_else(PoisonError::into_inner)
        .as_ref()
        .filter(|s| s.isolates.is_none())
        .map(|s| s.url.clone());
    if let Some(url) = unknown {
        let _ = check_proxy(&url).await;
    }
}

struct ProxyState {
    url: ProxyUrl,
    /// Whether the proxy accepts a username and password; `None` until
    /// [`check_proxy`] has asked.
    isolates: Option<bool>,
}

static PROXY: RwLock<Option<ProxyState>> = RwLock::new(None);

/// Sends every later request, to nodes and light wallet servers alike,
/// through `proxy`, or directly with `None`. Clients already built keep
/// their setting; the app restarts sync after changing it.
pub fn set_proxy(proxy: Option<ProxyUrl>) {
    *PROXY.write().unwrap_or_else(PoisonError::into_inner) = proxy.map(|url| ProxyState {
        url,
        isolates: None,
    });
}

/// The proxy set with [`set_proxy`].
#[must_use]
pub fn proxy() -> Option<ProxyUrl> {
    PROXY
        .read()
        .unwrap_or_else(PoisonError::into_inner)
        .as_ref()
        .map(|s| s.url.clone())
}

/// Why a connection is made. Each purpose of each wallet gets its own
/// SOCKS credentials, and so its own Tor circuit.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Purpose {
    /// Following the chain, or the light wallet server's reports.
    Sync,
    /// Preparing and publishing a transaction.
    Broadcast,
    /// Confirming a light wallet server's payments with a node.
    CrossCheck,
    /// Comparing the wallet's node with an independent one.
    Opinion,
    /// The fiat price.
    Price,
    /// Testing nodes and servers, and reading their certificates.
    Discovery,
    /// Checking a payment proof.
    Proof,
}

impl Purpose {
    fn tag(self) -> &'static str {
        match self {
            Self::Sync => "sync",
            Self::Broadcast => "broadcast",
            Self::CrossCheck => "cross-check",
            Self::Opinion => "opinion",
            Self::Price => "price",
            Self::Discovery => "discovery",
            Self::Proof => "proof",
        }
    }
}

/// Who a connection is for: a wallet, by its id (which is not secret), and
/// a [`Purpose`]. Through Tor, connections for different circuits never
/// share an exit, so a node cannot link two wallets, or one wallet's sync
/// and its broadcast, by address.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Circuit {
    wallet: String,
    purpose: Purpose,
}

impl Circuit {
    #[must_use]
    pub fn new(wallet: &str, purpose: Purpose) -> Self {
        Self {
            wallet: wallet.to_owned(),
            purpose,
        }
    }

    /// For requests that belong to no wallet: the price, node checks.
    #[must_use]
    pub fn app(purpose: Purpose) -> Self {
        Self::new("", purpose)
    }

    /// The SOCKS5 username and password for this circuit: a hash of the
    /// wallet id and purpose, nothing secret, the same every time.
    #[must_use]
    pub fn socks_credentials(&self) -> (String, String) {
        let mut hash = ring::digest::Context::new(&ring::digest::SHA256);
        hash.update(b"kilonova-socks");
        hash.update(&(self.wallet.len() as u64).to_le_bytes());
        hash.update(self.wallet.as_bytes());
        hash.update(self.purpose.tag().as_bytes());
        let digest = hash.finish();
        let bytes = digest.as_ref();
        (hex::encode(&bytes[..12]), hex::encode(&bytes[12..24]))
    }
}

/// A client builder that goes through the proxy from [`set_proxy`] with
/// `circuit`'s credentials, or directly when none is set.
pub(crate) fn client_builder(
    target: &NodeUrl,
    circuit: &Circuit,
) -> Result<reqwest::ClientBuilder, SyncError> {
    let state = PROXY.read().unwrap_or_else(PoisonError::into_inner);
    match state.as_ref() {
        None if target.is_onion() => Err(SyncError::NeedsProxy),
        None => Ok(reqwest::Client::builder().no_proxy()),
        Some(state) => {
            let mut url =
                reqwest::Url::parse(state.url.as_str()).map_err(|_| SyncError::BadProxyUrl)?;
            // Credentials the owner put in the address are theirs to keep;
            // a proxy known to refuse them gets none.
            if url.username().is_empty() && state.isolates != Some(false) {
                let (user, password) = circuit.socks_credentials();
                url.set_username(&user)
                    .and_then(|()| url.set_password(Some(&password)))
                    .map_err(|()| SyncError::BadProxyUrl)?;
            }
            Ok(reqwest::Client::builder()
                .proxy(reqwest::Proxy::all(url.as_str()).map_err(|_| SyncError::BadProxyUrl)?))
        }
    }
}

/// Community nodes shipped with the app, for `network`. Run by third
/// parties; users can add their own.
///
/// # Panics
///
/// Never at runtime: the bundled list is checked by this crate's tests.
#[must_use]
pub fn bundled_nodes(network: Network) -> Vec<NodeUrl> {
    #[derive(Deserialize)]
    struct List {
        mainnet: Vec<String>,
        stagenet: Vec<String>,
        testnet: Vec<String>,
    }
    let list: List =
        serde_json::from_str(include_str!("nodes.json")).expect("bundled node list is valid JSON");
    let urls = match network {
        Network::Mainnet => list.mainnet,
        Network::Stagenet => list.stagenet,
        Network::Testnet => list.testnet,
    };
    urls.iter()
        .map(|u| NodeUrl::parse(u).expect("bundled node URLs are valid"))
        .collect()
}

/// Test chains' stand-ins for the bundled nodes when broadcasting.
static BROADCAST_NODES: RwLock<Vec<(Network, Vec<NodeUrl>)>> = RwLock::new(Vec::new());

/// Replaces the nodes [`broadcast_nodes`] offers for `network`, or restores
/// the bundled list with `None`. For tests on private chains, where no
/// bundled node can help; not a user setting.
#[doc(hidden)]
pub fn set_broadcast_nodes_for_tests(network: Network, nodes: Option<Vec<NodeUrl>>) {
    let mut list = BROADCAST_NODES
        .write()
        .unwrap_or_else(PoisonError::into_inner);
    list.retain(|(n, _)| *n != network);
    if let Some(nodes) = nodes {
        list.push((network, nodes));
    }
}

/// The nodes a transaction can be broadcast through instead of the sync
/// node: the bundled ones for `network`.
#[must_use]
pub fn broadcast_nodes(network: Network) -> Vec<NodeUrl> {
    BROADCAST_NODES
        .read()
        .unwrap_or_else(PoisonError::into_inner)
        .iter()
        .find(|(n, _)| *n == network)
        .map_or_else(|| bundled_nodes(network), |(_, nodes)| nodes.clone())
}

/// One of `candidates` other than `avoid`, chosen uniformly at random, so
/// no single bundled node sees every wallet's broadcasts or checks.
#[must_use]
pub fn other_node(candidates: Vec<NodeUrl>, avoid: &NodeUrl) -> Option<NodeUrl> {
    let mut others: Vec<NodeUrl> = candidates.into_iter().filter(|n| n != avoid).collect();
    if others.is_empty() {
        return None;
    }
    Some(others.swap_remove(crate::random::index(others.len())))
}

/// The HTTP transport monero-oxide's daemon client runs on.
#[derive(Clone)]
pub struct Http {
    client: reqwest::Client,
    base: Arc<str>,
}

/// The HTTP client every Kilonova network request to `target` uses: rustls
/// on ring with Mozilla's roots, timeouts, no identifying user agent, and
/// the proxy from [`set_proxy`] with `circuit`'s credentials (system proxy
/// settings are ignored, so traffic goes exactly where the user chose).
pub(crate) fn http_client(
    target: &NodeUrl,
    circuit: &Circuit,
) -> Result<reqwest::Client, SyncError> {
    let tls = crate::tls::config_for(target);
    client_builder(target, circuit)?
        .tls_backend_preconfigured(tls)
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_mins(2))
        .user_agent("")
        .build()
        .map_err(|e| SyncError::Node(format!("could not set up HTTP: {e}")))
}

impl Http {
    /// A transport for `circuit`; every connection it opens uses that
    /// circuit's proxy credentials.
    ///
    /// # Errors
    ///
    /// Fails only if the TLS stack cannot be set up.
    pub fn new(node: &NodeUrl, circuit: &Circuit) -> Result<Self, SyncError> {
        Ok(Self {
            client: http_client(node, circuit)?,
            base: node.as_str().into(),
        })
    }
}

impl HttpTransport for Http {
    async fn post(
        &self,
        route: &str,
        body: Vec<u8>,
        response_size_limit: Option<usize>,
    ) -> Result<Vec<u8>, InterfaceError> {
        let mut response = self
            .client
            .post(format!("{}/{route}", self.base))
            .body(body)
            .send()
            .await
            .map_err(|e| InterfaceError::InterfaceError(format!("request failed: {e}")))?;
        if !response.status().is_success() {
            return Err(InterfaceError::InterfaceError(format!(
                "node answered HTTP {}",
                response.status()
            )));
        }
        // Read in chunks so an oversized response is cut off, not buffered.
        let mut out = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|e| InterfaceError::InterfaceError(format!("reading response: {e}")))?
        {
            out.extend_from_slice(&chunk);
            if response_size_limit.is_some_and(|limit| out.len() > limit) {
                return Err(InterfaceError::InvalidInterface(
                    "response larger than allowed".into(),
                ));
            }
        }
        Ok(out)
    }
}

/// Reads a response body, failing once it passes `limit` bytes instead of
/// buffering whatever a server sends.
pub(crate) async fn read_limited(
    mut response: reqwest::Response,
    limit: usize,
) -> Result<Vec<u8>, SyncError> {
    let mut out = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|e| SyncError::Node(format!("reading response: {e}")))?
    {
        out.extend_from_slice(&chunk);
        if out.len() > limit {
            return Err(SyncError::Node("response larger than allowed".into()));
        }
    }
    Ok(out)
}

/// What a node reports about itself.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NodeStatus {
    /// Number of blocks the node has.
    pub height: u64,
    /// Height the node believes the network is at; equals `height` when
    /// synced.
    pub target_height: u64,
    /// A private test chain (regtest), which no public node shares.
    pub test_chain: bool,
}

/// Connects to `node` for `circuit` and checks it serves `network`.
///
/// # Errors
///
/// [`SyncError::WrongNetwork`] if it serves another network, otherwise
/// [`SyncError::Node`] when it cannot be reached or answers nonsense.
pub async fn connect(
    node: &NodeUrl,
    network: Network,
    circuit: &Circuit,
) -> Result<(MoneroDaemon<Http>, NodeStatus), SyncError> {
    #[derive(Deserialize)]
    struct Info {
        nettype: String,
        height: u64,
        target_height: u64,
    }

    probe_proxy().await;
    let daemon = MoneroDaemon::new(Http::new(node, circuit)?).await?;
    let raw = daemon.rpc_call("get_info", None, 64 * 1024).await?;
    let info: Info = serde_json::from_str(&raw)
        .map_err(|_| SyncError::Node("unexpected get_info response".into()))?;
    // A regtest node ("fakechain") uses mainnet addresses.
    let served = match info.nettype.as_str() {
        "mainnet" | "fakechain" => Network::Mainnet,
        "stagenet" => Network::Stagenet,
        "testnet" => Network::Testnet,
        _ => return Err(SyncError::Node("unknown network type".into())),
    };
    if served != network {
        return Err(SyncError::WrongNetwork);
    }
    let height = u64::try_from(daemon.latest_block_number().await?)
        .map_err(|_| SyncError::Node("height out of range".into()))?
        + 1;
    Ok((
        daemon,
        NodeStatus {
            height: height.max(info.height),
            target_height: info.target_height.max(height),
            test_chain: info.nettype == "fakechain",
        },
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_node_urls() {
        assert_eq!(
            NodeUrl::parse("node.example.org:18089").unwrap().as_str(),
            "http://node.example.org:18089"
        );
        assert_eq!(
            NodeUrl::parse(" https://node.example.org:18081/ ")
                .unwrap()
                .as_str(),
            "https://node.example.org:18081"
        );
        for bad in [
            "",
            "ftp://node.example.org",
            "http://node.example.org/json_rpc",
            "http://user:pw@node.example.org",
            "http://node.example.org?x=1",
        ] {
            assert!(NodeUrl::parse(bad).is_err(), "{bad:?} should be rejected");
        }
    }

    #[test]
    fn credentials_differ_by_wallet_and_purpose_only() {
        let a = Circuit::new("wallet-a", Purpose::Sync).socks_credentials();
        assert_eq!(
            a,
            Circuit::new("wallet-a", Purpose::Sync).socks_credentials()
        );
        assert_ne!(
            a,
            Circuit::new("wallet-b", Purpose::Sync).socks_credentials()
        );
        assert_ne!(
            a,
            Circuit::new("wallet-a", Purpose::Broadcast).socks_credentials()
        );
        assert_ne!(a, Circuit::app(Purpose::Sync).socks_credentials());
        assert_eq!(a.0.len(), 24);
        assert!(a.0.bytes().all(|b| b.is_ascii_hexdigit()));
    }

    #[test]
    fn another_node_is_never_the_one_avoided() {
        let a = NodeUrl::parse("a.example:1").unwrap();
        let b = NodeUrl::parse("b.example:1").unwrap();
        let c = NodeUrl::parse("c.example:1").unwrap();
        let (mut saw_b, mut saw_c) = (false, false);
        for _ in 0..200 {
            let pick = other_node(vec![a.clone(), b.clone(), c.clone()], &a).unwrap();
            assert_ne!(pick, a);
            saw_b |= pick == b;
            saw_c |= pick == c;
        }
        assert!(saw_b && saw_c, "the choice is random");
        assert_eq!(other_node(vec![a.clone()], &a), None);
    }

    #[test]
    fn bundled_lists_are_non_empty_for_every_network() {
        for network in [Network::Mainnet, Network::Stagenet, Network::Testnet] {
            assert!(!bundled_nodes(network).is_empty());
        }
    }
}

/// What a self-hosted server's pairing code names (see `tools/selfhost`):
/// `kilonova-server:?network=mainnet&node=<url>&lws=<url>`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ServerPairing {
    pub network: Network,
    pub node: Option<NodeUrl>,
    pub lws: Option<NodeUrl>,
}

impl ServerPairing {
    /// # Errors
    ///
    /// [`SyncError::BadNodeUrl`] for anything that is not a pairing code
    /// with at least one valid address.
    pub fn parse(text: &str) -> Result<Self, SyncError> {
        let query = text
            .trim()
            .strip_prefix("kilonova-server:")
            .ok_or(SyncError::BadNodeUrl)?
            .trim_start_matches('?');
        let mut network = None;
        let mut node = None;
        let mut lws = None;
        for pair in query.split('&').filter(|p| !p.is_empty()) {
            let (key, value) = pair.split_once('=').ok_or(SyncError::BadNodeUrl)?;
            let value = percent_decode(value).ok_or(SyncError::BadNodeUrl)?;
            match key {
                "network" => {
                    network = Some(match value.as_str() {
                        "mainnet" => Network::Mainnet,
                        "stagenet" => Network::Stagenet,
                        "testnet" => Network::Testnet,
                        _ => return Err(SyncError::BadNodeUrl),
                    });
                }
                "node" => node = Some(NodeUrl::parse(&value)?),
                "lws" => lws = Some(NodeUrl::parse(&value)?),
                // Later versions may add fields; ignore what is not known.
                _ => {}
            }
        }
        if node.is_none() && lws.is_none() {
            return Err(SyncError::BadNodeUrl);
        }
        Ok(Self {
            network: network.ok_or(SyncError::BadNodeUrl)?,
            node,
            lws,
        })
    }
}

fn percent_decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = std::str::from_utf8(bytes.get(i + 1..i + 3)?).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

#[cfg(test)]
mod pairing_tests {
    use super::*;

    #[test]
    fn reads_the_code_the_selfhost_kit_prints() {
        let onion = "ciczdlujjvdfuvwndzmqpefmndzxelyh3cbip4eqwet6it3tmuwgh2ad.onion";
        let code = format!(
            "kilonova-server:?network=mainnet&node=http%3A%2F%2F{onion}%3A18089&lws=http%3A%2F%2F{onion}%3A8443"
        );
        let pairing = ServerPairing::parse(&code).unwrap();
        assert_eq!(pairing.network, Network::Mainnet);
        assert_eq!(
            pairing.node.unwrap().as_str(),
            format!("http://{onion}:18089")
        );
        let lws = pairing.lws.unwrap();
        assert!(lws.is_onion() && lws.is_private_channel());
        for bad in [
            "monero:4abc",
            "kilonova-server:?network=mainnet",
            "kilonova-server:?network=moon&node=http%3A%2F%2Fa.onion%3A1",
            "kilonova-server:?node=http%3A%2F%2Fa.onion%3A1",
            "kilonova-server:?network=mainnet&node=%ZZ",
        ] {
            assert!(ServerPairing::parse(bad).is_err(), "{bad}");
        }
    }
}
