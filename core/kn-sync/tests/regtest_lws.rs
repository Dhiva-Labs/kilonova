//! LWS mode end to end on the regtest chain: monero-lws scans, Kilonova
//! checks, and the result must match both full-mode scanning and Monero's
//! reference wallet.
//!
//! Needs the regtest profile of `tools/devnet` running (monerod, wallet-rpc
//! and monero-lws):
//!
//! ```sh
//! cd tools/devnet && docker compose --profile regtest up -d
//! cd core && cargo test -p kn-sync --test regtest_lws -- --ignored --test-threads 1
//! ```

use std::collections::BTreeSet;
use std::sync::atomic::AtomicBool;
use std::time::Duration;

use kn_keys::{Network, SeedFormat, WalletKeys};
use kn_sync::{Direction, LwsServer, NodeUrl, SyncState, check_lws, connect, lws_sync, sync};
use monero_wallet::address::{MoneroAddress, Network as MoneroNetwork};
use serde_json::{Value, json};

const NODE: &str = "http://127.0.0.1:18181";
const LWS: &str = "http://127.0.0.1:18443";
const WALLET_RPC: &str = "http://127.0.0.1:18183/json_rpc";

async fn post(url: &str, body: Value) -> Value {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let reply: Value = serde_json::from_slice(
        &reqwest::Client::new()
            .post(url)
            .body(body.to_string())
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap(),
    )
    .unwrap();
    assert!(reply.get("error").is_none(), "{url}: {reply}");
    reply
}

async fn wallet_rpc(method: &str, params: Value) -> Value {
    post(
        WALLET_RPC,
        json!({"jsonrpc": "2.0", "id": "0", "method": method, "params": params}),
    )
    .await["result"]
        .clone()
}

async fn mine(address: &str, blocks: usize) {
    let (daemon, _) = connect(&NodeUrl::parse(NODE).unwrap(), Network::Mainnet)
        .await
        .unwrap();
    let address = MoneroAddress::from_str(MoneroNetwork::Mainnet, address).unwrap();
    daemon.generate_blocks(&address, blocks).await.unwrap();
}

async fn chain_height() -> u64 {
    post(
        &format!("{NODE}/json_rpc"),
        json!({"jsonrpc": "2.0", "id": "0", "method": "get_info"}),
    )
    .await["result"]["height"]
        .as_u64()
        .unwrap()
}

/// Syncs from the LWS until it has scanned to the chain tip.
async fn lws_until_caught_up(keys: &WalletKeys, state: &mut SyncState, accounts: &[u32]) {
    let server = LwsServer::new(&NodeUrl::parse(LWS).unwrap()).unwrap();
    let tip = chain_height().await;
    for _ in 0..120 {
        let report = lws_sync(&server, keys, Network::Mainnet, accounts, 0, true, state)
            .await
            .unwrap();
        assert_eq!(report.rejected_outputs, 0);
        if report.scanned >= tip {
            return;
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    panic!("monero-lws did not catch up to {tip}");
}

fn key_images(state: &SyncState) -> BTreeSet<[u8; 32]> {
    state.outputs.iter().filter_map(|o| o.key_image).collect()
}

fn other_address() -> String {
    WalletKeys::generate(SeedFormat::Classic)
        .0
        .primary_address(Network::Mainnet)
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs the regtest devnet; see the file header"]
async fn lws_mode_matches_full_mode_and_monero_wallet_rpc() {
    let lws = NodeUrl::parse(LWS).unwrap();
    assert!(check_lws(&lws, Network::Mainnet).await.is_ok());
    assert!(matches!(
        check_lws(&lws, Network::Stagenet).await,
        Err(kn_sync::SyncError::WrongNetwork)
    ));

    let (keys, mnemonic) = WalletKeys::generate(SeedFormat::Classic);
    let address = keys.primary_address(Network::Mainnet);
    let start = chain_height().await;

    // Register with the server before any funds arrive.
    let mut lws_state = SyncState::default();
    lws_until_caught_up(&keys, &mut lws_state, &[2]).await;
    assert!(lws_state.outputs.is_empty());

    mine(&address, 70).await;
    lws_until_caught_up(&keys, &mut lws_state, &[2]).await;

    // Full mode over the same blocks.
    let mut full_state = SyncState::starting_at(start);
    let (daemon, _) = connect(&NodeUrl::parse(NODE).unwrap(), Network::Mainnet)
        .await
        .unwrap();
    sync(
        &daemon,
        &keys,
        &[2],
        &mut full_state,
        &AtomicBool::new(false),
        |_, _| {},
    )
    .await
    .unwrap();

    assert_eq!(lws_state.outputs.len(), 70);
    assert_eq!(key_images(&lws_state), key_images(&full_state));
    let tip = chain_height().await;
    assert_eq!(lws_state.balance(tip), full_state.balance(tip));
    assert!(lws_state.outputs.iter().all(|o| o.miner));

    // The reference wallet spends from this seed: part to someone else,
    // part to our subaddress 0/1.
    wallet_rpc(
        "restore_deterministic_wallet",
        json!({"filename": format!("lws-{}", &address[..16]), "password": "",
               "seed": mnemonic.words.as_str(), "restore_height": start,
               "language": "English"}),
    )
    .await;
    wallet_rpc("refresh", json!({})).await;
    let sub = keys.address(Network::Mainnet, 0, 1).unwrap();
    let to_sub: u64 = 2_000_000_000_000;
    let to_other: u64 = 1_000_000_000_000;
    let transfer = wallet_rpc(
        "transfer",
        json!({"destinations": [
            {"amount": to_other, "address": other_address()},
            {"amount": to_sub, "address": sub},
        ]}),
    )
    .await;
    let fee = transfer["fee"].as_u64().unwrap();
    let tx = transfer["tx_hash"].as_str().unwrap().to_owned();
    mine(&other_address(), 1).await;
    lws_until_caught_up(&keys, &mut lws_state, &[2]).await;

    // The spend is found through our own key images.
    let history = lws_state.history();
    let outgoing = history
        .iter()
        .find(|h| h.direction == Direction::Outgoing)
        .expect("the spend shows up as outgoing");
    assert_eq!(hex::encode(outgoing.tx), tx);
    // What left the wallet: the payment to someone else plus the fee. The
    // subaddress payment and the change came back.
    assert_eq!(outgoing.amount, to_other + fee);

    // The subaddress payment was verified against subaddress 0/1.
    assert!(lws_state.outputs.iter().any(|o| {
        o.output.subaddress().map(|s| (s.account(), s.address())) == Some((0, 1))
            && o.amount() == to_sub
    }));

    wallet_rpc("refresh", json!({})).await;
    let reference = wallet_rpc("get_balance", json!({})).await;
    assert_eq!(
        lws_state.balance(chain_height().await).total,
        reference["balance"].as_u64().unwrap(),
        "LWS-mode balance differs from monero-wallet-rpc"
    );
}
