//! The encrypted envelope around a wallet file's contents.
//!
//! Layout, all integers little-endian:
//!
//! ```text
//! magic      4  b"KNW1"
//! version    2  1
//! m_cost     4  Argon2id memory, KiB
//! t_cost     4  Argon2id iterations
//! p_cost     4  Argon2id lanes
//! salt      16
//! nonce     24  XChaCha20-Poly1305
//! ciphertext    payload + 16-byte tag
//! ```
//!
//! Everything before the ciphertext is authenticated as associated data, so
//! changing the KDF parameters or salt makes decryption fail instead of
//! silently deriving a different key.

use argon2::{Algorithm, Argon2, Params, Version};
use chacha20poly1305::{
    KeyInit, XChaCha20Poly1305, XNonce,
    aead::{Aead, Payload},
};
use rand_core::{OsRng, RngCore};
use zeroize::Zeroizing;

use crate::StoreError;

const MAGIC: &[u8; 4] = b"KNW1";
const FORMAT_VERSION: u16 = 1;
const SALT_LEN: usize = 16;
const NONCE_LEN: usize = 24;
const HEADER_LEN: usize = 4 + 2 + 4 + 4 + 4 + SALT_LEN + NONCE_LEN;

/// Argon2id cost parameters.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct KdfParams {
    pub memory_kib: u32,
    pub iterations: u32,
    pub lanes: u32,
}

impl KdfParams {
    /// Used for new wallet files: 64 MiB, 3 passes, 1 lane. Roughly half a
    /// second on a mid-range phone, which is paid once per unlock.
    pub const DEFAULT: Self = Self {
        memory_kib: 64 * 1024,
        iterations: 3,
        lanes: 1,
    };

    /// Floors below which a file is refused. Also the cheapest setting new
    /// files can use, which keeps tests fast.
    /// A tampered header cannot
    /// weaken the KDF anyway (it is authenticated), but a file written with
    /// weak parameters by a bug should not be accepted silently.
    pub const MIN: Self = Self {
        memory_kib: 19 * 1024,
        iterations: 2,
        lanes: 1,
    };

    /// Ceilings, so a crafted file cannot make unlocking allocate gigabytes
    /// or spin for minutes before the tag check fails.
    const MAX: Self = Self {
        memory_kib: 1024 * 1024,
        iterations: 64,
        lanes: 16,
    };

    fn in_bounds(self) -> bool {
        (Self::MIN.memory_kib..=Self::MAX.memory_kib).contains(&self.memory_kib)
            && (Self::MIN.iterations..=Self::MAX.iterations).contains(&self.iterations)
            && (Self::MIN.lanes..=Self::MAX.lanes).contains(&self.lanes)
    }
}

/// A key derived from a password, together with the salt and parameters
/// needed to write the file again without asking for the password.
pub struct SealingKey {
    key: Zeroizing<[u8; 32]>,
    salt: [u8; SALT_LEN],
    params: KdfParams,
}

impl SealingKey {
    pub fn derive(password: &[u8], params: KdfParams) -> Result<Self, StoreError> {
        let mut salt = [0u8; SALT_LEN];
        OsRng.fill_bytes(&mut salt);
        Self::derive_with_salt(password, salt, params)
    }

    fn derive_with_salt(
        password: &[u8],
        salt: [u8; SALT_LEN],
        params: KdfParams,
    ) -> Result<Self, StoreError> {
        let argon = Argon2::new(
            Algorithm::Argon2id,
            Version::V0x13,
            Params::new(params.memory_kib, params.iterations, params.lanes, Some(32))
                .map_err(|_| StoreError::Corrupt("invalid key derivation parameters"))?,
        );
        let mut key = Zeroizing::new([0u8; 32]);
        argon
            .hash_password_into(password, &salt, key.as_mut())
            .map_err(|_| StoreError::Corrupt("key derivation failed"))?;
        Ok(Self { key, salt, params })
    }

    /// Encrypts `plaintext` with a fresh random nonce.
    pub fn seal(&self, plaintext: &[u8]) -> Vec<u8> {
        let mut nonce = [0u8; NONCE_LEN];
        OsRng.fill_bytes(&mut nonce);

        let mut out = Vec::with_capacity(HEADER_LEN + plaintext.len() + 16);
        out.extend_from_slice(MAGIC);
        out.extend_from_slice(&FORMAT_VERSION.to_le_bytes());
        out.extend_from_slice(&self.params.memory_kib.to_le_bytes());
        out.extend_from_slice(&self.params.iterations.to_le_bytes());
        out.extend_from_slice(&self.params.lanes.to_le_bytes());
        out.extend_from_slice(&self.salt);
        out.extend_from_slice(&nonce);

        let cipher = XChaCha20Poly1305::new(self.key.as_ref().into());
        let ciphertext = cipher
            .encrypt(
                XNonce::from_slice(&nonce),
                Payload {
                    msg: plaintext,
                    aad: &out,
                },
            )
            .expect("XChaCha20-Poly1305 encryption cannot fail for in-memory buffers");
        out.extend_from_slice(&ciphertext);
        out
    }
}

