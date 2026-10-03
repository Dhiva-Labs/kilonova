# Changelog

Release notes for each version are in [docs/release-notes](docs/release-notes).

## 0.4.0 (2026-10-04)

Backups: Settings, Your data saves the wallets you choose, with their sync
cache, labels, contacts, notes, requests and node settings, to one file
encrypted with its own passphrase; restoring never overwrites a wallet.

Network privacy: with Tor, each wallet and each kind of request gets its
own circuit. With a proxy, payments go out through a different node from
the one you sync with. Looking up a transaction (payment checks and the
light wallet server cross-check) hides it among real transactions from
nearby blocks, so checking a light wallet server's payments against a
node is now on by default.

Payment notifications from your own server: the self-hosting kit gains
ntfy and a relay, `push-register` turns them on per wallet, and Kilonova
receives the push through UnifiedPush on Android or by asking the server
on Linux and Windows. A push says only that something arrived. On Linux
and Windows, "Keep syncing when the window is closed" keeps unlocked
wallets syncing from the system tray.

Checking for payments while the app is closed, on Android, replaces
background sync. It is off by default; turning it on explains what it
does, asks for the notification permission and for the password of each
wallet you choose. About every 15 minutes, without starting the app or
unlocking anything, Kilonova checks those wallets with their view keys
(kept encrypted by the phone's secure hardware; never the seed or spend
key) and notifies you of incoming payments. Leaving the app locks wallets
again, and the always-on notification is gone. The update turns the old
background sync setting off, on desktops too; turn it on again through
the new consent screen.

## 0.3.0 (2026-10-03)

Resource use: full sync makes about 35 times fewer requests to the node,
downloads about 7 times less and writes about 24 times less to disk;
wallets at the chain tip check less often in the background and write
nothing while idle; the bundled Rust library is a third smaller; long
histories and coin lists build only the rows on screen.

## 0.2.0 (2026-10-03)

Every feature in [docs/ROADMAP.md](docs/ROADMAP.md): a phone as an offline
cold wallet that signs over QR codes, pairing with a self-hosted node and
light wallet server, checking a light wallet server's payments against a
node, payment requests that watch for their payment, coin control with a
linked-address warning, a second node's opinion on the chain, finding nodes
on the local network, and checking a payment proof. Also copy buttons for
addresses, keys and the seed, a Show keys screen, and paste buttons on long
fields.

## 0.1.0 (2026-10-03)

First release: full and light-wallet-server sync, sending and receiving,
QR codes, address book and payment proofs, Tor/SOCKS5 proxy and pinned
certificates, optional prices, notifications and Android background sync.
See [docs/release-notes/v0.1.0.md](docs/release-notes/v0.1.0.md).
