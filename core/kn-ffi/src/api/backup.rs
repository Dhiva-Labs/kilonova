//! Backing up wallets to one file, encrypted with a passphrase of its own,
//! and restoring them from it.
//!
//! A backup holds each wallet's file and sync cache exactly as stored
//! (still encrypted with the wallet's password, so exporting needs no
//! wallet unlocked), its entry in the wallet list and the network settings
//! it used. See `kn_store::bundle` for the format.
//!
//! Arguments are owned because `flutter_rust_bridge` hands them over that way.
#![allow(clippy::needless_pass_by_value)]

use std::fs;
use std::path::{Path, PathBuf};

use flutter_rust_bridge::frb;
use kn_store::{BundleWallet, RestoredWallet, StoreError, WalletSettings, open_bundle};
use zeroize::Zeroizing;

use super::network::Network;
use super::nodes::apply_saved_pins;
use super::wallets::{WalletError, store};
use crate::node_settings::{Settings, key, load, save};

/// Shortest backup passphrase accepted for a new backup.
const MIN_PASSPHRASE: usize = 12;

/// Largest file read as a backup; far above any real one.
const MAX_BACKUP: u64 = 512 << 20;

/// Why a backup could not be written or read. The app maps each case to
/// its own message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackupError {
    /// Shorter than [`backup_passphrase_min_length`].
    ShortPassphrase,
    WrongPassphrase,
    /// Not a Kilonova backup, or a damaged one.
    NotABackup,
    /// Written by a newer version of Kilonova.
    NewerVersion,
    /// No wallets were chosen.
    NoWallets,
    /// A chosen wallet does not exist.
    NotFound,
    /// The file could not be written or read.
    Storage,
    NotInitialized,
}

impl From<StoreError> for BackupError {
    fn from(e: StoreError) -> Self {
        match e {
            StoreError::WrongPasswordOrDamaged => Self::WrongPassphrase,
            StoreError::Corrupt(_) | StoreError::Keys(_) | StoreError::EmptyName => {
                Self::NotABackup
            }
            StoreError::UnsupportedVersion(_) => Self::NewerVersion,
            StoreError::NotFound => Self::NotFound,
            StoreError::Io(_) => Self::Storage,
        }
    }
}

impl From<WalletError> for BackupError {
    fn from(e: WalletError) -> Self {
        match e {
            WalletError::NotInitialized => Self::NotInitialized,
            WalletError::NotFound => Self::NotFound,
            _ => Self::Storage,
        }
    }
}

/// One wallet in a backup, for the preview before importing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BackupEntry {
    pub name: String,
    pub network: Network,
    pub view_only: bool,
    pub cold: bool,
}

/// What a backup holds.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BackupSummary {
    pub wallets: Vec<BackupEntry>,
    pub count: u32,
}

/// A wallet added from a backup.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImportedWallet {
    pub id: String,
    /// Its name in the list now.
    pub name: String,
    /// Its name in the backup; differs from `name` when a wallet of that
    /// name already existed, which is kept as it was.
    pub original_name: String,
    pub network: Network,
}

/// The shortest passphrase [`export_backup`] accepts.
#[frb(sync)]
#[must_use]
pub fn backup_passphrase_min_length() -> u32 {
    u32::try_from(MIN_PASSPHRASE).unwrap_or(u32::MAX)
}

/// Writes the wallets `wallet_ids` to a backup at `path`, encrypted with
/// `passphrase`. No wallet needs to be unlocked. Returns the file's size in
/// bytes.
///
/// # Errors
///
/// See [`BackupError`].
pub fn export_backup(
    wallet_ids: Vec<String>,
    passphrase: String,
    path: String,
) -> Result<u64, BackupError> {
    let passphrase = Zeroizing::new(passphrase);
    if passphrase.chars().count() < MIN_PASSPHRASE {
        return Err(BackupError::ShortPassphrase);
    }
    if wallet_ids.is_empty() {
        return Err(BackupError::NoWallets);
    }
    // Read before taking the store: settings go through it too.
    let settings = load().map_err(|_| BackupError::Storage)?;
    let bundle = {
        let store = store()?;
        let wallets = wallet_ids
            .iter()
            .map(|id| {
                let mut wallet = store.backup_wallet(id)?;
                if !wallet.entry.cold {
                    wallet.settings = settings_for(&settings, wallet.entry.network.into());
                }
                Ok(wallet)
            })
            .collect::<Result<Vec<BundleWallet>, StoreError>>()?;
        store.seal_bundle(&wallets, passphrase.as_bytes())?
    };
    write_file(Path::new(&path), &bundle)?;
    Ok(bundle.len() as u64)
}

/// Opens the backup at `path` with `passphrase` and lists the wallets in
/// it, without adding them.
///
/// # Errors
///
/// See [`BackupError`].
pub fn read_backup_summary(path: String, passphrase: String) -> Result<BackupSummary, BackupError> {
    let wallets = read(&path, &Zeroizing::new(passphrase))?;
    Ok(BackupSummary {
        count: u32::try_from(wallets.len()).unwrap_or(u32::MAX),
        wallets: wallets
            .iter()
            .map(|w| BackupEntry {
                name: w.entry.name.clone(),
                network: w.entry.network.into(),
                view_only: w.entry.view_only,
                cold: w.entry.cold,
            })
            .collect(),
    })
}

