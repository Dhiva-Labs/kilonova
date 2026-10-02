//! Encrypted wallet files and the wallet registry.
//!
//! A store is one directory:
//!
//! ```text
//! wallets.json        registry: id, name, network, mode, view-only flag
//! <id>.knw            one encrypted file per wallet (see `crypto`)
//! ```
//!
//! The registry holds no secrets, balances or addresses, so the app can list
//! wallets before any of them is unlocked. Each wallet file has its own
//! password; unlocking one never unlocks another.

#![forbid(unsafe_code)]

mod crypto;

use std::{
    fs,
    io::Write as _,
    path::{Path, PathBuf},
};

use kn_keys::{KeyError, Network, WalletKeys};
use rand_core::{OsRng, RngCore};
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

pub use crypto::KdfParams;
use crypto::SealingKey;

const REGISTRY_FILE: &str = "wallets.json";
const WALLET_EXTENSION: &str = "knw";
const PAYLOAD_VERSION: u32 = 1;

#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("wrong password, or the wallet file is damaged")]
    WrongPasswordOrDamaged,
    #[error("the wallet file is damaged: {0}")]
    Corrupt(&'static str),
    #[error("this wallet file was written by a newer version of Kilonova (format {0})")]
    UnsupportedVersion(u16),
    #[error("no wallet with this id")]
    NotFound,
    #[error("a wallet name cannot be empty")]
    EmptyName,
    #[error(transparent)]
    Keys(#[from] KeyError),
    #[error("storage error: {0}")]
    Io(#[from] std::io::Error),
}

/// How a wallet syncs. Stored per wallet; switching rebuilds the sync cache.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SyncMode {
    Full,
    Lws,
}

/// A wallet as listed in the registry. Nothing here is secret.
#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub struct WalletEntry {
    pub id: String,
    pub name: String,
    #[serde(with = "network_serde")]
    pub network: Network,
    pub mode: SyncMode,
    pub view_only: bool,
    /// Seconds since the Unix epoch.
    pub created_at: u64,
}

/// What a wallet was created or restored from. This is what the encrypted
/// file stores; keys are re-derived on unlock.
#[derive(Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum WalletSecret {
    /// A 25-word or 16-word seed. Kept so the user can view it again.
    Seed { words: Zeroizing<String> },
    /// A private spend key, for wallets restored from keys.
    SpendKey { hex: Zeroizing<String> },
    /// A standard address and private view key.
    ViewOnly {
        address: String,
        view_key: Zeroizing<String>,
    },
}

impl WalletSecret {
    fn keys(&self, network: Network) -> Result<WalletKeys, KeyError> {
        match self {
            Self::Seed { words } => WalletKeys::from_mnemonic(words).map(|(keys, _)| keys),
            Self::SpendKey { hex } => WalletKeys::from_spend_key(hex),
            Self::ViewOnly { address, view_key } => {
                WalletKeys::view_only(network, address, view_key)
            }
        }
    }
}

/// A label the user gave an address.
#[derive(Clone, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub struct AddressLabel {
    pub account: u32,
    pub index: u32,
    pub label: String,
}

/// Everything inside a wallet file.
#[derive(Serialize, Deserialize)]
pub struct WalletData {
    version: u32,
    /// The registry id this file belongs to, checked on unlock so a file
    /// copied over another wallet's file is refused.
    wallet_id: String,
    #[serde(with = "network_serde")]
    pub network: Network,
    pub secret: WalletSecret,
    /// Block height to start scanning from, if known.
    pub restore_height: Option<u64>,
    /// Polyseed birthday, seconds since the Unix epoch.
    pub birthday: Option<u64>,
    /// Subaddresses handed out so far, per account (index 0 = account 0).
    pub next_subaddress: Vec<u32>,
    pub labels: Vec<AddressLabel>,
}

impl WalletData {
    #[must_use]
    pub fn new(network: Network, secret: WalletSecret) -> Self {
        Self {
            version: PAYLOAD_VERSION,
            wallet_id: String::new(),
            network,
            secret,
            restore_height: None,
            birthday: None,
            next_subaddress: vec![1],
            labels: Vec::new(),
        }
    }
}

