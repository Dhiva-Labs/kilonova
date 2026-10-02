//! A light wallet server that lies. Kilonova must keep what really belongs
//! to the wallet, drop everything else, and never accept a spend it cannot
//! confirm with its own key images.

use curve25519_dalek::{Scalar as DalekScalar, constants::ED25519_BASEPOINT_TABLE};
use kn_keys::{Network, SeedFormat, WalletKeys};
use kn_sync::{LwsServer, NodeUrl, SyncState, lws_sync};
use monero_wallet::address::{MoneroAddress, Network as MoneroNetwork};
use monero_wallet::ed25519::{Commitment, Scalar};
use rand_core::OsRng;
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

/// Sender side: (tx public key, one-time output key) for output `index`.
fn pay(address: &str, index: u8) -> (String, String) {
    let (tx_pub, key, _) = pay_with_mask(address, index);
    (tx_pub, key)
}

/// Like [`pay`], also returning the `RingCT` mask the recipient derives.
fn pay_with_mask(address: &str, index: u8) -> (String, String, DalekScalar) {
    let address = MoneroAddress::from_str(MoneroNetwork::Mainnet, address).unwrap();
    let spend: curve25519_dalek::EdwardsPoint = address.spend().into();
    let view: curve25519_dalek::EdwardsPoint = address.view().into();
    let r = DalekScalar::random(&mut OsRng);
    let tx_pub = if address.is_subaddress() {
        r * spend
    } else {
        &r * ED25519_BASEPOINT_TABLE
    };
    let mut derivation = (r * view).mul_by_cofactor().compress().to_bytes().to_vec();
    derivation.push(index);
    let shared: DalekScalar = Scalar::hash(&derivation).into();
    let output_key = &shared * ED25519_BASEPOINT_TABLE + spend;
    let mut mask_input = b"commitment_mask".to_vec();
    mask_input.extend_from_slice(shared.as_bytes());
    let mask: DalekScalar = Scalar::hash(&mask_input).into();
    (
        hex::encode(tx_pub.compress().to_bytes()),
        hex::encode(output_key.compress().to_bytes()),
        mask,
    )
}

/// A `RingCT` output (not a miner one): `rct` carries a commitment to
/// `committed` while the server claims `claimed`.
fn rct_output(tx: u8, address: &str, committed: u64, claimed: u64) -> Value {
    let (tx_pub, key, mask) = pay_with_mask(address, 0);
    let commitment = Commitment::new(Scalar::from(mask), committed)
        .commit()
        .compress();
    let mut out = output(tx, (tx_pub, key), (0, 0), claimed);
    out["rct"] = json!(format!(
        "{}{}{}",
        hex::encode(commitment.to_bytes()),
        hex::encode([0u8; 32]),
        hex::encode([0u8; 8])
    ));
    out
}

fn output(tx: u8, (tx_pub, key): (String, String), sub: (u32, u32), amount: u64) -> Value {
    json!({
        "amount": amount.to_string(), "public_key": key, "index": 0,
        "global_index": "10", "tx_id": 1, "tx_hash": hex::encode([tx; 32]),
        "tx_prefix_hash": hex::encode([0; 32]), "tx_pub_key": tx_pub,
        "timestamp": "2026-10-02T00:00:00Z", "height": 100,
        "recipient": {"maj_i": sub.0, "min_i": sub.1},
    })
}

/// Serves canned answers per route, one connection at a time.
async fn serve(routes: Vec<(&'static str, Value)>) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(async move {
        loop {
            let (mut socket, _) = listener.accept().await.unwrap();
            let routes = routes.clone();
            tokio::spawn(async move {
                let mut request = Vec::new();
                let mut buf = [0u8; 4096];
                // Read headers and the body (Content-Length).
                loop {
                    let n = socket.read(&mut buf).await.unwrap();
                    if n == 0 {
                        return;
                    }
                    request.extend_from_slice(&buf[..n]);
                    let text = String::from_utf8_lossy(&request);
                    if let Some(end) = text.find("\r\n\r\n") {
                        let length = text[..end]
                            .lines()
                            .find_map(|l| {
                                l.to_ascii_lowercase()
                                    .strip_prefix("content-length:")
                                    .map(|v| v.trim().parse::<usize>().unwrap())
                            })
                            .unwrap_or(0);
                        if request.len() >= end + 4 + length {
                            break;
                        }
                    }
                }
                let text = String::from_utf8_lossy(&request);
                let path = text.split_whitespace().nth(1).unwrap_or("/");
                let body = routes
                    .iter()
                    .find(|(route, _)| path == format!("/{route}"))
                    .map_or_else(|| json!({}), |(_, v)| v.clone())
                    .to_string();
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                socket.write_all(response.as_bytes()).await.unwrap();
            });
        }
    });
    url
}

#[tokio::test]
async fn dishonest_outputs_and_spends_are_ignored() {
    let (keys, _) = WalletKeys::generate(SeedFormat::Classic);
    let (stranger, _) = WalletKeys::generate(SeedFormat::Classic);
    let ours = keys.primary_address(Network::Mainnet);
    let our_sub = keys.address(Network::Mainnet, 0, 2).unwrap();

    let routes = vec![
        ("login", json!({"new_address": false, "start_height": 0})),
        (
            "get_address_info",
            json!({"scanned_block_height": 199, "blockchain_height": 199, "start_height": 0}),
        ),
        ("upsert_subaddrs", json!({})),
        (
            "get_unspent_outs",
            json!({"per_byte_fee": "1", "fee_mask": "1", "amount": "0", "outputs": [
                // Really ours.
                output(1, pay(&ours, 0), (0, 0), 5),
                // Really ours, at a subaddress.
                output(2, pay(&our_sub, 0), (0, 2), 7),
                // Someone else's, passed off as ours.
                output(3, pay(&stranger.primary_address(Network::Mainnet), 0), (0, 0), 1_000),
                // Ours, but the server names the wrong subaddress.
                output(4, pay(&our_sub, 0), (0, 3), 9),
                // Ours, with a commitment that opens to the claimed amount.
                rct_output(5, &ours, 11, 11),
                // Ours, but the server inflates the amount.
                rct_output(6, &ours, 3, 3_000),
            ]}),
        ),
        (
            "get_address_txs",
            json!({"transactions": [{
                "hash": hex::encode([9; 32]), "height": 150, "coinbase": false,
                "mempool": false,
                // A spend claim with a key image the wallet never produced.
                "spent_outputs": [{"amount": "5", "key_image": hex::encode([7; 32]),
                                    "tx_pub_key": hex::encode([0; 32]), "out_index": 0, "mixin": 15}],
            }]}),
        ),
    ];
    let url = serve(routes).await;
    let server = LwsServer::new(&NodeUrl::parse(&url).unwrap()).unwrap();

    let mut state = SyncState::default();
    let report = lws_sync(&server, &keys, Network::Mainnet, &[3], 0, true, &mut state)
        .await
        .unwrap();

    assert_eq!(report.rejected_outputs, 3);
    assert_eq!(state.outputs.len(), 3);
    let amounts: Vec<u64> = state
        .outputs
        .iter()
        .map(kn_sync::OwnedOutput::amount)
        .collect();
    assert_eq!(amounts, vec![5, 7, 11]);
    assert!(
        state.outputs.iter().all(|o| o.spent.is_none()),
        "a spend without our key image must not count"
    );
    assert_eq!(state.balance(1_000).total, 23);
    assert_eq!((report.scanned, report.tip), (200, 200));
}
