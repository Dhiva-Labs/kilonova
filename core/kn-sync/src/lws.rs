//! LWS mode: a light wallet server (monero-lws or a MyMonero-compatible
//! service) scans the chain with the wallet's view key, and the wallet
//! checks what it is told.
//!
//! The server can always hide payments or invent incoming ones; it holds
//! the view key, and the wallet has no chain data to compare against. What
//! it cannot do is fake a spend: marking an output spent needs that output's
//! key image, which only the spend key produces. So:
//!
//! - every output the server reports must open with this wallet's keys
//!   ([`WalletKeys::verify_claimed_output`]) or it is dropped;
//! - an output counts as spent only if one of the server's candidate key
//!   images equals the key image computed here.

use std::collections::HashMap;
use std::sync::Arc;

use kn_keys::{ClaimedOutput, Network, WalletKeys};
use monero_wallet::WalletOutput;
use monero_wallet::ed25519::{Commitment, Scalar};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use zeroize::Zeroizing;

use crate::SyncError;
use crate::node::{NodeUrl, http_client, read_limited};

/// Largest answer accepted from a light wallet server. A busy wallet's
/// history is a few megabytes; this leaves ample room.
const MAX_RESPONSE: usize = 64 << 20;
use crate::scan::SUBADDRESS_LOOKAHEAD;
use crate::state::{OwnedOutput, Spend, SyncState};

/// A light wallet server's REST endpoint.
#[derive(Clone)]
pub struct LwsServer {
    client: reqwest::Client,
    base: Arc<str>,
}

/// What a sync against a light wallet server found.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LwsReport {
    /// Blocks the server has scanned for this wallet (a count, like
    /// [`crate::Progress::scanned`]).
    pub scanned: u64,
    /// Blocks the server's node has.
    pub tip: u64,
    /// Outputs the server reported that did not open with this wallet's
    /// keys and were ignored. Anything but zero means the server is buggy or
    /// dishonest.
    pub rejected_outputs: u32,
    /// The server accepted an import from an earlier height but has not
    /// finished it (or needs approval).
    pub import_pending: bool,
}

impl LwsServer {
    /// # Errors
    ///
    /// [`SyncError::InsecureLws`] for a plain-http address that is neither an
    /// onion service nor this device: the view key would cross the network
    /// unencrypted.
    pub fn new(url: &NodeUrl) -> Result<Self, SyncError> {
        if !url.is_private_channel() {
            return Err(SyncError::InsecureLws);
        }
        Ok(Self {
            client: http_client(url)?,
            base: url.as_str().into(),
        })
    }

    async fn post<T: DeserializeOwned>(&self, route: &str, body: &Value) -> Result<T, SyncError> {
        let response = self
            .client
            .post(format!("{}/{route}", self.base))
            .header("Content-Type", "application/json")
            .body(body.to_string())
            .send()
            .await
            .map_err(|e| SyncError::Node(format!("request failed: {e}")))?;
        match response.status().as_u16() {
            200 => {}
            403 => return Err(SyncError::LwsDenied),
            501 => return Err(SyncError::LwsCreationRefused),
            status => return Err(SyncError::Node(format!("server answered HTTP {status}"))),
        }
        let bytes = read_limited(response, MAX_RESPONSE).await?;
        serde_json::from_slice(&bytes)
            .map_err(|e| SyncError::Node(format!("unexpected response to {route}: {e}")))
    }
}

/// What a light wallet server says about itself.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LwsInfo {
    /// Blocks the server has processed.
    pub height: u64,
    /// Implementation name, for example `monero-lws`.
    pub server_type: Option<String>,
}

/// Checks a light wallet server is reachable and, if it says which network
/// it serves, that it is `network`.
///
/// # Errors
///
/// [`SyncError::WrongNetwork`] for a server on another network, otherwise
/// [`SyncError::Node`].
pub async fn check_lws(url: &NodeUrl, network: Network) -> Result<LwsInfo, SyncError> {
    #[derive(Deserialize)]
    struct Version {
        #[serde(default)]
        server_type: Option<String>,
        #[serde(default)]
        blockchain_height: u64,
        #[serde(default)]
        network_type: Option<String>,
    }
    let server = LwsServer::new(url)?;
    let version: Version = server.post("get_version", &json!({})).await?;
    let reported = match version.network_type.as_deref() {
        Some("main" | "mainnet" | "fakechain") => Some(Network::Mainnet),
        Some("stage" | "stagenet") => Some(Network::Stagenet),
        Some("test" | "testnet") => Some(Network::Testnet),
        _ => None,
    };
    if reported.is_some_and(|reported| reported != network) {
        return Err(SyncError::WrongNetwork);
    }
    Ok(LwsInfo {
        height: version.blockchain_height,
        server_type: version.server_type,
    })
}

