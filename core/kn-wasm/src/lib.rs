//! WebAssembly bindings for the Kilonova browser extension.
//!
//! The extension's JavaScript holds a [`Wallet`] while it is unlocked. Keys
//! stay in this module's memory and leave it only sealed: the wallet blob
//! and the sync cache, in the formats the desktop app writes (kn-store).
//! Sync is kn-sync's full mode, unchanged, over the browser's `fetch`.

#![forbid(unsafe_code)]
// wasm-bindgen exports take owned values and return plain values to
// JavaScript; these pedantic lints fight that calling convention.
#![allow(clippy::needless_pass_by_value, clippy::must_use_candidate)]

mod transport;

use std::{
    cell::{Cell, RefCell},
    rc::Rc,
    sync::atomic::{AtomicBool, Ordering},
};

use kn_keys::{Network, SeedFormat, WalletKeys};
use kn_store::{KdfParams, SealedWallet, WalletData, WalletSecret};
use kn_sync::{
    NodeUrl, Progress, SyncCache, SyncState, approximate_height, bundled_nodes, node_status,
    sync_with,
};
use monero_daemon_rpc::MoneroDaemon;
use serde::Serialize;
use wasm_bindgen::prelude::*;
use wasm_bindgen_futures::future_to_promise;

use transport::Fetch;

/// The sync cache goes back to JavaScript every this many batches (and at
/// the end), so a closed popup loses little progress without sealing the
/// whole state after every batch.
const CACHE_EVERY_BATCHES: u32 = 10;

/// Extra blocks scanned before a new wallet's first sync point, on top of
/// twice the blocks expected since it was created.
const FRESH_MARGIN_BLOCKS: u64 = 20;

#[wasm_bindgen(start)]
fn start() {
    console_error_panic_hook::set_once();
}

fn error(e: impl std::fmt::Display) -> JsError {
    JsError::new(&e.to_string())
}

fn js_error(e: impl std::fmt::Display) -> JsValue {
    error(e).into()
}

fn parse_network(name: &str) -> Result<Network, JsError> {
    match name {
        "mainnet" => Ok(Network::Mainnet),
        "stagenet" => Ok(Network::Stagenet),
        "testnet" => Ok(Network::Testnet),
        _ => Err(JsError::new("unknown network")),
    }
}

fn network_name(network: Network) -> &'static str {
    match network {
        Network::Mainnet => "mainnet",
        Network::Stagenet => "stagenet",
        Network::Testnet => "testnet",
    }
}

/// JavaScript numbers to whole seconds or heights; negative and fractional
/// parts are dropped.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
fn whole(n: f64) -> u64 {
    if n.is_finite() && n > 0.0 {
        n as u64
    } else {
        0
    }
}

/// Heights fit a JavaScript number exactly; amounts do not, so they go out
/// as decimal strings of atomic units.
#[allow(clippy::cast_precision_loss)]
fn number(n: u64) -> f64 {
    n as f64
}

fn to_js(value: &impl Serialize) -> JsValue {
    serde_wasm_bindgen::to_value(value).unwrap_or(JsValue::NULL)
}

/// A fresh seed, not yet a wallet. The user writes it down; it then goes to
/// [`Wallet::create`] with `created_now` set.
#[wasm_bindgen(js_name = newSeed)]
pub fn new_seed(polyseed: bool, now_secs: f64) -> String {
    let format = if polyseed {
        SeedFormat::Polyseed
    } else {
        SeedFormat::Classic
    };
    let (_, mnemonic) = WalletKeys::generate_at(format, whole(now_secs));
    mnemonic.words.to_string()
}

#[derive(Serialize)]
struct SeedInfo {
    polyseed: bool,
    /// Unix seconds, Polyseed only.
    birthday: Option<f64>,
}

/// Checks a seed typed for restoring and says what kind it is.
///
/// # Errors
///
/// The reason the seed is not valid, as a sentence for the user.
#[wasm_bindgen(js_name = checkSeed)]
pub fn check_seed(words: &str) -> Result<JsValue, JsError> {
    let (_, mnemonic) = WalletKeys::from_mnemonic(words).map_err(error)?;
    Ok(to_js(&SeedInfo {
        polyseed: mnemonic.format == SeedFormat::Polyseed,
        birthday: mnemonic.birthday.map(number),
    }))
}

/// A block height safely before `unix_secs` on `network`, for restoring a
/// seed without a birthday from a date.
///
/// # Errors
///
/// For an unknown network name.
#[wasm_bindgen(js_name = heightAt)]
pub fn height_at(network: &str, unix_secs: f64) -> Result<f64, JsError> {
    Ok(number(approximate_height(
        parse_network(network)?,
        whole(unix_secs),
    )))
}

/// Community nodes Kilonova ships for `network`.
///
/// # Errors
///
/// For an unknown network name.
#[wasm_bindgen(js_name = bundledNodes)]
pub fn bundled_node_list(network: &str) -> Result<Vec<String>, JsError> {
    Ok(bundled_nodes(parse_network(network)?)
        .iter()
        .map(|n| n.as_str().to_owned())
        .collect())
}

