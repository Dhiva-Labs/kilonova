//! App-wide choices that are not about networks: notifications and
//! background checks (off until the owner turns them on), confirming a
//! light wallet server's payments and broadcasting through another node
//! (both on).

use super::nodes::NodeError;
use crate::node_settings::{load, save};

// Independent on/off choices, not states of one thing.
#[allow(clippy::struct_excessive_bools)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Preferences {
    /// Show a notification for incoming payments while the app is not in
    /// front.
    pub notify_incoming: bool,
    /// Android: check the chosen wallets for payments while the app is
    /// closed (see `api::background`). Linux and Windows: keep syncing with
    /// the window closed. Off until the owner agrees on the consent screen;
    /// turned off by the upgrade that introduced background checks.
    pub background_sync: bool,
    /// LWS-mode wallets confirm each payment the server reports with the
    /// network's node (through the proxy). Each lookup is hidden among
    /// cover lookups, so it is on by default.
    pub confirm_lws_payments: bool,
    /// With a proxy set, publish transactions through a random bundled
    /// node other than the wallet's own, so the node that sees the wallet
    /// sync does not see it send. No effect without a proxy.
    pub broadcast_elsewhere: bool,
}

/// # Errors
///
/// Fails if the settings cannot be read.
pub fn preferences() -> Result<Preferences, NodeError> {
    let settings = load()?;
    Ok(Preferences {
        notify_incoming: settings.notify_incoming,
        background_sync: settings.background_sync,
        confirm_lws_payments: settings.confirm_lws_payments,
        broadcast_elsewhere: settings.broadcast_elsewhere,
    })
}

/// # Errors
///
/// Fails if the settings cannot be saved.
pub fn set_preferences(preferences: Preferences) -> Result<(), NodeError> {
    let mut settings = load()?;
    settings.notify_incoming = preferences.notify_incoming;
    settings.background_sync = preferences.background_sync;
    settings.confirm_lws_payments = preferences.confirm_lws_payments;
    settings.broadcast_elsewhere = preferences.broadcast_elsewhere;
    save(&settings)
}
