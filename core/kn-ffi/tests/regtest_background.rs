//! Background checks end to end on the regtest chain: export a wallet's
//! watch state as the app does, pay the wallet from Monero's reference
//! wallet, and run the worker's entry point. Each payment is reported
//! once, then never again.
//!
//! Needs the regtest profile of `tools/devnet` running (monerod,
//! wallet-rpc and monero-lws):
//!
//! ```sh
//! cd tools/devnet && docker compose --profile regtest up -d
//! cd core && cargo test -p kn_ffi --test regtest_background -- --ignored --test-threads 1
//! ```

use std::time::{Duration, Instant};

use kn_ffi::api::background::export_watch_state;
use kn_ffi::api::network::Network;
use kn_ffi::api::nodes::{add_node, set_lws_server};
use kn_ffi::api::wallets::{
    SeedFormat, SyncMode, create_wallet_from_seed, generate_seed, init_wallet_store,
};
use kn_ffi::background::{Reply, Request, Status, background_scan, scan_input, scan_output};
use serde_json::{Value, json};

const NODE: &str = "http://127.0.0.1:18181";
const LWS: &str = "http://127.0.0.1:18443";
const WALLET_RPC: &str = "http://127.0.0.1:18183/json_rpc";
const XMR: u64 = 1_000_000_000_000;

fn post(url: &str, body: &Value) -> Value {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let reply: Value = runtime.block_on(async {
        let bytes = reqwest::Client::new()
            .post(url)
            .body(body.to_string())
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap();
        serde_json::from_slice(&bytes).unwrap()
    });
    assert!(reply.get("error").is_none(), "{url}: {reply}");
    reply["result"].clone()
}

fn rpc(url: &str, method: &str, params: &Value) -> Value {
    post(
        url,
        &json!({"jsonrpc": "2.0", "id": "0", "method": method, "params": params}),
    )
}

fn mine(address: &str, blocks: u64) {
    rpc(
        &format!("{NODE}/json_rpc"),
        "generateblocks",
        &json!({"amount_of_blocks": blocks, "wallet_address": address}),
    );
}

fn chain_height() -> u64 {
    rpc(&format!("{NODE}/json_rpc"), "get_info", &json!({}))["height"]
        .as_u64()
        .unwrap()
}

/// A wallet in monero-wallet-rpc with unlocked mined funds.
fn funded_payer(name: &str) {
    rpc(
        WALLET_RPC,
        "create_wallet",
        &json!({"filename": name, "password": "", "language": "English"}),
    );
    let address = rpc(WALLET_RPC, "get_address", &json!({"account_index": 0}))["address"]
        .as_str()
        .unwrap()
        .to_owned();
    mine(&address, 80);
    rpc(WALLET_RPC, "refresh", &json!({}));
}

fn pay(address: &str, amount: u64) -> String {
    rpc(
        WALLET_RPC,
        "transfer",
        &json!({"destinations": [{"amount": amount, "address": address}]}),
    )["tx_hash"]
        .as_str()
        .unwrap()
        .to_owned()
}

fn store_dir() -> String {
    static DIR: std::sync::OnceLock<tempfile::TempDir> = std::sync::OnceLock::new();
    let dir = DIR.get_or_init(|| tempfile::tempdir().unwrap());
    let path = dir.path().to_string_lossy().into_owned();
    init_wallet_store(path.clone()).unwrap();
    path
}

/// One run of the worker; returns the reply and keeps the new state.
fn run(state: &mut Vec<u8>, dir: &str) -> Reply {
    let request = Request {
        dir: Some(dir.to_owned()),
        ..Request::default()
    };
    let output = background_scan(&scan_input(&request, state));
    let (reply, new_state) = scan_output(&output).expect("a framed reply");
    if !new_state.is_empty() {
        *state = new_state.to_vec();
    }
    reply
}

/// The address of subaddress (0, `index`) of the wallet with `words`.
fn subaddress(words: &str, index: u32) -> String {
    let (keys, _) = kn_keys::WalletKeys::from_mnemonic(words).unwrap();
    keys.address(kn_keys::Network::Mainnet, 0, index).unwrap()
}

