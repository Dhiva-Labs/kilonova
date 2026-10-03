//! Backup bundles: export, wipe, import, and nothing lost or overwritten.

use std::collections::BTreeMap;
use std::fs;

use kn_keys::{Network, SeedFormat, WalletKeys};
use kn_store::{
    AddressLabel, BundleWallet, Contact, KdfParams, PaymentRequest, SentRecord, Store, StoreError,
    SyncMode, WalletData, WalletSecret, WalletSettings, open_bundle,
};
use zeroize::Zeroizing;

const PASSPHRASE: &[u8] = b"correct horse battery staple";

fn store() -> (tempfile::TempDir, Store) {
    let dir = tempfile::tempdir().unwrap();
    let store = Store::with_kdf(dir.path(), KdfParams::MIN).unwrap();
    (dir, store)
}

/// A wallet with something in every field a backup has to carry.
fn full_wallet(store: &Store, name: &str, password: &[u8]) -> (String, String) {
    let (keys, mnemonic) = WalletKeys::generate(SeedFormat::Polyseed);
    let mut data = WalletData::new(
        Network::Stagenet,
        WalletSecret::Seed {
            words: mnemonic.words.clone(),
        },
    );
    data.birthday = mnemonic.birthday;
    data.restore_height = Some(1_234_567);
    data.next_subaddress = vec![5, 2];
    data.created_here = true;
    data.lws_consent = Some("https://lws.example.org".into());
    let mut wallet = store
        .create(name, SyncMode::Lws, data, password, 1_700_000_000)
        .unwrap();
    wallet.data.labels.push(AddressLabel {
        account: 0,
        index: 3,
        label: "Rent".into(),
    });
    wallet.data.contacts.push(Contact {
        name: "Ana".into(),
        address: keys.primary_address(Network::Stagenet),
    });
    wallet
        .data
        .notes
        .insert("ab".repeat(32), "Coffee beans".into());
    wallet.data.sent.insert(
        "cd".repeat(32),
        SentRecord {
            destinations: vec![(keys.primary_address(Network::Stagenet), 42)],
            tx_key: Some(Zeroizing::new("ef".repeat(32))),
        },
    );
    wallet.data.requests.push(PaymentRequest {
        id: "req-1".into(),
        index: 4,
        amount: 1_000_000,
        label: "Invoice 7".into(),
        created_at: 1_700_000_100,
        expires_at: Some(1_700_086_500),
    });
    wallet.data.frozen.insert("12".repeat(32));
    store.save(&wallet).unwrap();
    store.save_cache(&wallet, b"scanned to 1234567").unwrap();
    (wallet.entry.id, mnemonic.words.to_string())
}

fn view_only_wallet(store: &Store, name: &str) -> String {
    let (keys, _) = WalletKeys::generate(SeedFormat::Classic);
    let data = WalletData::new(
        Network::Mainnet,
        WalletSecret::ViewOnly {
            address: keys.primary_address(Network::Mainnet),
            view_key: keys.secret_view_key_hex(),
        },
    );
    let wallet = store
        .create(name, SyncMode::Full, data, b"view pw", 1_700_000_200)
        .unwrap();
    store.set_cold(&wallet.entry.id, true).unwrap();
    wallet.entry.id
}

fn settings() -> WalletSettings {
    WalletSettings {
        node: Some("https://node.example.org:18089".into()),
        custom_nodes: vec!["https://node.example.org:18089".into()],
        lws_server: Some("https://lws.example.org".into()),
        pins: BTreeMap::from([("https://node.example.org:18089".into(), "aa".repeat(32))]),
    }
}

fn export(store: &Store, ids: &[String]) -> Vec<u8> {
    let wallets: Vec<BundleWallet> = ids
        .iter()
        .map(|id| {
            let mut w = store.backup_wallet(id).unwrap();
            w.settings = settings();
            w
        })
        .collect();
    store.seal_bundle(&wallets, PASSPHRASE).unwrap()
}

fn json(data: &WalletData) -> serde_json::Value {
    serde_json::to_value(data).unwrap()
}

#[test]
fn export_wipe_import_keeps_every_field() {
    let (dir, source) = store();
    let (full, words) = full_wallet(&source, "Savings", b"wallet pw");
    let view = view_only_wallet(&source, "Watch");
    let entries = source.list().unwrap();
    let files: Vec<_> = [&full, &view]
        .iter()
        .map(|id| fs::read(dir.path().join(format!("{id}.knw"))).unwrap())
        .collect();
    let original = source.unlock(&full, b"wallet pw").unwrap();
    let original_cache = source.load_cache(&original).unwrap().unwrap();

    // Exported without unlocking anything.
    let bundle = export(&source, &[full.clone(), view.clone()]);
    // Nothing readable inside: not the name, not a note, not the seed.
    for needle in [
        b"Savings".as_slice(),
        b"Coffee beans",
        words.split(' ').next().unwrap().as_bytes(),
    ] {
        assert!(!bundle.windows(needle.len()).any(|w| w == needle));
    }

    // Wipe: a fresh device.
    drop(source);
    drop(dir);
    let (new_dir, target) = store();
    let restored = target
        .restore_bundle(open_bundle(&bundle, PASSPHRASE).unwrap())
        .unwrap();
    assert_eq!(restored.len(), 2);
    for r in &restored {
        assert_eq!(r.settings, settings());
        assert_eq!(r.entry.name, r.original_name);
        assert_eq!(r.entry.file_id, None);
    }
    assert_eq!(target.list().unwrap(), entries);
    for (id, file) in [&full, &view].iter().zip(&files) {
        assert_eq!(
            &fs::read(new_dir.path().join(format!("{id}.knw"))).unwrap(),
            file
        );
    }

    let again = target.unlock(&full, b"wallet pw").unwrap();
    assert_eq!(json(&again.data), json(&original.data));
    assert_eq!(again.entry, original.entry);
    assert_eq!(
        target.load_cache(&again).unwrap().unwrap().as_slice(),
        original_cache.as_slice()
    );
    let watch = target.unlock(&view, b"view pw").unwrap();
    assert!(watch.keys.is_view_only());
    assert!(target.load_cache(&watch).unwrap().is_none());
}

