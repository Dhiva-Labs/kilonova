//! The optional fiat price of XMR. Off unless the user picks a currency;
//! the request goes through the proxy like everything else and carries
//! nothing about any wallet.

use serde_json::Value;

use crate::SyncError;
use crate::node::{NodeUrl, http_client};

/// Currencies offered, as ISO 4217 codes in lower case.
pub const PRICE_CURRENCIES: &[&str] = &[
    "usd", "eur", "gbp", "inr", "jpy", "cny", "cad", "aud", "chf", "brl", "rub", "krw", "try",
    "zar", "mxn", "sek", "nok", "pln",
];

/// The public price API of `CoinGecko`, which needs no account.
pub const PRICE_SOURCE: &str = "https://api.coingecko.com";

/// The price of 1 XMR in `currency` from `source` (see [`PRICE_SOURCE`]).
///
/// # Errors
///
/// [`SyncError::Node`] if the service cannot be reached or does not answer
/// with a price; [`SyncError::BadNodeUrl`] for an unknown currency.
pub async fn xmr_price(source: &NodeUrl, currency: &str) -> Result<f64, SyncError> {
    if !PRICE_CURRENCIES.contains(&currency) {
        return Err(SyncError::BadNodeUrl);
    }
    let body = http_client(source)?
        .get(format!(
            "{}/api/v3/simple/price?ids=monero&vs_currencies={currency}",
            source.as_str()
        ))
        .send()
        .await
        .map_err(|e| SyncError::Node(format!("price: {e}")))?
        .error_for_status()
        .map_err(|e| SyncError::Node(format!("price: {e}")))?
        .bytes()
        .await
        .map_err(|e| SyncError::Node(format!("price: {e}")))?;
    let reply: Value =
        serde_json::from_slice(&body).map_err(|e| SyncError::Node(format!("price: {e}")))?;
    reply["monero"][currency]
        .as_f64()
        .filter(|p| p.is_finite() && *p > 0.0)
        .ok_or_else(|| SyncError::Node("price: no price in the answer".into()))
}
