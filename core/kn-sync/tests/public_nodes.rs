//! Checks the bundled public nodes. Needs internet access, so ignored by
//! default; the weekly node-list workflow runs it:
//!
//! ```sh
//! cargo test -p kn-sync --test public_nodes -- --ignored
//! ```

use std::sync::atomic::AtomicBool;

use kn_keys::{Network, SeedFormat, WalletKeys};
use kn_sync::{SyncState, bundled_nodes, connect, sync};

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs internet access"]
async fn every_bundled_node_answers_on_its_network() {
    let mut failures = Vec::new();
    for network in [Network::Mainnet, Network::Stagenet, Network::Testnet] {
        for node in bundled_nodes(network) {
            match connect(&node, network).await {
                Ok((_, status)) if status.height + 10 >= status.target_height => {}
                Ok((_, status)) => failures.push(format!(
                    "{}: behind ({} of {})",
                    node.as_str(),
                    status.height,
                    status.target_height
                )),
                Err(e) => failures.push(format!("{}: {e}", node.as_str())),
            }
        }
    }
    assert!(
        failures.is_empty(),
        "unhealthy nodes:\n{}",
        failures.join("\n")
    );
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs internet access"]
async fn scans_recent_stagenet_blocks_from_a_public_node() {
    let node = &bundled_nodes(Network::Stagenet)[0];
    let (daemon, status) = connect(node, Network::Stagenet).await.unwrap();
    let (keys, _) = WalletKeys::generate(SeedFormat::Polyseed);
    let mut state = SyncState::starting_at(status.height - 20);
    let mut reports = 0;
    sync(
        &daemon,
        &keys,
        &[1],
        &mut state,
        &AtomicBool::new(false),
        |_, _| {
            reports += 1;
        },
    )
    .await
    .unwrap();
    assert!(state.next_height >= status.height);
    assert!(state.outputs.is_empty(), "a fresh wallet owns nothing");
    assert!(reports >= 1);
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs internet access"]
async fn refuses_a_node_on_another_network() {
    let node = &bundled_nodes(Network::Stagenet)[0];
    assert!(matches!(
        connect(node, Network::Mainnet).await,
        Err(kn_sync::SyncError::WrongNetwork)
    ));
}