/// An unlocked wallet: its data, derived keys, and the sealing key that lets
/// it be saved again without asking for the password.
pub struct UnlockedWallet {
    pub entry: WalletEntry,
    pub data: WalletData,
    pub keys: WalletKeys,
    sealing: SealingKey,
}

/// A wallet directory.
pub struct Store {
    dir: PathBuf,
    kdf: KdfParams,
}

impl Store {
    /// Opens (creating if needed) the store in `dir`.
    ///
    /// # Errors
    ///
    /// Returns an error if the directory cannot be created.
    pub fn open(dir: impl Into<PathBuf>) -> Result<Self, StoreError> {
        Self::with_kdf(dir, KdfParams::DEFAULT)
    }

    /// Like [`Store::open`] with explicit KDF parameters for new files.
    /// Existing files keep the parameters they were written with.
    ///
    /// # Errors
    ///
    /// Returns an error if the directory cannot be created.
    pub fn with_kdf(dir: impl Into<PathBuf>, kdf: KdfParams) -> Result<Self, StoreError> {
        let dir = dir.into();
        fs::create_dir_all(&dir)?;
        Ok(Self { dir, kdf })
    }

    /// Lists wallets in creation order. Never touches wallet files.
    ///
    /// # Errors
    ///
    /// Returns an error if the registry exists but cannot be read or parsed.
    pub fn list(&self) -> Result<Vec<WalletEntry>, StoreError> {
        let path = self.dir.join(REGISTRY_FILE);
        match fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map_err(|_| StoreError::Corrupt("wallet list is unreadable")),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
            Err(e) => Err(e.into()),
        }
    }

    /// Creates a wallet file and adds it to the registry.
    ///
    /// The secret is checked first: a seed that does not parse or a view key
    /// that does not match its address is rejected before anything is
    /// written.
    ///
    /// # Errors
    ///
    /// Returns an error for an empty name, invalid secret, or I/O failure.
    pub fn create(
        &self,
        name: &str,
        mode: SyncMode,
        mut data: WalletData,
        password: &[u8],
        created_at: u64,
    ) -> Result<UnlockedWallet, StoreError> {
        let name = name.trim();
        if name.is_empty() {
            return Err(StoreError::EmptyName);
        }
        let keys = data.secret.keys(data.network)?;
        data.wallet_id = new_id();
        let entry = WalletEntry {
            id: data.wallet_id.clone(),
            name: name.to_owned(),
            network: data.network,
            mode,
            view_only: keys.is_view_only(),
            created_at,
        };
        let wallet = UnlockedWallet {
            entry,
            data,
            keys,
            sealing: SealingKey::derive(password, self.kdf)?,
        };
        self.write_wallet(&wallet)?;
        let mut entries = self.list()?;
        entries.push(wallet.entry.clone());
        self.write_registry(&entries)?;
        Ok(wallet)
    }

    /// Decrypts a wallet.
    ///
    /// # Errors
    ///
    /// [`StoreError::WrongPasswordOrDamaged`] for a wrong password or a
    /// modified file; other errors for missing or unreadable files.
    pub fn unlock(&self, id: &str, password: &[u8]) -> Result<UnlockedWallet, StoreError> {
        let entry = self.entry(id)?;
        let file = fs::read(self.wallet_path(&entry.id))?;
        let (plaintext, sealing) = crypto::open(&file, password)?;
        let data: WalletData = serde_json::from_slice(&plaintext)
            .map_err(|_| StoreError::Corrupt("wallet contents are unreadable"))?;
        if data.version != PAYLOAD_VERSION {
            return Err(StoreError::UnsupportedVersion(
                u16::try_from(data.version).unwrap_or(u16::MAX),
            ));
        }
        if data.wallet_id != entry.id || data.network != entry.network {
            return Err(StoreError::Corrupt(
                "this file belongs to a different wallet",
            ));
        }
        let keys = data.secret.keys(data.network)?;
        Ok(UnlockedWallet {
            entry,
            data,
            keys,
            sealing,
        })
    }

    /// Writes an unlocked wallet back to disk with a fresh nonce.
    ///
    /// # Errors
    ///
    /// Returns an error on I/O failure.
    pub fn save(&self, wallet: &UnlockedWallet) -> Result<(), StoreError> {
        self.write_wallet(wallet)
    }

    /// Re-encrypts a wallet under a new password, with a new salt.
    ///
    /// # Errors
    ///
    /// Returns an error on I/O failure; the old file is kept if writing fails.
    pub fn change_password(
        &self,
        wallet: &mut UnlockedWallet,
        new_password: &[u8],
    ) -> Result<(), StoreError> {
        let sealing = SealingKey::derive(new_password, self.kdf)?;
        let previous = std::mem::replace(&mut wallet.sealing, sealing);
        if let Err(e) = self.write_wallet(wallet) {
            wallet.sealing = previous;
            return Err(e);
        }
        Ok(())
    }

    /// Renames a wallet in the registry.
    ///
    /// # Errors
    ///
    /// Returns an error for an empty name, unknown id, or I/O failure.
    pub fn rename(&self, id: &str, name: &str) -> Result<(), StoreError> {
        let name = name.trim();
        if name.is_empty() {
            return Err(StoreError::EmptyName);
        }
        let mut entries = self.list()?;
        let entry = entries
            .iter_mut()
            .find(|e| e.id == id)
            .ok_or(StoreError::NotFound)?;
        name.clone_into(&mut entry.name);
        self.write_registry(&entries)
    }

    /// Removes a wallet from the registry and deletes its file.
    ///
    /// The file is unlinked, not overwritten: on flash storage overwriting
    /// does not reliably destroy the old blocks, and the file is encrypted.
    ///
    /// # Errors
    ///
    /// Returns an error for an unknown id or I/O failure.
    pub fn delete(&self, id: &str) -> Result<(), StoreError> {
        let mut entries = self.list()?;
        let before = entries.len();
        entries.retain(|e| e.id != id);
        if entries.len() == before {
            return Err(StoreError::NotFound);
        }
        self.write_registry(&entries)?;
        match fs::remove_file(self.wallet_path(id)) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e.into()),
            _ => Ok(()),
        }
    }

    fn entry(&self, id: &str) -> Result<WalletEntry, StoreError> {
        self.list()?
            .into_iter()
            .find(|e| e.id == id)
            .ok_or(StoreError::NotFound)
    }

    fn wallet_path(&self, id: &str) -> PathBuf {
        self.dir.join(format!("{id}.{WALLET_EXTENSION}"))
    }

    fn write_wallet(&self, wallet: &UnlockedWallet) -> Result<(), StoreError> {
        let plaintext = Zeroizing::new(
            serde_json::to_vec(&wallet.data).expect("wallet data always serializes"),
        );
        let sealed = wallet.sealing.seal(&plaintext);
        write_atomic(&self.wallet_path(&wallet.entry.id), &sealed)
    }

    fn write_registry(&self, entries: &[WalletEntry]) -> Result<(), StoreError> {
        let json = serde_json::to_vec_pretty(entries).expect("registry always serializes");
        write_atomic(&self.dir.join(REGISTRY_FILE), &json)
    }
}

