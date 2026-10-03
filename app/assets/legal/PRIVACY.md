# Kilonova privacy policy

Last updated: (set on first release)

Kilonova is a Monero wallet made by Dhiva Labs. This page explains, in plain
terms, what the app does with your information.

## The short version

- Dhiva Labs does not collect anything from you. There are no accounts, no
  analytics, no tracking and no crash reports sent to us.
- Your seed and private spend key never leave your device.
- The app does have to talk to the Monero network. Who it talks to, and what
  they can learn, depends on the settings you choose. Those choices are
  described below.

## What stays on your device

- Your seed phrase and private keys, stored in an encrypted wallet file that
  only your password opens.
- Your transaction history, balances, address labels, address book and notes.
- Your settings, including which nodes and servers you use.

We cannot see any of this, recover it, or reset your password. If you lose
your seed and your password, nobody can restore your wallet.

## Who the app connects to

### Monero node (Full mode)

In Full mode the app downloads blocks from a Monero node and checks them on
your device. Out of the box it uses a public node from a list of community
nodes bundled with the app. Those nodes are run by third parties, not by
Dhiva Labs. You can add your own node in Settings and make it the default.
The node can see:

- your IP address, unless you use Tor or a proxy;
- when you sync and how much you download;
- transactions you send, when you broadcast them.

The node does **not** receive your keys and cannot tell which incoming
transactions are yours. Running your own node gives you the most privacy.

Once each time a wallet starts syncing, the app also asks one of the bundled
public nodes for the hash of a recent block, to check your node is on the
same chain as everyone else. That node sees your IP address (or your
proxy's) and that a Monero wallet checked a block; nothing about any wallet.

If you check a payment proof (a transaction id, its key and an address
someone gave you), the node is asked for that transaction.

### Light wallet server (LWS mode)

In LWS mode a monero-lws server scans the blockchain for you. To do that it
needs your **private view key**. With it, the server can see:

- every payment you receive and its amount;
- your IP address, unless you use Tor or a proxy.

It can also see outgoing payments when it notices your coins being spent.
When you send in LWS mode, the server also chooses the decoys for your
transaction, suggests its fee and broadcasts it, so it sees the transaction
before anyone else. It
**cannot** spend your funds, because your spend key stays on your device. Only
use a server you run yourself or one you trust, such as MyMonero. Kilonova
does not run a light wallet server and never picks one for you.

Before a wallet's view key is sent anywhere, the app shows you which server
will receive it and asks you to agree. Your answer is remembered for that
wallet and that server only: choosing a different server asks again.

If you turn on **Confirm the server's payments with a node** (off by
default), the app also asks your network's node for each transaction the
server reports, to make sure it exists as reported. That node then learns
which transactions you looked up, so use it with Tor or your own node.

### Your own server (optional)

The self-hosting kit in `tools/selfhost` runs a node and a light wallet
server on your own machine as a Tor onion service. Its pairing code holds the
onion address; anyone who has it can use your server, so show it only to your
own devices.

### Offline (cold) wallets

A wallet marked offline never connects to anything. It signs for a
view-only "watching" wallet on another device through QR codes or files.
The pairing code it shows carries the private view key, which is why it asks
for the password and should only be shown to your own watching wallet. The
codes it answers with carry key images (so the watching wallet can see your
spends) and signed transactions; they hold no spend key.

### Looking for nodes on your network (optional)

If you tap "Find nodes on this network", the app tries the usual Monero
ports on your own computer and on the other addresses of your local network.
Nothing leaves your local network, and it is never done while a proxy is
set.

### Price data (optional, off by default)

If you turn on prices (Settings, Prices), the app asks CoinGecko
(api.coingecko.com) for the XMR price in the currency you chose, about every
ten minutes, through your proxy if one is set. CoinGecko sees your IP address
(or your proxy's) and the currency. The request carries nothing about any
wallet, and test-network balances are never priced.

### Nothing else

The app does not contact Dhiva Labs servers, ad networks, analytics services
or font/CDN providers. Fonts and icons are bundled with the app.

## Reducing what others can learn

- Run your own Monero node, or your own monero-lws server.
- Turn on Settings, Proxy and Tor. Every connection then goes through Tor (or
  your SOCKS5 proxy), host names are looked up through it, and onion nodes
  can be used.
- Leave fiat prices off.

## Permissions

- **Camera (Android):** only to scan QR codes, only while the scanner is open.
  Frames are read on the device and never saved or sent. On desktop you pick an
  image file instead, which is read the same way.
- **Fingerprint or face (Android):** only if you turn on biometric unlock.

Kilonova does not ask for the microphone, contacts, location or shared storage.
- **Notifications:** to tell you about incoming payments, if you turn that on
  (Settings, Notifications and background). Off by default. A locked phone
  shows only that a payment arrived, not the amount or wallet.
- **Background sync (Android):** off by default. If you turn it on, unlocked
  wallets stay unlocked when you leave the app so they keep syncing, behind an
  ongoing notification. Anyone who opens Kilonova on your phone during that
  time can use those wallets.
- **Network:** to reach the node, server or price service you configured.

## Downloads and app stores

If you install Kilonova from an app store or GitHub, that store or site may
collect data under its own policy. Dhiva Labs receives no personal data from
those downloads.

## Children

Kilonova is not directed at children and collects no data from anyone.

## Changes to this policy

Changes are made in public, through pull requests on
github.com/Dhiva-Labs/kilonova, and listed in the changelog below.

## Contact

Questions: reachout@dhivalabs.com.
Security issues: see SECURITY.md in the repository.

## Changelog

Newest first.

- 2026-10-03: offline wallets, the node check against a public node, confirming server payments, payment proofs, self-hosting and finding nodes on your network.
- 2026-10-02: payment notifications and background sync, both off by default.
- 2026-10-02: name the price service and say how often it is asked.
- 2026-10-02: QR scanning: what the camera is used for, and permissions the app never asks for.
- 2026-10-02: describe what a light wallet server sees when you send.
- 2026-10-02: describe the consent step before a view key is shared with a light wallet server.
- 2026-10-02: first version.
