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