/// A ring member the server offers as a decoy.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RandomOutput {
    pub global_index: u64,
    pub public_key: [u8; 32],
    pub commitment: [u8; 32],
}

/// Fee rates the server's node suggests, lowest priority first, in atomic
/// units per byte of transaction weight, with the quantization mask.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LwsFees {
    pub per_priority: Vec<u64>,
    pub mask: u64,
}

impl LwsServer {
    /// `count` random ring members for each of `inputs` inputs, chosen by the
    /// server from the chain. Malformed entries are skipped.
    ///
    /// # Errors
    ///
    /// [`SyncError::Node`] if the server cannot answer.
    pub async fn random_outputs(
        &self,
        inputs: usize,
        count: u8,
    ) -> Result<Vec<Vec<RandomOutput>>, SyncError> {
        let amounts = vec!["0"; inputs];
        let response: RandomOuts = self
            .post(
                "get_random_outs",
                &json!({"amounts": amounts, "count": count}),
            )
            .await?;
        Ok(parse_random_outs(response))
    }

    /// The fee rates the server's node suggests.
    ///
    /// # Errors
    ///
    /// [`SyncError::Node`] if the server cannot answer or gives no rates.
    pub async fn fees(&self, keys: &WalletKeys, network: Network) -> Result<LwsFees, SyncError> {
        #[derive(Deserialize)]
        struct Response {
            #[serde(default)]
            fees: Vec<u64>,
            #[serde(deserialize_with = "u64_from_string_or_number")]
            per_byte_fee: u64,
            #[serde(deserialize_with = "u64_from_string_or_number")]
            fee_mask: u64,
        }
        let response: Response = self
            .post(
                "get_unspent_outs",
                &json!({
                    "address": keys.primary_address(network),
                    "view_key": keys.secret_view_key_hex().as_str(),
                    "amount": "0", "mixin": 0, "use_dust": false, "dust_threshold": "0",
                }),
            )
            .await?;
        let per_priority = if response.fees.is_empty() {
            vec![response.per_byte_fee]
        } else {
            response.fees
        };
        Ok(LwsFees {
            per_priority,
            mask: response.fee_mask.max(1),
        })
    }

    /// Asks the server to relay a signed transaction.
    ///
    /// # Errors
    ///
    /// [`SyncError::Node`] with the server's reason if it is refused.
    pub async fn submit(&self, raw_transaction: &[u8]) -> Result<(), SyncError> {
        #[derive(Deserialize)]
        struct Response {
            #[serde(default)]
            status: String,
        }
        let response: Response = self
            .post(
                "submit_raw_tx",
                &json!({"tx": hex::encode(raw_transaction)}),
            )
            .await?;
        if response.status.eq_ignore_ascii_case("ok") || response.status.is_empty() {
            Ok(())
        } else {
            Err(SyncError::Node(format!(
                "server refused the transaction: {}",
                response.status
            )))
        }
    }
}

#[derive(Deserialize)]
struct RandomOut {
    #[serde(deserialize_with = "u64_from_string_or_number")]
    global_index: u64,
    public_key: String,
    rct: String,
}

#[derive(Deserialize)]
struct AmountOuts {
    outputs: Vec<RandomOut>,
}

#[derive(Deserialize)]
struct RandomOuts {
    amount_outs: Vec<AmountOuts>,
}

/// Ring member candidates from a `get_random_outs` answer; malformed entries
/// are skipped.
fn parse_random_outs(response: RandomOuts) -> Vec<Vec<RandomOutput>> {
    response
        .amount_outs
        .into_iter()
        .map(|set| {
            set.outputs
                .iter()
                .filter_map(|o| {
                    Some(RandomOutput {
                        global_index: o.global_index,
                        public_key: hex32(&o.public_key)?,
                        commitment: hex32(o.rct.get(..64)?)?,
                    })
                })
                .collect()
        })
        .collect()
}

#[derive(Deserialize)]
struct Login {
    #[serde(default)]
    start_height: Option<u64>,
}

#[derive(Deserialize)]
struct Import {
    #[serde(default)]
    request_fulfilled: bool,
}

// Field names mirror the server's JSON.
#[allow(clippy::struct_field_names)]
#[derive(Deserialize)]
struct AddressInfo {
    scanned_block_height: u64,
    blockchain_height: u64,
    #[serde(default)]
    start_height: u64,
}

#[derive(Deserialize)]
struct Recipient {
    maj_i: u32,
    min_i: u32,
}

