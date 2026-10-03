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
/// greeting only: nothing is sent to any other host.
///
/// # Errors
///
/// [`SyncError::Node`] if nothing answers or it is not a SOCKS5 proxy that
/// accepts connections without a password.
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
        // Version 5, one method offered: no authentication.
        stream.write_all(&[5, 1, 0]).await.map_err(unreachable)?;
        let mut reply = [0u8; 2];
        stream.read_exact(&mut reply).await.map_err(unreachable)?;
        if reply == [5, 0] {
            Ok(())
        } else {
            Err(SyncError::Node(
                "not a SOCKS5 proxy without a password".into(),
            ))
        }
    };
    tokio::time::timeout(Duration::from_secs(10), exchange)
        .await
        .map_err(|_| SyncError::Node("proxy did not answer".into()))?
}

static PROXY: RwLock<Option<ProxyUrl>> = RwLock::new(None);

/// Sends every later request, to nodes and light wallet servers alike,
/// through `proxy`, or directly with `None`. Clients already built keep
/// their setting; the app restarts sync after changing it.
pub fn set_proxy(proxy: Option<ProxyUrl>) {
    *PROXY.write().unwrap_or_else(PoisonError::into_inner) = proxy;
}

/// The proxy set with [`set_proxy`].
#[must_use]
pub fn proxy() -> Option<ProxyUrl> {
    PROXY.read().unwrap_or_else(PoisonError::into_inner).clone()
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

/// The HTTP transport monero-oxide's daemon client runs on.
#[derive(Clone)]
pub struct Http {
    client: reqwest::Client,
    base: Arc<str>,
}

/// The HTTP client every Kilonova network request to `target` uses: rustls
/// on ring with Mozilla's roots, timeouts, no identifying user agent, and
/// the proxy from [`set_proxy`] (system proxy settings are ignored, so
/// traffic goes exactly where the user chose).
pub(crate) fn http_client(target: &NodeUrl) -> Result<reqwest::Client, SyncError> {
    let proxy = proxy();
    if proxy.is_none() && target.is_onion() {
        return Err(SyncError::NeedsProxy);
    }
    let tls = crate::tls::config_for(target);
    let builder = match proxy {
        Some(p) => reqwest::Client::builder()
            .proxy(reqwest::Proxy::all(p.as_str()).map_err(|_| SyncError::BadProxyUrl)?),
        None => reqwest::Client::builder().no_proxy(),
    };
    builder
        .tls_backend_preconfigured(tls)
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_mins(2))
        .user_agent("")
        .build()
        .map_err(|e| SyncError::Node(format!("could not set up HTTP: {e}")))
}

impl Http {
    /// # Errors
    ///
    /// Fails only if the TLS stack cannot be set up.
    pub fn new(node: &NodeUrl) -> Result<Self, SyncError> {
        Ok(Self {
            client: http_client(node)?,
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

/// Connects to `node` and checks it serves `network`.
///
/// # Errors
///
/// [`SyncError::WrongNetwork`] if it serves another network, otherwise
/// [`SyncError::Node`] when it cannot be reached or answers nonsense.
pub async fn connect(
    node: &NodeUrl,
    network: Network,
) -> Result<(MoneroDaemon<Http>, NodeStatus), SyncError> {
    #[derive(Deserialize)]
    struct Info {
        nettype: String,
        height: u64,
        target_height: u64,
    }

    let daemon = MoneroDaemon::new(Http::new(node)?).await?;
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
