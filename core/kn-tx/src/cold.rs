//! Offline signing: a phone that holds the spend key and never goes online
//! (the cold wallet) signs for a view-only wallet that syncs (the watching
//! wallet). They talk in short messages carried as QR codes or files:
//!
//! - `Pairing` (cold to watching): address, view key and restore height, to
//!   create the watching wallet.
//! - `SyncRequest` (watching to cold): outputs the watching wallet found
//!   but cannot derive key images for.
//! - `SyncAnswer` (cold to watching): their key images, so the watching
//!   wallet can see its own spends.
//! - `SignRequest` (watching to cold): a built, unsigned transaction, plus
//!   any outputs still missing key images.
//! - `Signed` (cold to watching): the signed transaction, its transaction
//!   key and the key images.
//!
//! The cold wallet trusts nothing in a request. It reads the payments, change
//! and fee from the transaction it is about to sign, refuses inputs that are
//! not its own and change that does not come back to itself, and answers key
//! image requests only for outputs it can spend.

use std::io::{Cursor, Read};

use kn_keys::{Network, WalletKeys};
use kn_sync::{OwnedOutput, SyncState};
use monero_wallet::OutputWithDecoys;
use monero_wallet::address::{MoneroAddress, Network as MoneroNetwork};
use monero_wallet::ed25519::{CompressedPoint, Point, Scalar};
use monero_wallet::io::{VarInt, read_byte, read_bytes, read_u32, read_u64};
use monero_wallet::primitives::keccak256;
use monero_wallet::send::{SignableTransaction, TransactionKeys};
use monero_wallet::transaction::{Input, Transaction};
use zeroize::Zeroizing;

use crate::{MAX_FEE_MASK, MAX_FEE_PER_WEIGHT, TxError, Unsigned, confirmed_tx_key};

/// `(output one-time key, key image)`, or in a request `(output key, key
/// offset)`.
pub type KeyImagePair = ([u8; 32], [u8; 32]);

const MAGIC: &[u8; 4] = b"KNCW";
const VERSION: u8 = 1;

/// Characters of base32 per QR frame. Small frames scan quickly with a
/// phone camera; a long transaction becomes an animated sequence.
pub const FRAME_CHARS: usize = 480;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum ColdError {
    #[error("this is not a Kilonova cold wallet message")]
    NotColdData,
    #[error("this message is for another wallet")]
    WrongWallet,
    #[error("this message is for another network")]
    WrongNetwork,
    #[error("this message is not the kind expected here")]
    WrongKind,
    #[error("the message is damaged or incomplete")]
    Damaged,
    #[error("the transaction spends coins that are not this wallet's")]
    NotOurs,
    #[error("the transaction sends its change somewhere other than this wallet")]
    ChangeElsewhere,
    #[error("the transaction pays an address on another network")]
    BadAddress,
    #[error("the fee is far above normal")]
    FeeTooHigh,
    #[error("the amounts in the transaction do not add up")]
    Inconsistent,
    #[error("a view-only wallet cannot sign")]
    ViewOnly,
    #[error("signing failed: {0}")]
    Signing(String),
}

impl From<ColdError> for TxError {
    fn from(e: ColdError) -> Self {
        TxError::Build(e.to_string())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Pairing,
    SyncRequest,
    SyncAnswer,
    SignRequest,
    Signed,
}

impl Kind {
    fn byte(self) -> u8 {
        match self {
            Self::Pairing => 0,
            Self::SyncRequest => 1,
            Self::SyncAnswer => 2,
            Self::SignRequest => 3,
            Self::Signed => 4,
        }
    }

