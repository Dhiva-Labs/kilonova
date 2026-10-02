//! The optional fiat price of XMR, off by default.
//!
//! Arguments are owned because `flutter_rust_bridge` hands them over that way.
#![allow(clippy::needless_pass_by_value)]

use flutter_rust_bridge::frb;
use kn_sync::{NodeUrl, PRICE_CURRENCIES, PRICE_SOURCE, xmr_price};

use super::nodes::{NodeError, RUNTIME};
use crate::node_settings::{load, save};

/// Currencies prices can be shown in, as lower-case ISO 4217 codes.
#[frb(sync)]
#[must_use]
pub fn price_currencies() -> Vec<String> {
    PRICE_CURRENCIES.iter().map(|c| (*c).to_owned()).collect()
}

/// The service prices come from, for the settings screen.
#[frb(sync)]
#[must_use]
pub fn price_source() -> String {
    PRICE_SOURCE.to_owned()
}

/// The chosen currency, or `None` while prices are off.
///
/// # Errors
///
/// Fails if the settings cannot be read.
pub fn price_currency() -> Result<Option<String>, NodeError> {
    Ok(load()?.price_currency)
}

/// Turns prices on in `currency`, or off with `None`.
///
/// # Errors
///
/// [`NodeError::BadUrl`] for a currency not in [`price_currencies`].
pub fn set_price_currency(currency: Option<String>) -> Result<(), NodeError> {
    if let Some(c) = &currency
        && !PRICE_CURRENCIES.contains(&c.as_str())
    {
        return Err(NodeError::BadUrl);
    }
    let mut settings = load()?;
    settings.price_currency = currency;
    save(&settings)
}

/// The price of 1 XMR in the chosen currency. `None` while prices are off,
/// in which case nothing is fetched.
///
/// # Errors
///
/// [`NodeError::Unreachable`] if the price service does not answer.
pub fn fetch_xmr_price() -> Result<Option<f64>, NodeError> {
    let Some(currency) = load()?.price_currency else {
        return Ok(None);
    };
    let source = NodeUrl::parse(PRICE_SOURCE)?;
    Ok(Some(RUNTIME.block_on(xmr_price(&source, &currency))?))
}