/// Writes to a temporary file, syncs it, then renames over the target, so a
/// crash leaves either the old file or the new one, never a torn mix.
fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), StoreError> {
    let tmp = path.with_extension("tmp");
    {
        let mut file = fs::File::create(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
    }
    fs::rename(&tmp, path)?;
    Ok(())
}

fn new_id() -> String {
    let mut bytes = [0u8; 16];
    OsRng.fill_bytes(&mut bytes);
    bytes.iter().fold(String::with_capacity(32), |mut id, b| {
        id.push(char::from_digit(u32::from(b >> 4), 16).expect("nibble is below 16"));
        id.push(char::from_digit(u32::from(b & 0xf), 16).expect("nibble is below 16"));
        id
    })
}

mod network_serde {
    use kn_keys::Network;
    use serde::{Deserialize, Deserializer, Serializer, de::Error};

    #[allow(clippy::trivially_copy_pass_by_ref)] // serde's `with` signature
    pub fn serialize<S: Serializer>(network: &Network, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(match network {
            Network::Mainnet => "mainnet",
            Network::Stagenet => "stagenet",
            Network::Testnet => "testnet",
        })
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Network, D::Error> {
        match String::deserialize(d)?.as_str() {
            "mainnet" => Ok(Network::Mainnet),
            "stagenet" => Ok(Network::Stagenet),
            "testnet" => Ok(Network::Testnet),
            other => Err(D::Error::custom(format!("unknown network {other}"))),
        }
    }
}
