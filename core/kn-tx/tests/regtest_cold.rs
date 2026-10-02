//! Offline signing end to end on a regtest chain: a view-only watching
//! wallet syncs and builds, a cold wallet that never touches the network
//! signs, every message travels as QR frames, and Monero's reference wallet
//! receives the payment.
//!
//! Needs the regtest profile of `tools/devnet`:
//!
//! ```sh
//! cd tools/devnet && docker compose --profile regtest up -d
//! cd core && cargo test -p kn-tx --test regtest_cold -- --ignored --test-threads 1
//! ```

use std::sync::atomic::AtomicBool;

use kn_keys::{Network, SeedFormat, WalletKeys};
use kn_sync::{Direction, NodeUrl, SyncState, connect, sync};
use kn_tx::cold::{self, Assembler, ColdError, Envelope, FRAME_CHARS};
use kn_tx::{Backend, Priority, Request, TxError, prepare_unsigned, publish_signed};
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

/// Sends a message the way the app does: QR frames, scanned in a scrambled
/// order with repeats, reassembled and parsed.
fn over_qr(envelope: &Envelope) -> Envelope {
    let frames = cold::frames(&envelope.to_bytes(), FRAME_CHARS);
    let mut assembler = Assembler::new();
    for f in frames.iter().skip(1).chain(frames.iter()) {
        assembler.add(f).unwrap();
    }
    Envelope::from_bytes(&assembler.message().unwrap()).unwrap()
}

fn burn() -> String {
    WalletKeys::generate(SeedFormat::Classic)
        .0
        .primary_address(Network::Mainnet)
}

// One end-to-end scenario, step by step; splitting it would hide the order
// the steps depend on.
#[allow(clippy::too_many_lines)]
#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs the regtest devnet; see the file header"]
async fn a_cold_wallet_signs_for_a_watching_wallet() {
    // The cold wallet: full keys, never given a node.
    let (cold_keys, _) = WalletKeys::generate(SeedFormat::Polyseed);
    let start = tip().await;

    // Pairing: the watching wallet is created from the cold wallet's QR.
    let pairing = cold::read_pairing(&over_qr(&cold::pairing(
        &cold_keys,
        Network::Mainnet,
        start,
    )))
    .unwrap();
    let watching =
        WalletKeys::view_only(Network::Mainnet, &pairing.address, &pairing.view_key_hex).unwrap();
    assert!(watching.is_view_only());

    mine(&pairing.address, 70).await;
    let mut state = SyncState::starting_at(pairing.restore_height);
    sync_to_tip(&watching, &mut state).await;
    assert_eq!(state.outputs.len(), 70);
    assert!(state.outputs.iter().all(|o| o.key_image.is_none()));
    let d = daemon().await;
    let height = tip().await;

    // Without key images nothing is spendable: the watching wallet cannot
    // tell what is already spent.
    let to = {
        wallet_rpc(
            "create_wallet",
            json!({"filename": format!("cold-recv-{}", &pairing.address[..12]),
                   "password": "", "language": "English"}),
        )
        .await;
        wallet_rpc("get_address", json!({"account_index": 0})).await["address"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    let err = prepare_unsigned(
        Backend::Node(&d),
        &watching,
        Network::Mainnet,
        &state,
        height,
        &Request::Pay(vec![(to.clone(), XMR)]),
        Priority::Normal,
    )
    .await;
    assert!(matches!(err, Err(TxError::InsufficientFunds { .. })));

    // Sync with the cold wallet: key images for every output.
    let request = over_qr(&cold::sync_request(&watching, Network::Mainnet, &state));
    let (answer, refused) = cold::answer_sync(&cold_keys, Network::Mainnet, &request).unwrap();
    assert_eq!(refused, 0);
    let answer = cold::read_answer(&watching, Network::Mainnet, &over_qr(&answer)).unwrap();
    assert_eq!(answer.key_images.len(), 70);
    let rescan = state.learn_key_images(&answer.key_images).unwrap();
    state.rescan_from(rescan);
    sync_to_tip(&watching, &mut state).await;
    assert!(state.outputs.iter().all(|o| o.key_image.is_some()));
    // They match what the cold wallet derives itself.
    for o in &state.outputs {
        assert_eq!(
            o.key_image,
            cold_keys.key_image(o.output.key(), o.output.key_offset())
        );
    }

    // Build, sign offline, publish.
    let height = tip().await;
    let before = state.balance(height).total;
    let unsigned = prepare_unsigned(
        Backend::Node(&d),
        &watching,
        Network::Mainnet,
        &state,
        height,
        &Request::Pay(vec![(to.clone(), 3 * XMR / 2)]),
        Priority::Normal,
    )
    .await
    .unwrap();
    let request = over_qr(&cold::sign_request(
        &watching,
        Network::Mainnet,
        &state,
        &unsigned,
    ));
    let review = cold::review(&cold_keys, Network::Mainnet, &request).unwrap();
    // The cold wallet shows what it reads from the transaction itself, and
    // it agrees with what the watching wallet built.
    assert_eq!(review.destinations, vec![(to.clone(), 3 * XMR / 2)]);
    assert_eq!(review.fee, unsigned.fee);
    assert_eq!(review.change, unsigned.change);

    // Another wallet's cold device refuses it.
    let (stranger, _) = WalletKeys::generate(SeedFormat::Classic);
    assert_eq!(
        cold::review(&stranger, Network::Mainnet, &request).unwrap_err(),
        ColdError::WrongWallet
    );
    // A request carrying this wallet's tag but someone else's transaction is
    // refused too.
    let forged = Envelope {
        wallet: cold::wallet_tag(&stranger.primary_address(Network::Mainnet)),
        ..request.clone()
    };
    assert!(cold::review(&stranger, Network::Mainnet, &forged).is_err());

    let (answer, signed_here) = cold::sign(&cold_keys, Network::Mainnet, review).unwrap();
    let answer = cold::read_answer(&watching, Network::Mainnet, &over_qr(&answer)).unwrap();
    let signed = answer.signed.expect("a signed transaction");
    assert_eq!(signed.hash, signed_here.hash);
    if let Some(rescan) = state.learn_key_images(&answer.key_images) {
        state.rescan_from(rescan);
        sync_to_tip(&watching, &mut state).await;
    }
    publish_signed(Backend::Node(&d), &signed, &mut state, height)
        .await
        .unwrap();

    mine(&burn(), 1).await;
    sync_to_tip(&watching, &mut state).await;
    let outgoing = state
        .history()
        .into_iter()
        .find(|h| h.direction == Direction::Outgoing)
        .expect("the watching wallet sees its own spend");
    assert!(!outgoing.pending);
    assert_eq!(outgoing.tx, signed.hash);
    assert_eq!(
        state.balance(tip().await).total,
        before - 3 * XMR / 2 - unsigned.fee
    );

    wallet_rpc("refresh", json!({})).await;
    let received = wallet_rpc("get_balance", json!({})).await["balance"]
        .as_u64()
        .unwrap();
    assert_eq!(received, 3 * XMR / 2);
    let check = wallet_rpc(
        "check_tx_key",
        json!({"txid": hex::encode(signed.hash),
               "tx_key": signed.tx_key.as_deref().expect("tx key"),
               "address": to}),
    )
    .await;
    assert_eq!(check["received"].as_u64(), Some(3 * XMR / 2));
}
