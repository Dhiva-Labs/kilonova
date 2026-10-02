//! Wallet management for the app: the registry, creating and restoring
//! wallets, and unlocked wallets.
//!
//! Secrets cross into Dart only where the user has to see them: a new seed
//! before it is written down, and a seed the user asks to reveal after
//! re-entering the password. Everything else stays in Rust.
//!
//! Arguments are owned because `flutter_rust_bridge` hands them over that
//! way; secret ones are moved into `Zeroizing` first thing.
#![allow(clippy::needless_pass_by_value)]

use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use flutter_rust_bridge::frb;
use kn_keys::{KeyError, WalletKeys};
use kn_store::{AddressLabel, Store, StoreError, UnlockedWallet, WalletData, WalletSecret};
use zeroize::Zeroizing;

use super::network::Network;

static STORE: OnceLock<Mutex<Store>> = OnceLock::new();

/// Why a wallet operation failed. The app maps each case to its own message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WalletError {
    WrongPassword,
    WrongWordCount,
    UnknownWord,
    BadChecksum,
    UnsupportedPolyseed,
    MalformedKey,
    InvalidKey,
    BadAddress,
    ViewKeyMismatch,
    NotStandardAddress,
    EmptyName,
    Damaged,
    NewerVersion,
    NotFound,
    Storage,
    NotInitialized,
}

impl From<KeyError> for WalletError {
    fn from(e: KeyError) -> Self {
        match e {
            KeyError::WrongWordCount(_) => Self::WrongWordCount,
            KeyError::UnknownWord => Self::UnknownWord,
            KeyError::BadChecksum => Self::BadChecksum,
            KeyError::UnsupportedPolyseed => Self::UnsupportedPolyseed,
            KeyError::MalformedKey => Self::MalformedKey,
            KeyError::NonCanonicalKey | KeyError::BadSubaddressIndex => Self::InvalidKey,
            KeyError::BadAddress(_) => Self::BadAddress,
            KeyError::ViewKeyMismatch => Self::ViewKeyMismatch,
            KeyError::NotStandardAddress => Self::NotStandardAddress,
        }
    }
}

impl From<StoreError> for WalletError {
    fn from(e: StoreError) -> Self {
        match e {
            StoreError::WrongPasswordOrDamaged => Self::WrongPassword,
            StoreError::Corrupt(_) => Self::Damaged,
            StoreError::UnsupportedVersion(_) => Self::NewerVersion,
            StoreError::NotFound => Self::NotFound,
            StoreError::EmptyName => Self::EmptyName,
            StoreError::Keys(k) => k.into(),
            StoreError::Io(_) => Self::Storage,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SeedFormat {
    /// 16 words; also records when the wallet was created.
    Polyseed,
    /// Monero's original 25 words.
    Classic,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncMode {
    Full,
    Lws,
}

impl From<SyncMode> for kn_store::SyncMode {
    fn from(mode: SyncMode) -> Self {
        match mode {
            SyncMode::Full => Self::Full,
            SyncMode::Lws => Self::Lws,
        }
    }
}

impl From<kn_store::SyncMode> for SyncMode {
    fn from(mode: kn_store::SyncMode) -> Self {
        match mode {
            kn_store::SyncMode::Full => Self::Full,
            kn_store::SyncMode::Lws => Self::Lws,
        }
    }
}

/// A wallet as shown in the list. Nothing here is secret.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WalletSummary {
    pub id: String,
    pub name: String,
    pub network: Network,
    pub mode: SyncMode,
    pub view_only: bool,
    pub created_at: u64,
}

impl From<&kn_store::WalletEntry> for WalletSummary {
    fn from(e: &kn_store::WalletEntry) -> Self {
        Self {
            id: e.id.clone(),
            name: e.name.clone(),
            network: e.network.into(),
            mode: e.mode.into(),
            view_only: e.view_only,
            created_at: e.created_at,
        }
    }
}

/// A freshly generated seed, shown once so the user can write it down.
pub struct NewSeed {
    pub format: SeedFormat,
    pub words: Vec<String>,
}

/// One receiving address of an unlocked wallet.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AddressRow {
    pub account: u32,
    pub index: u32,
    pub address: String,
    pub label: String,
}

/// Opens the wallet directory. Call once at startup with the app's private
/// data directory.
///
/// # Errors
///
/// Fails if the directory cannot be created.
pub fn init_wallet_store(dir: String) -> Result<(), WalletError> {
    if STORE.get().is_some() {
        return Ok(());
    }
    let store = Store::open(dir)?;
    // A concurrent caller may have won the race; either store is equivalent.
    let _ = STORE.set(Mutex::new(store));
    Ok(())
}

pub(crate) fn store() -> Result<MutexGuard<'static, Store>, WalletError> {
    let store = STORE.get().ok_or(WalletError::NotInitialized)?;
    Ok(store
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner))
}

