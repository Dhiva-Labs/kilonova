//! Traffic goes through the configured SOCKS5 proxy, host names are
//! resolved by the proxy, onion addresses are refused without one, and
//! each wallet and purpose gets its own SOCKS credentials (so its own Tor
//! circuit).

use std::sync::{Arc, Mutex};

use kn_keys::Network;
use kn_sync::{Circuit, NodeUrl, ProxyUrl, Purpose, SyncError, check_lws, check_proxy, set_proxy};
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

/// One connection a fake proxy forwarded: the host asked for and the
/// username and password given, if any.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Seen {
    host: String,
    credentials: Option<(String, String)>,
}

/// A SOCKS5 proxy that records what each connection asks for and sends it
/// to `upstream`. With `takes_credentials` it picks username/password
/// authentication when offered and accepts any values, as Tor does;
/// without, it only knows "no authentication".
async fn fake_socks(upstream: u16, takes_credentials: bool, seen: Arc<Mutex<Vec<Seen>>>) -> u16 {
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
                let method = if takes_credentials && methods.contains(&2) {
                    2
                } else if methods.contains(&0) {
                    0
                } else {
                    0xff
                };
                client.write_all(&[5, method]).await.unwrap();
                let mut credentials = None;
                if method == 2 {
                    // RFC 1929: version 1, username, password.
                    let mut head = [0u8; 2];
                    if client.read_exact(&mut head).await.is_err() {
                        return; // check_proxy stops after the greeting
                    }
                    let mut user = vec![0u8; usize::from(head[1])];
                    client.read_exact(&mut user).await.unwrap();
                    let mut len = [0u8; 1];
                    client.read_exact(&mut len).await.unwrap();
                    let mut password = vec![0u8; usize::from(len[0])];
                    client.read_exact(&mut password).await.unwrap();
                    client.write_all(&[1, 0]).await.unwrap();
                    credentials = Some((
                        String::from_utf8(user).unwrap(),
                        String::from_utf8(password).unwrap(),
                    ));
                } else if method != 0 {
                    return;
                }
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
                seen.lock().unwrap().push(Seen { host, credentials });
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
        check_lws(
            &onion,
            Network::Mainnet,
            &kn_sync::Circuit::app(kn_sync::Purpose::Sync)
        )
        .await,
        Err(SyncError::NeedsProxy)
    ));

    let lws = fake_lws().await;
    let seen = Arc::new(Mutex::new(Vec::new()));
    let socks = fake_socks(lws, true, seen.clone()).await;
    let proxy = ProxyUrl::parse(&format!("127.0.0.1:{socks}")).unwrap();
    check_proxy(&proxy).await.unwrap();
    // Something that is not a SOCKS5 proxy fails the check.
    assert!(
        check_proxy(&ProxyUrl::parse(&format!("127.0.0.1:{lws}")).unwrap())
            .await
            .is_err()
    );

    set_proxy(Some(proxy));
    let app = Circuit::app(Purpose::Discovery);
    // Plain http to a named host would expose the view key; refused before
    // anything is sent, proxy or not.
    let named = NodeUrl::parse("http://lws.kilonova.invalid:8443").unwrap();
    assert!(matches!(
        check_lws(&named, Network::Mainnet, &app).await,
        Err(SyncError::InsecureLws)
    ));
    // Onion names resolve only inside Tor: reaching one proves the name
    // went to the proxy.
    let info = check_lws(&onion, Network::Mainnet, &app).await.unwrap();
    assert_eq!(info.height, 42);
    assert_eq!(info.server_type.as_deref(), Some("fake"));
    let host = "kilonovaexampleexampleexampleexampleexampleexample.onion";
    assert_eq!(seen.lock().unwrap().len(), 1);
    assert_eq!(seen.lock().unwrap()[0].host, host);
    seen.lock().unwrap().clear();

    // Each wallet, and each purpose of one wallet, uses its own
    // credentials; the same wallet and purpose always the same ones.
    let circuits = [
        Circuit::new("wallet-a", Purpose::Sync),
        Circuit::new("wallet-a", Purpose::Sync),
        Circuit::new("wallet-b", Purpose::Sync),
        Circuit::new("wallet-a", Purpose::Broadcast),
    ];
    for circuit in &circuits {
        check_lws(&onion, Network::Mainnet, circuit).await.unwrap();
    }
    let used: Vec<_> = seen
        .lock()
        .unwrap()
        .iter()
        .map(|s| s.credentials.clone().expect("credentials were sent"))
        .collect();
    assert_eq!(used.len(), 4, "one connection each");
    assert_eq!(used[0], used[1], "same wallet and purpose");
    assert_ne!(used[0], used[2], "two wallets");
    assert_ne!(used[0], used[3], "two purposes of one wallet");
    assert_eq!(used[0], circuits[0].socks_credentials());
    for (user, password) in &used {
        assert!(!user.contains("wallet") && !password.contains("wallet"));
    }

    // A proxy that takes no credentials gets none, and still works.
    let plain_seen = Arc::new(Mutex::new(Vec::new()));
    let plain = fake_socks(lws, false, plain_seen.clone()).await;
    set_proxy(Some(
        ProxyUrl::parse(&format!("127.0.0.1:{plain}")).unwrap(),
    ));
    check_lws(&onion, Network::Mainnet, &circuits[0])
        .await
        .unwrap();
    assert_eq!(
        *plain_seen.lock().unwrap(),
        [Seen {
            host: host.into(),
            credentials: None
        }]
    );
    set_proxy(None);
}
