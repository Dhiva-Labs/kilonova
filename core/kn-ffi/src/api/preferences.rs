//! App-wide choices that are not about networks: notifications and
//! background sync (off until the owner turns them on), and confirming a
//! light wallet server's payments (on).

use super::nodes::NodeError;
use crate::node_settings::{load, save};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Preferences {
    /// Show a notification for incoming payments while the app is not in
    /// front.
    pub notify_incoming: bool,
    /// Android: keep unlocked wallets syncing in the background instead of
    /// locking them when the app leaves the screen.
    pub background_sync: bool,
    /// LWS-mode wallets confirm each payment the server reports with the
    /// network's node (through the proxy). Each lookup is hidden among
    /// cover lookups, so it is on by default.
    pub confirm_lws_payments: bool,
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
    save(&settings)
}
