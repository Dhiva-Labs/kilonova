//! A light wallet server cannot make Kilonova pay an absurd fee.

use kn_keys::{Network, SeedFormat, WalletKeys};
use kn_sync::{LwsServer, NodeUrl, SyncState};
use kn_tx::{Backend, Priority, Request, TxError, prepare};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

/// Answers every request with `body`.
async fn serve(body: &'static str) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(async move {
        loop {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut buf = vec![0u8; 8192];
            let _ = socket.read(&mut buf).await;
            let reply = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            let _ = socket.write_all(reply.as_bytes()).await;
        }
    });
    url
}

async fn fee_answer(body: &'static str) -> TxError {
    let url = serve(body).await;
    let server = LwsServer::new(
        &NodeUrl::parse(&url).unwrap(),
        &kn_sync::Circuit::app(kn_sync::Purpose::Sync),
    )
    .unwrap();
    let (keys, _) = WalletKeys::generate(SeedFormat::Classic);
    let to = WalletKeys::generate(SeedFormat::Classic)
        .0
        .primary_address(Network::Mainnet);
    // The fee is fetched before anything about the wallet's funds matters.
    prepare(
        Backend::Lws(&server),
        &keys,
        Network::Mainnet,
        &SyncState::default(),
        100,
        &Request::Pay(vec![(to, 1)]),
        Priority::Normal,
    )
    .await
    .unwrap_err()
}

#[tokio::test]
async fn absurd_fee_rates_and_masks_are_refused() {
    assert!(matches!(
        fee_answer(r#"{"per_byte_fee":"1","fee_mask":"10000","fees":[20000,999999999999,3,4]}"#)
            .await,
        TxError::FeeTooHigh
    ));
    assert!(matches!(
        fee_answer(r#"{"per_byte_fee":"20000","fee_mask":"1000000000000"}"#).await,
        TxError::FeeTooHigh
    ));
    // A normal rate gets past the fee check (and then fails for lack of
    // funds in this empty wallet).
    assert!(matches!(
        fee_answer(r#"{"per_byte_fee":"20000","fee_mask":"10000"}"#).await,
        TxError::InsufficientFunds { .. }
    ));
}
