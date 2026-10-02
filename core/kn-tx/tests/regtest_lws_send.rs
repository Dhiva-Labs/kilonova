//! Sending in LWS mode on a regtest chain: decoys, fees and broadcasting all
//! go through monero-lws, and Monero's reference wallet must receive.
//!
//! Needs the regtest profile of `tools/devnet` (monerod, wallet-rpc and
//! monero-lws):
//!
//! ```sh
//! cd tools/devnet && docker compose --profile regtest up -d
//! cd core && cargo test -p kn-tx --test regtest_lws_send -- --ignored --test-threads 1
//! ```

use std::time::Duration;

use kn_keys::{Network, SeedFormat, WalletKeys};
use kn_sync::{Direction, LwsServer, NodeUrl, SyncState, connect, lws_sync};
use kn_tx::{Backend, Priority, Request, prepare, publish};
use monero_wallet::address::{MoneroAddress, Network as MoneroNetwork};
use serde_json::{Value, json};

const NODE: &str = "http://127.0.0.1:18181";
const LWS: &str = "http://127.0.0.1:18443";
const WALLET_RPC: &str = "http://127.0.0.1:18183/json_rpc";
const XMR: u64 = 1_000_000_000_000;

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

async fn tip() -> u64 {
    post(
        &format!("{NODE}/json_rpc"),
        json!({"jsonrpc": "2.0", "id": "0", "method": "get_info"}),
    )
    .await["result"]["height"]
        .as_u64()
        .unwrap()
}

fn server() -> LwsServer {
    LwsServer::new(&NodeUrl::parse(LWS).unwrap()).unwrap()
}

async fn lws_until_caught_up(keys: &WalletKeys, state: &mut SyncState) {
    let tip = tip().await;
    for _ in 0..120 {
        let report = lws_sync(&server(), keys, Network::Mainnet, &[1], 0, true, state)
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

fn burn_address() -> String {
    WalletKeys::generate(SeedFormat::Classic)
        .0
        .primary_address(Network::Mainnet)
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs the regtest devnet; see the file header"]
async fn lws_mode_pays_monero_wallet_rpc() {
    let (keys, _) = WalletKeys::generate(SeedFormat::Classic);
    let mut state = SyncState::default();
    lws_until_caught_up(&keys, &mut state).await;
    mine(&keys.primary_address(Network::Mainnet), 80).await;
    lws_until_caught_up(&keys, &mut state).await;
    let height = tip().await;
    let before = state.balance(height);
    assert!(before.unlocked >= 10 * XMR, "need unlocked mined funds");

    wallet_rpc(
        "create_wallet",
        json!({"filename": format!("lws-recv-{}", &keys.primary_address(Network::Mainnet)[..12]),
               "password": "", "language": "English"}),
    )
    .await;
    let to = wallet_rpc("get_address", json!({"account_index": 0})).await["address"]
        .as_str()
        .unwrap()
        .to_owned();

    let lws = server();
    let prepared = prepare(
        Backend::Lws(&lws),
        &keys,
        Network::Mainnet,
        &state,
        height,
        &Request::Pay(vec![(to, 4 * XMR)]),
        Priority::Normal,
    )
    .await
    .unwrap();
    assert!(prepared.fee > 0);
    publish(Backend::Lws(&lws), &prepared, &mut state, height)
        .await
        .unwrap();
    assert!(
        state
            .history()
            .iter()
            .any(|h| h.direction == Direction::Outgoing && h.pending),
        "pending at once"
    );

    mine(&burn_address(), 1).await;
    lws_until_caught_up(&keys, &mut state).await;
    let outgoing = state
        .history()
        .into_iter()
        .find(|h| h.direction == Direction::Outgoing)
        .unwrap();
    assert!(!outgoing.pending, "confirmed once mined");
    assert_eq!(outgoing.tx, prepared.hash);
    assert_eq!(
        state.balance(tip().await).total,
        before.total - 4 * XMR - prepared.fee
    );

    wallet_rpc("refresh", json!({})).await;
    let received = wallet_rpc("get_balance", json!({})).await["balance"]
        .as_u64()
        .unwrap();
    assert_eq!(received, 4 * XMR);
}