#[derive(Deserialize)]
struct LwsOutput {
    #[serde(deserialize_with = "u64_from_string")]
    amount: u64,
    public_key: String,
    index: u64,
    #[serde(deserialize_with = "u64_from_string_or_number")]
    global_index: u64,
    tx_hash: String,
    tx_pub_key: String,
    height: u64,
    rct: Option<String>,
    recipient: Option<Recipient>,
}

#[derive(Deserialize)]
struct Unspent {
    #[serde(default)]
    outputs: Vec<LwsOutput>,
}

#[derive(Deserialize)]
struct SpentCandidate {
    key_image: String,
}

#[derive(Deserialize)]
struct LwsTx {
    hash: String,
    #[serde(default)]
    height: Option<u64>,
    #[serde(default)]
    coinbase: bool,
    #[serde(default)]
    mempool: bool,
    #[serde(default)]
    spent_outputs: Vec<SpentCandidate>,
}

#[derive(Deserialize)]
struct Txs {
    #[serde(default)]
    transactions: Vec<LwsTx>,
}

/// Brings `state` up to date from a light wallet server.
///
/// The server keeps the scan, so every call replaces the wallet's outputs
/// with the server's current answer after checking it. `accounts[i]` is how
/// many subaddresses account `i` has handed out; the server is asked to
/// watch those plus [`SUBADDRESS_LOOKAHEAD`]. `restore_height` asks the
/// server to scan from that height for wallets restored from an older
/// seed; `generated_locally` tells it a new wallet has no earlier history.
///
/// # Errors
///
/// [`SyncError::LwsDenied`] or [`SyncError::LwsCreationRefused`] when the
/// server will not serve this wallet, otherwise [`SyncError::Node`].
pub async fn lws_sync(
    server: &LwsServer,
    keys: &WalletKeys,
    network: Network,
    accounts: &[u32],
    restore_height: u64,
    generated_locally: bool,
    state: &mut SyncState,
) -> Result<LwsReport, SyncError> {
    let address = keys.primary_address(network);
    let view_key = keys.secret_view_key_hex();
    // Every request carries the address and view key; that is how the LWS
    // protocol authenticates.
    let login = |extra: Value| {
        let mut body = json!({"address": address, "view_key": view_key.as_str()});
        if let (Value::Object(body), Value::Object(extra)) = (&mut body, extra) {
            body.extend(extra);
        }
        body
    };

    let account: Login = server
        .post(
            "login",
            &login(json!({"create_account": true, "generated_locally": generated_locally})),
        )
        .await?;

    let mut import_pending = false;
    let info: AddressInfo = server.post("get_address_info", &login(json!({}))).await?;
    let start = account.start_height.unwrap_or(info.start_height);
    if !generated_locally && restore_height < start {
        let import: Import = server
            .post(
                "import_wallet_request",
                &login(json!({"from_height": restore_height})),
            )
            .await?;
        import_pending = !import.request_fulfilled;
    }

    let ranges: Vec<Value> = accounts
        .iter()
        .enumerate()
        .map(|(i, handed_out)| {
            // Index 0 of account 0 is the primary address, not a subaddress.
            let first = u32::from(i == 0);
            let last = handed_out
                .saturating_add(SUBADDRESS_LOOKAHEAD)
                .max(first + 1)
                - 1;
            json!({"key": i, "value": [[first, last]]})
        })
        .collect();
    // Servers without subaddress support refuse this; primary-address
    // payments still sync, so carry on.
    let _: Result<Value, _> = server
        .post(
            "upsert_subaddrs",
            &login(json!({"subaddrs": ranges, "get_all": false})),
        )
        .await;

    let unspent: Unspent = server
        .post(
            "get_unspent_outs",
            &login(json!({"amount": "0", "mixin": 0, "use_dust": true, "dust_threshold": "0"})),
        )
        .await?;
    let txs: Txs = server.post("get_address_txs", &login(json!({}))).await?;

    Ok(apply_replies(
        keys,
        &info,
        &unspent,
        &txs,
        import_pending,
        state,
    ))
}