/// Lists every wallet, on every network, in creation order.
///
/// # Errors
///
/// Fails if the wallet list cannot be read.
pub fn list_wallets() -> Result<Vec<WalletSummary>, WalletError> {
    Ok(store()?.list()?.iter().map(WalletSummary::from).collect())
}

/// Generates a new seed. Nothing is stored until [`create_wallet_from_seed`].
#[must_use]
pub fn generate_seed(format: SeedFormat) -> NewSeed {
    let (_, mnemonic) = WalletKeys::generate(match format {
        SeedFormat::Polyseed => kn_keys::SeedFormat::Polyseed,
        SeedFormat::Classic => kn_keys::SeedFormat::Classic,
    });
    NewSeed {
        format,
        words: mnemonic.words.split(' ').map(str::to_owned).collect(),
    }
}

/// Checks a seed without storing anything, so the restore form can say what
/// is wrong before asking for a name and password.
///
/// # Errors
///
/// Returns the reason the seed is invalid.
pub fn check_seed(words: String) -> Result<SeedFormat, WalletError> {
    let words = Zeroizing::new(words);
    let (_, mnemonic) = WalletKeys::from_mnemonic(&words)?;
    Ok(match mnemonic.format {
        kn_keys::SeedFormat::Polyseed => SeedFormat::Polyseed,
        kn_keys::SeedFormat::Classic => SeedFormat::Classic,
    })
}

/// Creates or restores a wallet from a 25-word or 16-word seed.
///
/// # Errors
///
/// Fails for an invalid seed, empty name, or storage error.
pub fn create_wallet_from_seed(
    name: String,
    network: Network,
    mode: SyncMode,
    words: String,
    password: String,
    restore_height: Option<u64>,
) -> Result<OpenWallet, WalletError> {
    let words = Zeroizing::new(words);
    let (_, mnemonic) = WalletKeys::from_mnemonic(&words)?;
    let mut data = WalletData::new(
        network.into(),
        WalletSecret::Seed {
            words: mnemonic.words,
        },
    );
    data.birthday = mnemonic.birthday;
    data.restore_height = restore_height;
    create(&name, mode, data, password)
}

/// Restores a wallet from its private spend key.
///
/// # Errors
///
/// Fails for an invalid key, empty name, or storage error.
pub fn create_wallet_from_spend_key(
    name: String,
    network: Network,
    mode: SyncMode,
    spend_key: String,
    password: String,
    restore_height: Option<u64>,
) -> Result<OpenWallet, WalletError> {
    let spend_key = Zeroizing::new(spend_key);
    let mut data = WalletData::new(
        network.into(),
        WalletSecret::SpendKey {
            hex: Zeroizing::new(spend_key.trim().to_owned()),
        },
    );
    data.restore_height = restore_height;
    create(&name, mode, data, password)
}

/// Adds a view-only wallet from a standard address and private view key.
///
/// # Errors
///
/// Fails for a bad address, mismatched view key, empty name, or storage
/// error.
pub fn create_view_only_wallet(
    name: String,
    network: Network,
    mode: SyncMode,
    address: String,
    view_key: String,
    password: String,
    restore_height: Option<u64>,
) -> Result<OpenWallet, WalletError> {
    let view_key = Zeroizing::new(view_key);
    let mut data = WalletData::new(
        network.into(),
        WalletSecret::ViewOnly {
            address: address.trim().to_owned(),
            view_key: Zeroizing::new(view_key.trim().to_owned()),
        },
    );
    data.restore_height = restore_height;
    create(&name, mode, data, password)
}

fn create(
    name: &str,
    mode: SyncMode,
    data: WalletData,
    password: String,
) -> Result<OpenWallet, WalletError> {
    let password = Zeroizing::new(password);
    let created_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    let wallet = store()?.create(name, mode.into(), data, password.as_bytes(), created_at)?;
    Ok(OpenWallet::new(wallet))
}