impl SealingKey {
    /// Decrypts a file sealed with this key, such as the wallet's sync cache.
    pub fn open(&self, file: &[u8]) -> Result<Zeroizing<Vec<u8>>, StoreError> {
        let (salt, params, nonce) = parse_header(file)?;
        if salt != self.salt || params != self.params {
            return Err(StoreError::WrongPasswordOrDamaged);
        }
        decrypt(&self.key, nonce, file)
    }
}

pub(crate) fn parse_header(file: &[u8]) -> Result<([u8; SALT_LEN], KdfParams, &[u8]), StoreError> {
    if file.len() < HEADER_LEN + 16 || &file[..4] != MAGIC {
        return Err(StoreError::Corrupt("not a Kilonova wallet file"));
    }
    let version = u16::from_le_bytes([file[4], file[5]]);
    if version != FORMAT_VERSION {
        return Err(StoreError::UnsupportedVersion(version));
    }
    let u32_at = |at: usize| u32::from_le_bytes(file[at..at + 4].try_into().expect("4 bytes"));
    let params = KdfParams {
        memory_kib: u32_at(6),
        iterations: u32_at(10),
        lanes: u32_at(14),
    };
    if !params.in_bounds() {
        return Err(StoreError::Corrupt(
            "key derivation parameters out of range",
        ));
    }
    let salt: [u8; SALT_LEN] = file[18..18 + SALT_LEN].try_into().expect("salt length");
    Ok((salt, params, &file[18 + SALT_LEN..HEADER_LEN]))
}

fn decrypt(key: &[u8; 32], nonce: &[u8], file: &[u8]) -> Result<Zeroizing<Vec<u8>>, StoreError> {
    let cipher = XChaCha20Poly1305::new(key.into());
    cipher
        .decrypt(
            XNonce::from_slice(nonce),
            Payload {
                msg: &file[HEADER_LEN..],
                aad: &file[..HEADER_LEN],
            },
        )
        .map(Zeroizing::new)
        .map_err(|_| StoreError::WrongPasswordOrDamaged)
}

/// Decrypts a wallet file, returning the plaintext and the key to write it
/// back with.
pub fn open(file: &[u8], password: &[u8]) -> Result<(Zeroizing<Vec<u8>>, SealingKey), StoreError> {
    let (salt, params, nonce) = parse_header(file)?;
    let key = SealingKey::derive_with_salt(password, salt, params)?;
    let plaintext = decrypt(&key.key, nonce, file)?;
    Ok((plaintext, key))
}

#[cfg(test)]
mod tests {
    use super::*;

    // Cheap parameters at the floor keep the tests fast.
    const TEST: KdfParams = KdfParams::MIN;

    #[test]
    fn round_trips() {
        let key = SealingKey::derive(b"hunter2", TEST).unwrap();
        let file = key.seal(b"secret payload");
        let (plain, _) = open(&file, b"hunter2").unwrap();
        assert_eq!(plain.as_slice(), b"secret payload");
    }

    #[test]
    fn wrong_password_fails() {
        let file = SealingKey::derive(b"hunter2", TEST).unwrap().seal(b"x");
        assert!(matches!(
            open(&file, b"hunter3"),
            Err(StoreError::WrongPasswordOrDamaged)
        ));
    }

    #[test]
    fn every_header_and_body_byte_is_authenticated() {
        let file = SealingKey::derive(b"pw", TEST).unwrap().seal(b"payload");
        // Skip the magic and version (rejected earlier with their own errors)
        // and the KDF parameters (rejected or re-derived); flip every byte
        // from the salt onward.
        for i in 18..file.len() {
            let mut tampered = file.clone();
            tampered[i] ^= 0x01;
            assert!(
                matches!(
                    open(&tampered, b"pw"),
                    Err(StoreError::WrongPasswordOrDamaged)
                ),
                "byte {i} was not authenticated"
            );
        }
    }

    #[test]
    fn weakened_parameters_are_refused() {
        let mut file = SealingKey::derive(b"pw", TEST).unwrap().seal(b"payload");
        file[6..10].copy_from_slice(&8u32.to_le_bytes());
        assert!(matches!(open(&file, b"pw"), Err(StoreError::Corrupt(_))));
    }

    #[test]
    fn oversized_parameters_are_refused_before_deriving() {
        let mut file = SealingKey::derive(b"pw", TEST).unwrap().seal(b"payload");
        file[6..10].copy_from_slice(&u32::MAX.to_le_bytes());
        assert!(matches!(open(&file, b"pw"), Err(StoreError::Corrupt(_))));
    }

    #[test]
    fn nonces_are_fresh_per_write() {
        let key = SealingKey::derive(b"pw", TEST).unwrap();
        let a = key.seal(b"same");
        let b = key.seal(b"same");
        assert_ne!(a[18 + SALT_LEN..HEADER_LEN], b[18 + SALT_LEN..HEADER_LEN]);
        assert_ne!(a, b);
    }

    #[test]
    fn rejects_other_files_and_versions() {
        assert!(matches!(open(b"hello", b"pw"), Err(StoreError::Corrupt(_))));
        let mut file = SealingKey::derive(b"pw", TEST).unwrap().seal(b"payload");
        file[4] = 9;
        assert!(matches!(
            open(&file, b"pw"),
            Err(StoreError::UnsupportedVersion(9))
        ));
    }
}