/// Turns the server's answers into wallet state, keeping only what the
/// wallet's own keys confirm.
fn apply_replies(
    keys: &WalletKeys,
    info: &AddressInfo,
    unspent: &Unspent,
    txs: &Txs,
    import_pending: bool,
    state: &mut SyncState,
) -> LwsReport {
    let coinbase: HashMap<&str, bool> = txs
        .transactions
        .iter()
        .map(|t| (t.hash.as_str(), t.coinbase))
        .collect();

    let mut outputs: Vec<OwnedOutput> = Vec::new();
    let mut by_key: HashMap<[u8; 32], usize> = HashMap::new();
    let mut rejected_outputs = 0u32;
    for out in &unspent.outputs {
        let Some(owned) = owned_output(keys, out, coinbase.get(out.tx_hash.as_str()).copied())
        else {
            rejected_outputs = rejected_outputs.saturating_add(1);
            continue;
        };
        // One spendable output per one-time key (see the burning bug note in
        // scan.rs): a duplicate keeps the larger and counts as rejected.
        let key = owned.output.key().compress().to_bytes();
        if let Some(&i) = by_key.get(&key) {
            rejected_outputs = rejected_outputs.saturating_add(1);
            if owned.amount() > outputs[i].amount() {
                outputs[i] = owned;
            }
        } else {
            by_key.insert(key, outputs.len());
            outputs.push(owned);
        }
    }

    mark_spends(&mut outputs, &txs.transactions, state);

    // The server reports the index of the last block; full mode and the
    // rest of the app count blocks.
    let scanned = info.scanned_block_height.saturating_add(1);
    let tip = info.blockchain_height.saturating_add(1);
    state.outputs = outputs;
    state.expire_pending(tip);
    state.next_height = scanned;
    state.recent.clear();
    LwsReport {
        scanned,
        tip,
        rejected_outputs,
        import_pending,
    }
}

/// Marks outputs spent where a confirmed transaction's candidate key image
/// matches the one derived locally, and keeps this wallet's own pending
/// spends that the server has not seen in a block yet.
fn mark_spends(outputs: &mut [OwnedOutput], transactions: &[LwsTx], state: &SyncState) {
    let by_key_image: HashMap<[u8; 32], usize> = outputs
        .iter()
        .enumerate()
        .filter_map(|(i, o): (usize, &OwnedOutput)| o.key_image.map(|ki| (ki, i)))
        .collect();
    for tx in transactions.iter().filter(|t| !t.mempool) {
        let (Some(height), Some(hash)) = (tx.height, hex32(&tx.hash)) else {
            continue;
        };
        for candidate in &tx.spent_outputs {
            if let Some(&i) = hex32(&candidate.key_image).and_then(|ki| by_key_image.get(&ki)) {
                outputs[i].spent = Some(Spend {
                    tx: hash,
                    height,
                    pending: false,
                });
            }
        }
    }

    // Spends sent from this wallet that the server has not seen in a block
    // yet stay pending, as in full mode.
    for (key_image, spend) in state.pending_spends() {
        if let Some(&i) = by_key_image.get(&key_image)
            && outputs[i].spent.is_none()
        {
            outputs[i].spent = Some(spend);
        }
    }
}

/// Verifies one reported output and turns it into a wallet output, or
/// `None` if it does not belong to this wallet or is malformed.
fn owned_output(keys: &WalletKeys, out: &LwsOutput, coinbase: Option<bool>) -> Option<OwnedOutput> {
    let tx_hash = hex32(&out.tx_hash)?;
    let output_key = hex32(&out.public_key)?;
    let subaddress = out
        .recipient
        .as_ref()
        .map_or((0, 0), |r| (r.maj_i, r.min_i));
    let verified = keys
        .verify_claimed_output(&ClaimedOutput {
            tx_pub_key: hex32(&out.tx_pub_key)?,
            index_in_tx: out.index,
            output_key,
            subaddress,
        })
        .ok()?;

    // Packed RingCT: commitment | mask | amount. Miner outputs have no
    // commitment on chain (the network uses the identity mask). For the
    // rest the mask is derived locally; older outputs carry it encrypted, in
    // which case the server's value is tried. Either way the mask must open
    // the reported commitment to the reported amount, or the output could
    // not be spent.
    let rct = out.rct.as_deref().map(hex::decode).transpose().ok()?;
    let miner = coinbase.unwrap_or(false)
        || rct
            .as_ref()
            .is_some_and(|r| r.len() >= 32 && r[..32].iter().all(|b| *b == 0));
    let mask = if miner {
        let mut one = [0u8; 32];
        one[0] = 1;
        one
    } else {
        let derived = scalar_bytes(&verified.compact_mask);
        match rct.as_ref().filter(|r| r.len() >= 64) {
            Some(r) => {
                let commitment: [u8; 32] = r[..32].try_into().ok()?;
                let server_mask: [u8; 32] = r[32..64].try_into().ok()?;
                [derived, server_mask]
                    .into_iter()
                    .find(|mask| opens(mask, out.amount, &commitment))?
            }
            None => derived,
        }
    };

    let output = wallet_output(
        tx_hash,
        out.index,
        out.global_index,
        output_key,
        &verified.key_offset,
        mask,
        out.amount,
        subaddress,
    )?;
    Some(OwnedOutput {
        output,
        height: out.height,
        miner,
        key_image: verified.key_image,
        spent: None,
    })
}

