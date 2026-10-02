/// The Monero network a wallet belongs to.
///
/// A wallet's network is fixed when it is created, because address prefixes
/// differ between networks. Stagenet and testnet coins have no value.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Network {
    Mainnet,
    Stagenet,
    Testnet,
}

impl Network {
    /// True for networks whose coins have no value.
    #[flutter_rust_bridge::frb(sync)]
    #[must_use]
    pub fn is_test_network(&self) -> bool {
        !matches!(self, Network::Mainnet)
    }
}

impl From<Network> for kn_keys::Network {
    fn from(network: Network) -> Self {
        match network {
            Network::Mainnet => Self::Mainnet,
            Network::Stagenet => Self::Stagenet,
            Network::Testnet => Self::Testnet,
        }
    }
}

impl From<kn_keys::Network> for Network {
    fn from(network: kn_keys::Network) -> Self {
        match network {
            kn_keys::Network::Mainnet => Self::Mainnet,
            kn_keys::Network::Stagenet => Self::Stagenet,
            kn_keys::Network::Testnet => Self::Testnet,
        }
    }
}

/// All networks, in the order the network switcher shows them.
#[flutter_rust_bridge::frb(sync)]
#[must_use]
pub fn all_networks() -> Vec<Network> {
    vec![Network::Mainnet, Network::Stagenet, Network::Testnet]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_mainnet_has_value() {
        let test_nets: Vec<_> = all_networks()
            .into_iter()
            .filter(Network::is_test_network)
            .collect();
        assert_eq!(test_nets, vec![Network::Stagenet, Network::Testnet]);
    }
}
