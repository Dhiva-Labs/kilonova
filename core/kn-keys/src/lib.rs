//! Seeds, keys and addresses for Kilonova wallets.
//!
//! A wallet is a private view key plus a public spend key, and, unless it is
//! view-only, the private spend key. Everything here is checked against
//! vectors produced by monero-wallet-rpc (see `tests/vectors.rs`).
//!
//! Secrets are held in [`Zeroizing`] containers and are wiped on drop. Debug
//! output never includes them.

#![forbid(unsafe_code)]

use core::fmt;

use curve25519_dalek::{Scalar as DalekScalar, constants::ED25519_BASEPOINT_TABLE};
use monero_seed::{Language as ClassicLanguage, Seed as ClassicSeed};
use monero_wallet::{
    ViewPair,
    address::{MoneroAddress, Network as MoneroNetwork, SubaddressIndex},
    ed25519::{Point, Scalar},
};
use polyseed::{Language as PolyseedLanguage, Polyseed};
use rand_core::OsRng;
use zeroize::Zeroizing;

/// The Monero network a wallet's addresses belong to.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Hash)]
pub enum Network {
    Mainnet,
    Stagenet,
    Testnet,
}

impl From<Network> for MoneroNetwork {
    fn from(network: Network) -> Self {
        match network {
            Network::Mainnet => MoneroNetwork::Mainnet,
            Network::Stagenet => MoneroNetwork::Stagenet,
            Network::Testnet => MoneroNetwork::Testnet,
        }
    }
}

/// Which mnemonic format a wallet was created or restored from.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum SeedFormat {
    /// Monero's original 25-word seed.
    Classic,
    /// The 16-word Polyseed format, which also encodes the wallet's birthday.
    Polyseed,
}

#[derive(Clone, PartialEq, Eq, Debug, thiserror::Error)]
pub enum KeyError {
    #[error("a seed has 25 words (or 16 for Polyseed); this one has {0}")]
    WrongWordCount(usize),
    #[error("one or more words are not in the English seed word list")]
    UnknownWord,
    #[error("the seed's checksum does not match; check the words and their order")]
    BadChecksum,
    #[error("this Polyseed uses features Kilonova does not support")]
    UnsupportedPolyseed,
    #[error("a key must be 64 hexadecimal characters")]
    MalformedKey,
    #[error("the key is not a valid Monero private key")]
    NonCanonicalKey,
    #[error("the address is not a valid {0:?} address")]
    BadAddress(Network),
    #[error("the view key does not belong to this address")]
    ViewKeyMismatch,
    #[error("view-only wallets need a standard address, not a subaddress or integrated address")]
    NotStandardAddress,
    #[error("subaddress index out of range")]
    BadSubaddressIndex,
}

/// A seed phrase and what it encodes beyond the keys.
pub struct Mnemonic {
    pub format: SeedFormat,
    /// The words, separated by single spaces.
    pub words: Zeroizing<String>,
    /// For Polyseed, when the wallet was created, in seconds since the Unix
    /// epoch. Sync can start from the block at that time.
    pub birthday: Option<u64>,
}

impl fmt::Debug for Mnemonic {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Mnemonic")
            .field("format", &self.format)
            .field("birthday", &self.birthday)
            .finish_non_exhaustive()
    }
}

/// The keys of one wallet.
pub struct WalletKeys {
    /// `None` for view-only wallets.
    spend: Option<Zeroizing<DalekScalar>>,
    /// Kept alongside `view_pair`, which does not expose its private half.
    view: Zeroizing<DalekScalar>,
    view_pair: ViewPair,
}

impl fmt::Debug for WalletKeys {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("WalletKeys")
            .field("view_only", &self.is_view_only())
            .finish_non_exhaustive()
    }
}

