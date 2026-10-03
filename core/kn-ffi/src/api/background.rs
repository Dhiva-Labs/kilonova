//! Checking for payments while the app is closed (Android, opt-in): the
//! view-only data the background worker gets for a wallet the owner chose.
//! The worker itself calls [`crate::background::background_scan`], not
//! through the bridge.
//!
//! Arguments are owned because `flutter_rust_bridge` hands them over that way.
#![allow(clippy::needless_pass_by_value)]

use kn_store::{StoreError, SyncMode as StoreSyncMode};
use kn_sync::{SyncState, WatchMode, WatchState};
use zeroize::Zeroizing;

use super::nodes::{current_node, lws_server};
use super::sync::starting_state;
use super::wallets::store;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackgroundError {
    WrongPassword,
    NotFound,
    /// An offline wallet never goes online, not even to check.
    Cold,
    /// An LWS-mode wallet whose owner has not agreed to share the view key
    /// with the light wallet server now set (or none is set).
    LwsConsentNeeded,
    Storage,
    NotInitialized,
}

impl From<StoreError> for BackgroundError {
    fn from(e: StoreError) -> Self {
        match e {
            StoreError::WrongPasswordOrDamaged => Self::WrongPassword,
            StoreError::NotFound => Self::NotFound,
            _ => Self::Storage,
        }
    }
}

/// The watch state for wallet `id`, after checking `password`: its
/// primary address, private view key and public spend key, where its sync
/// has got to, and the node (full mode) or the light wallet server it
/// already shares the view key with (LWS mode). Never the spend key or the
/// seed. The app hands it to the platform, which keeps it encrypted.
///
/// # Errors
///
/// [`BackgroundError::WrongPassword`] for a wrong password,
/// [`BackgroundError::Cold`] for an offline wallet,
/// [`BackgroundError::LwsConsentNeeded`] for an LWS-mode wallet not yet
/// agreed with the current server.
pub fn export_watch_state(id: String, password: String) -> Result<Vec<u8>, BackgroundError> {
    let password = Zeroizing::new(password);
    let wallet = store()
        .map_err(|_| BackgroundError::NotInitialized)?
        .unlock(&id, password.as_bytes())?;
    if wallet.entry.cold {
        return Err(BackgroundError::Cold);
    }
    let network = wallet.entry.network;
    let (mode, server) = match wallet.entry.mode {
        StoreSyncMode::Full => (
            WatchMode::Full,
            current_node(network.into())
                .map_err(|_| BackgroundError::Storage)?
                .as_str()
                .to_owned(),
        ),
        StoreSyncMode::Lws => {
            let server = lws_server(network.into()).map_err(|_| BackgroundError::Storage)?;
            match server {
                Some(server) if wallet.data.lws_consent.as_deref() == Some(server.as_str()) => {
                    (WatchMode::Lws, server)
                }
                _ => return Err(BackgroundError::LwsConsentNeeded),
            }
        }
    };
    let synced = store()
        .map_err(|_| BackgroundError::NotInitialized)?
        .load_cache(&wallet)
        .ok()
        .flatten()
        .and_then(|bytes| SyncState::from_bytes(&bytes).ok())
        .unwrap_or_else(|| starting_state(&wallet));
    let state = WatchState::new(
        &wallet.entry.id,
        network,
        mode,
        &wallet.keys,
        &wallet.data.next_subaddress,
        &synced,
        &server,
    );
    Ok(state.to_bytes().to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::network::Network;
    use crate::api::wallets::{SeedFormat, SyncMode, create_wallet_from_seed, generate_seed};

    #[test]
    fn exports_view_only_data_after_the_password() {
        crate::test_store::init();
        let seed = generate_seed(SeedFormat::Classic);
        let wallet = create_wallet_from_seed(
            "Watched".into(),
            Network::Stagenet,
            SyncMode::Full,
            seed.words.join(" "),
            "pw".into(),
            Some(1234),
            true,
        )
        .unwrap();
        let id = wallet.summary().unwrap().id;
        let spend = wallet
            .reveal_keys("pw".into())
            .unwrap()
            .secret_spend_key
            .unwrap();
        wallet.lock();

        assert_eq!(
            export_watch_state(id.clone(), "wrong".into()),
            Err(BackgroundError::WrongPassword)
        );
        let bytes = export_watch_state(id.clone(), "pw".into()).unwrap();
        let text = String::from_utf8(bytes.clone()).unwrap();
        assert!(!text.contains(&seed.words[..3].join(" ")));
        assert!(!text.contains(&spend));
        let state = WatchState::from_bytes(&bytes).unwrap();
        assert_eq!(state.wallet, id);
        assert_eq!(state.next_height, 1234);
        assert_eq!(state.mode, WatchMode::Full);
        assert!(state.keys().unwrap().is_view_only());
        assert!(!state.server.is_empty());
    }
}
