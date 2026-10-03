//! Backup bundles: one or more wallets in a single file, encrypted with a
//! passphrase of its own.
//!
//! Each wallet travels as stored: its encrypted wallet file and sync cache
//! byte for byte (never decrypted, so a bundle holds nothing the locked
//! wallet files do not), its registry entry and its network settings.
//! Labels, the address book, notes, payment requests and sent records live
//! inside the wallet file and come along with it.
//!
//! Layout, all integers little-endian:
//!
//! ```text
//! magic      8  b"KNBACKUP"
//! version    2  1
//! sealed        the payload in the wallet file envelope (`crypto`):
//!               Argon2id from the passphrase, XChaCha20-Poly1305
//! ```
//!
//! The payload repeats the magic and version (so the outer header is
//! checked against authenticated data), then:
//!
//! ```text
//! count      4  wallets
//! per wallet
//!   meta     4 + n  JSON: registry entry and settings
//!   file     4 + n  the wallet file as stored
//!   cache    4 + n  the sync cache as stored; empty if there is none
//! ```

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

use crate::crypto::{self, SealingKey};
use crate::{KdfParams, StoreError, WalletEntry};

const MAGIC: &[u8; 8] = b"KNBACKUP";
const VERSION: u16 = 1;
const HEADER_LEN: usize = 8 + 2;
/// More wallets than anyone keeps; bounds what a crafted count can ask
/// for.
const MAX_WALLETS: u32 = 4096;

/// Network choices a wallet was using, so a restored wallet syncs the same
/// way. Nothing here is secret.
#[derive(Clone, Default, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub struct WalletSettings {
    /// The node the wallet's network synced from.
    #[serde(default)]
    pub node: Option<String>,
    /// Nodes the owner added for that network.
    #[serde(default)]
    pub custom_nodes: Vec<String>,
    /// The light wallet server for that network.
    #[serde(default)]
    pub lws_server: Option<String>,
    /// Pinned certificate fingerprints, by https address, for the addresses
    /// above.
    #[serde(default)]
    pub pins: BTreeMap<String, String>,
}

/// One wallet in a bundle.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct BundleWallet {
    /// The registry entry: id, name, network, mode, flags.
    pub entry: WalletEntry,
    pub settings: WalletSettings,
    /// The encrypted wallet file, exactly as stored.
    pub file: Vec<u8>,
    /// The encrypted sync cache, exactly as stored, if there is one.
    pub cache: Option<Vec<u8>>,
}

#[derive(Serialize, Deserialize)]
struct Meta {
    entry: WalletEntry,
    #[serde(default)]
    settings: WalletSettings,
}

/// Encrypts `wallets` into a bundle with `passphrase`, using `kdf` for the
/// key derivation.
///
/// # Errors
///
/// Fails only if the key cannot be derived (parameters out of range).
pub fn seal(
    wallets: &[BundleWallet],
    passphrase: &[u8],
    kdf: KdfParams,
) -> Result<Vec<u8>, StoreError> {
    let mut payload = Zeroizing::new(Vec::new());
    payload.extend_from_slice(MAGIC);
    payload.extend_from_slice(&VERSION.to_le_bytes());
    put_len(&mut payload, wallets.len())?;
    for wallet in wallets {
        let meta = serde_json::to_vec(&Meta {
            entry: wallet.entry.clone(),
            settings: wallet.settings.clone(),
        })
        .expect("bundle metadata always serializes");
        for part in [
            meta.as_slice(),
            wallet.file.as_slice(),
            wallet.cache.as_deref().unwrap_or_default(),
        ] {
            put_len(&mut payload, part.len())?;
            payload.extend_from_slice(part);
        }
    }
    let mut out = Vec::with_capacity(HEADER_LEN + payload.len() + 128);
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&VERSION.to_le_bytes());
    out.extend_from_slice(&SealingKey::derive(passphrase, kdf)?.seal(&payload));
    Ok(out)
}

