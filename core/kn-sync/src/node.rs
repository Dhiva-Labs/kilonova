//! Talking to a monerod node: the HTTP transport monero-oxide drives, and
//! the bundled list of public nodes.

use std::{sync::Arc, time::Duration};

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

impl Http {
    /// # Errors
    ///
    /// Fails only if the TLS stack cannot be set up.
    pub fn new(node: &NodeUrl) -> Result<Self, SyncError> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let mut roots = rustls::RootCertStore::empty();
        roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
        let tls = rustls::ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth();
        let client = reqwest::Client::builder()
            .tls_backend_preconfigured(tls)
            .connect_timeout(Duration::from_secs(15))
            .timeout(Duration::from_mins(2))
            .user_agent("")
            .build()
            .map_err(|e| SyncError::Node(format!("could not set up HTTP: {e}")))?;
        Ok(Self {
            client,
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

/// What a node reports about itself.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NodeStatus {
    /// Number of blocks the node has.
    pub height: u64,
    /// Height the node believes the network is at; equals `height` when
    /// synced.
    pub target_height: u64,
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