/// Builds monero-oxide's `WalletOutput` from verified parts, through its
/// serialization (monero-wallet 0.2 layout).
#[allow(clippy::too_many_arguments)]
fn wallet_output(
    tx: [u8; 32],
    index_in_tx: u64,
    index_on_blockchain: u64,
    key: [u8; 32],
    key_offset: &Scalar,
    mask: [u8; 32],
    amount: u64,
    subaddress: (u32, u32),
) -> Option<WalletOutput> {
    let mut bytes = Zeroizing::new(Vec::with_capacity(32 + 8 + 8 + 32 + 32 + 32 + 8 + 12));
    bytes.extend_from_slice(&tx);
    bytes.extend_from_slice(&index_in_tx.to_le_bytes());
    bytes.extend_from_slice(&index_on_blockchain.to_le_bytes());
    bytes.extend_from_slice(&key);
    bytes.extend_from_slice(&scalar_bytes(key_offset));
    bytes.extend_from_slice(&mask);
    bytes.extend_from_slice(&amount.to_le_bytes());
    bytes.push(0); // no additional timelock
    if subaddress == (0, 0) {
        bytes.push(0);
    } else {
        bytes.push(1);
        bytes.extend_from_slice(&subaddress.0.to_le_bytes());
        bytes.extend_from_slice(&subaddress.1.to_le_bytes());
    }
    bytes.push(0); // no payment id
    bytes.push(0); // no arbitrary data
    WalletOutput::read(&mut bytes.as_slice()).ok()
}

/// Whether `mask` and `amount` open `commitment`.
fn opens(mask: &[u8; 32], amount: u64, commitment: &[u8; 32]) -> bool {
    Scalar::read(&mut mask.as_slice()).is_ok_and(|mask| {
        Commitment::new(mask, amount).commit().compress().to_bytes() == *commitment
    })
}

fn scalar_bytes(scalar: &Scalar) -> [u8; 32] {
    let mut out = Vec::with_capacity(32);
    scalar
        .write(&mut out)
        .expect("writing to a Vec cannot fail");
    out.try_into().expect("a scalar is 32 bytes")
}

fn hex32(s: &str) -> Option<[u8; 32]> {
    hex::decode(s).ok()?.try_into().ok()
}

fn u64_from_string<'de, D: serde::Deserializer<'de>>(d: D) -> Result<u64, D::Error> {
    let s = String::deserialize(d)?;
    s.parse().map_err(serde::de::Error::custom)
}

fn u64_from_string_or_number<'de, D: serde::Deserializer<'de>>(d: D) -> Result<u64, D::Error> {
    match Value::deserialize(d)? {
        Value::Number(n) => n
            .as_u64()
            .ok_or_else(|| serde::de::Error::custom("negative index")),
        Value::String(s) => s.parse().map_err(serde::de::Error::custom),
        _ => Err(serde::de::Error::custom("expected a number")),
    }
}

/// Entry points for the fuzz targets in `core/fuzz`; not part of the API.
#[cfg(feature = "fuzzing")]
#[doc(hidden)]
pub mod fuzzing {
    use super::{AddressInfo, RandomOuts, Txs, Unspent, apply_replies, parse_random_outs};
    use crate::SyncState;
    use kn_keys::{SeedFormat, WalletKeys};
    use std::sync::LazyLock;

    static KEYS: LazyLock<WalletKeys> =
        LazyLock::new(|| WalletKeys::generate(SeedFormat::Classic).0);

    /// Feeds arbitrary server answers through the code that checks them.
    pub fn lws_replies(data: &[u8]) {
        if let Ok((info, unspent, txs)) =
            serde_json::from_slice::<(AddressInfo, Unspent, Txs)>(data)
        {
            let mut state = SyncState::default();
            let _ = apply_replies(&KEYS, &info, &unspent, &txs, false, &mut state);
            let _ = state.balance(u64::MAX);
            let _ = state.history();
        }
        if let Ok(outs) = serde_json::from_slice::<RandomOuts>(data) {
            let _ = parse_random_outs(outs);
        }
    }

    /// Reads a decrypted sync cache.
    pub fn cache(data: &[u8]) {
        if let Ok(state) = SyncState::from_bytes(data) {
            let _ = state.balance(u64::MAX);
            let _ = state.history();
        }
    }
}
