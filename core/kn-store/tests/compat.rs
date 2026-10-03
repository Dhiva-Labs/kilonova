//! Wallet files and backups written by earlier versions must keep opening.
//!
//! `fixtures/v1` was written by the code at the commit before the argon2
//! 0.6 upgrade (argon2 0.5, chacha20poly1305 0.10), for the stagenet wallet
//! in `kn-keys/tests/vectors.json`. `fixtures/backup-v1.knbackup` is that
//! wallet in a version 1 backup bundle, written by
//! `write_backup_v1_fixture` when bundles were introduced. Never regenerate
//! either: add a new fixture when a format changes, and keep testing the
//! old ones.

use std::fs;
use std::path::Path;

use kn_keys::Network;
use kn_store::{KdfParams, Store, SyncMode, WalletSecret, WalletSettings, open_bundle};

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

const BACKUP_PASSPHRASE: &[u8] = b"fixture backup passphrase";

fn backup_settings() -> WalletSettings {
    WalletSettings {
        node: Some("http://127.0.0.1:38081".into()),
        custom_nodes: vec!["http://127.0.0.1:38081".into()],
        lws_server: None,
        pins: std::collections::BTreeMap::new(),
    }
}

#[test]
fn v1_backups_still_open() {
    let bundle =
        fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/backup-v1.knbackup"))
            .unwrap();
    assert!(open_bundle(&bundle, b"wrong passphrase").is_err());
    let wallets = open_bundle(&bundle, BACKUP_PASSPHRASE).unwrap();
    assert_eq!(wallets.len(), 1);
    assert_eq!(wallets[0].settings, backup_settings());

    let dir = tempfile::tempdir().unwrap();
    let store = Store::open(dir.path()).unwrap();
    let restored = store.restore_bundle(wallets).unwrap();
    assert_eq!(restored[0].entry.name, "Fixture");
    assert_eq!(restored[0].entry.id, "4c9e046dc961168abbc47a506e7604d8");
    let wallet = store
        .unlock(&restored[0].entry.id, b"fixture password")
        .unwrap();
    assert_eq!(
        wallet.keys.primary_address(Network::Stagenet),
        expected_address()
    );
    assert_eq!(wallet.data.labels[0].label, "Fixture");
    let cache = store.load_cache(&wallet).unwrap().unwrap();
    assert_eq!(cache.as_slice(), br#"{"fixture":true}"#);
}

/// Wrote `fixtures/backup-v1.knbackup` once; kept to show how. Run with
/// `--ignored` only to make a fixture for a new format version.
#[test]
#[ignore = "writes a committed fixture"]
fn write_backup_v1_fixture() {
    let dir = copy_fixture("v1");
    let store = Store::with_kdf(dir.path(), KdfParams::MIN).unwrap();
    let id = &store.list().unwrap()[0].id;
    let mut wallet = store.backup_wallet(id).unwrap();
    wallet.settings = backup_settings();
    let bundle = store.seal_bundle(&[wallet], BACKUP_PASSPHRASE).unwrap();
    fs::write(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/backup-v1.knbackup"),
        bundle,
    )
    .unwrap();
}
