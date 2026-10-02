//! Checks kn-keys against wallets created by monero-wallet-rpc.
//!
//! `vectors.json` is produced by `tools/vectors/gen_key_vectors.py`.

use kn_keys::{KeyError, Network, SeedFormat, WalletKeys};
use serde::Deserialize;

#[derive(Deserialize)]
struct Vectors {
    networks: Vec<NetworkVectors>,
}

#[derive(Deserialize)]
struct NetworkVectors {
    network: String,
    classic: Wallet,
    polyseed: Wallet,
}

#[derive(Deserialize)]
struct Wallet {
    mnemonic: Option<String>,
    words: Option<String>,
    spend_key: String,
    view_key: String,
    address: String,
    subaddresses: Vec<Sub>,
}

#[derive(Deserialize)]
struct Sub {
    account: u32,
    index: u32,
    address: String,
}

fn vectors() -> Vec<(Network, NetworkVectors)> {
    let parsed: Vectors = serde_json::from_str(include_str!("vectors.json")).unwrap();
    parsed
        .networks
        .into_iter()
        .map(|v| {
            let network = match v.network.as_str() {
                "mainnet" => Network::Mainnet,
                "stagenet" => Network::Stagenet,
                "testnet" => Network::Testnet,
                other => panic!("unknown network {other}"),
            };
            (network, v)
        })
        .collect()
}

fn assert_wallet(keys: &WalletKeys, network: Network, expected: &Wallet) {
    assert_eq!(keys.secret_view_key_hex().as_str(), expected.view_key);
    assert_eq!(keys.primary_address(network), expected.address);
    assert_eq!(keys.address(network, 0, 0).unwrap(), expected.address);
    for sub in &expected.subaddresses {
        assert_eq!(
            keys.address(network, sub.account, sub.index).unwrap(),
            sub.address,
            "subaddress {}/{} on {network:?}",
            sub.account,
            sub.index,
        );
    }
}

#[test]
fn classic_seed_matches_monero_wallet_rpc() {
    for (network, v) in vectors() {
        let words = v.classic.mnemonic.as_deref().unwrap();
        let (keys, mnemonic) = WalletKeys::from_mnemonic(words).unwrap();
        assert_eq!(mnemonic.format, SeedFormat::Classic);
        assert_eq!(mnemonic.words.as_str(), words);
        assert_eq!(
            keys.secret_spend_key_hex().unwrap().as_str(),
            v.classic.spend_key
        );
        assert_wallet(&keys, network, &v.classic);
    }
}

#[test]
fn polyseed_matches_monero_wallet_rpc() {
    for (network, v) in vectors() {
        let words = v.polyseed.words.as_deref().unwrap();
        let (keys, mnemonic) = WalletKeys::from_mnemonic(words).unwrap();
        assert_eq!(mnemonic.format, SeedFormat::Polyseed);
        assert!(mnemonic.birthday.is_some());
        assert_eq!(
            keys.secret_spend_key_hex().unwrap().as_str(),
            v.polyseed.spend_key
        );
        assert_wallet(&keys, network, &v.polyseed);
    }
}

#[test]
fn spend_key_restore_matches_seed_restore() {
    for (network, v) in vectors() {
        let keys = WalletKeys::from_spend_key(&v.classic.spend_key).unwrap();
        assert_wallet(&keys, network, &v.classic);
    }
}

#[test]
fn view_only_wallet_derives_the_same_addresses() {
    for (network, v) in vectors() {
        let keys = WalletKeys::view_only(network, &v.classic.address, &v.classic.view_key).unwrap();
        assert!(keys.is_view_only());
        assert!(keys.secret_spend_key_hex().is_none());
        assert_wallet(&keys, network, &v.classic);
    }
}

#[test]
fn view_only_rejects_wrong_view_key() {
    let all = vectors();
    let (network, v) = &all[0];
    let err =
        WalletKeys::view_only(*network, &v.classic.address, &v.polyseed.view_key).unwrap_err();
    assert_eq!(err, KeyError::ViewKeyMismatch);
}

#[test]
fn view_only_rejects_address_from_another_network() {
    let all = vectors();
    let mainnet = &all.iter().find(|(n, _)| *n == Network::Mainnet).unwrap().1;
    let err = WalletKeys::view_only(
        Network::Stagenet,
        &mainnet.classic.address,
        &mainnet.classic.view_key,
    )
    .unwrap_err();
    assert_eq!(err, KeyError::BadAddress(Network::Stagenet));
}

#[test]
fn view_only_rejects_subaddress() {
    let all = vectors();
    let (network, v) = &all[0];
    let err = WalletKeys::view_only(
        *network,
        &v.classic.subaddresses[0].address,
        &v.classic.view_key,
    )
    .unwrap_err();
    assert_eq!(err, KeyError::NotStandardAddress);
}

#[test]
fn mnemonic_input_is_normalized() {
    let all = vectors();
    let (_, v) = &all[0];
    let words = v.classic.mnemonic.as_deref().unwrap();
    let messy = format!("  {}\n", words.to_uppercase().replace(' ', "   "));
    let (keys, _) = WalletKeys::from_mnemonic(&messy).unwrap();
    assert_eq!(
        keys.secret_spend_key_hex().unwrap().as_str(),
        v.classic.spend_key
    );
}

#[test]
fn mnemonic_errors_are_specific() {
    let all = vectors();
    let (_, v) = &all[0];
    let words: Vec<&str> = v.classic.mnemonic.as_deref().unwrap().split(' ').collect();

    assert_eq!(
        WalletKeys::from_mnemonic(&words[..24].join(" ")).unwrap_err(),
        KeyError::WrongWordCount(24)
    );

    let mut unknown = words.clone();
    unknown[3] = "kilonova";
    assert_eq!(
        WalletKeys::from_mnemonic(&unknown.join(" ")).unwrap_err(),
        KeyError::UnknownWord
    );

    let mut swapped = words.clone();
    swapped.swap(0, 1);
    assert!(matches!(
        WalletKeys::from_mnemonic(&swapped.join(" ")).unwrap_err(),
        KeyError::BadChecksum
    ));
}

#[test]
fn malformed_keys_are_rejected() {
    assert_eq!(
        WalletKeys::from_spend_key("abc").unwrap_err(),
        KeyError::MalformedKey
    );
    assert_eq!(
        WalletKeys::from_spend_key(&"zz".repeat(32)).unwrap_err(),
        KeyError::MalformedKey
    );
    // Larger than the group order, so not a valid private key.
    assert_eq!(
        WalletKeys::from_spend_key(&"ff".repeat(32)).unwrap_err(),
        KeyError::NonCanonicalKey
    );
}

#[test]
fn generated_wallets_round_trip_through_their_mnemonic() {
    for format in [SeedFormat::Classic, SeedFormat::Polyseed] {
        let (keys, mnemonic) = WalletKeys::generate(format);
        assert_eq!(mnemonic.format, format);
        let (restored, again) = WalletKeys::from_mnemonic(&mnemonic.words).unwrap();
        assert_eq!(again.words.as_str(), mnemonic.words.as_str());
        assert_eq!(
            restored.primary_address(Network::Mainnet),
            keys.primary_address(Network::Mainnet)
        );
    }
}

#[test]
fn debug_output_hides_secrets() {
    let (keys, mnemonic) = WalletKeys::generate(SeedFormat::Classic);
    let spend = keys.secret_spend_key_hex().unwrap();
    let rendered = format!("{keys:?} {mnemonic:?}");
    assert!(!rendered.contains(spend.as_str()));
    assert!(!rendered.contains(mnemonic.words.as_str()));
}
