//! Sending from an unlocked wallet, in two steps so the owner sees exactly
//! what will happen before anything leaves the device: [`OpenWallet::prepare_send`]
//! builds and signs a transaction, [`OpenWallet::confirm_send`] checks the
//! password again and publishes it.
//!
//! Full-mode wallets get decoys and fees from their node and publish
//! through it; LWS-mode wallets use their light wallet server for both.
//!
//! Arguments are owned because `flutter_rust_bridge` hands them over that way.
#![allow(clippy::needless_pass_by_value)]

use std::sync::Mutex;

use flutter_rust_bridge::frb;
use kn_keys::WalletKeys;
use kn_store::SyncMode as StoreSyncMode;
use kn_sync::{LwsServer, NodeUrl, SyncState, connect};
use kn_tx::{Backend, Prepared, Priority, Request, TxError};
use zeroize::Zeroizing;

use super::network::Network;
use super::nodes::{RUNTIME, current_node, lws_server};
use super::sync::hex_string;
use super::wallets::{OpenWallet, WalletError, store};

/// Why sending failed. The app maps each case to its own message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SendError {
    BadAddress,
    ZeroAmount,
    TooManyPayments,
    InsufficientFunds,
    TooManyInputs,
    ViewOnly,
    /// The node or server suggested an absurd fee rate.
    FeeTooHigh,
    /// Sync has not reached the chain tip yet.
    NotSynced,
    /// The node or light wallet server could not be reached or could not
    /// provide decoys or fees.
    Unreachable,
    /// The network refused the transaction.
    Rejected,
    /// The transaction could not be built.
    Build,
    LwsServerNotSet,
    LwsConsentNeeded,
    WrongPassword,
    /// This prepared transaction was already published or discarded.
    AlreadyUsed,
    /// The wallet was locked.
    Locked,
    Storage,
}

impl From<TxError> for SendError {
    fn from(e: TxError) -> Self {
        match e {
            TxError::BadAddress(_) => Self::BadAddress,
            TxError::ZeroAmount => Self::ZeroAmount,
            TxError::TooManyPayments => Self::TooManyPayments,
            TxError::InsufficientFunds { .. } => Self::InsufficientFunds,
            TxError::TooManyInputs => Self::TooManyInputs,
            TxError::ViewOnly => Self::ViewOnly,
            TxError::FeeTooHigh => Self::FeeTooHigh,
            TxError::Node(_) => Self::Unreachable,
            TxError::Rejected(_) => Self::Rejected,
            TxError::Build(_) => Self::Build,
        }
    }
}