    fn from_byte(b: u8) -> Result<Self, ColdError> {
        Ok(match b {
            0 => Self::Pairing,
            1 => Self::SyncRequest,
            2 => Self::SyncAnswer,
            3 => Self::SignRequest,
            4 => Self::Signed,
            _ => return Err(ColdError::NotColdData),
        })
    }
}

fn network_byte(network: Network) -> u8 {
    match network {
        Network::Mainnet => 0,
        Network::Stagenet => 1,
        Network::Testnet => 2,
    }
}

fn network_from_byte(b: u8) -> Result<Network, ColdError> {
    Ok(match b {
        0 => Network::Mainnet,
        1 => Network::Stagenet,
        2 => Network::Testnet,
        _ => return Err(ColdError::NotColdData),
    })
}

/// Identifies a wallet without revealing it: the first eight bytes of the
/// Keccak hash of its primary address.
#[must_use]
pub fn wallet_tag(address: &str) -> [u8; 8] {
    let hash = keccak256(address.as_bytes());
    let mut tag = [0u8; 8];
    tag.copy_from_slice(&hash[..8]);
    tag
}

/// One cold wallet message.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Envelope {
    pub kind: Kind,
    pub network: Network,
    /// [`wallet_tag`] of the wallet both sides share; zero for pairing.
    pub wallet: [u8; 8],
    pub body: Vec<u8>,
}

impl Envelope {
    fn for_wallet(kind: Kind, keys: &WalletKeys, network: Network, body: Vec<u8>) -> Self {
        Self {
            kind,
            network,
            wallet: wallet_tag(&keys.primary_address(network)),
            body,
        }
    }

    #[must_use]
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(15 + self.body.len());
        out.extend_from_slice(MAGIC);
        out.push(VERSION);
        out.push(self.kind.byte());
        out.push(network_byte(self.network));
        out.extend_from_slice(&self.wallet);
        out.extend_from_slice(&self.body);
        out
    }

    /// # Errors
    ///
    /// [`ColdError::NotColdData`] for anything else.
    pub fn from_bytes(bytes: &[u8]) -> Result<Self, ColdError> {
        if bytes.len() < 15 || &bytes[..4] != MAGIC || bytes[4] != VERSION {
            return Err(ColdError::NotColdData);
        }
        let mut wallet = [0u8; 8];
        wallet.copy_from_slice(&bytes[7..15]);
        Ok(Self {
            kind: Kind::from_byte(bytes[5])?,
            network: network_from_byte(bytes[6])?,
            wallet,
            body: bytes[15..].to_vec(),
        })
    }

    /// Checks the message is `kind`, for this wallet and network.
    fn expect(&self, kind: Kind, keys: &WalletKeys, network: Network) -> Result<(), ColdError> {
        if self.network != network {
            return Err(ColdError::WrongNetwork);
        }
        if self.wallet != wallet_tag(&keys.primary_address(network)) {
            return Err(ColdError::WrongWallet);
        }
        if self.kind != kind {
            return Err(ColdError::WrongKind);
        }
        Ok(())
    }
}

// ---- QR frames ------------------------------------------------------------

const BASE32: &[u8; 32] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

fn base32_encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(5) * 8);
    let mut buffer = 0u32;
    let mut bits = 0u32;
    for &b in bytes {
        buffer = (buffer << 8) | u32::from(b);
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            out.push(char::from(BASE32[((buffer >> bits) & 31) as usize]));
        }
    }
    if bits > 0 {
        out.push(char::from(BASE32[((buffer << (5 - bits)) & 31) as usize]));
    }
    out
}

fn base32_decode(text: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(text.len() * 5 / 8);
    let mut buffer = 0u32;
    let mut bits = 0u32;
    for c in text.bytes() {
        let value = BASE32.iter().position(|&b| b == c)?;
        buffer = (buffer << 5) | u32::try_from(value).ok()?;
        bits += 5;
        if bits >= 8 {
            bits -= 8;
            out.push(u8::try_from((buffer >> bits) & 0xff).ok()?);
        }
    }
    Some(out)
}

fn checksum(bytes: &[u8]) -> String {
    let hash = keccak256(bytes);
    base32_encode(&hash[..5])
}

