//! Traffic goes through the configured SOCKS5 proxy, host names are
//! resolved by the proxy, and onion addresses are refused without one.

use std::sync::{Arc, Mutex};

use kn_keys::Network;
use kn_sync::{NodeUrl, ProxyUrl, SyncError, check_lws, check_proxy, set_proxy};
use tokio::io::{AsyncReadExt, AsyncWriteExt, copy_bidirectional};
use tokio::net::{TcpListener, TcpStream};

/// A light wallet server that answers `get_version`.
async fn fake_lws() -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        loop {
            let (mut socket, _) = listener.accept().await.unwrap();
            tokio::spawn(async move {
                let mut buf = vec![0u8; 4096];
                let _ = socket.read(&mut buf).await;
                let body = r#"{"server_type":"fake","blockchain_height":42,"network_type":"main"}"#;
                let reply = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = socket.write_all(reply.as_bytes()).await;
            });
        }
    });
    port
}

/// A SOCKS5 proxy (no authentication) that records the host names it is
/// asked to connect to and sends every connection to `upstream`.
async fn fake_socks(upstream: u16, seen: Arc<Mutex<Vec<String>>>) -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        loop {
            let (mut client, _) = listener.accept().await.unwrap();
            let seen = seen.clone();
            tokio::spawn(async move {
                let mut greeting = [0u8; 2];
                client.read_exact(&mut greeting).await.unwrap();
                let mut methods = vec![0u8; usize::from(greeting[1])];
                client.read_exact(&mut methods).await.unwrap();
                client.write_all(&[5, 0]).await.unwrap();
                let mut head = [0u8; 4];
                if client.read_exact(&mut head).await.is_err() {
                    return; // check_proxy stops after the greeting
                }
                let host = match head[3] {
                    3 => {
                        let mut len = [0u8; 1];
                        client.read_exact(&mut len).await.unwrap();
                        let mut name = vec![0u8; usize::from(len[0])];
                        client.read_exact(&mut name).await.unwrap();
                        String::from_utf8(name).unwrap()
                    }
                    1 => {
                        let mut ip = [0u8; 4];
                        client.read_exact(&mut ip).await.unwrap();
                        format!("ip:{ip:?}")
                    }
                    other => panic!("address type {other}"),
                };
                let mut target_port = [0u8; 2];
                client.read_exact(&mut target_port).await.unwrap();
                seen.lock().unwrap().push(host);
                client
                    .write_all(&[5, 0, 0, 1, 127, 0, 0, 1, 0, 0])
                    .await
                    .unwrap();
                let mut server = TcpStream::connect(("127.0.0.1", upstream)).await.unwrap();
                let _ = copy_bidirectional(&mut client, &mut server).await;
            });
        }
    });
    port
}

#[test]
fn proxy_addresses_are_normalized() {
    for (input, expected) in [
        ("127.0.0.1:9050", "socks5h://127.0.0.1:9050"),
        ("socks5://localhost:9150", "socks5h://localhost:9150"),
        (" socks5h://10.0.0.2:1080/ ", "socks5h://10.0.0.2:1080"),
    ] {
        assert_eq!(ProxyUrl::parse(input).unwrap().as_str(), expected);
    }
    for bad in ["", "127.0.0.1", "http://127.0.0.1:9050", "socks5h://:9050"] {
        assert!(
            matches!(ProxyUrl::parse(bad), Err(SyncError::BadProxyUrl)),
            "{bad}"
        );
    }
}

// One test, because the proxy setting is process-wide.
#[tokio::test(flavor = "multi_thread")]
async fn requests_go_through_the_proxy() {
    let onion =
        NodeUrl::parse("http://kilonovaexampleexampleexampleexampleexampleexample.onion:18089")
            .unwrap();
    assert!(onion.is_onion());
    set_proxy(None);
    assert!(matches!(
        check_lws(&onion, Network::Mainnet).await,
        Err(SyncError::NeedsProxy)
    ));

    let lws = fake_lws().await;
    let seen = Arc::new(Mutex::new(Vec::new()));
    let socks = fake_socks(lws, seen.clone()).await;
    let proxy = ProxyUrl::parse(&format!("127.0.0.1:{socks}")).unwrap();
    check_proxy(&proxy).await.unwrap();
    // Something that is not a SOCKS5 proxy fails the check.
    assert!(
        check_proxy(&ProxyUrl::parse(&format!("127.0.0.1:{lws}")).unwrap())
            .await
            .is_err()
    );

    set_proxy(Some(proxy));
    // A name no resolver here knows: only the proxy can look it up.
    let named = NodeUrl::parse("http://lws.kilonova.invalid:8443").unwrap();
    let info = check_lws(&named, Network::Mainnet).await.unwrap();
    assert_eq!(info.height, 42);
    let info = check_lws(&onion, Network::Mainnet).await.unwrap();
    assert_eq!(info.server_type.as_deref(), Some("fake"));
    set_proxy(None);

    assert_eq!(
        *seen.lock().unwrap(),
        [
            "lws.kilonova.invalid",
            "kilonovaexampleexampleexampleexampleexampleexample.onion"
        ]
    );
}
