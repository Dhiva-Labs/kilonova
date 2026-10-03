//! Broadcasting through a node other than the wallet's own, on a regtest
//! chain with two daemons: the wallet syncs from A, the transaction goes to
//! B, and A never receives it from the wallet.
//!
//! Needs the regtest profile of `tools/devnet` (monerod-regtest and
//! monerod-regtest-b):
//!
//! ```sh
//! cd tools/devnet && docker compose --profile regtest up -d
//! cd core && cargo test -p kn-tx --test regtest_broadcast -- --ignored --test-threads 1
//! ```

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use kn_keys::{Network, SeedFormat, WalletKeys};
use kn_sync::{
    Circuit, NodeUrl, Purpose, SyncState, broadcast_nodes, connect, other_node,
    set_broadcast_nodes_for_tests, sync,
};
use kn_tx::{
    Backend, Connected, Elsewhere, Priority, Request, Sent, TxError, prepare, publish_through,
    raw_transaction,
};
use monero_wallet::address::{MoneroAddress, Network as MoneroNetwork};
use serde_json::{Value, json};

/// The wallet's own node.
const NODE_A: &str = "http://127.0.0.1:18181";
/// The other node, peered only with A.
const NODE_B: &str = "http://127.0.0.1:18191";
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

async fn info(node: &str) -> Value {
    post(
        &format!("{node}/json_rpc"),
        json!({"jsonrpc": "2.0", "id": "0", "method": "get_info"}),
    )
    .await["result"]
        .clone()
}

async fn height(node: &str) -> u64 {
    info(node).await["height"].as_u64().unwrap()
}

async fn daemon(node: &str) -> monero_daemon_rpc::MoneroDaemon<kn_sync::Http> {
    connect(
        &NodeUrl::parse(node).unwrap(),
        Network::Mainnet,
        &Circuit::app(Purpose::Sync),
    )
    .await
    .unwrap()
    .0
}

async fn mine(node: &str, address: &str, blocks: usize) {
    let address = MoneroAddress::from_str(MoneroNetwork::Mainnet, address).unwrap();
    daemon(node)
        .await
        .generate_blocks(&address, blocks)
        .await
        .unwrap();
}

fn burn_address() -> String {
    WalletKeys::generate(SeedFormat::Classic)
        .0
        .primary_address(Network::Mainnet)
}

