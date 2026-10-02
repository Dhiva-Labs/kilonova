use std::fs;

use kn_keys::{Network, SeedFormat, WalletKeys};
use kn_store::{AddressLabel, KdfParams, Store, StoreError, SyncMode, WalletData, WalletSecret};
use zeroize::Zeroizing;

fn store() -> (tempfile::TempDir, Store) {
    let dir = tempfile::tempdir().unwrap();
    let store = Store::with_kdf(dir.path(), KdfParams::MIN).unwrap();
    (dir, store)
}

fn seed_data(network: Network) -> (WalletData, String) {
    let (keys, mnemonic) = WalletKeys::generate(SeedFormat::Polyseed);
    let address = keys.primary_address(network);
    let mut data = WalletData::new(
        network,
        WalletSecret::Seed {
            words: mnemonic.words.clone(),
        },
    );
    data.birthday = mnemonic.birthday;
    (data, address)
}

#[test]
fn create_list_and_unlock() {
    let (_dir, store) = store();
    let (data, address) = seed_data(Network::Stagenet);
    let created = store
        .create(" Savings ", SyncMode::Full, data, b"pw", 1_700_000_000)
        .unwrap();

    let listed = store.list().unwrap();
    assert_eq!(listed, vec![created.entry.clone()]);
    assert_eq!(listed[0].name, "Savings");
    assert_eq!(listed[0].network, Network::Stagenet);
    assert!(!listed[0].view_only);

    let unlocked = store.unlock(&created.entry.id, b"pw").unwrap();
    assert_eq!(unlocked.keys.primary_address(Network::Stagenet), address);
    assert!(unlocked.data.birthday.is_some());
}

#[test]
fn wrong_password_is_rejected() {
    let (_dir, store) = store();
    let (data, _) = seed_data(Network::Mainnet);
    let id = store
        .create("A", SyncMode::Full, data, b"right", 0)
        .unwrap()
        .entry
        .id;
    assert!(matches!(
        store.unlock(&id, b"wrong"),
        Err(StoreError::WrongPasswordOrDamaged)
    ));
}

#[test]
fn each_wallet_has_its_own_password() {
    let (_dir, store) = store();
    let a = store
        .create(
            "A",
            SyncMode::Full,
            seed_data(Network::Mainnet).0,
            b"alpha",
            0,
        )
        .unwrap()
        .entry
        .id;
    let b = store
        .create(
            "B",
            SyncMode::Lws,
            seed_data(Network::Testnet).0,
            b"bravo",
            0,
        )
        .unwrap()
        .entry
        .id;
    assert!(store.unlock(&a, b"alpha").is_ok());
    assert!(store.unlock(&b, b"bravo").is_ok());
    assert!(store.unlock(&a, b"bravo").is_err());
    assert!(store.unlock(&b, b"alpha").is_err());
    assert_eq!(store.list().unwrap().len(), 2);
}

#[test]
fn registry_and_files_contain_no_secrets_in_the_clear() {
    let (dir, store) = store();
    let (keys, mnemonic) = WalletKeys::generate(SeedFormat::Classic);
    let address = keys.primary_address(Network::Mainnet);
    let data = WalletData::new(
        Network::Mainnet,
        WalletSecret::Seed {
            words: mnemonic.words.clone(),
        },
    );
    store.create("W", SyncMode::Full, data, b"pw", 0).unwrap();

    let first_words: String = mnemonic
        .words
        .split(' ')
        .take(3)
        .collect::<Vec<_>>()
        .join(" ");
    for entry in fs::read_dir(dir.path()).unwrap() {
        let bytes = fs::read(entry.unwrap().path()).unwrap();
        let text = String::from_utf8_lossy(&bytes);
        assert!(!text.contains(&first_words));
        assert!(!text.contains(&address));
        assert!(!text.contains(keys.secret_view_key_hex().as_str()));
    }
}