/// A node address in the form the wallet stores, or an error saying what
/// is wrong with it.
///
/// # Errors
///
/// When the address is not `host:port` or an `http(s)://host:port` URL.
#[wasm_bindgen(js_name = normalizeNode)]
pub fn normalize_node(input: &str) -> Result<String, JsError> {
    Ok(NodeUrl::parse(input).map_err(error)?.as_str().to_owned())
}

struct Inner {
    wallet: SealedWallet,
    state: SyncState,
    /// Transaction pool cache; only valid for the node it came from.
    pool: SyncCache,
    pool_node: Option<String>,
    tip: u64,
    /// Unix seconds, for a wallet created in this session and not yet
    /// synced: its first sync can start near the node's tip.
    created_at: Option<u64>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Status {
    /// Next block to scan.
    scanned: f64,
    /// Blocks the node has.
    tip: f64,
    total: String,
    unlocked: String,
    incoming: String,
}

impl Status {
    fn of(state: &SyncState, tip: u64) -> Self {
        let balance = state.balance(tip);
        Self {
            scanned: number(state.next_height),
            tip: number(tip),
            total: balance.total.to_string(),
            unlocked: balance.unlocked.to_string(),
            incoming: balance.incoming.to_string(),
        }
    }
}

/// An unlocked wallet. Dropping it (JavaScript's `free()`) wipes the keys.
#[wasm_bindgen]
pub struct Wallet {
    inner: Rc<RefCell<Inner>>,
    cancel: Rc<AtomicBool>,
}

impl Wallet {
    fn from_sealed(wallet: SealedWallet) -> Self {
        let start = wallet.data.restore_height.unwrap_or_else(|| {
            wallet
                .data
                .birthday
                .map_or(0, |b| approximate_height(wallet.data.network, b))
        });
        Self {
            inner: Rc::new(RefCell::new(Inner {
                wallet,
                state: SyncState::starting_at(start),
                pool: SyncCache::default(),
                pool_node: None,
                tip: start,
                created_at: None,
            })),
            cancel: Rc::new(AtomicBool::new(false)),
        }
    }

    fn inner(&self) -> Result<std::cell::Ref<'_, Inner>, JsError> {
        self.inner
            .try_borrow()
            .map_err(|_| JsError::new("the wallet is busy syncing"))
    }
}

#[wasm_bindgen]
impl Wallet {
    /// Creates a wallet from a seed and seals it under `password`.
    ///
    /// `created_now` marks a seed from [`new_seed`]: scanning starts at
    /// today's height. Otherwise it starts at `restore_height`, else the
    /// Polyseed birthday, else the first block.
    ///
    /// # Errors
    ///
    /// For an invalid seed or unknown network.
    pub fn create(
        words: &str,
        network: &str,
        password: &str,
        restore_height: Option<f64>,
        created_now: bool,
        now_secs: f64,
    ) -> Result<Wallet, JsError> {
        let network = parse_network(network)?;
        let (_, mnemonic) = WalletKeys::from_mnemonic(words).map_err(error)?;
        let mut data = WalletData::new(
            network,
            WalletSecret::Seed {
                words: mnemonic.words,
            },
        );
        data.birthday = mnemonic.birthday;
        data.created_here = created_now;
        data.restore_height = if created_now {
            Some(approximate_height(network, whole(now_secs)))
        } else {
            restore_height.map(whole)
        };
        let (wallet, _) =
            SealedWallet::create(data, password.as_bytes(), KdfParams::DEFAULT).map_err(error)?;
        let created = Self::from_sealed(wallet);
        if created_now {
            created.inner.borrow_mut().created_at = Some(whole(now_secs));
        }
        Ok(created)
    }

    /// Opens a wallet sealed by [`Wallet::sealed`] (or a desktop wallet
    /// file).
    ///
    /// # Errors
    ///
    /// For a wrong password or a damaged blob.
    pub fn unlock(blob: &[u8], password: &str) -> Result<Wallet, JsError> {
        let wallet = SealedWallet::unlock(blob, password.as_bytes()).map_err(error)?;
        Ok(Self::from_sealed(wallet))
    }

    /// The wallet, sealed for storage.
    ///
    /// # Errors
    ///
    /// While a sync is running.
    pub fn sealed(&self) -> Result<Vec<u8>, JsError> {
        Ok(self.inner()?.wallet.seal())
    }

    /// The scan progress, sealed with the wallet's key.
    ///
    /// # Errors
    ///
    /// While a sync is running.
    #[wasm_bindgen(js_name = sealedCache)]
    pub fn sealed_cache(&self) -> Result<Vec<u8>, JsError> {
        let inner = self.inner()?;
        Ok(inner.wallet.seal_cache(&inner.state.to_bytes()))
    }