/// Splits a message into QR frames `KN1:<i>/<n>:<checksum>:<data>`, all in
/// the QR alphanumeric character set so the codes stay small.
///
/// # Panics
///
/// Never: base32 output is ASCII.
#[must_use]
pub fn frames(message: &[u8], chunk_chars: usize) -> Vec<String> {
    let data = base32_encode(message);
    let sum = checksum(message);
    let chunk_chars = chunk_chars.max(16);
    let chunks: Vec<&str> = data
        .as_bytes()
        .chunks(chunk_chars)
        .map(|c| std::str::from_utf8(c).expect("base32 is ASCII"))
        .collect();
    let total = chunks.len().max(1);
    if chunks.is_empty() {
        return vec![format!("KN1:1/1:{sum}:")];
    }
    chunks
        .iter()
        .enumerate()
        .map(|(i, chunk)| format!("KN1:{}/{total}:{sum}:{chunk}", i + 1))
        .collect()
}

/// Collects QR frames in any order, and repeats, until a message is whole.
#[derive(Debug, Default)]
pub struct Assembler {
    checksum: Option<String>,
    parts: Vec<Option<String>>,
}

/// How far an [`Assembler`] has come.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Progress {
    pub received: usize,
    pub total: usize,
}

impl Assembler {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Adds one scanned frame. A frame from a different message starts over.
    ///
    /// # Errors
    ///
    /// [`ColdError::NotColdData`] for a code that is not a Kilonova frame.
    pub fn add(&mut self, frame: &str) -> Result<Progress, ColdError> {
        let frame = frame.trim();
        let rest = frame.strip_prefix("KN1:").ok_or(ColdError::NotColdData)?;
        let mut fields = rest.splitn(3, ':');
        let position = fields.next().ok_or(ColdError::NotColdData)?;
        let sum = fields.next().ok_or(ColdError::NotColdData)?;
        let data = fields.next().ok_or(ColdError::NotColdData)?;
        let (index, total) = position.split_once('/').ok_or(ColdError::NotColdData)?;
        let index: usize = index.parse().map_err(|_| ColdError::NotColdData)?;
        let total: usize = total.parse().map_err(|_| ColdError::NotColdData)?;
        if index == 0 || index > total || total > 10_000 {
            return Err(ColdError::NotColdData);
        }
        if self.checksum.as_deref() != Some(sum) || self.parts.len() != total {
            self.checksum = Some(sum.to_owned());
            self.parts = vec![None; total];
        }
        self.parts[index - 1] = Some(data.to_owned());
        Ok(self.progress())
    }

    #[must_use]
    pub fn progress(&self) -> Progress {
        Progress {
            received: self.parts.iter().filter(|p| p.is_some()).count(),
            total: self.parts.len(),
        }
    }

    /// The whole message, once every frame has arrived and it matches its
    /// checksum.
    ///
    /// # Errors
    ///
    /// [`ColdError::Damaged`] if frames are missing or do not match.
    pub fn message(&self) -> Result<Vec<u8>, ColdError> {
        let mut data = String::new();
        for part in &self.parts {
            data.push_str(part.as_deref().ok_or(ColdError::Damaged)?);
        }
        let bytes = base32_decode(&data).ok_or(ColdError::Damaged)?;
        if Some(checksum(&bytes)) != self.checksum {
            return Err(ColdError::Damaged);
        }
        Ok(bytes)
    }
}

// ---- body encoding ----------------------------------------------------------

fn write_varint(n: usize, out: &mut Vec<u8>) {
    VarInt::write(&n, out).expect("writing to a Vec cannot fail");
}

fn read_varint(r: &mut impl Read) -> Result<usize, ColdError> {
    VarInt::read(r).map_err(|_| ColdError::Damaged)
}

fn read_32(r: &mut impl Read) -> Result<[u8; 32], ColdError> {
    read_bytes(r).map_err(|_| ColdError::Damaged)
}

fn write_blob(bytes: &[u8], out: &mut Vec<u8>) {
    write_varint(bytes.len(), out);
    out.extend_from_slice(bytes);
}