#[test]
fn saved_changes_survive_unlock() {
    let (_dir, store) = store();
    let mut wallet = store
        .create("W", SyncMode::Full, seed_data(Network::Mainnet).0, b"pw", 0)
        .unwrap();
    wallet.data.labels.push(AddressLabel {
        account: 0,
        index: 1,
        label: "Rent".into(),
    });
    wallet.data.next_subaddress[0] = 2;
    store.save(&wallet).unwrap();

    let again = store.unlock(&wallet.entry.id, b"pw").unwrap();
    assert_eq!(again.data.labels, wallet.data.labels);
    assert_eq!(again.data.next_subaddress, vec![2]);
}

#[test]
fn change_password() {
    let (_dir, store) = store();
    let mut wallet = store
        .create(
            "W",
            SyncMode::Full,
            seed_data(Network::Mainnet).0,
            b"old",
            0,
        )
        .unwrap();
    store.change_password(&mut wallet, b"new").unwrap();
    assert!(store.unlock(&wallet.entry.id, b"old").is_err());
    assert!(store.unlock(&wallet.entry.id, b"new").is_ok());
}

#[test]
fn rename_and_delete() {
    let (dir, store) = store();
    let id = store
        .create(
            "Old",
            SyncMode::Full,
            seed_data(Network::Mainnet).0,
            b"pw",
            0,
        )
        .unwrap()
        .entry
        .id;

    store.rename(&id, "New").unwrap();
    assert_eq!(store.list().unwrap()[0].name, "New");
    assert!(matches!(
        store.rename(&id, "  "),
        Err(StoreError::EmptyName)
    ));

    store.delete(&id).unwrap();
    assert!(store.list().unwrap().is_empty());
    assert!(!dir.path().join(format!("{id}.knw")).exists());
    assert!(matches!(store.delete(&id), Err(StoreError::NotFound)));
    assert!(matches!(
        store.unlock(&id, b"pw"),
        Err(StoreError::NotFound)
    ));
}

#[test]
fn view_only_wallets_are_flagged() {
    let (_dir, store) = store();
    let (keys, _) = WalletKeys::generate(SeedFormat::Classic);
    let data = WalletData::new(
        Network::Stagenet,
        WalletSecret::ViewOnly {
            address: keys.primary_address(Network::Stagenet),
            view_key: keys.secret_view_key_hex(),
        },
    );
    let wallet = store
        .create("Watch", SyncMode::Lws, data, b"pw", 0)
        .unwrap();
    assert!(wallet.entry.view_only);
    assert!(wallet.keys.is_view_only());
}

#[test]
fn invalid_secrets_are_rejected_before_anything_is_written() {
    let (dir, store) = store();
    let data = WalletData::new(
        Network::Mainnet,
        WalletSecret::Seed {
            words: Zeroizing::new("not a seed".into()),
        },
    );
    assert!(matches!(
        store.create("Bad", SyncMode::Full, data, b"pw", 0),
        Err(StoreError::Keys(_))
    ));
    assert!(matches!(
        store.create("", SyncMode::Full, seed_data(Network::Mainnet).0, b"pw", 0),
        Err(StoreError::EmptyName)
    ));
    assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 0);
}

#[test]
fn a_file_swapped_between_wallets_is_detected() {
    let (dir, store) = store();
    let main = store
        .create("M", SyncMode::Full, seed_data(Network::Mainnet).0, b"pw", 0)
        .unwrap()
        .entry
        .id;
    // Same network and password, so only the id binding can catch it.
    let other = store
        .create("O", SyncMode::Full, seed_data(Network::Mainnet).0, b"pw", 0)
        .unwrap()
        .entry
        .id;
    fs::copy(
        dir.path().join(format!("{other}.knw")),
        dir.path().join(format!("{main}.knw")),
    )
    .unwrap();
    assert!(matches!(
        store.unlock(&main, b"pw"),
        Err(StoreError::Corrupt(_))
    ));
}
