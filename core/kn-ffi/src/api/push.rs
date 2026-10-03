//! Payment pushes from the owner's own server (see `tools/selfhost`):
//! which wallets have a push topic, binding a phone's `UnifiedPush` endpoint
//! to it, and polling it on desktops.
//!
//! Stored as plain JSON next to the wallets. A topic tells whoever has it
//! when the wallet receives payments, so it never leaves the device except
//! to the server that made it.
//!
//! Arguments are owned because `flutter_rust_bridge` hands them over that way.
#![allow(clippy::needless_pass_by_value)]

use std::collections::BTreeMap;

use flutter_rust_bridge::frb;
use kn_sync::push::{PushCode, endpoint_topic};
use kn_sync::{Circuit, NodeUrl, Purpose, SyncError};
use serde::{Deserialize, Serialize};

use super::network::Network;
use super::nodes::{NodeError, RUNTIME};
use super::wallets::store;
use crate::node_settings::key;

const SETTINGS: &str = "push";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PushError {
    /// Not a push code.
    BadCode,
    /// The code names no server, and no paired server has one.
    NoServer,
    /// The `UnifiedPush` distributor uses a server other than the wallet's
    /// own; pushes would pass through a third party.
    WrongServer,
    /// An onion server without a Tor proxy set.
    NeedsTor,
    /// The server or its relay could not be reached, or refused.
    Unreachable,
    /// The wallet has no push topic.
    NotSet,
    Storage,
    NotInitialized,
}

impl From<NodeError> for PushError {
    fn from(e: NodeError) -> Self {
        match e {
            NodeError::NotInitialized => Self::NotInitialized,
            NodeError::Storage => Self::Storage,
            _ => Self::Unreachable,
        }
    }
}

impl From<SyncError> for PushError {
    fn from(e: SyncError) -> Self {
        match e {
            SyncError::NeedsProxy => Self::NeedsTor,
            SyncError::BadNodeUrl => Self::BadCode,
            _ => Self::Unreachable,
        }
    }
}

/// A wallet's push topic and the server (ntfy) it is on.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PushSubscription {
    pub wallet_id: String,
    pub server: String,
    pub topic: String,
}

#[frb(ignore)]
#[derive(Default, Serialize, Deserialize)]
struct Stored {
    /// The push server each paired network's code named.
    #[serde(default)]
    servers: BTreeMap<String, String>,
    #[serde(default)]
    wallets: BTreeMap<String, PushSubscription>,
}

fn load() -> Result<Stored, PushError> {
    let bytes = store()
        .map_err(|_| PushError::NotInitialized)?
        .read_settings(SETTINGS)
        .map_err(|_| PushError::Storage)?;
    Ok(bytes
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default())
}

fn save(stored: &Stored) -> Result<(), PushError> {
    let bytes = serde_json::to_vec_pretty(stored).map_err(|_| PushError::Storage)?;
    store()
        .map_err(|_| PushError::NotInitialized)?
        .write_settings(SETTINGS, &bytes)
        .map_err(|_| PushError::Storage)
}

/// Remembers the push server a pairing code named for `network`.
pub(crate) fn remember_server(network: Network, server: &NodeUrl) -> Result<(), NodeError> {
    let mut stored = load().map_err(|_| NodeError::Storage)?;
    stored
        .servers
        .insert(key(network).to_owned(), server.as_str().to_owned());
    save(&stored).map_err(|_| NodeError::Storage)
}

/// The push server the pairing code for `network` named, if any.
///
/// # Errors
///
/// Fails if the settings cannot be read.
pub fn push_server(network: Network) -> Result<Option<String>, PushError> {
    Ok(load()?.servers.remove(key(network)))
}

/// Every wallet's push topic.
///
/// # Errors
///
/// Fails if the settings cannot be read.
pub fn push_subscriptions() -> Result<Vec<PushSubscription>, PushError> {
    Ok(load()?.wallets.into_values().collect())
}

/// Sets `wallet_id`'s push topic from the code `push-register` printed.
/// A code without a server uses the one paired for `network`.
///
/// # Errors
///
/// [`PushError::BadCode`] or [`PushError::NoServer`].
pub fn set_push_subscription(
    wallet_id: String,
    network: Network,
    code: String,
) -> Result<PushSubscription, PushError> {
    let code = PushCode::parse(&code).map_err(|_| PushError::BadCode)?;
    let mut stored = load()?;
    let server = match code.server {
        Some(server) => server.as_str().to_owned(),
        None => stored
            .servers
            .get(key(network))
            .cloned()
            .ok_or(PushError::NoServer)?,
    };
    let subscription = PushSubscription {
        wallet_id: wallet_id.clone(),
        server,
        topic: code.topic,
    };
    stored.wallets.insert(wallet_id, subscription.clone());
    save(&stored)?;
    Ok(subscription)
}

/// Forgets `wallet_id`'s push topic.
///
/// # Errors
///
/// Fails if the settings cannot be saved.
pub fn remove_push_subscription(wallet_id: String) -> Result<(), PushError> {
    let mut stored = load()?;
    if stored.wallets.remove(&wallet_id).is_some() {
        save(&stored)?;
    }
    Ok(())
}

fn subscription(wallet_id: &str) -> Result<(PushSubscription, NodeUrl), PushError> {
    let sub = load()?.wallets.remove(wallet_id).ok_or(PushError::NotSet)?;
    let server = NodeUrl::parse(&sub.server).map_err(|_| PushError::BadCode)?;
    Ok((sub, server))
}

/// Asks the server to repeat `wallet_id`'s pushes on a phone's `UnifiedPush`
/// `endpoint`, which must be on the same server. Goes through the proxy,
/// on the wallet's sync circuit (the server is the wallet's own).
///
/// # Errors
///
/// [`PushError::WrongServer`] for an endpoint elsewhere; otherwise as
/// [`PushError`] says.
pub fn bind_push_endpoint(wallet_id: String, endpoint: String) -> Result<(), PushError> {
    let (sub, server) = subscription(&wallet_id)?;
    let bound = endpoint_topic(&server, &endpoint).map_err(|_| PushError::WrongServer)?;
    let circuit = Circuit::new(&wallet_id, Purpose::Sync);
    RUNTIME.block_on(kn_sync::push::bind(&server, &sub.topic, &bound, &circuit))?;
    Ok(())
}

/// What [`poll_push`] found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushPoll {
    /// Pushes since `since`.
    pub arrived: u32,
    /// What to pass as `since` next time.
    pub since: String,
}

/// Looks for pushes on `wallet_id`'s topic since `since` (an id from the
/// last poll, or a Unix time in seconds), through the proxy.
///
/// # Errors
///
/// As [`PushError`] says.
pub fn poll_push(wallet_id: String, since: String) -> Result<PushPoll, PushError> {
    let (sub, server) = subscription(&wallet_id)?;
    let circuit = Circuit::new(&wallet_id, Purpose::Sync);
    let poll = RUNTIME.block_on(kn_sync::push::poll(&server, &sub.topic, &since, &circuit))?;
    Ok(PushPoll {
        arrived: poll.arrived,
        since: poll.since,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn errors_say_what_to_fix() {
        assert_eq!(PushError::from(SyncError::NeedsProxy), PushError::NeedsTor);
        assert_eq!(PushError::from(SyncError::BadNodeUrl), PushError::BadCode);
        assert_eq!(
            PushError::from(SyncError::Node("down".into())),
            PushError::Unreachable
        );
    }
}