fn read_blob(r: &mut impl Read, limit: usize) -> Result<Vec<u8>, ColdError> {
    let len = read_varint(r)?;
    if len > limit {
        return Err(ColdError::Damaged);
    }
    let mut out = vec![0u8; len];
    r.read_exact(&mut out).map_err(|_| ColdError::Damaged)?;
    Ok(out)
}

fn scalar_bytes(scalar: Scalar) -> [u8; 32] {
    <[u8; 32]>::from(scalar)
}

/// Outputs a cold wallet should derive key images for: one-time key and
/// key offset each.
fn write_output_refs(outputs: &[&OwnedOutput], out: &mut Vec<u8>) {
    write_varint(outputs.len(), out);
    for o in outputs {
        out.extend_from_slice(&o.output.key().compress().to_bytes());
        out.extend_from_slice(&scalar_bytes(o.output.key_offset()));
    }
}

fn read_output_refs(r: &mut impl Read) -> Result<Vec<KeyImagePair>, ColdError> {
    let n = read_varint(r)?;
    if n > 100_000 {
        return Err(ColdError::Damaged);
    }
    (0..n).map(|_| Ok((read_32(r)?, read_32(r)?))).collect()
}

fn write_key_images(pairs: &[KeyImagePair], out: &mut Vec<u8>) {
    write_varint(pairs.len(), out);
    for (key, image) in pairs {
        out.extend_from_slice(key);
        out.extend_from_slice(image);
    }
}

fn read_key_images(r: &mut impl Read) -> Result<Vec<KeyImagePair>, ColdError> {
    read_output_refs(r)
}

/// Key images for outputs a watching wallet asked about, skipping any that
/// are not this wallet's. Returns the answered pairs and how many were
/// refused.
fn derive_key_images(keys: &WalletKeys, refs: &[KeyImagePair]) -> (Vec<KeyImagePair>, usize) {
    let mut answered = Vec::with_capacity(refs.len());
    let mut refused = 0;
    for (key, offset) in refs {
        let parsed = CompressedPoint::from(*key)
            .decompress()
            .zip(Scalar::read(&mut offset.as_slice()).ok());
        match parsed.map(|(point, offset)| keys.owned_key_image(point, offset)) {
            Some(Ok(image)) => answered.push((*key, image)),
            _ => refused += 1,
        }
    }
    (answered, refused)
}

// ---- pairing ------------------------------------------------------------------

/// What a watching wallet needs to watch a cold wallet.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pairing {
    pub network: Network,
    pub address: String,
    pub view_key_hex: Zeroizing<String>,
    pub restore_height: u64,
}

/// The pairing message a cold wallet shows.
///
/// # Panics
///
/// Never: the view key is always hex.
#[must_use]
pub fn pairing(keys: &WalletKeys, network: Network, restore_height: u64) -> Envelope {
    let mut body = Vec::new();
    write_blob(keys.primary_address(network).as_bytes(), &mut body);
    let view = hex::decode(keys.secret_view_key_hex().as_str()).expect("view key is hex");
    body.extend_from_slice(&view);
    body.extend_from_slice(&restore_height.to_le_bytes());
    Envelope {
        kind: Kind::Pairing,
        network,
        wallet: [0; 8],
        body,
    }
}

/// # Errors
///
/// [`ColdError::WrongKind`] or [`ColdError::Damaged`].
pub fn read_pairing(envelope: &Envelope) -> Result<Pairing, ColdError> {
    if envelope.kind != Kind::Pairing {
        return Err(ColdError::WrongKind);
    }
    let mut r = Cursor::new(&envelope.body);
    let address = String::from_utf8(read_blob(&mut r, 256)?).map_err(|_| ColdError::Damaged)?;
    let view = Zeroizing::new(read_32(&mut r)?);
    let restore_height = read_u64(&mut r).map_err(|_| ColdError::Damaged)?;
    Ok(Pairing {
        network: envelope.network,
        address,
        view_key_hex: Zeroizing::new(hex::encode(*view)),
        restore_height,
    })
}

// ---- watching wallet side ---------------------------------------------------------