#[test]
#[ignore = "needs the regtest devnet; see the file header"]
fn full_mode_reports_each_payment_once() {
    let dir = store_dir();
    add_node(Network::Mainnet, NODE.into()).unwrap();
    let seed = generate_seed(SeedFormat::Classic);
    let words = seed.words.join(" ");
    let wallet = create_wallet_from_seed(
        "Watched".into(),
        Network::Mainnet,
        SyncMode::Full,
        words.clone(),
        "pw".into(),
        Some(chain_height()),
        true,
    )
    .unwrap();
    let id = wallet.summary().unwrap().id;
    wallet.lock();
    let mut state = export_watch_state(id, "pw".into()).unwrap();

    funded_payer(&format!("bg-full-{}", &words[..8]));
    let reply = run(&mut state, &dir);
    assert_eq!(reply.status, Status::Done, "{reply:?}");
    assert!(reply.payments.is_empty(), "mined blocks went elsewhere");

    // Waiting in the pool: reported once, as pending.
    let tx = pay(&subaddress(&words, 2), XMR / 4);
    let reply = run(&mut state, &dir);
    assert_eq!(reply.status, Status::Done, "{reply:?}");
    assert_eq!(reply.payments.len(), 1, "{reply:?}");
    assert_eq!(reply.payments[0].tx, tx);
    assert_eq!(reply.payments[0].amount, "0.25");
    assert!(reply.payments[0].pending);
    assert!(run(&mut state, &dir).payments.is_empty(), "not again");

    // Mined: not announced a second time.
    mine(
        &subaddress(&generate_seed(SeedFormat::Classic).words.join(" "), 0),
        1,
    );
    let reply = run(&mut state, &dir);
    assert_eq!(reply.status, Status::Done);
    assert!(reply.payments.is_empty(), "{reply:?}");

    // Paid and mined between two runs: reported as confirmed.
    let tx = pay(&subaddress(&words, 0), XMR);
    mine(
        &subaddress(&generate_seed(SeedFormat::Classic).words.join(" "), 0),
        1,
    );
    let reply = run(&mut state, &dir);
    assert_eq!(reply.payments.len(), 1, "{reply:?}");
    assert_eq!(reply.payments[0].tx, tx);
    assert_eq!(reply.payments[0].amount, "1.0");
    assert!(!reply.payments[0].pending);
    assert!(run(&mut state, &dir).payments.is_empty());

    // A run is bounded (here to 10 blocks, so it stops after the first
    // batch of 50); the next one carries on from where it stopped.
    mine(
        &subaddress(&generate_seed(SeedFormat::Classic).words.join(" "), 0),
        120,
    );
    let request = Request {
        dir: Some(dir.clone()),
        max_blocks: Some(10),
        ..Request::default()
    };
    let output = background_scan(&scan_input(&request, &state));
    let (reply, new_state) = scan_output(&output).unwrap();
    assert_eq!(reply.status, Status::More, "{reply:?}");
    state = new_state.to_vec();
    assert_eq!(run(&mut state, &dir).status, Status::Done);
}

#[test]
#[ignore = "needs the regtest devnet; see the file header"]
fn lws_mode_reports_each_payment_once() {
    let dir = store_dir();
    add_node(Network::Mainnet, NODE.into()).unwrap();
    set_lws_server(Network::Mainnet, LWS.into()).unwrap();
    let seed = generate_seed(SeedFormat::Classic);
    let words = seed.words.join(" ");
    let wallet = create_wallet_from_seed(
        "Watched by a server".into(),
        Network::Mainnet,
        SyncMode::Lws,
        words.clone(),
        "pw".into(),
        Some(chain_height()),
        true,
    )
    .unwrap();
    wallet.grant_lws_consent(LWS.into()).unwrap();
    let id = wallet.summary().unwrap().id;
    wallet.lock();
    let mut state = export_watch_state(id, "pw".into()).unwrap();

    funded_payer(&format!("bg-lws-{}", &words[..8]));
    let reply = run(&mut state, &dir);
    assert!(
        matches!(reply.status, Status::Done | Status::More),
        "{reply:?}"
    );

    let tx = pay(&subaddress(&words, 1), XMR / 2);
    mine(
        &subaddress(&generate_seed(SeedFormat::Classic).words.join(" "), 0),
        1,
    );
    let end = Instant::now() + Duration::from_mins(2);
    let reply = loop {
        let reply = run(&mut state, &dir);
        if !reply.payments.is_empty() {
            break reply;
        }
        assert!(
            Instant::now() < end,
            "monero-lws never reported the payment"
        );
        std::thread::sleep(Duration::from_millis(500));
    };
    assert_eq!(reply.payments.len(), 1, "{reply:?}");
    assert_eq!(reply.payments[0].tx, tx);
    assert_eq!(reply.payments[0].amount, "0.5");
    for _ in 0..3 {
        assert!(run(&mut state, &dir).payments.is_empty(), "not again");
    }

    // Another server set in the app: the view key is not sent to it.
    set_lws_server(Network::Mainnet, "https://other.example".into()).unwrap();
    assert_eq!(run(&mut state, &dir).status, Status::Skipped);
    set_lws_server(Network::Mainnet, LWS.into()).unwrap();
}
