//! Storage for node choices; the API is in `api::nodes`. Kept outside
//! `api` so the bridge generator does not export these internals.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::api::network::Network;
use crate::api::nodes::NodeError;
use crate::api::wallets::store;

const SETTINGS: &str = "nodes";

#[derive(Default, Serialize, Deserialize)]
pub(crate) struct PerNetwork {
    pub(crate) selected: Option<String>,
    pub(crate) custom: Vec<String>,
    /// The light wallet server for LWS-mode wallets. There is no default:
    /// it receives view keys, so only the user chooses it.
    #[serde(default)]
    pub(crate) lws: Option<String>,
}

// Independent on/off choices, not states of one thing.
#[allow(clippy::struct_excessive_bools)]
#[derive(Serialize, Deserialize)]
pub(crate) struct Settings {
    #[serde(flatten)]
    pub(crate) networks: BTreeMap<String, PerNetwork>,
    /// SOCKS5 proxy for all traffic, as `socks5h://host:port`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) proxy: Option<String>,
    /// Currency for the optional fiat price; `None` means prices are off
    /// and the price service is never contacted.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) price_currency: Option<String>,
    /// Notify about incoming payments while the app is not in front.
    #[serde(default)]
    pub(crate) notify_incoming: bool,
    /// Android: check the wallets the owner chose for payments while the
    /// app is closed. Linux and Windows: keep syncing with the window
    /// closed. Both only after the consent screen. Stored under a new name
    /// so the old Android setting, which kept wallets unlocked in the
    /// background, is off after upgrading and the owner opts in again.
    #[serde(rename = "background_checks", default)]
    pub(crate) background_sync: bool,
    /// The setting before background checks, read so it is not taken for
    /// a network name and otherwise ignored.
    #[serde(rename = "background_sync", default, skip_serializing)]
    pub(crate) _old_background_sync: Option<serde::de::IgnoredAny>,
    /// LWS-mode wallets confirm each payment the server reports with the
    /// network's node, hidden among cover lookups. On by default; stored
    /// under a new name so the old key, which was saved as off by default
    /// before cover lookups existed, does not keep it off.
    #[serde(rename = "lws_cross_check", default = "on")]
    pub(crate) confirm_lws_payments: bool,
    /// The pre-cover setting, read so it is not taken for a network name
    /// and otherwise ignored.
    #[serde(rename = "confirm_lws_payments", default, skip_serializing)]
    pub(crate) _old_confirm_lws_payments: Option<serde::de::IgnoredAny>,
    /// With a proxy set, publish transactions through a random bundled
    /// node other than the wallet's own. On by default; no effect without
    /// a proxy.
    #[serde(default = "on")]
    pub(crate) broadcast_elsewhere: bool,
    /// Pinned certificate fingerprints by https address.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub(crate) pins: BTreeMap<String, String>,
}

fn on() -> bool {
    true
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            networks: BTreeMap::new(),
            proxy: None,
            price_currency: None,
            notify_incoming: false,
            background_sync: false,
            _old_background_sync: None,
            confirm_lws_payments: on(),
            _old_confirm_lws_payments: None,
            broadcast_elsewhere: on(),
            pins: BTreeMap::new(),
        }
    }
}

pub(crate) fn key(network: Network) -> &'static str {
    match network {
        Network::Mainnet => "mainnet",
        Network::Stagenet => "stagenet",
        Network::Testnet => "testnet",
    }
}

pub(crate) fn load() -> Result<Settings, NodeError> {
    let bytes = store()
        .map_err(|_| NodeError::NotInitialized)?
        .read_settings(SETTINGS)
        .map_err(|_| NodeError::Storage)?;
    // A damaged settings file falls back to defaults rather than blocking
    // sync; it holds nothing that cannot be chosen again.
    Ok(bytes
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default())
}

pub(crate) fn save(settings: &Settings) -> Result<(), NodeError> {
    let bytes = serde_json::to_vec_pretty(settings).map_err(|_| NodeError::Storage)?;
    store()
        .map_err(|_| NodeError::NotInitialized)?
        .write_settings(SETTINGS, &bytes)
        .map_err(|_| NodeError::Storage)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn background_sync_from_before_background_checks_is_off() {
        let old = br#"{"mainnet": {"selected": "http://n:1", "custom": []},
                       "background_sync": true, "notify_incoming": true}"#;
        let settings: Settings = serde_json::from_slice(old).unwrap();
        assert!(!settings.background_sync, "opt in again after upgrading");
        assert!(settings.notify_incoming);
        assert!(!settings.networks.contains_key("background_sync"));

        let on = Settings {
            background_sync: true,
            ..Settings::default()
        };
        let saved = serde_json::to_vec(&on).unwrap();
        assert!(!String::from_utf8_lossy(&saved).contains("\"background_sync\""));
        let again: Settings = serde_json::from_slice(&saved).unwrap();
        assert!(again.background_sync, "a choice made now is kept");
    }

    #[test]
    fn confirming_lws_payments_is_on_even_for_settings_saved_with_it_off() {
        let old = br#"{"mainnet": {"selected": "http://n:1", "custom": []},
                       "confirm_lws_payments": false}"#;
        let settings: Settings = serde_json::from_slice(old).unwrap();
        assert!(settings.confirm_lws_payments);
        assert_eq!(
            settings.networks["mainnet"].selected.as_deref(),
            Some("http://n:1")
        );
        assert!(Settings::default().confirm_lws_payments);
        assert!(settings.broadcast_elsewhere, "on unless turned off");

        let off = Settings {
            confirm_lws_payments: false,
            ..Settings::default()
        };
        let saved = serde_json::to_vec(&off).unwrap();
        let again: Settings = serde_json::from_slice(&saved).unwrap();
        assert!(!again.confirm_lws_payments, "a choice made now is kept");
    }
}