/// Asks the cold wallet for key images of every output that lacks one.
#[must_use]
pub fn sync_request(keys: &WalletKeys, network: Network, state: &SyncState) -> Envelope {
    let mut body = Vec::new();
    write_output_refs(&state.outputs_without_key_images(), &mut body);
    Envelope::for_wallet(Kind::SyncRequest, keys, network, body)
}

/// Asks the cold wallet to sign `unsigned`, and for any missing key images.
#[must_use]
pub fn sign_request(
    keys: &WalletKeys,
    network: Network,
    state: &SyncState,
    unsigned: &Unsigned,
) -> Envelope {
    let mut body = Vec::new();
    write_output_refs(&state.outputs_without_key_images(), &mut body);
    write_blob(&unsigned.signable, &mut body);
    Envelope::for_wallet(Kind::SignRequest, keys, network, body)
}

/// What a cold wallet answered.
#[derive(Clone, Debug)]
pub struct Answer {
    pub key_images: Vec<KeyImagePair>,
    /// For a [`Kind::Signed`] answer.
    pub signed: Option<Signed>,
}

/// A transaction the cold wallet signed.
#[derive(Clone, Debug)]
pub struct Signed {
    pub transaction: Transaction,
    pub hash: [u8; 32],
    pub tx_key: Option<Zeroizing<String>>,
}

impl Signed {
    /// Key images of the outputs it spends.
    #[must_use]
    pub fn spends(&self) -> Vec<[u8; 32]> {
        self.transaction
            .prefix()
            .inputs
            .iter()
            .filter_map(|input| match input {
                Input::ToKey { key_image, .. } => Some(key_image.to_bytes()),
                Input::Gen(_) => None,
            })
            .collect()
    }

    #[must_use]
    pub fn raw(&self) -> Vec<u8> {
        self.transaction.serialize()
    }
}

/// Reads a cold wallet's answer to a sync or sign request.
///
/// # Errors
///
/// See [`ColdError`].
pub fn read_answer(
    keys: &WalletKeys,
    network: Network,
    envelope: &Envelope,
) -> Result<Answer, ColdError> {
    let kind = envelope.kind;
    if kind != Kind::SyncAnswer && kind != Kind::Signed {
        return Err(ColdError::WrongKind);
    }
    envelope.expect(kind, keys, network)?;
    let mut r = Cursor::new(&envelope.body);
    let key_images = read_key_images(&mut r)?;
    let signed = if kind == Kind::Signed {
        let raw = read_blob(&mut r, 1 << 20)?;
        let transaction = Transaction::read(&mut raw.as_slice()).map_err(|_| ColdError::Damaged)?;
        let tx_key = read_blob(&mut r, 4096)?;
        let tx_key = if tx_key.is_empty() {
            None
        } else {
            Some(Zeroizing::new(
                String::from_utf8(tx_key).map_err(|_| ColdError::Damaged)?,
            ))
        };
        Some(Signed {
            hash: transaction.hash(),
            transaction,
            tx_key,
        })
    } else {
        None
    };
    Ok(Answer { key_images, signed })
}

/// Checks a signed transaction spends only this wallet's unspent outputs,
/// as the watching wallet knows them after learning the answer's key images.
///
/// # Errors
///
/// [`ColdError::NotOurs`] otherwise.
pub fn check_signed(state: &SyncState, signed: &Signed) -> Result<(), ColdError> {
    let ours: Vec<[u8; 32]> = state
        .outputs
        .iter()
        .filter(|o| o.spent.is_none())
        .filter_map(|o| o.key_image)
        .collect();
    let spends = signed.spends();
    if spends.is_empty() || spends.iter().any(|ki| !ours.contains(ki)) {
        return Err(ColdError::NotOurs);
    }
    Ok(())
}

// ---- cold wallet side ---------------------------------------------------------------

