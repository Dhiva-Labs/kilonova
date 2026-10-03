//! Cover lookups against a fake node that records every `get_transactions`
//! request: the batch size never changes, the real hash moves around, and
//! the cover comes from blocks around the real one's height.

use std::sync::{Arc, Mutex};

use kn_keys::{Network, SeedFormat, WalletKeys};
use kn_sync::{
    COVER_WINDOW, Circuit, CoverLookups, LOOKUP_BATCH, NodeUrl, ProofError, Purpose, check_tx_key,
    connect,
};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

/// The fake chain's last block.
const TIP: u64 = 10_000;
/// Transactions per fake block, the miner one included.
const PER_BLOCK: u8 = 4;
/// Asked for, but in no block.
const REAL: [u8; 32] = [0xee; 32];

/// The hash of transaction `index` in block `height`: the height is
/// readable from it, so the test can tell where cover came from.
fn tx_hash(height: u64, index: u8) -> [u8; 32] {
    let mut hash = [0xc0; 32];
    hash[..8].copy_from_slice(&height.to_le_bytes());
    hash[8] = index;
    hash
}

fn height_of(hash: &[u8; 32]) -> u64 {
    u64::from_le_bytes(hash[..8].try_into().unwrap())
}

#[derive(Default)]
struct Seen {
    lookups: Vec<Vec<[u8; 32]>>,
    blocks_read: usize,
}

fn answer(path: &str, body: &Value, seen: &Mutex<Seen>) -> Value {
    match path {
        "/get_height" => json!({"height": TIP + 1, "status": "OK"}),
        "/get_info" => json!({"nettype": "fakechain", "height": TIP + 1,
                              "target_height": TIP + 1, "status": "OK"}),
        "/get_transactions" => {
            let hashes: Vec<[u8; 32]> = body["txs_hashes"]
                .as_array()
                .unwrap()
                .iter()
                .map(|h| {
                    hex::decode(h.as_str().unwrap())
                        .unwrap()
                        .try_into()
                        .unwrap()
                })
                .collect();
            // Cover transactions come back as garbage: they must never be
            // read. The real one is missing.
            let txs: Vec<Value> = hashes
                .iter()
                .filter(|h| **h != REAL)
                .map(|h| json!({"tx_hash": hex::encode(h), "as_hex": "zz", "in_pool": false}))
                .collect();
            seen.lock().unwrap().lookups.push(hashes);
            json!({"txs": txs, "missed_tx": [hex::encode(REAL)], "status": "OK"})
        }
        "/json_rpc" if body.is_array() => json!([]),
        "/json_rpc" if body["method"] == "get_block" => {
            let height = body["params"]["height"].as_u64().unwrap();
            assert!(height <= TIP, "asked for a block past the tip");
            seen.lock().unwrap().blocks_read += 1;
            let txs: Vec<String> = (1..PER_BLOCK)
                .map(|i| hex::encode(tx_hash(height, i)))
                .collect();
            json!({"id": 0, "jsonrpc": "2.0", "result": {
                "miner_tx_hash": hex::encode(tx_hash(height, 0)),
                "tx_hashes": txs, "status": "OK"}})
        }
        _ => json!({}),
    }
}

async fn fake_node() -> (NodeUrl, Arc<Mutex<Seen>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = NodeUrl::parse(&format!("http://{}", listener.local_addr().unwrap())).unwrap();
    let seen = Arc::new(Mutex::new(Seen::default()));
    let shared = Arc::clone(&seen);
    tokio::spawn(async move {
        loop {
            let (mut socket, _) = listener.accept().await.unwrap();
            let seen = Arc::clone(&shared);
            tokio::spawn(async move {
                // Keep-alive: answer requests on this connection until the
                // client closes it.
                let mut buf = Vec::new();
                loop {
                    let (path, body) = loop {
                        let text = String::from_utf8_lossy(&buf).into_owned();
                        if let Some(end) = text.find("\r\n\r\n") {
                            let length = text[..end]
                                .lines()
                                .find_map(|l| {
                                    l.to_ascii_lowercase()
                                        .strip_prefix("content-length:")
                                        .map(|v| v.trim().parse::<usize>().unwrap())
                                })
                                .unwrap_or(0);
                            if buf.len() >= end + 4 + length {
                                let path = text.split_whitespace().nth(1).unwrap().to_owned();
                                let body: Value =
                                    serde_json::from_slice(&buf[end + 4..end + 4 + length])
                                        .unwrap_or(Value::Null);
                                buf.drain(..end + 4 + length);
                                break (path, body);
                            }
                        }
                        let mut chunk = [0u8; 4096];
                        let n = socket.read(&mut chunk).await.unwrap_or(0);
                        if n == 0 {
                            return;
                        }
                        buf.extend_from_slice(&chunk[..n]);
                    };
                    let reply = answer(&path, &body, &seen).to_string();
                    let response = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{reply}",
                        reply.len()
                    );
                    if socket.write_all(response.as_bytes()).await.is_err() {
                        return;
                    }
                }
            });
        }
    });
    (url, seen)
}