impl WalletKeys {
    /// Creates a new wallet with a fresh seed from the OS random source.
    #[must_use]
    pub fn generate(format: SeedFormat) -> (Self, Mnemonic) {
        match format {
            SeedFormat::Classic => {
                let seed = ClassicSeed::new(&mut OsRng, ClassicLanguage::English);
                let keys = Self::from_spend_bytes(&seed.entropy());
                let mnemonic = Mnemonic {
                    format,
                    words: seed.to_string(),
                    birthday: None,
                };
                (keys, mnemonic)
            }
            SeedFormat::Polyseed => {
                let seed = Polyseed::new(&mut OsRng, PolyseedLanguage::English);
                Self::from_polyseed(&seed)
            }
        }
    }

    /// Restores a wallet from a 25-word or 16-word English seed.
    ///
    /// Case and extra whitespace are ignored.
    ///
    /// # Errors
    ///
    /// Returns an error if the word count, any word, or the checksum is wrong.
    pub fn from_mnemonic(phrase: &str) -> Result<(Self, Mnemonic), KeyError> {
        let normalized = Zeroizing::new(
            phrase
                .split_whitespace()
                .map(str::to_lowercase)
                .collect::<Vec<_>>()
                .join(" "),
        );
        match normalized.split(' ').filter(|w| !w.is_empty()).count() {
            25 => {
                let seed = ClassicSeed::from_string(ClassicLanguage::English, normalized).map_err(
                    |e| match e {
                        monero_seed::SeedError::InvalidSeed => KeyError::UnknownWord,
                        _ => KeyError::BadChecksum,
                    },
                )?;
                let keys = Self::from_spend_bytes(&seed.entropy());
                let mnemonic = Mnemonic {
                    format: SeedFormat::Classic,
                    words: seed.to_string(),
                    birthday: None,
                };
                Ok((keys, mnemonic))
            }
            16 => {
                let seed =
                    Polyseed::from_string(PolyseedLanguage::English, normalized).map_err(|e| {
                        match e {
                            polyseed::PolyseedError::InvalidSeed => KeyError::UnknownWord,
                            polyseed::PolyseedError::UnsupportedFeatures
                            | polyseed::PolyseedError::InvalidEntropy => {
                                KeyError::UnsupportedPolyseed
                            }
                            polyseed::PolyseedError::InvalidChecksum => KeyError::BadChecksum,
                        }
                    })?;
                Ok(Self::from_polyseed(&seed))
            }
            n => Err(KeyError::WrongWordCount(n)),
        }
    }

    /// Restores a wallet from its private spend key, as 64 hex characters.
    ///
    /// The view key is derived from the spend key, as for any wallet created
    /// from a seed.
    ///
    /// # Errors
    ///
    /// Returns an error if the key is not valid hex or not a reduced scalar.
    pub fn from_spend_key(hex: &str) -> Result<Self, KeyError> {
        let bytes = parse_key(hex)?;
        canonical_scalar(&bytes)?;
        Ok(Self::from_spend_bytes(&bytes))
    }

    /// Creates a view-only wallet from a standard address and its private
    /// view key. It can see incoming funds but cannot spend.
    ///
    /// # Errors
    ///
    /// Returns an error if the address is invalid for `network`, is not a
    /// standard address, or the view key does not match it.
    pub fn view_only(network: Network, address: &str, view_hex: &str) -> Result<Self, KeyError> {
        let address = MoneroAddress::from_str(network.into(), address.trim())
            .map_err(|_| KeyError::BadAddress(network))?;
        if address.is_subaddress() || address.payment_id().is_some() {
            return Err(KeyError::NotStandardAddress);
        }
        let view_bytes = parse_key(view_hex)?;
        let view = canonical_scalar(&view_bytes)?;
        let view_public = Point::from(&*view * ED25519_BASEPOINT_TABLE);
        if view_public.compress().to_bytes() != address.view().compress().to_bytes() {
            return Err(KeyError::ViewKeyMismatch);
        }
        let view_pair = ViewPair::new(address.spend(), Zeroizing::new(Scalar::from(*view)))
            .map_err(|_| KeyError::BadAddress(network))?;
        Ok(Self {
            spend: None,
            view,
            view_pair,
        })
    }

