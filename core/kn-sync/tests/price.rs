//! The price request asks for one currency and reads the answer strictly.

use kn_sync::{NodeUrl, SyncError, xmr_price};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

/// Answers every request with `body` and returns the first request line.
async fn serve(body: &'static str) -> (String, tokio::sync::oneshot::Receiver<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let (tx, rx) = tokio::sync::oneshot::channel();
    tokio::spawn(async move {
        let mut tx = Some(tx);
        loop {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut buf = vec![0u8; 4096];
            let n = socket.read(&mut buf).await.unwrap();
            let request = String::from_utf8_lossy(&buf[..n]).to_string();
            if let Some(tx) = tx.take() {
                let _ = tx.send(request.lines().next().unwrap_or_default().to_owned());
            }
            let reply = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            socket.write_all(reply.as_bytes()).await.unwrap();
        }
    });
    (url, rx)
}

#[tokio::test]
async fn reads_the_price_for_the_chosen_currency() {
    let (url, request) = serve(r#"{"monero":{"inr":31415.5}}"#).await;
    let source = NodeUrl::parse(&url).unwrap();
    assert!((xmr_price(&source, "inr").await.unwrap() - 31415.5).abs() < f64::EPSILON);
    assert_eq!(
        request.await.unwrap(),
        "GET /api/v3/simple/price?ids=monero&vs_currencies=inr HTTP/1.1"
    );
    assert!(matches!(
        xmr_price(&source, "doge").await,
        Err(SyncError::BadNodeUrl)
    ));
}

#[tokio::test]
async fn rejects_answers_without_a_usable_price() {
    for body in [r#"{"monero":{}}"#, r#"{"monero":{"usd":-1}}"#, "not json"] {
        let (url, _) = serve(body).await;
        let source = NodeUrl::parse(&url).unwrap();
        assert!(xmr_price(&source, "usd").await.is_err(), "{body}");
    }
}