/// Answers a sync request. Returns the answer and how many outputs were
/// refused because they are not this wallet's.
///
/// # Errors
///
/// See [`ColdError`].
pub fn answer_sync(
    keys: &WalletKeys,
    network: Network,
    envelope: &Envelope,
) -> Result<(Envelope, usize), ColdError> {
    if keys.is_view_only() {
        return Err(ColdError::ViewOnly);
    }
    envelope.expect(Kind::SyncRequest, keys, network)?;
    let refs = read_output_refs(&mut Cursor::new(&envelope.body))?;
    let (answered, refused) = derive_key_images(keys, &refs);
    let mut body = Vec::new();
    write_key_images(&answered, &mut body);
    Ok((
        Envelope::for_wallet(Kind::SyncAnswer, keys, network, body),
        refused,
    ))
}

/// Reads the payments of a serialized `SignableTransaction`, positioned
/// after its inputs. Returns them and whether change comes back to this
/// wallet; change anywhere else is refused.
fn read_payments(
    p: &mut Cursor<&Vec<u8>>,
    keys: &WalletKeys,
    network: Network,
) -> Result<(Vec<(MoneroAddress, u64)>, bool), ColdError> {
    let own_spend = keys.view_pair().spend().compress().to_bytes();
    let own_view = Zeroizing::new(
        hex::decode(keys.secret_view_key_hex().as_str()).map_err(|_| ColdError::Damaged)?,
    );
    let monero_network = MoneroNetwork::from(network);
    let mut payments = Vec::new();
    let mut change_seen = false;
    for _ in 0..read_varint(p)? {
        match read_byte(p).map_err(|_| ColdError::Damaged)? {
            0 => {
                let text = String::from_utf8(read_blob(p, 256)?).map_err(|_| ColdError::Damaged)?;
                let address = MoneroAddress::from_str(monero_network, &text)
                    .map_err(|_| ColdError::BadAddress)?;
                let amount = read_u64(p).map_err(|_| ColdError::Damaged)?;
                payments.push((address, amount));
            }
            2 => {
                let spend = read_32(p)?;
                let view = Zeroizing::new(read_32(p)?);
                let account = read_u32(p).map_err(|_| ColdError::Damaged)?;
                let index = read_u32(p).map_err(|_| ColdError::Damaged)?;
                if spend != own_spend
                    || view.as_slice() != own_view.as_slice()
                    || (account, index) != (0, 0)
                {
                    return Err(ColdError::ChangeElsewhere);
                }
                change_seen = true;
            }
            // Change to a bare address could hide a payment as "change".
            _ => return Err(ColdError::ChangeElsewhere),
        }
    }
    Ok((payments, change_seen))
}

/// A sign request the cold wallet checked and can sign.
pub struct Review {
    signable: SignableTransaction,
    outgoing_view_key: Zeroizing<[u8; 32]>,
    input_keys: Vec<(Point, Point)>,
    payments: Vec<(MoneroAddress, u64)>,
    /// Key images for the inputs and for any outputs the request asked about.
    key_images: Vec<KeyImagePair>,
    /// Recipients and amounts, read from the transaction itself.
    pub destinations: Vec<(String, u64)>,
    pub fee: u64,
    /// Coming back to this wallet.
    pub change: u64,
    pub inputs_total: u64,
    pub input_count: usize,
}

impl std::fmt::Debug for Review {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Review")
            .field("destinations", &self.destinations)
            .field("fee", &self.fee)
            .field("change", &self.change)
            .finish_non_exhaustive()
    }
}

