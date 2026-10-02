//! Sending on a regtest chain, received by Monero's reference wallet.
//!
//! Needs the regtest profile of `tools/devnet`:
//!
//! ```sh
//! cd tools/devnet && docker compose --profile regtest up -d
//! cd core && cargo test -p kn-tx --test regtest_send -- --ignored --test-threads 1
//! ```

use std::sync::atomic::AtomicBool;

use kn_keys::{Network, SeedFormat, WalletKeys};
use kn_sync::{Direction, NodeUrl, SyncState, connect, sync};
use kn_tx::{Backend, Priority, Request, TxError, prepare, publish, spendable};
use monero_wallet::address::{MoneroAddress, Network as MoneroNetwork};
use serde_json::{Value, json};

const NODE: &str = "http://127.0.0.1:18181";
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

async fn daemon() -> monero_daemon_rpc::MoneroDaemon<kn_sync::Http> {
    connect(&NodeUrl::parse(NODE).unwrap(), Network::Mainnet)
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
    post(
        &format!("{NODE}/json_rpc"),
        json!({"jsonrpc": "2.0", "id": "0", "method": "get_info"}),
    )
    .await["result"]["height"]
        .as_u64()
        .unwrap()
}

async fn sync_to_tip(keys: &WalletKeys, state: &mut SyncState) {
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

fn burn_address() -> String {
    WalletKeys::generate(SeedFormat::Classic)
        .0
        .primary_address(Network::Mainnet)
}

/// A fresh wallet in monero-wallet-rpc to receive payments.
async fn reference_wallet(name: &str) -> (String, String) {
    wallet_rpc(
        "create_wallet",
        json!({"filename": name, "password": "", "language": "English"}),
    )
    .await;
    let primary = wallet_rpc("get_address", json!({"account_index": 0})).await["address"]
        .as_str()
        .unwrap()
        .to_owned();
    let sub = wallet_rpc("create_address", json!({"account_index": 0})).await["address"]
        .as_str()
        .unwrap()
        .to_owned();
    (primary, sub)
}

async fn received_by_reference() -> u64 {
    wallet_rpc("refresh", json!({})).await;
    wallet_rpc("get_balance", json!({})).await["balance"]
        .as_u64()
        .unwrap()
}

// One end-to-end scenario, step by step; splitting it would hide the order
// the steps depend on.
#[allow(clippy::too_many_lines)]
#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs the regtest devnet; see the file header"]
async fn pays_monero_wallet_rpc_and_tracks_the_spend() {
    let (keys, _) = WalletKeys::generate(SeedFormat::Classic);
    let start = tip().await;
    mine(&keys.primary_address(Network::Mainnet), 80).await;
    let mut state = SyncState::starting_at(start);
    sync_to_tip(&keys, &mut state).await;
    let height = tip().await;
    let before = state.balance(height);
    assert!(before.unlocked >= 20 * XMR, "need unlocked mined funds");

    let (to_primary, to_sub) = reference_wallet(&format!(
        "recv-{}",
        &keys.primary_address(Network::Mainnet)[..12]
    ))
    .await;
    let d = daemon().await;

    // Errors first: nothing is published.
    let err = prepare(
        Backend::Node(&d),
        &keys,
        Network::Mainnet,
        &state,
        height,
        &Request::Pay(vec![(to_primary.clone(), before.total * 2)]),
        Priority::Normal,
    )
    .await
    .unwrap_err();
    assert!(matches!(err, TxError::InsufficientFunds { .. }));
    let stagenet_address = WalletKeys::generate(SeedFormat::Classic)
        .0
        .primary_address(Network::Stagenet);
    let err = prepare(
        Backend::Node(&d),
        &keys,
        Network::Mainnet,
        &state,
        height,
        &Request::Pay(vec![(stagenet_address, XMR)]),
        Priority::Normal,
    )
    .await
    .unwrap_err();
    assert!(matches!(err, TxError::BadAddress(_)));

    // Pay two addresses of the reference wallet in one transaction.
    let prepared = prepare(
        Backend::Node(&d),
        &keys,
        Network::Mainnet,
        &state,
        height,
        &Request::Pay(vec![
            (to_primary.clone(), 3 * XMR),
            (to_sub.clone(), 2 * XMR),
        ]),
        Priority::Normal,
    )
    .await
    .unwrap();
    assert_eq!(prepared.amount, 5 * XMR);
    assert!(prepared.fee > 0);
    let spent_inputs: u64 = state
        .outputs
        .iter()
        .filter(|o| o.key_image.is_some_and(|ki| prepared.spends.contains(&ki)))
        .map(kn_sync::OwnedOutput::amount)
        .sum();
    assert_eq!(
        spent_inputs,
        prepared.amount + prepared.fee + prepared.change
    );
    publish(Backend::Node(&d), &prepared, &mut state, height)
        .await
        .unwrap();
    assert_eq!(
        prepared.destinations,
        vec![(to_primary.clone(), 3 * XMR), (to_sub.clone(), 2 * XMR)]
    );

    // Pending at once: the inputs are no longer counted.
    let pending = state.balance(height);
    assert_eq!(pending.total, before.total - spent_inputs);
    let outgoing = state
        .history()
        .into_iter()
        .find(|h| h.direction == Direction::Outgoing)
        .unwrap();
    assert!(outgoing.pending);

    mine(&burn_address(), 1).await;
    sync_to_tip(&keys, &mut state).await;
    let outgoing = state
        .history()
        .into_iter()
        .find(|h| h.direction == Direction::Outgoing)
        .unwrap();
    assert!(!outgoing.pending, "confirmed once mined");
    assert_eq!(outgoing.tx, prepared.hash);
    assert_eq!(outgoing.amount, 5 * XMR + prepared.fee);
    assert_eq!(
        state.balance(tip().await).total,
        before.total - 5 * XMR - prepared.fee
    );
    assert_eq!(received_by_reference().await, 5 * XMR);
    // The transaction key proves each payment to Monero's reference wallet.
    let tx_key = prepared
        .tx_key
        .as_deref()
        .expect("tx key confirmed")
        .to_owned();
    for (address, amount) in [(&to_primary, 3 * XMR), (&to_sub, 2 * XMR)] {
        let check = wallet_rpc(
            "check_tx_key",
            json!({"txid": hex::encode(prepared.hash), "tx_key": tx_key, "address": address}),
        )
        .await;
        assert_eq!(check["received"].as_u64(), Some(amount), "{address}");
    }

    // Sweep everything spendable (the change is locked for 10 blocks, so
    // unlock it first) to the reference wallet.
    mine(&burn_address(), 10).await;
    sync_to_tip(&keys, &mut state).await;
    let height = tip().await;
    let sweepable: u64 = spendable(&state, height).iter().map(|o| o.amount()).sum();
    let swept = prepare(
        Backend::Node(&d),
        &keys,
        Network::Mainnet,
        &state,
        height,
        &Request::SweepAll(to_primary.clone()),
        Priority::Normal,
    )
    .await
    .unwrap();
    assert_eq!(swept.amount + swept.fee, sweepable);
    assert_eq!(swept.change, 0);
    publish(Backend::Node(&d), &swept, &mut state, height)
        .await
        .unwrap();
    assert!(
        spendable(&state, height).is_empty(),
        "everything spendable went"
    );
    mine(&burn_address(), 1).await;
    sync_to_tip(&keys, &mut state).await;
    // The new block unlocks more of the wallet's mined outputs; only those,
    // which were still locked at sweep time, may be spendable now.
    assert!(
        spendable(&state, tip().await)
            .iter()
            .all(|o| o.unlock_height() > height)
    );
    assert_eq!(received_by_reference().await, 5 * XMR + swept.amount);
    let check = wallet_rpc(
        "check_tx_key",
        json!({"txid": hex::encode(swept.hash),
               "tx_key": swept.tx_key.as_deref().expect("tx key confirmed"),
               "address": to_primary}),
    )
    .await;
    assert_eq!(check["received"].as_u64(), Some(swept.amount));

    // A transaction that never reaches a block (here: never broadcast) must
    // not lock its inputs forever.
    let height = tip().await;
    let stuck: Vec<[u8; 32]> = spendable(&state, height)
        .iter()
        .filter_map(|o| o.key_image)
        .collect();
    assert!(!stuck.is_empty());
    state.mark_pending(&stuck, [0xab; 32], height);
    assert!(spendable(&state, height).is_empty());
    mine(
        &burn_address(),
        usize::try_from(kn_sync::PENDING_EXPIRY_BLOCKS).unwrap() + 1,
    )
    .await;
    sync_to_tip(&keys, &mut state).await;
    let freed: Vec<[u8; 32]> = spendable(&state, tip().await)
        .iter()
        .filter_map(|o| o.key_image)
        .collect();
    assert!(
        stuck.iter().all(|ki| freed.contains(ki)),
        "dropped spend expired"
    );
}
