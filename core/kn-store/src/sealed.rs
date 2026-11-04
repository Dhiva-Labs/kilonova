//! A wallet kept as one sealed blob instead of in a [`Store`](crate::Store)
//! directory. The browser extension has no file system; it keeps the blob
//! in extension storage.
//!
//! The blob is byte for byte what a store writes as `<id>.wallet`, and the
//! sync cache what it writes as `<id>.cache`, so the same password opens a
//! wallet in either place.

use kn_keys::WalletKeys;
use zeroize::Zeroizing;

use crate::{KdfParams, PAYLOAD_VERSION, StoreError, WalletData, crypto, crypto::SealingKey};

/// An unlocked wallet together with the key that seals it again.
pub struct SealedWallet {
    pub data: WalletData,
    pub keys: WalletKeys,
    sealing: SealingKey,
}

impl SealedWallet {
    /// Creates a wallet and seals it under `password`. The secret is checked
    /// first, as [`Store::create`](crate::Store::create) does.
    ///
    /// # Errors
    ///
    /// Returns an error for an invalid secret or unusable KDF parameters.
    pub fn create(
        mut data: WalletData,
        password: &[u8],
        kdf: KdfParams,
    ) -> Result<(Self, Vec<u8>), StoreError> {
        let keys = data.secret.keys(data.network)?;
        data.wallet_id = crate::new_id();
        let wallet = Self {
            data,
            keys,
            sealing: SealingKey::derive(password, kdf)?,
        };
        let sealed = wallet.seal();
        Ok((wallet, sealed))
    }

    /// Opens a sealed wallet.
    ///
    /// # Errors
    ///
    /// [`StoreError::WrongPasswordOrDamaged`] for a wrong password or a
    /// modified blob, [`StoreError::UnsupportedVersion`] for a newer format.
    pub fn unlock(file: &[u8], password: &[u8]) -> Result<Self, StoreError> {
        let (plaintext, sealing) = crypto::open(file, password)?;
        let data: WalletData = serde_json::from_slice(&plaintext)
            .map_err(|_| StoreError::Corrupt("wallet contents are unreadable"))?;
        if data.version != PAYLOAD_VERSION {
            return Err(StoreError::UnsupportedVersion(
                u16::try_from(data.version).unwrap_or(u16::MAX),
            ));
        }
        let keys = data.secret.keys(data.network)?;
        Ok(Self {
            data,
            keys,
            sealing,
        })
    }

    /// The wallet's id, fixed at creation; it also binds the sync cache.
    #[must_use]
    pub fn id(&self) -> &str {
        &self.data.wallet_id
    }

    /// The wallet sealed again with a fresh nonce, after `data` changed.
    ///
    /// # Panics
    ///
    /// Never: wallet data always serializes.
    #[must_use]
    pub fn seal(&self) -> Vec<u8> {
        let plaintext =
            Zeroizing::new(serde_json::to_vec(&self.data).expect("wallet data always serializes"));
        self.sealing.seal(&plaintext)
    }

    /// Seals a sync cache with the wallet's key, tagged with its id so it
    /// cannot be swapped for another wallet's.
    #[must_use]
    pub fn seal_cache(&self, cache: &[u8]) -> Vec<u8> {
        let id = self.data.wallet_id.as_bytes();
        let mut plaintext = Zeroizing::new(Vec::with_capacity(id.len() + 1 + cache.len()));
        plaintext.extend_from_slice(id);
        plaintext.push(b'\n');
        plaintext.extend_from_slice(cache);
        self.sealing.seal(&plaintext)
    }

    /// Opens a cache from [`seal_cache`](Self::seal_cache).
    ///
    /// # Errors
    ///
    /// [`StoreError::Corrupt`] if it cannot be decrypted or belongs to
    /// another wallet; sync then starts over.
    pub fn open_cache(&self, file: &[u8]) -> Result<Zeroizing<Vec<u8>>, StoreError> {
        let plaintext = self
            .sealing
            .open(file)
            .map_err(|_| StoreError::Corrupt("sync cache cannot be read"))?;
        let id = self.data.wallet_id.as_bytes();
        if plaintext.len() <= id.len()
            || &plaintext[..id.len()] != id
            || plaintext[id.len()] != b'\n'
        {
            return Err(StoreError::Corrupt("sync cache belongs to another wallet"));
        }
        Ok(Zeroizing::new(plaintext[id.len() + 1..].to_vec()))
    }
}

#[cfg(test)]
mod tests {
    use kn_keys::{Network, SeedFormat};

    use super::*;
    use crate::{SyncMode, WalletSecret};

    fn new_wallet() -> (SealedWallet, Vec<u8>) {
        let (_, mnemonic) = WalletKeys::generate(SeedFormat::Polyseed);
        let data = WalletData::new(
            Network::Stagenet,
            WalletSecret::Seed {
                words: mnemonic.words,
            },
        );
        SealedWallet::create(data, b"pw", KdfParams::MIN).unwrap()
    }

    #[test]
    fn round_trips_and_rejects_wrong_password() {
        let (wallet, blob) = new_wallet();
        let opened = SealedWallet::unlock(&blob, b"pw").unwrap();
        assert_eq!(opened.data.wallet_id, wallet.data.wallet_id);
        assert_eq!(
            opened.keys.primary_address(Network::Stagenet),
            wallet.keys.primary_address(Network::Stagenet)
        );
        assert!(matches!(
            SealedWallet::unlock(&blob, b"other"),
            Err(StoreError::WrongPasswordOrDamaged)
        ));
    }

    #[test]
    fn cache_is_bound_to_its_wallet() {
        let (wallet, _) = new_wallet();
        let (other, _) = new_wallet();
        let cache = wallet.seal_cache(b"state");
        assert_eq!(wallet.open_cache(&cache).unwrap().as_slice(), b"state");
        assert!(other.open_cache(&cache).is_err());
    }

    #[test]
    fn opens_a_wallet_file_a_store_wrote() {
        let (_, mnemonic) = WalletKeys::generate(SeedFormat::Classic);
        let dir = tempfile::tempdir().unwrap();
        let store = crate::Store::with_kdf(dir.path(), KdfParams::MIN).unwrap();
        let created = store
            .create(
                "desktop",
                SyncMode::Full,
                WalletData::new(
                    Network::Mainnet,
                    WalletSecret::Seed {
                        words: mnemonic.words,
                    },
                ),
                b"pw",
                0,
            )
            .unwrap();
        let file = std::fs::read(dir.path().join(format!(
            "{}.{}",
            created.entry.id,
            crate::WALLET_EXTENSION
        )))
        .unwrap();
        let opened = SealedWallet::unlock(&file, b"pw").unwrap();
        assert_eq!(opened.data.wallet_id, created.data.wallet_id);
        assert_eq!(
            opened.keys.primary_address(Network::Mainnet),
            created.keys.primary_address(Network::Mainnet)
        );
    }
}