/// Reads and checks a sign request without signing it.
///
/// # Errors
///
/// See [`ColdError`]: anything that is not this wallet's own, sane
/// transaction is refused here, before the owner is asked to confirm.
///
/// # Panics
///
/// Never: a fee rate always writes 16 bytes.
pub fn review(
    keys: &WalletKeys,
    network: Network,
    envelope: &Envelope,
) -> Result<Review, ColdError> {
    if keys.is_view_only() {
        return Err(ColdError::ViewOnly);
    }
    envelope.expect(Kind::SignRequest, keys, network)?;
    let mut r = Cursor::new(&envelope.body);
    let refs = read_output_refs(&mut r)?;
    let raw = read_blob(&mut r, 1 << 20)?;
    let signable =
        SignableTransaction::read(&mut raw.as_slice()).map_err(|_| ColdError::Damaged)?;

    // monero-oxide has no accessors for what a SignableTransaction pays, so
    // read its serialization (checked just now by `read`) directly.
    let mut p = Cursor::new(&raw);
    read_byte(&mut p).map_err(|_| ColdError::Damaged)?;
    let outgoing_view_key = Zeroizing::new(read_32(&mut p)?);
    let input_count = read_varint(&mut p)?;
    let mut inputs = Vec::with_capacity(input_count);
    for _ in 0..input_count {
        inputs.push(OutputWithDecoys::read(&mut p).map_err(|_| ColdError::Damaged)?);
    }
    let (payments, change_seen) = read_payments(&mut p, keys, network)?;

    // Every input must be this wallet's to spend.
    let mut key_images = Vec::with_capacity(inputs.len() + refs.len());
    let mut inputs_total = 0u64;
    for input in &inputs {
        let image = keys
            .owned_key_image(input.key(), input.key_offset())
            .map_err(|_| ColdError::NotOurs)?;
        key_images.push((input.key().compress().to_bytes(), image));
        inputs_total = inputs_total
            .checked_add(input.commitment().amount)
            .ok_or(ColdError::Inconsistent)?;
    }
    let (extra, _) = derive_key_images(keys, &refs);
    for pair in extra {
        if !key_images.contains(&pair) {
            key_images.push(pair);
        }
    }

    let mut rate = Vec::with_capacity(16);
    signable
        .fee_rate()
        .write(&mut rate)
        .expect("writing to a Vec cannot fail");
    let per_weight = u64::from_le_bytes(rate[..8].try_into().expect("8 bytes"));
    let mask = u64::from_le_bytes(rate[8..16].try_into().expect("8 bytes"));
    if per_weight > MAX_FEE_PER_WEIGHT || mask > MAX_FEE_MASK {
        return Err(ColdError::FeeTooHigh);
    }
    let fee = signable.necessary_fee();
    let paid = payments
        .iter()
        .try_fold(0u64, |sum, (_, amount)| sum.checked_add(*amount))
        .ok_or(ColdError::Inconsistent)?;
    let change = inputs_total
        .checked_sub(paid)
        .and_then(|rest| rest.checked_sub(fee))
        .ok_or(ColdError::Inconsistent)?;
    if change > 0 && !change_seen {
        return Err(ColdError::Inconsistent);
    }

    Ok(Review {
        input_keys: inputs
            .iter()
            .map(|o| (o.key(), o.commitment().commit()))
            .collect(),
        destinations: payments
            .iter()
            .map(|(address, amount)| (address.to_string(), *amount))
            .collect(),
        payments,
        signable,
        outgoing_view_key,
        key_images,
        fee,
        change,
        inputs_total,
        input_count: inputs.len(),
    })
}