/// Unlocks a wallet with its password.
///
/// # Errors
///
/// [`WalletError::WrongPassword`] for a wrong password or a damaged file.
pub fn unlock_wallet(id: String, password: String) -> Result<OpenWallet, WalletError> {
    let password = Zeroizing::new(password);
    // Release the store before building the wallet: loading its sync cache
    // takes the store lock again.
    let wallet = store()?.unlock(&id, password.as_bytes())?;
    Ok(OpenWallet::new(wallet))
}

/// Renames a wallet. Works while locked.
///
/// # Errors
///
/// Fails for an empty name or unknown wallet.
pub fn rename_wallet(id: String, name: String) -> Result<(), WalletError> {
    Ok(store()?.rename(&id, &name)?)
}

/// Deletes a wallet after checking its password.
///
/// # Errors
///
/// [`WalletError::WrongPassword`] if the password does not open it.
pub fn delete_wallet(id: String, password: String) -> Result<(), WalletError> {
    let password = Zeroizing::new(password);
    let store = store()?;
    store.unlock(&id, password.as_bytes())?;
    Ok(store.delete(&id)?)
}

/// An unlocked wallet. Dropping it (or calling [`OpenWallet::lock`] and
/// letting Dart release it) stops its sync and wipes its keys from memory.
#[frb(opaque)]
pub struct OpenWallet {
    pub(crate) inner: Arc<Inner>,
}

pub(crate) struct Inner {
    pub(crate) wallet: Mutex<Option<UnlockedWallet>>,
    pub(crate) sync: super::sync::SyncHandle,
}

impl Inner {
    pub(crate) fn with<T>(
        &self,
        f: impl FnOnce(&mut UnlockedWallet) -> Result<T, WalletError>,
    ) -> Result<T, WalletError> {
        let mut guard = self
            .wallet
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let wallet = guard.as_mut().ok_or(WalletError::NotFound)?;
        f(wallet)
    }
}

impl Drop for OpenWallet {
    fn drop(&mut self) {
        self.inner.sync.stop();
    }
}

impl OpenWallet {
    fn new(wallet: UnlockedWallet) -> Self {
        let sync = super::sync::SyncHandle::load(&wallet);
        Self {
            inner: Arc::new(Inner {
                wallet: Mutex::new(Some(wallet)),
                sync,
            }),
        }
    }

    fn with<T>(
        &self,
        f: impl FnOnce(&mut UnlockedWallet) -> Result<T, WalletError>,
    ) -> Result<T, WalletError> {
        self.inner.with(f)
    }

    /// The wallet's registry entry.
    ///
    /// # Errors
    ///
    /// Fails if the wallet has been locked.
    #[frb(sync)]
    pub fn summary(&self) -> Result<WalletSummary, WalletError> {
        self.with(|w| Ok(WalletSummary::from(&w.entry)))
    }

    /// The primary address followed by every subaddress handed out so far
    /// in account 0, with labels.
    ///
    /// # Errors
    ///
    /// Fails if the wallet has been locked.
    #[frb(sync)]
    pub fn addresses(&self) -> Result<Vec<AddressRow>, WalletError> {
        self.with(|w| {
            let next = w.data.next_subaddress.first().copied().unwrap_or(1);
            (0..next).map(|index| address_row(w, 0, index)).collect()
        })
    }

    /// Hands out the next subaddress in account 0 and saves the wallet.
    ///
    /// # Errors
    ///
    /// Fails if the wallet has been locked or cannot be saved.
    pub fn new_address(&self, label: String) -> Result<AddressRow, WalletError> {
        self.with(|w| {
            if w.data.next_subaddress.is_empty() {
                w.data.next_subaddress.push(1);
            }
            let index = w.data.next_subaddress[0];
            w.data.next_subaddress[0] = index + 1;
            set_label(w, 0, index, &label);
            store()?.save(w)?;
            address_row(w, 0, index)
        })
    }

    /// Sets or clears (empty string) an address label and saves the wallet.
    ///
    /// # Errors
    ///
    /// Fails if the wallet has been locked or cannot be saved.
    pub fn set_address_label(
        &self,
        account: u32,
        index: u32,
        label: String,
    ) -> Result<(), WalletError> {
        self.with(|w| {
            set_label(w, account, index, &label);
            Ok(store()?.save(w)?)
        })
    }