/// Adds the wallets in the backup at `path` to the wallet list. Existing
/// wallets are never replaced: a restored wallet whose name is taken is
/// called "Name (restored)". Network settings from the backup fill in only
/// what this device has not chosen itself.
///
/// # Errors
///
/// See [`BackupError`].
pub fn import_backup(path: String, passphrase: String) -> Result<Vec<ImportedWallet>, BackupError> {
    let wallets = read(&path, &Zeroizing::new(passphrase))?;
    let restored = store()?.restore_bundle(wallets)?;
    // The wallets are in; settings that cannot be saved can be chosen again.
    let _ = apply_settings(&restored);
    Ok(restored
        .into_iter()
        .map(|r| ImportedWallet {
            id: r.entry.id,
            name: r.entry.name,
            original_name: r.original_name,
            network: r.entry.network.into(),
        })
        .collect())
}

fn read(path: &str, passphrase: &str) -> Result<Vec<BundleWallet>, BackupError> {
    let size = fs::metadata(path).map_err(|_| BackupError::Storage)?.len();
    if size > MAX_BACKUP {
        return Err(BackupError::NotABackup);
    }
    let bytes = fs::read(path).map_err(|_| BackupError::Storage)?;
    Ok(open_bundle(&bytes, passphrase.as_bytes())?)
}

/// What a wallet on `network` uses: the selected node, added nodes, the
/// light wallet server and the pins for those addresses.
fn settings_for(settings: &Settings, network: Network) -> WalletSettings {
    let Some(net) = settings.networks.get(key(network)) else {
        return WalletSettings::default();
    };
    let used: Vec<&String> = net
        .selected
        .iter()
        .chain(&net.custom)
        .chain(&net.lws)
        .collect();
    WalletSettings {
        node: net.selected.clone(),
        custom_nodes: net.custom.clone(),
        lws_server: net.lws.clone(),
        pins: settings
            .pins
            .iter()
            .filter(|(url, _)| used.contains(url))
            .map(|(url, pin)| (url.clone(), pin.clone()))
            .collect(),
    }
}

/// Fills in node choices this device has not made from the restored
/// wallets' settings; never changes a choice already made.
fn apply_settings(restored: &[RestoredWallet]) -> Result<(), BackupError> {
    let mut settings = load().map_err(|_| BackupError::Storage)?;
    for wallet in restored {
        let network: Network = wallet.entry.network.into();
        let from = &wallet.settings;
        let net = settings
            .networks
            .entry(key(network).to_owned())
            .or_default();
        if net.selected.is_none() {
            net.selected.clone_from(&from.node);
        }
        for url in &from.custom_nodes {
            if !net.custom.contains(url) {
                net.custom.push(url.clone());
            }
        }
        if net.lws.is_none() {
            net.lws.clone_from(&from.lws_server);
        }
        for (url, pin) in &from.pins {
            settings
                .pins
                .entry(url.clone())
                .or_insert_with(|| pin.clone());
        }
    }
    save(&settings).map_err(|_| BackupError::Storage)?;
    apply_saved_pins(&settings);
    Ok(())
}

/// Writes next to `path` and renames over it, so a failed write never
/// leaves half a backup under the chosen name.
fn write_file(path: &Path, bytes: &[u8]) -> Result<(), BackupError> {
    let mut tmp = PathBuf::from(path);
    tmp.as_mut_os_string().push(".tmp");
    let written = fs::write(&tmp, bytes).and_then(|()| fs::rename(&tmp, path));
    if written.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    written.map_err(|_| BackupError::Storage)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::wallets::{SyncMode, create_wallet_from_seed, generate_seed, list_wallets};

    #[test]
    fn export_preview_and_import() {
        crate::test_store::init();
        let seed = generate_seed(crate::api::wallets::SeedFormat::Polyseed);
        let wallet = create_wallet_from_seed(
            "Backup test".into(),
            Network::Stagenet,
            SyncMode::Full,
            seed.words.join(" "),
            "wallet password".into(),
            Some(0),
            true,
        )
        .unwrap();
        let id = wallet.summary().unwrap().id;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("wallets.knbackup");
        let path = path.to_string_lossy().into_owned();

        assert_eq!(
            export_backup(vec![id.clone()], "short".into(), path.clone()),
            Err(BackupError::ShortPassphrase)
        );
        assert_eq!(
            export_backup(vec![], "long enough passphrase".into(), path.clone()),
            Err(BackupError::NoWallets)
        );
        let size = export_backup(
            vec![id.clone()],
            "long enough passphrase".into(),
            path.clone(),
        )
        .unwrap();
        assert_eq!(size, fs::metadata(&path).unwrap().len());

        assert_eq!(
            read_backup_summary(path.clone(), "wrong passphrase!".into()),
            Err(BackupError::WrongPassphrase)
        );
        let summary = read_backup_summary(path.clone(), "long enough passphrase".into()).unwrap();
        assert_eq!(summary.count, 1);
        assert_eq!(summary.wallets[0].name, "Backup test");
        assert_eq!(summary.wallets[0].network, Network::Stagenet);

        let imported = import_backup(path.clone(), "long enough passphrase".into()).unwrap();
        assert_eq!(imported.len(), 1);
        assert_eq!(imported[0].name, "Backup test (restored)");
        assert_eq!(imported[0].original_name, "Backup test");
        assert_ne!(imported[0].id, id);
        assert!(
            list_wallets()
                .unwrap()
                .iter()
                .any(|w| w.id == imported[0].id)
        );
        crate::api::wallets::unlock_wallet(imported[0].id.clone(), "wallet password".into())
            .unwrap();

        let junk = dir.path().join("junk");
        fs::write(&junk, b"not a backup").unwrap();
        assert_eq!(
            read_backup_summary(junk.to_string_lossy().into_owned(), "whatever".into()),
            Err(BackupError::NotABackup)
        );
    }
}