/// Waits up to `seconds` for `done`.
async fn wait_for<F: AsyncFn() -> bool>(seconds: u64, what: &str, done: F) {
    for _ in 0..seconds * 4 {
        if done().await {
            return;
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    panic!("timed out waiting for {what}");
}

async fn in_pool(node: &str, tx: [u8; 32]) -> bool {
    let reply = post(&format!("{node}/get_transaction_pool_hashes"), json!({})).await;
    reply["tx_hashes"]
        .as_array()
        .is_some_and(|hashes| hashes.iter().any(|h| h == &json!(hex::encode(tx))))
}

/// Whether `node` has `tx`, in its pool or in a block.
async fn knows(node: &str, tx: [u8; 32]) -> bool {
    let reply = post(
        &format!("{node}/get_transactions"),
        json!({"txs_hashes": [hex::encode(tx)]}),
    )
    .await;
    reply["txs"].as_array().is_some_and(|txs| !txs.is_empty())
}

async fn connections(node: &str) -> u64 {
    let info = info(node).await;
    info["incoming_connections_count"].as_u64().unwrap()
        + info["outgoing_connections_count"].as_u64().unwrap()
}

/// Cuts (or restores) the p2p link between A and B, so whatever B's pool
/// holds came from an RPC call, not from A.
async fn link(up: bool) {
    let limit = if up { 8 } else { 0 };
    for node in [NODE_A, NODE_B] {
        post(
            &format!("{node}/out_peers"),
            json!({"set": true, "out_peers": limit}),
        )
        .await;
        post(
            &format!("{node}/in_peers"),
            json!({"set": true, "in_peers": limit}),
        )
        .await;
    }
    if up {
        wait_for(60, "A and B to reconnect", async || {
            connections(NODE_A).await > 0
        })
        .await;
    } else {
        wait_for(30, "A and B to disconnect", async || {
            connections(NODE_A).await == 0 && connections(NODE_B).await == 0
        })
        .await;
    }
}

/// Restores the link even when an assertion fails, so later suites see one
/// chain.
struct Relink;

impl Drop for Relink {
    fn drop(&mut self) {
        std::thread::spawn(|| {
            tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap()
                .block_on(link(true));
        })
        .join()
        .unwrap();
    }
}

/// A wallet with unlocked funds, synced from A, with B caught up.
async fn funded_wallet() -> (WalletKeys, SyncState) {
    link(true).await;
    // Decoy selection needs a few hundred outputs on a fresh chain.
    let have = height(NODE_A).await;
    if have < 400 {
        mine(
            NODE_A,
            &burn_address(),
            usize::try_from(400 - have).unwrap(),
        )
        .await;
    }
    let (keys, _) = WalletKeys::generate(SeedFormat::Classic);
    let start = height(NODE_A).await;
    mine(NODE_A, &keys.primary_address(Network::Mainnet), 70).await;
    let mut state = SyncState::starting_at(start);
    sync(
        &daemon(NODE_A).await,
        &keys,
        &[1],
        &mut state,
        &AtomicBool::new(false),
        |_, _| {},
    )
    .await
    .unwrap();
    let tip = height(NODE_A).await;
    assert!(
        state.balance(tip).unlocked >= 2 * XMR,
        "need unlocked funds"
    );
    wait_for(60, "B to catch up with A", async || {
        height(NODE_B).await == tip
    })
    .await;
    (keys, state)
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs the regtest devnet with both daemons; see the file header"]
async fn the_transaction_goes_to_the_other_node_and_never_to_the_sync_node() {
    let (keys, mut state) = funded_wallet().await;
    let node_a = NodeUrl::parse(NODE_A).unwrap();
    let node_b = NodeUrl::parse(NODE_B).unwrap();

    // The broadcast node is drawn from the list, never the sync node.
    set_broadcast_nodes_for_tests(Network::Mainnet, Some(vec![node_a.clone(), node_b.clone()]));
    for _ in 0..20 {
        assert_eq!(
            other_node(broadcast_nodes(Network::Mainnet), &node_a),
            Some(node_b.clone())
        );
    }
    let chosen = other_node(broadcast_nodes(Network::Mainnet), &node_a).unwrap();
    set_broadcast_nodes_for_tests(Network::Mainnet, None);

    let tip = height(NODE_A).await;
    let a = daemon(NODE_A).await;
    let prepared = prepare(
        Backend::Node(&a),
        &keys,
        Network::Mainnet,
        &state,
        tip,
        &Request::Pay(vec![(burn_address(), XMR)]),
        Priority::Normal,
    )
    .await
    .unwrap();

    link(false).await;
    let _relink = Relink;
    let circuit = Circuit::new("wallet", Purpose::Broadcast);
    let sync_node_used = AtomicBool::new(false);
    let sent = publish_through(
        Some(Elsewhere {
            node: &chosen,
            network: Network::Mainnet,
            circuit: &circuit,
        }),
        async || {
            sync_node_used.store(true, Ordering::Relaxed);
            Err(TxError::Node("the sync node must not be asked".into()))
        },
        &prepared,
        &mut state,
        tip,
    )
    .await
    .unwrap();
    assert_eq!(sent, Sent::Elsewhere);
    assert!(!sync_node_used.load(Ordering::Relaxed));
    assert!(
        in_pool(NODE_B, prepared.hash).await,
        "the other node has it"
    );
    assert!(
        !knows(NODE_A, prepared.hash).await,
        "the sync node was never given it"
    );
    assert!(
        state.outputs.iter().any(|o| o.spent.is_some()),
        "inputs are pending"
    );

    // Tidy up for later suites: the nodes talk again, the transaction is
    // mined (handed to A here rather than waiting for B's relay timers), and
    // B follows.
    link(true).await;
    post(
        &format!("{NODE_A}/send_raw_transaction"),
        json!({"tx_as_hex": hex::encode(raw_transaction(&prepared))}),
    )
    .await;
    mine(NODE_A, &burn_address(), 1).await;
    let mined = height(NODE_A).await;
    wait_for(60, "B to take the block", async || {
        height(NODE_B).await == mined && !in_pool(NODE_B, prepared.hash).await
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs the regtest devnet with both daemons; see the file header"]
async fn an_unreachable_other_node_falls_back_to_the_sync_node() {
    let (keys, mut state) = funded_wallet().await;
    // Nothing listens there.
    let unreachable = {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        NodeUrl::parse(&format!("http://{}", listener.local_addr().unwrap())).unwrap()
    };
    let tip = height(NODE_A).await;
    let a = daemon(NODE_A).await;
    let prepared = prepare(
        Backend::Node(&a),
        &keys,
        Network::Mainnet,
        &state,
        tip,
        &Request::Pay(vec![(burn_address(), XMR)]),
        Priority::Normal,
    )
    .await
    .unwrap();
    let circuit = Circuit::new("wallet", Purpose::Broadcast);
    let sent = publish_through(
        Some(Elsewhere {
            node: &unreachable,
            network: Network::Mainnet,
            circuit: &circuit,
        }),
        async || Ok(Connected::Node(daemon(NODE_A).await)),
        &prepared,
        &mut state,
        tip,
    )
    .await
    .unwrap();
    assert_eq!(sent, Sent::FellBack);
    assert!(in_pool(NODE_A, prepared.hash).await);
    mine(NODE_A, &burn_address(), 1).await;
}
