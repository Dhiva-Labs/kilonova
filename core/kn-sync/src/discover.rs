//! Finding Monero nodes on the local network, so using your own node does
//! not start with looking up its address. Probes the standard RPC ports on
//! this machine and the local /24, then asks each open port which network it
//! serves. Nothing leaves the local network.

use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket};
use std::time::Duration;

use kn_keys::Network;
use tokio::net::TcpStream;
use tokio::task::JoinSet;

use crate::node::{NodeUrl, connect};

/// Ports monerod listens on for RPC: full and restricted, per network.
const PORTS: &[(u16, Network)] = &[
    (18081, Network::Mainnet),
    (18089, Network::Mainnet),
    (38081, Network::Stagenet),
    (38089, Network::Stagenet),
    (28081, Network::Testnet),
    (28089, Network::Testnet),
];

const PROBE_TIMEOUT: Duration = Duration::from_millis(400);
const CONCURRENT_PROBES: usize = 128;

/// A node that answered on the local network.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FoundNode {
    pub url: NodeUrl,
    pub network: Network,
    pub height: u64,
    pub synced: bool,
}

/// This machine's address on the local network, found without sending
/// anything: connecting a UDP socket only picks the outgoing interface.
#[must_use]
pub fn local_ipv4() -> Option<Ipv4Addr> {
    let socket = UdpSocket::bind(("0.0.0.0", 0)).ok()?;
    socket.connect(("192.0.2.1", 9)).ok()?;
    match socket.local_addr().ok()?.ip() {
        IpAddr::V4(ip) if ip.is_private() => Some(ip),
        _ => None,
    }
}

/// Every address worth probing: this machine, and the local /24 when the
/// machine is on a private network.
fn candidates() -> Vec<Ipv4Addr> {
    let mut hosts = vec![Ipv4Addr::LOCALHOST];
    if let Some(ip) = local_ipv4() {
        let [a, b, c, _] = ip.octets();
        hosts.extend((1..=254).map(|d| Ipv4Addr::new(a, b, c, d)));
    }
    hosts
}

/// Looks for nodes serving `network` (or any network with `None`).
pub async fn discover(network: Option<Network>) -> Vec<FoundNode> {
    let ports: Vec<(u16, Network)> = PORTS
        .iter()
        .filter(|(_, n)| network.is_none_or(|want| *n == want))
        .copied()
        .collect();
    discover_at(&candidates(), &ports).await
}

/// [`discover`] over given hosts and `(port, network)` pairs.
pub async fn discover_at(hosts: &[Ipv4Addr], ports: &[(u16, Network)]) -> Vec<FoundNode> {
    let targets: Vec<SocketAddr> = hosts
        .iter()
        .flat_map(|ip| {
            ports
                .iter()
                .map(move |(p, _)| SocketAddr::new(IpAddr::V4(*ip), *p))
        })
        .collect();

    // Open ports first: plain TCP connects, many at a time.
    let mut open = Vec::new();
    let mut probes = JoinSet::new();
    for target in targets {
        if probes.len() >= CONCURRENT_PROBES
            && let Some(Ok(Some(found))) = probes.join_next().await
        {
            open.push(found);
        }
        probes.spawn(async move {
            tokio::time::timeout(PROBE_TIMEOUT, TcpStream::connect(target))
                .await
                .ok()?
                .ok()
                .map(|_| target)
        });
    }
    while let Some(result) = probes.join_next().await {
        if let Ok(Some(found)) = result {
            open.push(found);
        }
    }

    // Then ask each what it is.
    let mut found = Vec::new();
    for target in open {
        let Some(&(_, expected)) = ports.iter().find(|(p, _)| *p == target.port()) else {
            continue;
        };
        let Ok(url) = NodeUrl::parse(&format!("http://{target}")) else {
            continue;
        };
        if let Ok(Ok((_, status))) =
            tokio::time::timeout(Duration::from_secs(5), connect(&url, expected)).await
        {
            found.push(FoundNode {
                url,
                network: expected,
                height: status.height,
                synced: status.height + 10 >= status.target_height,
            });
        }
    }
    found
}