/// Decrypts a bundle and reads the wallets in it. Nothing is written.
///
/// # Errors
///
/// [`StoreError::Corrupt`] for a file that is not a bundle or is damaged,
/// [`StoreError::UnsupportedVersion`] for a bundle from a newer version,
/// [`StoreError::WrongPasswordOrDamaged`] for a wrong passphrase.
pub fn open(bundle: &[u8], passphrase: &[u8]) -> Result<Vec<BundleWallet>, StoreError> {
    let sealed = parse_header(bundle)?;
    let (payload, _) = crypto::open(sealed, passphrase).map_err(|e| match e {
        // The envelope inside a bundle is part of the bundle.
        StoreError::Corrupt(_) | StoreError::UnsupportedVersion(_) => {
            StoreError::Corrupt(NOT_A_BUNDLE)
        }
        other => other,
    })?;
    parse_payload(&payload)
}

const NOT_A_BUNDLE: &str = "not a Kilonova backup, or a damaged one";

/// Checks the outer header and returns the sealed part.
pub(crate) fn parse_header(bundle: &[u8]) -> Result<&[u8], StoreError> {
    if bundle.len() < HEADER_LEN || &bundle[..8] != MAGIC {
        return Err(StoreError::Corrupt(NOT_A_BUNDLE));
    }
    let version = u16::from_le_bytes([bundle[8], bundle[9]]);
    if version != VERSION {
        return Err(StoreError::UnsupportedVersion(version));
    }
    Ok(&bundle[HEADER_LEN..])
}

/// Reads a decrypted payload. Every length is checked against what is
/// left, and every wallet file and cache must at least look like one.
pub(crate) fn parse_payload(payload: &[u8]) -> Result<Vec<BundleWallet>, StoreError> {
    let mut reader = Reader(payload);
    if reader.take(8)? != MAGIC || reader.take(2)? != VERSION.to_le_bytes() {
        return Err(StoreError::Corrupt(NOT_A_BUNDLE));
    }
    let count = reader.u32()?;
    if count > MAX_WALLETS {
        return Err(StoreError::Corrupt(NOT_A_BUNDLE));
    }
    let mut wallets = Vec::new();
    for _ in 0..count {
        let meta: Meta = serde_json::from_slice(reader.part()?)
            .map_err(|_| StoreError::Corrupt(NOT_A_BUNDLE))?;
        let file = reader.part()?.to_vec();
        let cache = reader.part()?;
        let cache = (!cache.is_empty()).then(|| cache.to_vec());
        let ids_ok = is_id(&meta.entry.id)
            && meta.entry.file_id.as_deref().is_none_or(is_id)
            && !meta.entry.name.trim().is_empty();
        if !ids_ok
            || crypto::parse_header(&file).is_err()
            || cache
                .as_deref()
                .is_some_and(|c| crypto::parse_header(c).is_err())
        {
            return Err(StoreError::Corrupt(NOT_A_BUNDLE));
        }
        wallets.push(BundleWallet {
            entry: meta.entry,
            settings: meta.settings,
            file,
            cache,
        });
    }
    if !reader.0.is_empty() {
        return Err(StoreError::Corrupt(NOT_A_BUNDLE));
    }
    Ok(wallets)
}

/// Wallet ids are 32 lowercase hex digits; they become file names, so
/// nothing else is accepted from a bundle.
pub(crate) fn is_id(id: &str) -> bool {
    id.len() == 32 && id.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

fn put_len(out: &mut Vec<u8>, len: usize) -> Result<(), StoreError> {
    let len = u32::try_from(len).map_err(|_| StoreError::Corrupt("backup is too large"))?;
    out.extend_from_slice(&len.to_le_bytes());
    Ok(())
}

struct Reader<'a>(&'a [u8]);

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8], StoreError> {
        if self.0.len() < n {
            return Err(StoreError::Corrupt(NOT_A_BUNDLE));
        }
        let (head, rest) = self.0.split_at(n);
        self.0 = rest;
        Ok(head)
    }

    fn u32(&mut self) -> Result<u32, StoreError> {
        Ok(u32::from_le_bytes(
            self.take(4)?.try_into().expect("4 bytes"),
        ))
    }

    fn part(&mut self) -> Result<&'a [u8], StoreError> {
        let len = usize::try_from(self.u32()?).map_err(|_| StoreError::Corrupt(NOT_A_BUNDLE))?;
        self.take(len)
    }
}
