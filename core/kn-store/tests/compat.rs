//! Wallet files written by earlier versions must keep opening.
//!
//! `fixtures/v1` was written by the code at the commit before the argon2
//! 0.6 upgrade (argon2 0.5, chacha20poly1305 0.10), for the stagenet wallet
//! in `kn-keys/tests/vectors.json`. Never regenerate it: add a new fixture
//! directory when the format changes, and keep testing the old ones.

use std::fs;
use std::path::Path;

use kn_keys::Network;
use kn_store::{Store, SyncMode, WalletSecret};

/// The stagenet primary address from kn-keys' vectors.
fn expected_address() -> String {
    let vectors: serde_json::Value =
        serde_json::from_str(include_str!("../../kn-keys/tests/vectors.json")).unwrap();
    vectors["networks"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["network"] == "stagenet")
        .unwrap()["classic"]["address"]
        .as_str()
        .unwrap()
        .to_owned()
}

/// Copies a fixture so the test never modifies the committed files.
fn copy_fixture(name: &str) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    let source = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name);
    for entry in fs::read_dir(source).unwrap() {
        let entry = entry.unwrap();
        fs::copy(entry.path(), dir.path().join(entry.file_name())).unwrap();
    }
    dir
}

#[test]
fn v1_wallet_files_still_open() {
    let dir = copy_fixture("v1");
    let store = Store::open(dir.path()).unwrap();

    let entries = store.list().unwrap();
    assert_eq!(entries.len(), 1);
    let entry = &entries[0];
    assert_eq!(entry.name, "Fixture");
    assert_eq!(entry.network, Network::Stagenet);
    assert_eq!(entry.mode, SyncMode::Full);

    assert!(store.unlock(&entry.id, b"wrong password").is_err());
    let wallet = store.unlock(&entry.id, b"fixture password").unwrap();
    assert_eq!(
        wallet.keys.primary_address(Network::Stagenet),
        expected_address()
    );
    assert!(matches!(wallet.data.secret, WalletSecret::Seed { .. }));
    assert_eq!(wallet.data.restore_height, Some(1_000_000));
    assert_eq!(wallet.data.next_subaddress, vec![2]);
    assert_eq!(wallet.data.labels[0].label, "Fixture");

    let cache = store.load_cache(&wallet).unwrap().unwrap();
    assert_eq!(cache.as_slice(), br#"{"fixture":true}"#);
}
