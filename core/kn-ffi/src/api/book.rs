//! The address book, transaction notes and transaction keys of an open
//! wallet. All of it lives in the encrypted wallet file.
//!
//! Arguments are owned because `flutter_rust_bridge` hands them over that way.
#![allow(clippy::needless_pass_by_value)]

use flutter_rust_bridge::frb;
use kn_store::Contact;
use zeroize::Zeroizing;

use super::send::Payment;
use super::wallets::{OpenWallet, WalletError, store};

/// A saved recipient.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContactRow {
    pub name: String,
    pub address: String,
}

/// What the wallet knows about one transaction beyond the chain.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TxDetails {
    /// The owner's note; empty if none.
    pub note: String,
    /// For transactions sent from this wallet: who was paid what.
    pub destinations: Vec<Payment>,
    /// A transaction key is stored and can be revealed for a payment proof.
    pub has_tx_key: bool,
}

impl OpenWallet {
    /// Saved recipients, by name.
    ///
    /// # Errors
    ///
    /// Fails if the wallet has been locked.
    #[frb(sync)]
    pub fn contacts(&self) -> Result<Vec<ContactRow>, WalletError> {
        self.inner.with(|w| {
            let mut rows: Vec<ContactRow> = w
                .data
                .contacts
                .iter()
                .map(|c| ContactRow {
                    name: c.name.clone(),
                    address: c.address.clone(),
                })
                .collect();
            rows.sort_by_key(|r| r.name.to_lowercase());
            Ok(rows)
        })
    }

    /// Saves a recipient, replacing any entry with the same address.
    ///
    /// # Errors
    ///
    /// [`WalletError::EmptyName`], or [`WalletError::BadAddress`] for an
    /// address not on this wallet's network.
    pub fn save_contact(&self, name: String, address: String) -> Result<(), WalletError> {
        let name = name.trim().to_owned();
        let address = address.trim().to_owned();
        if name.is_empty() {
            return Err(WalletError::EmptyName);
        }
        self.inner.with(|w| {
            kn_tx::check_address(&address, w.entry.network).map_err(|_| WalletError::BadAddress)?;
            w.data.contacts.retain(|c| c.address != address);
            w.data.contacts.push(Contact { name, address });
            Ok(store()?.save(w)?)
        })
    }

    /// Removes the recipient with `address`.
    ///
    /// # Errors
    ///
    /// Fails if the wallet has been locked or cannot be saved.
    pub fn delete_contact(&self, address: String) -> Result<(), WalletError> {
        self.inner.with(|w| {
            w.data.contacts.retain(|c| c.address != address);
            Ok(store()?.save(w)?)
        })
    }

    /// Notes and sending details for `tx_hash` (hex).
    ///
    /// # Errors
    ///
    /// Fails if the wallet has been locked.
    #[frb(sync)]
    pub fn tx_details(&self, tx_hash: String) -> Result<TxDetails, WalletError> {
        self.inner.with(|w| {
            let sent = w.data.sent.get(&tx_hash);
            Ok(TxDetails {
                note: w.data.notes.get(&tx_hash).cloned().unwrap_or_default(),
                destinations: sent
                    .map(|s| {
                        s.destinations
                            .iter()
                            .map(|(address, amount)| Payment {
                                address: address.clone(),
                                amount: *amount,
                            })
                            .collect()
                    })
                    .unwrap_or_default(),
                has_tx_key: sent.is_some_and(|s| s.tx_key.is_some()),
            })
        })
    }

    /// Sets the note for `tx_hash`; an empty note removes it.
    ///
    /// # Errors
    ///
    /// Fails if the wallet has been locked or cannot be saved.
    pub fn set_tx_note(&self, tx_hash: String, note: String) -> Result<(), WalletError> {
        self.inner.with(|w| {
            let note = note.trim();
            if note.is_empty() {
                w.data.notes.remove(&tx_hash);
            } else {
                w.data.notes.insert(tx_hash, note.to_owned());
            }
            Ok(store()?.save(w)?)
        })
    }

    /// The transaction key of a transaction this wallet sent, after
    /// checking the password. With it and the recipient's address, anyone
    /// can verify the payment (for example with `check_tx_key`).
    ///
    /// # Errors
    ///
    /// [`WalletError::WrongPassword`], or [`WalletError::NotFound`] if no key
    /// is stored for `tx_hash`.
    pub fn reveal_tx_key(&self, tx_hash: String, password: String) -> Result<String, WalletError> {
        let password = Zeroizing::new(password);
        let id = self.inner.with(|w| Ok(w.entry.id.clone()))?;
        store()?.unlock(&id, password.as_bytes())?;
        self.inner.with(|w| {
            w.data
                .sent
                .get(&tx_hash)
                .and_then(|s| s.tx_key.as_ref())
                .map(|k| k.as_str().to_owned())
                .ok_or(WalletError::NotFound)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::super::network::Network;
    use super::super::wallets::{
        SeedFormat, SyncMode, create_wallet_from_seed, generate_seed, unlock_wallet,
    };
    use super::*;

    #[test]
    fn address_book_and_notes_persist_in_the_wallet_file() {
        crate::test_store::init();
        let seed = generate_seed(SeedFormat::Classic).words.join(" ");
        let wallet = create_wallet_from_seed(
            "Book".into(),
            Network::Stagenet,
            SyncMode::Full,
            seed,
            "pw".into(),
            None,
            true,
        )
        .unwrap();
        let own = wallet.addresses().unwrap()[0].address.clone();
        let other = generate_seed(SeedFormat::Classic);
        let mainnet = create_wallet_from_seed(
            "Elsewhere".into(),
            Network::Mainnet,
            SyncMode::Full,
            other.words.join(" "),
            "pw".into(),
            None,
            true,
        )
        .unwrap();
        let mainnet_address = mainnet.addresses().unwrap()[0].address.clone();

        assert_eq!(
            wallet.save_contact(" ".into(), own.clone()),
            Err(WalletError::EmptyName)
        );
        assert_eq!(
            wallet.save_contact("Shop".into(), mainnet_address),
            Err(WalletError::BadAddress)
        );
        wallet.save_contact("me".into(), own.clone()).unwrap();
        wallet
            .save_contact(" Savings ".into(), own.clone())
            .unwrap();
        assert_eq!(
            wallet.contacts().unwrap(),
            vec![ContactRow {
                name: "Savings".into(),
                address: own.clone()
            }]
        );

        let tx = "ab".repeat(32);
        wallet.set_tx_note(tx.clone(), " rent ".into()).unwrap();
        assert_eq!(wallet.tx_details(tx.clone()).unwrap().note, "rent");
        assert!(!wallet.tx_details(tx.clone()).unwrap().has_tx_key);
        assert_eq!(
            wallet.reveal_tx_key(tx.clone(), "pw".into()),
            Err(WalletError::NotFound)
        );
        assert_eq!(
            wallet.reveal_tx_key(tx.clone(), "nope".into()),
            Err(WalletError::WrongPassword)
        );

        // Everything was saved to the encrypted file.
        let id = wallet.summary().unwrap().id;
        wallet.lock();
        let reopened = unlock_wallet(id, "pw".into()).unwrap();
        assert_eq!(reopened.contacts().unwrap().len(), 1);
        assert_eq!(reopened.tx_details(tx.clone()).unwrap().note, "rent");
        reopened.set_tx_note(tx.clone(), String::new()).unwrap();
        assert_eq!(reopened.tx_details(tx).unwrap().note, "");
        reopened.delete_contact(own).unwrap();
        assert!(reopened.contacts().unwrap().is_empty());
    }
}