    #[must_use]
    pub fn is_view_only(&self) -> bool {
        self.spend.is_none()
    }

    /// The wallet's primary address (account 0, index 0).
    #[must_use]
    pub fn primary_address(&self, network: Network) -> String {
        self.view_pair.legacy_address(network.into()).to_string()
    }

    /// The address for `account` and `index`. Index (0, 0) is the primary
    /// address; every other pair is a subaddress.
    ///
    /// # Errors
    ///
    /// Returns an error only if `monero-wallet` rejects the index pair.
    pub fn address(&self, network: Network, account: u32, index: u32) -> Result<String, KeyError> {
        if account == 0 && index == 0 {
            return Ok(self.primary_address(network));
        }
        let sub = SubaddressIndex::new(account, index).ok_or(KeyError::BadSubaddressIndex)?;
        Ok(self.view_pair.subaddress(network.into(), sub).to_string())
    }

    /// The private spend key as hex, for export. `None` if view-only.
    #[must_use]
    pub fn secret_spend_key_hex(&self) -> Option<Zeroizing<String>> {
        self.spend.as_ref().map(|s| hex_encode(s.as_bytes()))
    }

    /// The private view key as hex, for export or for an LWS login.
    #[must_use]
    pub fn secret_view_key_hex(&self) -> Zeroizing<String> {
        hex_encode(self.view.as_bytes())
    }

    fn from_polyseed(seed: &Polyseed) -> (Self, Mnemonic) {
        let keys = Self::from_spend_bytes(&seed.key());
        let mnemonic = Mnemonic {
            format: SeedFormat::Polyseed,
            words: seed.to_string(),
            birthday: Some(seed.birthday()),
        };
        (keys, mnemonic)
    }

    /// Derives the wallet the way wallet2 does: the spend key is the 32 bytes
    /// reduced mod l, and the view key is `Hs(spend)`.
    fn from_spend_bytes(bytes: &[u8; 32]) -> Self {
        let spend = Zeroizing::new(DalekScalar::from_bytes_mod_order(*bytes));
        let view = Zeroizing::new(Scalar::hash(spend.as_bytes()).into());
        let spend_public = Point::from(&*spend * ED25519_BASEPOINT_TABLE);
        let view_pair = ViewPair::new(spend_public, Zeroizing::new(Scalar::from(*view)))
            .expect("a basepoint multiple is always torsion-free");
        Self {
            spend: Some(spend),
            view,
            view_pair,
        }
    }
}

fn hex_encode(bytes: &[u8; 32]) -> Zeroizing<String> {
    let mut out = Zeroizing::new(String::with_capacity(64));
    for b in bytes {
        out.push(char::from_digit(u32::from(b >> 4), 16).expect("nibble is below 16"));
        out.push(char::from_digit(u32::from(b & 0xf), 16).expect("nibble is below 16"));
    }
    out
}

fn parse_key(hex: &str) -> Result<Zeroizing<[u8; 32]>, KeyError> {
    let hex = hex.trim().as_bytes();
    if hex.len() != 64 {
        return Err(KeyError::MalformedKey);
    }
    let mut out = Zeroizing::new([0u8; 32]);
    for (i, pair) in hex.chunks_exact(2).enumerate() {
        let hi = char::from(pair[0])
            .to_digit(16)
            .ok_or(KeyError::MalformedKey)?;
        let lo = char::from(pair[1])
            .to_digit(16)
            .ok_or(KeyError::MalformedKey)?;
        out[i] = u8::try_from(hi << 4 | lo).expect("two nibbles fit a byte");
    }
    Ok(out)
}

fn canonical_scalar(bytes: &[u8; 32]) -> Result<Zeroizing<DalekScalar>, KeyError> {
    Option::<DalekScalar>::from(DalekScalar::from_canonical_bytes(*bytes))
        .map(Zeroizing::new)
        .ok_or(KeyError::NonCanonicalKey)
}