impl From<WalletError> for SendError {
    fn from(e: WalletError) -> Self {
        match e {
            WalletError::WrongPassword => Self::WrongPassword,
            WalletError::NotFound => Self::Locked,
            _ => Self::Storage,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FeePriority {
    Low,
    Normal,
    High,
    Urgent,
}

impl From<FeePriority> for Priority {
    fn from(p: FeePriority) -> Self {
        match p {
            FeePriority::Low => Self::Low,
            FeePriority::Normal => Self::Normal,
            FeePriority::High => Self::High,
            FeePriority::Urgent => Self::Urgent,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AddressKind {
    Standard,
    Subaddress,
    Integrated,
}

/// One recipient.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Payment {
    pub address: String,
    /// Atomic units.
    pub amount: u64,
}

/// What a prepared transaction will do, for the confirmation screen.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SendSummary {
    pub tx_hash: String,
    /// Recipients with what each receives. For a sweep, the one recipient
    /// receives everything minus the fee.
    pub payments: Vec<Payment>,
    pub fee: u64,
    /// Returned to this wallet.
    pub change: u64,
    /// The node or light wallet server that will publish it.
    pub via: String,
}

/// A signed transaction waiting for the owner's confirmation. It can be
/// published once.
#[frb(opaque)]
pub struct PreparedSend {
    prepared: Mutex<Option<Prepared>>,
    summary: SendSummary,
    route: Route,
    tip: u64,
}

impl PreparedSend {
    #[frb(sync)]
    #[must_use]
    pub fn summary(&self) -> SendSummary {
        self.summary.clone()
    }
}

/// Where decoys and fees came from, and so where the transaction goes.
#[derive(Clone)]
enum Route {
    Node(NodeUrl),
    Lws(NodeUrl),
}

impl Route {
    fn url(&self) -> &NodeUrl {
        match self {
            Self::Node(url) | Self::Lws(url) => url,
        }
    }

    async fn prepare(
        &self,
        keys: &WalletKeys,
        network: kn_keys::Network,
        state: &SyncState,
        tip: u64,
        request: &Request,
        priority: Priority,
    ) -> Result<Prepared, SendError> {
        Ok(match self {
            Self::Node(url) => {
                let (daemon, _) = connect(url, network)
                    .await
                    .map_err(|_| SendError::Unreachable)?;
                let backend = Backend::Node(&daemon);
                kn_tx::prepare(backend, keys, network, state, tip, request, priority).await?
            }
            Self::Lws(url) => {
                let server = LwsServer::new(url).map_err(|_| SendError::Unreachable)?;
                let backend = Backend::Lws(&server);
                kn_tx::prepare(backend, keys, network, state, tip, request, priority).await?
            }
        })
    }

    async fn publish(
        &self,
        network: kn_keys::Network,
        prepared: &Prepared,
        state: &mut SyncState,
        tip: u64,
    ) -> Result<(), SendError> {
        match self {
            Self::Node(url) => {
                let (daemon, _) = connect(url, network)
                    .await
                    .map_err(|_| SendError::Unreachable)?;
                kn_tx::publish(Backend::Node(&daemon), prepared, state, tip).await?;
            }
            Self::Lws(url) => {
                let server = LwsServer::new(url).map_err(|_| SendError::Unreachable)?;
                kn_tx::publish(Backend::Lws(&server), prepared, state, tip).await?;
            }
        }
        Ok(())
    }
}

/// Checks an address for `network` without a wallet.
///
/// # Errors
///
/// [`SendError::BadAddress`] if it is not a valid address on `network`.
#[frb(sync)]
pub fn check_address(address: String, network: Network) -> Result<AddressKind, SendError> {
    Ok(match kn_tx::check_address(&address, network.into())? {
        kn_tx::AddressKind::Standard => AddressKind::Standard,
        kn_tx::AddressKind::Subaddress => AddressKind::Subaddress,
        kn_tx::AddressKind::Integrated => AddressKind::Integrated,
    })
}

impl OpenWallet {
    /// Builds and signs a transaction paying `payments`, or, with
    /// `sweep_to`, sending everything spendable to that address. Nothing is
    /// published; show [`PreparedSend::summary`] and call
    /// [`OpenWallet::confirm_send`].
    ///
    /// # Errors
    ///
    /// See [`SendError`]; sync must have reached the chain tip first.
    pub fn prepare_send(
        &self,
        payments: Vec<Payment>,
        sweep_to: Option<String>,
        priority: FeePriority,
    ) -> Result<PreparedSend, SendError> {
        let (keys, network, mode, consent) = self.inner.with(|w| {
            Ok((
                w.keys.clone(),
                w.entry.network,
                w.entry.mode,
                w.data.lws_consent.clone(),
            ))
        })?;
        if keys.is_view_only() {
            return Err(SendError::ViewOnly);
        }
        let (state, tip) = self
            .inner
            .sync
            .caught_up_state()
            .ok_or(SendError::NotSynced)?;
        let route = match mode {
            StoreSyncMode::Full => {
                Route::Node(current_node(network.into()).map_err(|_| SendError::Storage)?)
            }
            StoreSyncMode::Lws => {
                let url = lws_server(network.into())
                    .map_err(|_| SendError::Storage)?
                    .ok_or(SendError::LwsServerNotSet)?;
                if consent.as_deref() != Some(url.as_str()) {
                    return Err(SendError::LwsConsentNeeded);
                }
                Route::Lws(NodeUrl::parse(&url).map_err(|_| SendError::LwsServerNotSet)?)
            }
        };
        let request = match sweep_to {
            Some(address) => Request::SweepAll(address),
            None => Request::Pay(
                payments
                    .into_iter()
                    .map(|p| (p.address, p.amount))
                    .collect(),
            ),
        };
        let prepared = RUNTIME.block_on(route.prepare(
            &keys,
            network,
            &state,
            tip,
            &request,
            priority.into(),
        ))?;
        let payments = match &request {
            Request::Pay(payments) => payments
                .iter()
                .map(|(address, amount)| Payment {
                    address: address.trim().to_owned(),
                    amount: *amount,
                })
                .collect(),
            Request::SweepAll(address) => vec![Payment {
                address: address.trim().to_owned(),
                amount: prepared.amount,
            }],
        };
        let via = route.url().as_str().to_owned();
        Ok(PreparedSend {
            summary: SendSummary {
                tx_hash: hex_string(&prepared.hash),
                payments,
                fee: prepared.fee,
                change: prepared.change,
                via,
            },
            prepared: Mutex::new(Some(prepared)),
            route,
            tip,
        })
    }

    /// Checks `password` and publishes `send`. Its inputs count as spent at
    /// once; sync confirms the spend when it is mined. Sync is paused while
    /// publishing; start it again afterwards.
    ///
    /// # Errors
    ///
    /// [`SendError::WrongPassword`] leaves `send` usable; after any other
    /// error it is discarded.
    pub fn confirm_send(&self, send: &PreparedSend, password: String) -> Result<(), SendError> {
        let password = Zeroizing::new(password);
        let id = self.inner.with(|w| Ok(w.entry.id.clone()))?;
        store()?
            .unlock(&id, password.as_bytes())
            .map_err(WalletError::from)?;
        let prepared = send
            .prepared
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take()
            .ok_or(SendError::AlreadyUsed)?;
        let network = self.inner.with(|w| Ok(w.entry.network))?;

        // A running sync works on its own copy of the state and would
        // overwrite the pending spends; pause it while they are recorded.
        self.inner.sync.pause();
        let (mut state, _) = self
            .inner
            .sync
            .caught_up_state()
            .ok_or(SendError::NotSynced)?;
        RUNTIME.block_on(send.route.publish(network, &prepared, &mut state, send.tip))?;
        self.inner.sync.replace(&self.inner, state);
        // Remember who was paid and the transaction key; the chain does not
        // tell the sender later. A failed save loses only these details.
        let _ = self.inner.with(|w| {
            w.data.sent.insert(
                hex_string(&prepared.hash),
                kn_store::SentRecord {
                    destinations: prepared.destinations.clone(),
                    tx_key: prepared.tx_key.clone(),
                },
            );
            Ok(store()?.save(w)?)
        });
        Ok(())
    }
}
