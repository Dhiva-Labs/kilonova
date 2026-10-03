//! The entry point Android's background worker calls, without a Flutter
//! engine, to check one wallet for payments while the app is closed.
//!
//! The worker decrypts the wallet's watch state (see
//! [`kn_sync::WatchState`]) with its Keystore key, calls
//! [`background_scan`] through JNI, saves the new state it gets back and
//! shows a notification for each payment. Byte arrays only, so the view
//! key never becomes a Java string:
//!
//! - input: `1`, then a little-endian `u32` length and that many bytes of
//!   JSON ([`Request`]), then the watch state;
//! - output: `1`, then a little-endian `u32` length and that many bytes of
//!   JSON ([`Reply`], nothing secret in it), then the new watch state, or
//!   nothing when it did not change.

use std::path::Path;
use std::time::{Duration, Instant};

use kn_sync::{
    MAX_BLOCKS_PER_RUN, NodeUrl, ProxyUrl, SyncError, WatchLimits, WatchMode, WatchReport,
    WatchState, check_proxy, proxy, set_proxy, watch_full, watch_lws,
};
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

use crate::api::nodes::{RUNTIME, apply_saved_pins};
use crate::node_settings::{Settings, key};

/// Framing version of input and output.
const FRAME_VERSION: u8 = 1;

/// How long a run scans before it stops and leaves the rest for the next.
const SCAN_TIME: Duration = Duration::from_mins(1);

/// A run that has not finished by then is abandoned; the state stays as
/// it was.
const RUN_LIMIT: Duration = Duration::from_mins(3);

/// What the worker asks for, besides the watch state.
#[derive(Debug, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Request {
    /// The app's wallet directory. The proxy, the node and light wallet
    /// server choices and pinned certificates are read from its settings,
    /// so a check always uses what the owner set in the app.
    pub dir: Option<String>,
    /// A SOCKS5 proxy; overrides the one in the settings.
    pub proxy: Option<String>,
    /// The node (full mode) or light wallet server (LWS mode); overrides
    /// the one in the settings.
    pub server: Option<String>,
    /// Blocks to scan at most; [`MAX_BLOCKS_PER_RUN`] when absent.
    pub max_blocks: Option<u64>,
}

/// How a run went.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    /// Looked up to the chain tip.
    Done,
    /// Stopped at the run's limit; the next run goes on.
    More,
    /// Not tried: the proxy does not answer, or the light wallet server is
    /// not the one the owner agreed to. Try again next time.
    Skipped,
    /// The node or server failed. Try again next time.
    Failed,
    /// The watch state cannot be read (damaged, or from another version):
    /// delete it; the owner chooses the wallet again.
    Invalid,
}

/// One payment, for the notification.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FoundPayment {
    /// Transaction id, hex.
    pub tx: String,
    /// In XMR, as the app shows it: `0.25`.
    pub amount: String,
    /// Waiting for a block.
    pub pending: bool,
}

/// What the worker gets back.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Reply {
    pub status: Status,
    /// Why it was skipped or failed, for logs; never anything secret.
    pub reason: Option<String>,
    pub payments: Vec<FoundPayment>,
}

impl Reply {
    fn without_payments(status: Status, reason: &str) -> Self {
        Self {
            status,
            reason: Some(reason.to_owned()),
            payments: Vec::new(),
        }
    }
}

/// Checks one wallet for new payments. See the module documentation for
/// the byte layout. Never panics on bad input: it answers
/// [`Status::Invalid`].
#[must_use]
pub fn background_scan(input: &[u8]) -> Vec<u8> {
    let Some((request, state)) = split(input) else {
        return frame(
            &Reply::without_payments(Status::Invalid, "malformed input"),
            &[],
        );
    };
    let Ok(request) = serde_json::from_slice::<Request>(request) else {
        return frame(
            &Reply::without_payments(Status::Invalid, "malformed request"),
            &[],
        );
    };
    let mut state = match WatchState::from_bytes(state) {
        Ok(state) => state,
        Err(e) => {
            return frame(
                &Reply::without_payments(Status::Invalid, &e.to_string()),
                &[],
            );
        }
    };
    let run = RUNTIME
        .block_on(async { tokio::time::timeout(RUN_LIMIT, check(&request, &mut state)).await });
    match run {
        Ok(Ok(report)) => {
            let reply = Reply {
                status: if report.caught_up {
                    Status::Done
                } else {
                    Status::More
                },
                reason: None,
                payments: report
                    .arrivals
                    .iter()
                    .map(|a| FoundPayment {
                        tx: hex::encode(a.tx),
                        amount: xmr(a.amount),
                        pending: a.pending,
                    })
                    .collect(),
            };
            frame(&reply, &state.to_bytes())
        }
        Ok(Err(Skip(reason))) => frame(&Reply::without_payments(Status::Skipped, reason), &[]),
        Ok(Err(Fail(reason))) => frame(&Reply::without_payments(Status::Failed, &reason), &[]),
        Err(_) => frame(
            &Reply::without_payments(Status::Failed, "took too long"),
            &[],
        ),
    }
}