/// Signs a reviewed request and builds the answer for the watching wallet.
///
/// # Errors
///
/// [`ColdError::Signing`] if signing fails.
pub fn sign(
    keys: &WalletKeys,
    network: Network,
    review: Review,
) -> Result<(Envelope, Signed), ColdError> {
    let candidates: Vec<Zeroizing<Scalar>> =
        TransactionKeys::new(&review.outgoing_view_key, review.input_keys.clone())
            .take(review.payments.len() + 2)
            .collect();
    let transaction = keys
        .sign(review.signable)
        .map_err(|e| ColdError::Signing(e.to_string()))?;
    let tx_key = confirmed_tx_key(&transaction, &review.payments, &candidates);
    let mut body = Vec::new();
    write_key_images(&review.key_images, &mut body);
    write_blob(&transaction.serialize(), &mut body);
    write_blob(tx_key.as_ref().map_or(&[][..], |k| k.as_bytes()), &mut body);
    let signed = Signed {
        hash: transaction.hash(),
        transaction,
        tx_key,
    };
    Ok((
        Envelope::for_wallet(Kind::Signed, keys, network, body),
        signed,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base32_round_trips() {
        for len in 0..40u32 {
            let bytes: Vec<u8> = (0..len)
                .map(|i: u32| u8::try_from((i * 37 + 11) % 256).unwrap())
                .collect();
            assert_eq!(base32_decode(&base32_encode(&bytes)).unwrap(), bytes);
        }
    }

    #[test]
    fn frames_reassemble_in_any_order_and_with_repeats() {
        let message: Vec<u8> = (0..3000u32)
            .map(|i| u8::try_from(i % 251).unwrap())
            .collect();
        let frames = frames(&message, 200);
        assert!(frames.len() > 10);
        assert!(
            frames.iter().all(|f| f
                .chars()
                .all(|c| { c.is_ascii_uppercase() || c.is_ascii_digit() || c == ':' || c == '/' }))
        );
        let mut assembler = Assembler::new();
        for f in frames.iter().rev().chain(frames.iter()) {
            assembler.add(f).unwrap();
        }
        assert_eq!(assembler.progress().received, frames.len());
        assert_eq!(assembler.message().unwrap(), message);

        // A frame of another message starts over.
        let other = super::frames(b"something else", 200);
        assembler.add(&other[0]).unwrap();
        assert_eq!(assembler.message().unwrap(), b"something else");
        assert!(matches!(
            assembler.add("hello"),
            Err(ColdError::NotColdData)
        ));
    }

    #[test]
    fn a_damaged_frame_is_caught() {
        let frames = frames(b"pay Ana 1 XMR, not 9", 16);
        let mut assembler = Assembler::new();
        for f in &frames {
            let f = if f.ends_with('A') {
                format!("{}B", &f[..f.len() - 1])
            } else {
                format!("{}A", &f[..f.len() - 1])
            };
            assembler.add(&f).unwrap();
        }
        assert_eq!(assembler.message(), Err(ColdError::Damaged));
    }

    #[test]
    fn envelopes_are_bound_to_wallet_and_network() {
        let (keys, _) = WalletKeys::generate(kn_keys::SeedFormat::Classic);
        let (other, _) = WalletKeys::generate(kn_keys::SeedFormat::Classic);
        let state = SyncState::default();
        let request = sync_request(&keys, Network::Stagenet, &state);
        let back = Envelope::from_bytes(&request.to_bytes()).unwrap();
        assert_eq!(back, request);
        assert!(answer_sync(&keys, Network::Stagenet, &back).is_ok());
        assert_eq!(
            answer_sync(&other, Network::Stagenet, &back).unwrap_err(),
            ColdError::WrongWallet
        );
        assert_eq!(
            answer_sync(&keys, Network::Mainnet, &back).unwrap_err(),
            ColdError::WrongNetwork
        );
        assert_eq!(
            review(&keys, Network::Stagenet, &back).unwrap_err(),
            ColdError::WrongKind
        );
        assert_eq!(
            Envelope::from_bytes(b"not a wallet message").unwrap_err(),
            ColdError::NotColdData
        );
    }

    #[test]
    fn pairing_carries_what_a_watching_wallet_needs() {
        let (keys, _) = WalletKeys::generate(kn_keys::SeedFormat::Classic);
        let envelope = pairing(&keys, Network::Testnet, 1_234);
        let back = read_pairing(&Envelope::from_bytes(&envelope.to_bytes()).unwrap()).unwrap();
        assert_eq!(back.address, keys.primary_address(Network::Testnet));
        assert_eq!(
            back.view_key_hex.as_str(),
            keys.secret_view_key_hex().as_str()
        );
        assert_eq!(back.restore_height, 1_234);
        let watching =
            WalletKeys::view_only(Network::Testnet, &back.address, &back.view_key_hex).unwrap();
        assert_eq!(watching.primary_address(Network::Testnet), back.address);
    }
}
