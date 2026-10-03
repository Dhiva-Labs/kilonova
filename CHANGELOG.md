# Changelog

Release notes for each version are in [docs/release-notes](docs/release-notes).

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
