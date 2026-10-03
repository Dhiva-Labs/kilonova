//! Payment pushes from the self-hosting kit, end to end: runs
//! `tools/selfhost/test-push.sh` (its own regtest compose project, kn-push,
//! not `tools/devnet`), then reads the wallet's topic the way Kilonova on a
//! desktop does.
//!
//! ```sh
//! cd core && cargo test -p kn-sync --test selfhost_push -- --ignored
//! ```
//!
//! Needs docker (with compose), curl and jq.

use std::path::PathBuf;
use std::process::Command;

use kn_sync::push::{PushCode, poll};
use kn_sync::{Circuit, NodeUrl, Purpose};

const NTFY: &str = "http://127.0.0.1:29480";

#[tokio::test]
#[ignore = "needs docker; runs its own regtest compose project"]
async fn a_payment_is_pushed_without_details() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let selfhost = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tools/selfhost");
    let topic_file = std::env::temp_dir().join(format!("kn-push-topic-{}", std::process::id()));
    let status = Command::new(selfhost.join("test-push.sh"))
        .env("KN_PUSH_KEEP", "1")
        .env("KN_PUSH_TOPIC_FILE", &topic_file)
        .status()
        .expect("runs test-push.sh");
    let topic = std::fs::read_to_string(&topic_file).unwrap_or_default();
    let _ = std::fs::remove_file(&topic_file);

    let found = async {
        if !status.success() {
            return Err("test-push.sh failed".to_owned());
        }
        let code = PushCode::parse(topic.trim()).map_err(|e| format!("topic: {e}"))?;
        let server = NodeUrl::parse(NTFY).unwrap();
        let circuit = Circuit::new("push-test", Purpose::Sync);
        let all = poll(&server, &code.topic, "all", &circuit)
            .await
            .map_err(|e| e.to_string())?;
        let none = poll(&server, &code.topic, &all.since, &circuit)
            .await
            .map_err(|e| e.to_string())?;
        Ok((all, none))
    }
    .await;

    let _ = Command::new("docker")
        .args(["compose", "-p", "kn-push", "-f"])
        .arg(selfhost.join("test/compose.yaml"))
        .args(["down", "-v", "--remove-orphans"])
        .status();

    let (all, none) = found.unwrap();
    assert!(all.arrived >= 1, "no push seen: {all:?}");
    assert_eq!(none.arrived, 0, "pushes are reported once");
}
