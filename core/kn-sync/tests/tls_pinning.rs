//! A node with a self-signed certificate is refused until the user pins
//! that certificate, and then trusted for that certificate only.

use std::sync::Arc;

use kn_keys::Network;
use kn_sync::{NodeUrl, check_lws, fingerprint, server_certificate, set_pins};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio_rustls::TlsAcceptor;
use tokio_rustls::rustls::ServerConfig;
use tokio_rustls::rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};

/// An HTTPS light wallet server with a fresh self-signed certificate.
/// Returns its port and the certificate.
async fn self_signed_lws() -> (u16, Vec<u8>) {
    let _ = tokio_rustls::rustls::crypto::ring::default_provider().install_default();
    let generated = rcgen::generate_simple_self_signed(vec!["localhost".into()]).unwrap();
    let cert = generated.cert.der().to_vec();
    let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(
        generated.signing_key.serialize_der(),
    ));
    let config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(vec![CertificateDer::from(cert.clone())], key)
        .unwrap();
    let acceptor = TlsAcceptor::from(Arc::new(config));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        loop {
            let (socket, _) = listener.accept().await.unwrap();
            let acceptor = acceptor.clone();
            tokio::spawn(async move {
                let Ok(mut tls) = acceptor.accept(socket).await else {
                    return; // refused by the client
                };
                let mut buf = vec![0u8; 4096];
                let _ = tls.read(&mut buf).await;
                let body =
                    r#"{"server_type":"pinned","blockchain_height":7,"network_type":"main"}"#;
                let reply = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = tls.write_all(reply.as_bytes()).await;
                let _ = tls.shutdown().await;
            });
        }
    });
    (port, cert)
}

// One test, because pins are process-wide.
#[tokio::test(flavor = "multi_thread")]
async fn self_signed_servers_need_a_pin() {
    let (port, cert) = self_signed_lws().await;
    let url = NodeUrl::parse(&format!("https://localhost:{port}")).unwrap();

    let info = server_certificate(&url).await.unwrap();
    assert_eq!(info.fingerprint, fingerprint(&cert));
    assert!(!info.publicly_trusted);
    assert!(
        server_certificate(&NodeUrl::parse("http://localhost:1").unwrap())
            .await
            .is_err()
    );

    set_pins([]);
    assert!(check_lws(&url, Network::Mainnet).await.is_err(), "no pin");

    set_pins([(url.clone(), info.fingerprint)]);
    let reply = check_lws(&url, Network::Mainnet).await.unwrap();
    assert_eq!(reply.server_type.as_deref(), Some("pinned"));

    // A different certificate under the same address is refused.
    set_pins([(url.clone(), [7; 32])]);
    assert!(check_lws(&url, Network::Mainnet).await.is_err());

    // A pin applies to its address only.
    let other = NodeUrl::parse(&format!("https://127.0.0.1:{port}")).unwrap();
    set_pins([(url, info.fingerprint)]);
    assert!(check_lws(&other, Network::Mainnet).await.is_err());
    set_pins([]);
}
