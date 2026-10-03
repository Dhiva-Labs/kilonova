//! A light wallet server receives the view key, so Kilonova talks to one
//! only over a channel nobody else can read.

use kn_sync::{LwsServer, NodeUrl, SyncError};

#[test]
fn plain_http_to_another_machine_is_refused() {
    for url in ["http://lws.example.org:8443", "http://192.168.1.10:8443"] {
        assert!(
            matches!(
                LwsServer::new(
                    &NodeUrl::parse(url).unwrap(),
                    &kn_sync::Circuit::app(kn_sync::Purpose::Sync)
                ),
                Err(SyncError::InsecureLws)
            ),
            "{url}"
        );
    }
    for url in [
        "https://lws.example.org:8443",
        "http://127.0.0.1:8443",
        "http://localhost:8443",
        "http://[::1]:8443",
    ] {
        assert!(
            LwsServer::new(
                &NodeUrl::parse(url).unwrap(),
                &kn_sync::Circuit::app(kn_sync::Purpose::Sync)
            )
            .is_ok(),
            "{url}"
        );
    }
}

#[test]
fn host_and_port_mean_https_for_servers() {
    assert_eq!(
        NodeUrl::parse_https_default("lws.example.org:8443")
            .unwrap()
            .as_str(),
        "https://lws.example.org:8443"
    );
    assert_eq!(
        NodeUrl::parse_https_default("http://127.0.0.1:8443")
            .unwrap()
            .as_str(),
        "http://127.0.0.1:8443"
    );
    // Nodes see no keys and usually serve plain http.
    assert_eq!(
        NodeUrl::parse("node.example.org:18081").unwrap().as_str(),
        "http://node.example.org:18081"
    );
}

#[test]
fn onion_names_are_recognized_with_a_trailing_dot() {
    for url in ["http://abc.onion:18081", "http://ABC.ONION.:18081"] {
        let parsed = NodeUrl::parse(url).unwrap();
        assert!(parsed.is_onion(), "{url}");
        assert!(parsed.is_private_channel(), "{url}");
    }
}