/// Why a run did not check.
enum Outcome {
    Skip(&'static str),
    Fail(String),
}
use Outcome::{Fail, Skip};

async fn check(request: &Request, state: &mut WatchState) -> Result<WatchReport, Outcome> {
    let settings = request.dir.as_deref().map(read_settings);
    let proxy_setting = request
        .proxy
        .clone()
        .or_else(|| settings.as_ref().and_then(|s| s.proxy.clone()));
    let wanted = proxy_setting
        .as_deref()
        .map(ProxyUrl::parse)
        .transpose()
        .map_err(|_| Skip("the proxy setting is not valid"))?;
    // With a proxy set, nothing goes out without it: one that does not
    // answer (Orbot stopped, say) means trying again next time.
    if let Some(wanted) = &wanted
        && check_proxy(wanted).await.is_err()
    {
        return Err(Skip("the proxy does not answer"));
    }
    // The app may be running in this process with the same settings; leave
    // its proxy alone unless it differs.
    if proxy() != wanted {
        set_proxy(wanted.clone());
    }
    if let Some(settings) = &settings {
        apply_saved_pins(settings);
    }

    let per_network = settings
        .as_ref()
        .and_then(|s| s.networks.get(key(state.network.into())));
    let result = match state.mode {
        WatchMode::Full => {
            let node = request
                .server
                .clone()
                .or_else(|| per_network.and_then(|n| n.selected.clone()))
                .unwrap_or_else(|| state.server.clone());
            let node = NodeUrl::parse(&node).map_err(|_| Skip("the node setting is not valid"))?;
            let limits = WatchLimits {
                max_blocks: request.max_blocks.unwrap_or(MAX_BLOCKS_PER_RUN),
                deadline: Instant::now() + SCAN_TIME,
            };
            watch_full(state, &node, limits).await
        }
        WatchMode::Lws => {
            // The view key goes only to the server the owner agreed to share
            // it with for this wallet.
            let current = match (&request.server, &settings) {
                (Some(server), _) => Some(server.clone()),
                (None, Some(_)) => per_network.and_then(|n| n.lws.clone()),
                (None, None) => Some(state.server.clone()),
            };
            if current.as_deref() != Some(state.server.as_str()) {
                return Err(Skip("the light wallet server changed"));
            }
            let server = NodeUrl::parse(&state.server)
                .map_err(|_| Skip("the light wallet server setting is not valid"))?;
            watch_lws(state, &server).await
        }
    };
    result.map_err(|e| match e {
        SyncError::NeedsProxy => Skip("an onion address needs the proxy"),
        e => Fail(e.to_string()),
    })
}

/// The app's settings in `dir`, or the defaults if there are none.
fn read_settings(dir: &str) -> Settings {
    std::fs::read(Path::new(dir).join("nodes.json"))
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

fn split(input: &[u8]) -> Option<(&[u8], &[u8])> {
    let (&version, rest) = input.split_first()?;
    if version != FRAME_VERSION {
        return None;
    }
    let len = u32::from_le_bytes(rest.get(..4)?.try_into().ok()?);
    let len = usize::try_from(len).ok()?;
    let rest = &rest[4..];
    Some((rest.get(..len)?, rest.get(len..)?))
}

fn frame(reply: &Reply, state: &[u8]) -> Vec<u8> {
    let json = serde_json::to_vec(reply).expect("a reply always serializes");
    let len = u32::try_from(json.len()).expect("a reply is small");
    let mut out = Vec::with_capacity(5 + json.len() + state.len());
    out.push(FRAME_VERSION);
    out.extend_from_slice(&len.to_le_bytes());
    out.extend_from_slice(&json);
    out.extend_from_slice(state);
    out
}

/// Builds an input for [`background_scan`].
///
/// # Panics
///
/// Never: a request always serializes and is small.
#[must_use]
pub fn scan_input(request: &Request, state: &[u8]) -> Zeroizing<Vec<u8>> {
    let json = serde_json::to_vec(request).expect("a request always serializes");
    let len = u32::try_from(json.len()).expect("a request is small");
    let mut out = Zeroizing::new(Vec::with_capacity(5 + json.len() + state.len()));
    out.push(FRAME_VERSION);
    out.extend_from_slice(&len.to_le_bytes());
    out.extend_from_slice(&json);
    out.extend_from_slice(state);
    out
}

/// Reads what [`background_scan`] returned: the reply and the new state
/// (empty if unchanged).
#[must_use]
pub fn scan_output(output: &[u8]) -> Option<(Reply, &[u8])> {
    let (reply, state) = split(output)?;
    Some((serde_json::from_slice(reply).ok()?, state))
}

/// Atomic units as XMR, like the app's `formatXmr`: trailing zeros
/// dropped, at least one decimal.
fn xmr(atomic: u64) -> String {
    let whole = atomic / 1_000_000_000_000;
    let fraction = format!("{:012}", atomic % 1_000_000_000_000);
    let fraction = fraction.trim_end_matches('0');
    format!(
        "{whole}.{}",
        if fraction.is_empty() { "0" } else { fraction }
    )
}

/// `BackgroundScan.scan(input: ByteArray): ByteArray` in the Android app.
#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_dhivalabs_kilonova_BackgroundScan_scan<'local>(
    mut env: jni::EnvUnowned<'local>,
    _class: jni::objects::JClass<'local>,
    input: jni::objects::JByteArray<'local>,
) -> jni::objects::JByteArray<'local> {
    env.with_env(|env| -> jni::errors::Result<_> {
        let input = Zeroizing::new(env.convert_byte_array(&input)?);
        let output = Zeroizing::new(background_scan(&input));
        env.byte_array_from_slice(&output)
    })
    .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_amounts_like_the_app() {
        assert_eq!(xmr(250_000_000_000), "0.25");
        assert_eq!(xmr(1_000_000_000_000), "1.0");
        assert_eq!(xmr(1), "0.000000000001");
        assert_eq!(xmr(12_345_600_000_000), "12.3456");
    }

