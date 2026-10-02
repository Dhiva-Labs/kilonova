//! Light wallet servers report outputs; the wallet must recognise its own
//! and reject the rest. Outputs here are built the way a sender builds them.

use curve25519_dalek::{Scalar as DalekScalar, constants::ED25519_BASEPOINT_TABLE};
use kn_keys::{ClaimedOutput, KeyError, Network, SeedFormat, WalletKeys};
use monero_wallet::address::{MoneroAddress, Network as MoneroNetwork};
use monero_wallet::ed25519::Scalar;
use rand_core::OsRng;

/// Sender side: one-time key and tx public key for output `index` paying
/// `address`, with tx secret `r`.
fn send_to(address: &str, r: DalekScalar, index: u64) -> ([u8; 32], [u8; 32]) {
    let address = MoneroAddress::from_str(MoneroNetwork::Mainnet, address).unwrap();
    let spend: curve25519_dalek::EdwardsPoint = address.spend().into();
    let view: curve25519_dalek::EdwardsPoint = address.view().into();
    // Subaddress payments publish R = rD instead of rG.
    let tx_pub = if address.is_subaddress() {
        r * spend
    } else {
        &r * ED25519_BASEPOINT_TABLE
    };
    let mut derivation = (r * view).mul_by_cofactor().compress().to_bytes().to_vec();
    derivation.push(u8::try_from(index).unwrap()); // varint of a small index
    let shared: DalekScalar = Scalar::hash(&derivation).into();
    let output_key = &shared * ED25519_BASEPOINT_TABLE + spend;
    (
        tx_pub.compress().to_bytes(),
        output_key.compress().to_bytes(),
    )
}

fn claim(tx_pub: [u8; 32], output_key: [u8; 32], index: u64, sub: (u32, u32)) -> ClaimedOutput {
    ClaimedOutput {
        tx_pub_key: tx_pub,
        index_in_tx: index,
        output_key,
        subaddress: sub,
    }
}

#[test]
fn recognises_primary_and_subaddress_outputs() {
    let (keys, _) = WalletKeys::generate(SeedFormat::Classic);
    for (account, minor) in [(0, 0), (0, 3), (2, 7)] {
        let address = keys.address(Network::Mainnet, account, minor).unwrap();
        let r = DalekScalar::random(&mut OsRng);
        let (tx_pub, output_key) = send_to(&address, r, 1);
        let verified = keys
            .verify_claimed_output(&claim(tx_pub, output_key, 1, (account, minor)))
            .unwrap();
        assert!(verified.key_image.is_some());

        // b + offset opens the output key.
        let spend = DalekScalar::from_canonical_bytes(
            hex::decode(keys.secret_spend_key_hex().unwrap().as_str())
                .unwrap()
                .try_into()
                .unwrap(),
        )
        .unwrap();
        let opened = &(spend + verified.key_offset.into()) * ED25519_BASEPOINT_TABLE;
        assert_eq!(opened.compress().to_bytes(), output_key);
    }
}

#[test]
fn rejects_outputs_that_are_not_ours() {
    let (keys, _) = WalletKeys::generate(SeedFormat::Classic);
    let (other, _) = WalletKeys::generate(SeedFormat::Classic);
    let r = DalekScalar::random(&mut OsRng);

    // Paid to someone else.
    let (tx_pub, output_key) = send_to(&other.primary_address(Network::Mainnet), r, 0);
    assert_eq!(
        keys.verify_claimed_output(&claim(tx_pub, output_key, 0, (0, 0)))
            .unwrap_err(),
        KeyError::NotOurs
    );

    // Ours, but the server names the wrong index or subaddress.
    let (tx_pub, output_key) = send_to(&keys.primary_address(Network::Mainnet), r, 0);
    assert_eq!(
        keys.verify_claimed_output(&claim(tx_pub, output_key, 1, (0, 0)))
            .unwrap_err(),
        KeyError::NotOurs
    );
    assert_eq!(
        keys.verify_claimed_output(&claim(tx_pub, output_key, 0, (0, 1)))
            .unwrap_err(),
        KeyError::NotOurs
    );

    // Points unrelated to the wallet.
    assert_eq!(
        keys.verify_claimed_output(&claim([0xff; 32], output_key, 0, (0, 0)))
            .unwrap_err(),
        KeyError::NotOurs
    );
}

#[test]
fn view_only_wallets_verify_but_have_no_key_image() {
    let (keys, _) = WalletKeys::generate(SeedFormat::Classic);
    let address = keys.primary_address(Network::Mainnet);
    let watch =
        WalletKeys::view_only(Network::Mainnet, &address, &keys.secret_view_key_hex()).unwrap();
    let (tx_pub, output_key) = send_to(&address, DalekScalar::random(&mut OsRng), 4);
    let verified = watch
        .verify_claimed_output(&claim(tx_pub, output_key, 4, (0, 0)))
        .unwrap();
    assert!(verified.key_image.is_none());
}
