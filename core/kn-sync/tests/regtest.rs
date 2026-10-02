//! End-to-end sync against a private regtest chain, checked against
//! Monero's reference wallet.
//!
//! Needs the regtest profile of `tools/devnet` running:
//!
//! ```sh
//! cd tools/devnet && docker compose --profile regtest up -d
//! cd core && cargo test -p kn-sync --test regtest -- --ignored --test-threads 1
//! ```
//!
//! Ignored by default because it needs Docker; CI runs it in its own job.

use std::collections::BTreeSet;
use std::sync::atomic::AtomicBool;

use kn_keys::{Network, SeedFormat, WalletKeys};
use kn_sync::{Direction, NodeUrl, SyncState, connect, sync};
use monero_wallet::address::{MoneroAddress, Network as MoneroNetwork};
use serde_json::{Value, json};

const NODE: &str = "http://127.0.0.1:18181";
const WALLET_RPC: &str = "http://127.0.0.1:18183/json_rpc";

async fn post(url: &str, body: Value) -> Value {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let client = reqwest::Client::new();
    let reply: Value = serde_json::from_slice(
        &client
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
    let info = post(
        &format!("{NODE}/json_rpc"),
        json!({"jsonrpc": "2.0", "id": "0", "method": "get_info"}),
    )
    .await;
    info["result"]["height"].as_u64().unwrap()
}

async fn sync_from(keys: &WalletKeys, state: &mut SyncState) {
    let (daemon, _) = connect(&NodeUrl::parse(NODE).unwrap(), Network::Mainnet)
        .await
        .unwrap();
    sync(
        &daemon,
        keys,
        &[1],
        state,
        &AtomicBool::new(false),
        |_, _| {},
    )
    .await
    .unwrap();
}

fn other_address() -> String {
    WalletKeys::generate(SeedFormat::Classic)
        .0
        .primary_address(Network::Mainnet)
}

// One end-to-end scenario, step by step; splitting it would hide the order
// the steps depend on.
#[allow(clippy::too_many_lines)]
#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs the regtest devnet; see the file header"]
async fn scans_spends_and_survives_a_reorg() {
    let (keys, mnemonic) = WalletKeys::generate(SeedFormat::Classic);
    let address = keys.primary_address(Network::Mainnet);
    let start = chain_height().await;

    // 120 blocks to us: enough unlocked outputs for wallet-rpc to build a
    // 16-member ring later.
    mine(&address, 120).await;
    let mut state = SyncState::starting_at(start);
    sync_from(&keys, &mut state).await;

    assert_eq!(state.outputs.len(), 120);
    assert!(state.outputs.iter().all(|o| o.miner));
    let tip = chain_height().await;
    let balance = state.balance(tip);
    assert!(balance.unlocked > 0 && balance.unlocked < balance.total);

    // The reference wallet, restored from the same seed, agrees.
    let name = format!("kn-{}", &address[..16]);
    wallet_rpc(
        "restore_deterministic_wallet",
        json!({"filename": name, "password": "", "seed": mnemonic.words.as_str(),
               "restore_height": start, "language": "English"}),
    )
    .await;
    wallet_rpc("refresh", json!({})).await;
    let transfers = wallet_rpc("incoming_transfers", json!({"transfer_type": "all"})).await;
    let reference: BTreeSet<String> = transfers["transfers"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["key_image"].as_str().unwrap().to_owned())
        .collect();
    let ours: BTreeSet<String> = state
        .outputs
        .iter()
        .map(|o| hex::encode(o.key_image.unwrap()))
        .collect();
    assert_eq!(ours, reference, "key images differ from monero-wallet-rpc");
    let reference_balance = wallet_rpc("get_balance", json!({})).await;
    assert_eq!(
        balance.total,
        reference_balance["balance"].as_u64().unwrap()
    );

    // The reference wallet spends from this seed, paying a second Kilonova
    // wallet; both must notice, first in the pool, then in a block.
    let (receiver, _) = WalletKeys::generate(SeedFormat::Classic);
    let mut receiver_state = SyncState::starting_at(chain_height().await);
    let sent: u64 = 1_000_000_000_000;
    let transfer = wallet_rpc(
        "transfer",
        json!({"destinations": [{"amount": sent,
                                 "address": receiver.address(Network::Mainnet, 0, 4).unwrap()}]}),
    )
    .await;
    let fee = transfer["fee"].as_u64().unwrap();
    let tx = transfer["tx_hash"].as_str().unwrap().to_owned();

    sync_from(&receiver, &mut receiver_state).await;
    let waiting = receiver_state.history();
    assert_eq!(waiting.len(), 1);
    assert!(waiting[0].pending && waiting[0].direction == Direction::Incoming);
    assert_eq!(
        (waiting[0].amount, &waiting[0].subaddresses[..]),
        (sent, &[(0, 4)][..])
    );
    assert_eq!(receiver_state.balance(chain_height().await).incoming, sent);
    assert_eq!(receiver_state.balance(chain_height().await).total, 0);

    sync_from(&keys, &mut state).await;
    let pending = state
        .history()
        .into_iter()
        .find(|h| h.direction == Direction::Outgoing)
        .expect("a spend from another device shows while in the pool");
    assert!(pending.pending);
    assert_eq!(hex::encode(pending.tx), tx);
    assert_eq!(pending.amount, sent + fee, "change in the pool is netted");
    assert!(
        state
            .history()
            .iter()
            .all(|h| h.direction == Direction::Outgoing || !h.pending),
        "the change is not shown as a separate incoming payment"
    );

    mine(&other_address(), 1).await;
    sync_from(&receiver, &mut receiver_state).await;
    let mined = receiver_state.history();
    assert_eq!(mined.len(), 1);
    assert!(!mined[0].pending);
    assert_eq!(receiver_state.balance(chain_height().await).total, sent);
    assert_eq!(receiver_state.balance(chain_height().await).incoming, 0);
    sync_from(&keys, &mut state).await;

    let history = state.history();
    let outgoing = history
        .iter()
        .find(|h| h.direction == Direction::Outgoing)
        .expect("the spend shows up as outgoing");
    assert_eq!(hex::encode(outgoing.tx), tx);
    assert!(!outgoing.pending);
    assert_eq!(outgoing.amount, sent + fee);
    let after = state.balance(chain_height().await);
    assert_eq!(after.total, balance.total - sent - fee);

    // Reorganize: drop the last 30 blocks (29 of our coinbases and the
    // spend) and mine a longer chain elsewhere. The spend returns to the
    // pool and is mined again in the new chain, so its change comes back
    // at a new height; the dropped coinbases must not.
    let fork = chain_height().await - 30;
    post(&format!("{NODE}/pop_blocks"), json!({"nblocks": 30})).await;
    mine(&other_address(), 31).await;
    sync_from(&keys, &mut state).await;

    let miner_outputs = state.outputs.iter().filter(|o| o.miner);
    assert!(miner_outputs.clone().all(|o| o.height < fork));
    assert_eq!(miner_outputs.count(), 120 - 29);

    wallet_rpc("refresh", json!({})).await;
    let reference_balance = wallet_rpc("get_balance", json!({})).await;
    assert_eq!(
        state.balance(chain_height().await).total,
        reference_balance["balance"].as_u64().unwrap(),
        "balance after the reorg differs from monero-wallet-rpc"
    );
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs the regtest devnet; see the file header"]
async fn a_node_agrees_with_itself_and_regtest_is_marked_as_a_test_chain() {
    let node = NodeUrl::parse(NODE).unwrap();
    let (daemon, status) = connect(&node, Network::Mainnet).await.unwrap();
    // The app skips the comparison on test chains, which no public node
    // shares.
    assert!(status.test_chain);
    mine(&other_address(), 12).await;
    let opinion = kn_sync::second_opinion(&daemon, &node, Network::Mainnet)
        .await
        .unwrap();
    assert!(opinion.agrees);
    assert_eq!(opinion.ours, opinion.theirs);
}
