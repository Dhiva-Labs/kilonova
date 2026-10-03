//! A full-mode wallet and an LWS-mode wallet pay each other on a regtest
//! chain, each seeing the other's payment.
//!
//! Needs the regtest profile of `tools/devnet` (monerod and monero-lws):
//!
//! ```sh
//! cd tools/devnet && docker compose --profile regtest up -d
//! cd core && cargo test -p kn-tx --test regtest_full_lws -- --ignored --test-threads 1
//! ```

use std::sync::atomic::AtomicBool;
use std::time::Duration;

use kn_keys::{Network, SeedFormat, WalletKeys};
use kn_sync::{Direction, LwsServer, NodeUrl, SyncState, connect, lws_sync, sync};
use kn_tx::{Backend, Priority, Request, prepare, publish};
use monero_wallet::address::{MoneroAddress, Network as MoneroNetwork};
use serde_json::{Value, json};

const NODE: &str = "http://127.0.0.1:18181";
const LWS: &str = "http://127.0.0.1:18443";
const XMR: u64 = 1_000_000_000_000;

async fn daemon() -> monero_daemon_rpc::MoneroDaemon<kn_sync::Http> {
    connect(
        &NodeUrl::parse(NODE).unwrap(),
        Network::Mainnet,
        &kn_sync::Circuit::app(kn_sync::Purpose::Sync),
    )
    .await
    .unwrap()
    .0
}

async fn mine(address: &str, blocks: usize) {
    let address = MoneroAddress::from_str(MoneroNetwork::Mainnet, address).unwrap();
    daemon()
        .await
        .generate_blocks(&address, blocks)
        .await
        .unwrap();
}

async fn tip() -> u64 {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let reply: Value = serde_json::from_slice(
        &reqwest::Client::new()
            .post(format!("{NODE}/json_rpc"))
            .body(json!({"jsonrpc": "2.0", "id": "0", "method": "get_info"}).to_string())
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap(),
    )
    .unwrap();
    reply["result"]["height"].as_u64().unwrap()
}

fn server() -> LwsServer {
    LwsServer::new(
        &NodeUrl::parse(LWS).unwrap(),
        &kn_sync::Circuit::app(kn_sync::Purpose::Sync),
    )
    .unwrap()
}

async fn full_sync(keys: &WalletKeys, state: &mut SyncState) {
    sync(
        &daemon().await,
        keys,
        &[1],
        state,
        &AtomicBool::new(false),
        |_, _| {},
    )
    .await
    .unwrap();
}

async fn lws_sync_to_tip(keys: &WalletKeys, state: &mut SyncState) {
    let tip = tip().await;
    for _ in 0..120 {
        let report = lws_sync(&server(), keys, Network::Mainnet, &[1], 0, true, state)
            .await
            .unwrap();
        if report.scanned >= tip {
            return;
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    panic!("monero-lws did not catch up to {tip}");
}

fn burn() -> String {
    WalletKeys::generate(SeedFormat::Classic)
        .0
        .primary_address(Network::Mainnet)
}

fn received(state: &SyncState, tx: [u8; 32]) -> u64 {
    state
        .history()
        .into_iter()
        .find(|h| h.tx == tx && h.direction == Direction::Incoming)
        .map_or(0, |h| h.amount)
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs the regtest devnet; see the file header"]
async fn full_and_lws_wallets_pay_each_other() {
    let (full, _) = WalletKeys::generate(SeedFormat::Classic);
    let (light, _) = WalletKeys::generate(SeedFormat::Polyseed);
    let mut full_state = SyncState::starting_at(tip().await);
    let mut light_state = SyncState::default();
    // Register with the server before anything arrives.
    lws_sync_to_tip(&light, &mut light_state).await;

    mine(&full.primary_address(Network::Mainnet), 70).await;
    full_sync(&full, &mut full_state).await;

    // Full mode pays a subaddress of the LWS wallet.
    let to_light = light.address(Network::Mainnet, 0, 1).unwrap();
    let d = daemon().await;
    let height = tip().await;
    let sent = prepare(
        Backend::Node(&d),
        &full,
        Network::Mainnet,
        &full_state,
        height,
        &Request::Pay(vec![(to_light, 7 * XMR)]),
        Priority::Normal,
    )
    .await
    .unwrap();
    publish(Backend::Node(&d), &sent, &mut full_state, height)
        .await
        .unwrap();
    // Ten blocks unlock the payment for spending.
    mine(&burn(), 10).await;
    lws_sync_to_tip(&light, &mut light_state).await;
    assert_eq!(received(&light_state, sent.hash), 7 * XMR);
    // A node confirms the server's report of that payment.
    let check = kn_sync::cross_check(&daemon().await, &mut light_state)
        .await
        .unwrap();
    assert!(check.confirmed >= 1);
    assert_eq!(check.contradicted, 0);
    assert_eq!(light_state.cross_check_verdict(&sent.hash), Some(true));
    assert_eq!(received(&light_state, sent.hash), 7 * XMR);
    assert_eq!(light_state.balance(tip().await).unlocked, 7 * XMR);

    // The LWS wallet pays back through the server.
    let lws = server();
    let height = tip().await;
    let back = prepare(
        Backend::Lws(&lws),
        &light,
        Network::Mainnet,
        &light_state,
        height,
        &Request::Pay(vec![(full.primary_address(Network::Mainnet), 2 * XMR)]),
        Priority::Normal,
    )
    .await
    .unwrap();
    publish(Backend::Lws(&lws), &back, &mut light_state, height)
        .await
        .unwrap();
    mine(&burn(), 1).await;
    full_sync(&full, &mut full_state).await;
    lws_sync_to_tip(&light, &mut light_state).await;
    assert_eq!(received(&full_state, back.hash), 2 * XMR);
    assert_eq!(
        light_state.balance(tip().await).total,
        7 * XMR - 2 * XMR - back.fee
    );
}