#[test]
fn a_wrong_passphrase_fails_cleanly() {
    let (_dir, store) = store();
    let (id, _) = full_wallet(&store, "A", b"pw");
    let bundle = export(&store, &[id]);
    assert!(matches!(
        open_bundle(&bundle, b"not the passphrase"),
        Err(StoreError::WrongPasswordOrDamaged)
    ));
}

#[test]
fn damaged_bundles_fail_cleanly() {
    let (_dir, store) = store();
    let (id, _) = full_wallet(&store, "A", b"pw");
    let bundle = export(&store, &[id]);

    assert!(matches!(
        open_bundle(b"", PASSPHRASE),
        Err(StoreError::Corrupt(_))
    ));
    assert!(matches!(
        open_bundle(b"KNW1 a wallet file, not a backup", PASSPHRASE),
        Err(StoreError::Corrupt(_))
    ));
    let mut newer = bundle.clone();
    newer[8] = 2;
    assert!(matches!(
        open_bundle(&newer, PASSPHRASE),
        Err(StoreError::UnsupportedVersion(2))
    ));

    let len = bundle.len();
    for cut in [5, 10, 30, 60, len / 2, len - 1] {
        assert!(
            open_bundle(&bundle[..cut], PASSPHRASE).is_err(),
            "cut {cut}"
        );
    }
    for at in [12, 40, 70, len / 2, len - 1] {
        let mut flipped = bundle.clone();
        flipped[at] ^= 0x20;
        assert!(open_bundle(&flipped, PASSPHRASE).is_err(), "byte {at}");
    }
}

#[test]
fn importing_next_to_the_original_keeps_both() {
    let (dir, store) = store();
    let (id, _) = full_wallet(&store, "Savings", b"pw");
    let file = fs::read(dir.path().join(format!("{id}.knw"))).unwrap();
    let bundle = export(&store, std::slice::from_ref(&id));

    let first = store
        .restore_bundle(open_bundle(&bundle, PASSPHRASE).unwrap())
        .unwrap();
    let second = store
        .restore_bundle(open_bundle(&bundle, PASSPHRASE).unwrap())
        .unwrap();
    let names: Vec<_> = store.list().unwrap().into_iter().map(|e| e.name).collect();
    assert_eq!(
        names,
        ["Savings", "Savings (restored)", "Savings (restored 2)"]
    );
    assert_eq!(first[0].original_name, "Savings");

    // The original is untouched; each copy has its own id and opens with
    // the wallet's password, cache and all.
    assert_eq!(
        fs::read(dir.path().join(format!("{id}.knw"))).unwrap(),
        file
    );
    let original = store.unlock(&id, b"pw").unwrap();
    for copy in [&first[0].entry, &second[0].entry] {
        assert_ne!(copy.id, id);
        assert_eq!(copy.file_id.as_deref(), Some(id.as_str()));
        let wallet = store.unlock(&copy.id, b"pw").unwrap();
        assert_eq!(json(&wallet.data), json(&original.data));
        assert_eq!(
            store.load_cache(&wallet).unwrap().unwrap().as_slice(),
            b"scanned to 1234567"
        );
    }

    // A copy saves and re-exports like any wallet.
    let mut copy = store.unlock(&first[0].entry.id, b"pw").unwrap();
    copy.data
        .notes
        .insert("00".repeat(32), "after restore".into());
    store.save(&copy).unwrap();
    store.save_cache(&copy, b"later").unwrap();
    let again = store.unlock(&first[0].entry.id, b"pw").unwrap();
    assert_eq!(
        store.load_cache(&again).unwrap().unwrap().as_slice(),
        b"later"
    );
    let (_other_dir, other) = self::store();
    let moved = other
        .restore_bundle(
            open_bundle(&export(&store, &[first[0].entry.id.clone()]), PASSPHRASE).unwrap(),
        )
        .unwrap();
    assert!(other.unlock(&moved[0].entry.id, b"pw").is_ok());
}

#[test]
fn an_unlisted_file_with_the_same_id_is_not_overwritten() {
    let (dir, store) = store();
    let (id, _) = full_wallet(&store, "A", b"pw");
    let bundle = export(&store, std::slice::from_ref(&id));
    let (other_dir, other) = self::store();
    let stray = other_dir.path().join(format!("{id}.knw"));
    fs::write(&stray, b"someone else's file").unwrap();
    let restored = other
        .restore_bundle(open_bundle(&bundle, PASSPHRASE).unwrap())
        .unwrap();
    assert_ne!(restored[0].entry.id, id);
    assert_eq!(fs::read(&stray).unwrap(), b"someone else's file");
    assert!(other.unlock(&restored[0].entry.id, b"pw").is_ok());
    drop(dir);
}