    /// Returns the seed words after re-checking the password. `None` for
    /// wallets restored from keys or view-only wallets, which have no seed.
    ///
    /// # Errors
    ///
    /// [`WalletError::WrongPassword`] if the password does not open the file.
    pub fn reveal_seed(&self, password: String) -> Result<Option<Vec<String>>, WalletError> {
        let password = Zeroizing::new(password);
        let id = self.with(|w| Ok(w.entry.id.clone()))?;
        let check = store()?.unlock(&id, password.as_bytes())?;
        Ok(match &check.data.secret {
            WalletSecret::Seed { words } => Some(words.split(' ').map(str::to_owned).collect()),
            WalletSecret::SpendKey { .. } | WalletSecret::ViewOnly { .. } => None,
        })
    }

    /// Re-encrypts the wallet under a new password.
    ///
    /// # Errors
    ///
    /// [`WalletError::WrongPassword`] if `current` is wrong.
    pub fn change_password(
        &self,
        current: String,
        new_password: String,
    ) -> Result<(), WalletError> {
        let current = Zeroizing::new(current);
        let new_password = Zeroizing::new(new_password);
        self.with(|w| {
            let store = store()?;
            store.unlock(&w.entry.id, current.as_bytes())?;
            Ok(store.change_password(w, new_password.as_bytes())?)
        })
    }

    /// Wipes the keys now instead of waiting for Dart to release the object.
    #[frb(sync)]
    pub fn lock(&self) {
        self.inner.sync.stop();
        let mut guard = self
            .inner
            .wallet
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        guard.take();
    }
}

fn set_label(w: &mut UnlockedWallet, account: u32, index: u32, label: &str) {
    w.data
        .labels
        .retain(|l| !(l.account == account && l.index == index));
    let label = label.trim();
    if !label.is_empty() {
        w.data.labels.push(AddressLabel {
            account,
            index,
            label: label.to_owned(),
        });
    }
}

fn address_row(w: &UnlockedWallet, account: u32, index: u32) -> Result<AddressRow, WalletError> {
    let label = w
        .data
        .labels
        .iter()
        .find(|l| l.account == account && l.index == index)
        .map(|l| l.label.clone())
        .unwrap_or_default();
    Ok(AddressRow {
        account,
        index,
        address: w.keys.address(w.entry.network, account, index)?,
        label,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    // One test, because the store is process-global.
    #[test]
    fn wallet_lifecycle() {
        crate::test_store::init();

        let seed = generate_seed(SeedFormat::Polyseed);
        assert_eq!(seed.words.len(), 16);
        let phrase = seed.words.join(" ");
        assert_eq!(check_seed(phrase.clone()), Ok(SeedFormat::Polyseed));
        assert_eq!(
            check_seed("abandon ".repeat(12)),
            Err(WalletError::WrongWordCount)
        );

        let wallet = create_wallet_from_seed(
            "Main".into(),
            Network::Stagenet,
            SyncMode::Full,
            phrase.clone(),
            "pw".into(),
            None,
        )
        .unwrap();
        let summary = wallet.summary().unwrap();
        assert_eq!(summary.network, Network::Stagenet);
        assert!(list_wallets().unwrap().contains(&summary));

        let first = wallet.addresses().unwrap();
        assert_eq!(first.len(), 1);
        assert!(first[0].address.starts_with('5'), "stagenet primary");
        let sub = wallet.new_address("Rent".into()).unwrap();
        assert_eq!((sub.index, sub.label.as_str()), (1, "Rent"));
        wallet.set_address_label(0, 0, "Main".into()).unwrap();

        assert_eq!(
            wallet.reveal_seed("nope".into()).unwrap_err(),
            WalletError::WrongPassword
        );
        assert_eq!(wallet.reveal_seed("pw".into()).unwrap(), Some(seed.words));

        wallet.change_password("pw".into(), "pw2".into()).unwrap();
        wallet.lock();
        assert_eq!(wallet.addresses().unwrap_err(), WalletError::NotFound);

        let again = unlock_wallet(summary.id.clone(), "pw2".into()).unwrap();
        let rows = again.addresses().unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].label, "Main");
        assert_eq!(rows[1].label, "Rent");

        let view_only = create_view_only_wallet(
            "Watch".into(),
            Network::Stagenet,
            SyncMode::Lws,
            rows[0].address.clone(),
            "00".repeat(32),
            "pw".into(),
            None,
        );
        assert!(matches!(view_only, Err(WalletError::ViewKeyMismatch)));

        assert_eq!(
            delete_wallet(summary.id.clone(), "wrong".into()).unwrap_err(),
            WalletError::WrongPassword
        );
        delete_wallet(summary.id.clone(), "pw2".into()).unwrap();
        assert!(list_wallets().unwrap().iter().all(|w| w.id != summary.id));
    }
}
