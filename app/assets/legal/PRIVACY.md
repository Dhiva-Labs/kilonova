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

### Light wallet server (LWS mode)

In LWS mode a monero-lws server scans the blockchain for you. To do that it
needs your **private view key**. With it, the server can see:

- every payment you receive and its amount;
- your IP address, unless you use Tor or a proxy.

It can also see outgoing payments when it notices your coins being spent. It
**cannot** spend your funds, because your spend key stays on your device. Only
use a server you run yourself or one you trust, such as MyMonero. Kilonova
does not run a light wallet server and never picks one for you.

Before a wallet's view key is sent anywhere, the app shows you which server
will receive it and asks you to agree. Your answer is remembered for that
wallet and that server only: choosing a different server asks again.

### Price data (optional, off by default)

If you turn on fiat prices, the app asks a price service for exchange rates.
That service sees your IP address and which currency you chose. It does not
see your wallet.

### Nothing else

The app does not contact Dhiva Labs servers, ad networks, analytics services
or font/CDN providers. Fonts and icons are bundled with the app.

## Reducing what others can learn

- Run your own Monero node, or your own monero-lws server.
- Turn on the Tor/SOCKS5 proxy setting.
- Leave fiat prices off.

## Permissions

- **Camera (Android):** only to scan QR codes, only while the scanner is open.
- **Notifications:** to tell you about incoming payments, if you enable it.
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

- (date): first version.
- 2026-10-02: describe the consent step before a view key is shared with a light wallet server.