/// Checks one recorded batch and returns where the real hash was.
fn check_batch(batch: &[[u8; 32]], window_around: u64) -> usize {
    assert_eq!(batch.len(), LOOKUP_BATCH, "same batch size every time");
    let position = batch
        .iter()
        .position(|h| *h == REAL)
        .expect("real hash sent");
    let covers: Vec<&[u8; 32]> = batch.iter().filter(|h| **h != REAL).collect();
    let mut unique = covers.clone();
    unique.sort();
    unique.dedup();
    assert_eq!(unique.len(), LOOKUP_BATCH - 1, "covers are distinct");
    let heights: Vec<u64> = covers.iter().map(|h| height_of(h)).collect();
    let low = *heights.iter().min().unwrap();
    let high = *heights.iter().max().unwrap();
    assert!(high <= TIP);
    // One window of COVER_WINDOW blocks holds every cover hash and the
    // real transaction's height.
    assert!(
        high.max(window_around) - low.min(window_around) < COVER_WINDOW,
        "cover from {low}..={high} around {window_around}"
    );
    position
}

#[tokio::test(flavor = "multi_thread")]
async fn cover_hides_the_real_hash_by_position_and_height() {
    let (url, seen) = fake_node().await;
    let (daemon, _) = connect(&url, Network::Mainnet, &Circuit::app(Purpose::CrossCheck))
        .await
        .unwrap();

    let real_height = 5_000;
    let runs = 200;
    for _ in 0..runs {
        let mut lookups = CoverLookups::new();
        assert_eq!(
            lookups
                .fetch(&daemon, REAL, Some(real_height))
                .await
                .unwrap_err(),
            ProofError::UnknownTransaction,
            "garbage cover answers are never read"
        );
    }
    let seen = seen.lock().unwrap();
    assert_eq!(seen.lookups.len(), runs);
    let mut positions = [0usize; LOOKUP_BATCH];
    let (mut below, mut above) = (false, false);
    for batch in &seen.lookups {
        positions[check_batch(batch, real_height)] += 1;
        for h in batch.iter().filter(|h| **h != REAL) {
            below |= height_of(h) < real_height;
            above |= height_of(h) > real_height;
        }
    }
    assert!(
        positions.iter().all(|n| *n > 0),
        "every position is used: {positions:?}"
    );
    assert!(below && above, "the real height is not always at an edge");
}

#[tokio::test(flavor = "multi_thread")]
async fn one_run_reads_each_block_once() {
    let (url, seen) = fake_node().await;
    let (daemon, _) = connect(&url, Network::Mainnet, &Circuit::app(Purpose::CrossCheck))
        .await
        .unwrap();
    let mut lookups = CoverLookups::new();
    for _ in 0..30 {
        let _ = lookups.fetch(&daemon, REAL, Some(7_000)).await;
    }
    let seen = seen.lock().unwrap();
    assert_eq!(seen.lookups.len(), 30);
    for batch in &seen.lookups {
        assert_eq!(batch.len(), LOOKUP_BATCH);
    }
    // Windows around one height overlap; at most two windows' worth.
    assert!(
        (seen.blocks_read as u64) < 2 * COVER_WINDOW,
        "{} blocks read",
        seen.blocks_read
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn proof_checks_take_cover_from_the_latest_blocks() {
    let (url, seen) = fake_node().await;
    let (daemon, _) = connect(&url, Network::Mainnet, &Circuit::app(Purpose::Proof))
        .await
        .unwrap();
    let (keys, _) = WalletKeys::generate(SeedFormat::Classic);
    let address = keys.primary_address(Network::Mainnet);
    let tx_key = format!("01{}", "00".repeat(31));
    for _ in 0..20 {
        assert_eq!(
            check_tx_key(&daemon, Network::Mainnet, REAL, &tx_key, &address)
                .await
                .unwrap_err(),
            ProofError::UnknownTransaction
        );
    }
    let seen = seen.lock().unwrap();
    assert_eq!(seen.lookups.len(), 20);
    for batch in &seen.lookups {
        check_batch(batch, TIP);
    }
}
