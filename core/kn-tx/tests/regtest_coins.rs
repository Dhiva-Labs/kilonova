//! Coin control and payment requests on a regtest chain: spending only
//! chosen coins, never frozen ones, counting the addresses a spend links,
//! and what each subaddress received.
//!
//! Needs the regtest profile of `tools/devnet`:
//!
//! ```sh
//! cd tools/devnet && docker compose --profile regtest up -d
//! cd core && cargo test -p kn-tx --test regtest_coins -- --ignored --test-threads 1
//! ```

use std::sync::atomic::AtomicBool;

use kn_keys::{Network, SeedFormat, WalletKeys};
use kn_sync::{NodeUrl, SyncState, connect, sync};
use kn_tx::{
    Backend, Priority, Request, Selection, TxError, linked_addresses, prepare_selected, publish,
    spendable,
};
use monero_wallet::address::{MoneroAddress, Network as MoneroNetwork};
use serde_json::{Value, json};

const NODE: &str = "http://127.0.0.1:18181";
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

async fn sync_to_tip(keys: &WalletKeys, state: &mut SyncState) {
    sync(
        &daemon().await,
        keys,
        &[5],
        state,
        &AtomicBool::new(false),
        |_, _| {},
    )
    .await
    .unwrap();
}

fn key_of(o: &kn_sync::OwnedOutput) -> [u8; 32] {
    o.output.key().compress().to_bytes()
}

fn burn() -> String {
    WalletKeys::generate(SeedFormat::Classic)
        .0
        .primary_address(Network::Mainnet)
}

#[allow(clippy::too_many_lines)]
#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs the regtest devnet; see the file header"]
async fn coins_can_be_chosen_frozen_and_counted() {
    let (keys, _) = WalletKeys::generate(SeedFormat::Classic);
    let start = tip().await;
    mine(&keys.primary_address(Network::Mainnet), 70).await;
    let mut state = SyncState::starting_at(start);
    sync_to_tip(&keys, &mut state).await;
    let d = daemon().await;

    // Pay two of the wallet's own subaddresses, as two requests would be.
    let height = tip().await;
    let sub1 = keys.address(Network::Mainnet, 0, 1).unwrap();
    let sub2 = keys.address(Network::Mainnet, 0, 2).unwrap();
    let to_self = prepare_selected(
        Backend::Node(&d),
        &keys,
        Network::Mainnet,
        &state,
        height,
        &Request::Pay(vec![(sub1, 2 * XMR), (sub2, 3 * XMR)]),
        Priority::Normal,
        &Selection::default(),
    )
    .await
    .unwrap();
    publish(Backend::Node(&d), &to_self, &mut state, height)
        .await
        .unwrap();
    // Waiting in the pool first, then in a block.
    sync_to_tip(&keys, &mut state).await;
    assert_eq!(state.received_by(0, 1), (0, 2 * XMR));
    mine(&burn(), 10).await;
    sync_to_tip(&keys, &mut state).await;
    assert_eq!(state.received_by(0, 1), (2 * XMR, 0));
    assert_eq!(state.received_by(0, 2), (3 * XMR, 0));
    assert_eq!(state.received_by(0, 3), (0, 0));

    let height = tip().await;
    let coins = spendable(&state, height);
    let on = |index: u32| {
        coins
            .iter()
            .find(|o| o.output.subaddress().is_some_and(|s| s.address() == index))
            .copied()
            .unwrap()
    };
    let (first_coin, second_coin) = (on(1), on(2));
    assert_eq!(linked_addresses(&[first_coin, second_coin]), 2);
    assert_eq!(linked_addresses(&[first_coin]), 1);

    // Only the chosen coin is spent.
    let only = Selection {
        exclude: Vec::new(),
        only: Some(vec![key_of(second_coin)]),
    };
    let chosen = prepare_selected(
        Backend::Node(&d),
        &keys,
        Network::Mainnet,
        &state,
        height,
        &Request::Pay(vec![(burn(), XMR)]),
        Priority::Normal,
        &only,
    )
    .await
    .unwrap();
    assert_eq!(chosen.spends, vec![second_coin.key_image.unwrap()]);
    assert_eq!(chosen.linked_addresses, 1);

    // Two chosen coins from two addresses: the summary says so.
    let both = Selection {
        exclude: Vec::new(),
        only: Some(vec![key_of(first_coin), key_of(second_coin)]),
    };
    let linked = prepare_selected(
        Backend::Node(&d),
        &keys,
        Network::Mainnet,
        &state,
        height,
        &Request::Pay(vec![(burn(), 4 * XMR)]),
        Priority::Normal,
        &both,
    )
    .await
    .unwrap();
    assert_eq!(linked.linked_addresses, 2);

    // A frozen coin is never spent, even when it would be the obvious one.
    let largest = coins[0];
    let frozen = Selection {
        exclude: vec![key_of(largest)],
        only: None,
    };
    let around = prepare_selected(
        Backend::Node(&d),
        &keys,
        Network::Mainnet,
        &state,
        height,
        &Request::Pay(vec![(burn(), XMR)]),
        Priority::Normal,
        &frozen,
    )
    .await
    .unwrap();
    assert!(!around.spends.contains(&largest.key_image.unwrap()));

    // Chosen coins that cannot cover the amount are refused.
    let short = prepare_selected(
        Backend::Node(&d),
        &keys,
        Network::Mainnet,
        &state,
        height,
        &Request::Pay(vec![(burn(), 10 * XMR)]),
        Priority::Normal,
        &only,
    )
    .await;
    assert!(matches!(short, Err(TxError::InsufficientFunds { .. })));
}