    #[test]
    fn bad_input_is_invalid_not_a_crash() {
        for input in [&b""[..], &[2, 0, 0, 0, 0][..], &[1, 9, 0, 0, 0, b'{'][..]] {
            let output = background_scan(input);
            let (reply, state) = scan_output(&output).unwrap();
            assert_eq!(reply.status, Status::Invalid);
            assert!(state.is_empty());
        }
        let output = background_scan(&scan_input(&Request::default(), b"{\"version\": 9}"));
        let (reply, _) = scan_output(&output).unwrap();
        assert_eq!(reply.status, Status::Invalid);
        assert!(reply.reason.unwrap().contains("format 9"));
    }

    #[test]
    fn an_unreachable_proxy_skips_quietly() {
        let (keys, _) = kn_keys::WalletKeys::generate(kn_keys::SeedFormat::Classic);
        let state = WatchState::new(
            "proxied",
            kn_keys::Network::Mainnet,
            WatchMode::Full,
            &keys,
            &[1],
            &kn_sync::SyncState::starting_at(10),
            "http://127.0.0.1:1",
        );
        let request = Request {
            proxy: Some("127.0.0.1:1".into()),
            ..Request::default()
        };
        let output = background_scan(&scan_input(&request, &state.to_bytes()));
        let (reply, new_state) = scan_output(&output).unwrap();
        assert_eq!(reply.status, Status::Skipped);
        assert!(new_state.is_empty(), "the state is kept as it was");
        assert_eq!(proxy(), None, "an unreachable proxy is not set");
    }

    #[test]
    fn a_changed_light_wallet_server_gets_no_view_key() {
        let (keys, _) = kn_keys::WalletKeys::generate(kn_keys::SeedFormat::Classic);
        let state = WatchState::new(
            "lws",
            kn_keys::Network::Mainnet,
            WatchMode::Lws,
            &keys,
            &[1],
            &kn_sync::SyncState::default(),
            "https://agreed.example",
        );
        let request = Request {
            server: Some("https://other.example".into()),
            ..Request::default()
        };
        let output = background_scan(&scan_input(&request, &state.to_bytes()));
        let (reply, _) = scan_output(&output).unwrap();
        assert_eq!(reply.status, Status::Skipped);
    }
}