    /// Resumes from a cache from [`Wallet::sealed_cache`]. Returns false
    /// (and keeps scanning from the start) if it cannot be read.
    ///
    /// # Errors
    ///
    /// While a sync is running.
    #[wasm_bindgen(js_name = loadCache)]
    pub fn load_cache(&self, sealed: &[u8]) -> Result<bool, JsError> {
        let mut inner = self
            .inner
            .try_borrow_mut()
            .map_err(|_| JsError::new("the wallet is busy syncing"))?;
        let Some(state) = inner
            .wallet
            .open_cache(sealed)
            .ok()
            .and_then(|bytes| SyncState::from_bytes(&bytes).ok())
        else {
            return Ok(false);
        };
        inner.tip = inner.tip.max(state.next_height);
        inner.state = state;
        Ok(true)
    }

    /// The wallet's id, which names its storage keys.
    ///
    /// # Errors
    ///
    /// While a sync is running.
    pub fn id(&self) -> Result<String, JsError> {
        Ok(self.inner()?.wallet.id().to_owned())
    }

    /// `mainnet`, `stagenet` or `testnet`.
    ///
    /// # Errors
    ///
    /// While a sync is running.
    pub fn network(&self) -> Result<String, JsError> {
        Ok(network_name(self.inner()?.wallet.data.network).to_owned())
    }

    /// The primary address.
    ///
    /// # Errors
    ///
    /// While a sync is running.
    pub fn address(&self) -> Result<String, JsError> {
        let inner = self.inner()?;
        Ok(inner.wallet.keys.primary_address(inner.wallet.data.network))
    }

    /// Balance and scan progress: `{ scanned, tip, total, unlocked,
    /// incoming }`, amounts as strings of atomic units.
    ///
    /// # Errors
    ///
    /// While a sync is running; progress events carry the same fields.
    pub fn status(&self) -> Result<JsValue, JsError> {
        let inner = self.inner()?;
        Ok(to_js(&Status::of(&inner.state, inner.tip)))
    }

    /// Stops a running sync after its current batch.
    pub fn cancel(&self) {
        self.cancel.store(true, Ordering::Relaxed);
    }

    /// Scans from where the wallet is to `node`'s tip. Resolves with the
    /// final status plus `cache` (the sealed scan progress to store).
    ///
    /// `on_progress` gets a status after every batch of blocks; every few
    /// batches it also carries `cache`.
    // The borrow is held across awaits on purpose: while it is out, every
    // other method reports "busy syncing" (try_borrow) instead of seeing a
    // half-scanned state. Nothing awaited here can re-enter the wallet.
    #[allow(clippy::await_holding_refcell_ref)]
    pub fn sync(&self, node: String, on_progress: js_sys::Function) -> js_sys::Promise {
        let inner = Rc::clone(&self.inner);
        let cancel = Rc::clone(&self.cancel);
        future_to_promise(async move {
            let mut guard = inner
                .try_borrow_mut()
                .map_err(|_| js_error("the wallet is already syncing"))?;
            cancel.store(false, Ordering::Relaxed);

            let url = NodeUrl::parse(&node).map_err(js_error)?;
            let daemon = MoneroDaemon::new(Fetch::new(&url))
                .await
                .map_err(js_error)?;
            let network = guard.wallet.data.network;
            let node = node_status(&daemon, network).await.map_err(js_error)?;

            let Inner {
                wallet,
                state,
                pool,
                pool_node,
                tip,
                created_at,
            } = &mut *guard;
            // A wallet made moments ago cannot have been paid before it
            // existed. Its restore height carries the month of margin a
            // restored seed needs; skip that and start near the tip,
            // allowing twice the blocks expected since creation.
            if let Some(created) = created_at.take()
                && state.recent.is_empty()
            {
                let elapsed = whole(js_sys::Date::now() / 1000.0).saturating_sub(created);
                let start = node
                    .height
                    .saturating_sub(elapsed / 60 + FRESH_MARGIN_BLOCKS);
                if start > state.next_height {
                    *state = SyncState::starting_at(start);
                }
            }
            if pool_node.as_deref() != Some(url.as_str()) {
                *pool = SyncCache::default();
                *pool_node = Some(url.as_str().to_owned());
            }
            let accounts = wallet.data.next_subaddress.clone();
            let seen_tip = Cell::new(*tip);
            let batches = Cell::new(0u32);
            let result = sync_with(
                &daemon,
                pool,
                &wallet.keys,
                &accounts,
                state,
                &cancel,
                |state: &SyncState, progress: Progress| {
                    seen_tip.set(progress.tip);
                    let event = to_js(&Status::of(state, progress.tip));
                    batches.set(batches.get() + 1);
                    if batches.get().is_multiple_of(CACHE_EVERY_BATCHES) {
                        let cache = js_sys::Uint8Array::from(
                            wallet.seal_cache(&state.to_bytes()).as_slice(),
                        );
                        let _ = js_sys::Reflect::set(&event, &"cache".into(), &cache);
                    }
                    let _ = on_progress.call1(&JsValue::NULL, &event);
                },
            )
            .await;
            *tip = seen_tip.get();
            result.map_err(js_error)?;

            let done = to_js(&Status::of(state, *tip));
            let cache = js_sys::Uint8Array::from(wallet.seal_cache(&state.to_bytes()).as_slice());
            let _ = js_sys::Reflect::set(&done, &"cache".into(), &cache);
            Ok(done)
        })
    }
}
