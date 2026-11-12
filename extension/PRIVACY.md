# Kilonova browser extension privacy policy

Last updated: 2026-11-05

This policy covers the Kilonova extension for Chrome and Firefox. The
Kilonova app has its own policy in [PRIVACY.md](../PRIVACY.md).

## Summary

Kilonova is a Monero wallet that runs in your browser. Dhiva Labs runs no
server for it and receives nothing from it: no account, no analytics, no
crash reports, no tracking.

## What stays in your browser

The extension keeps these in the browser's extension storage, on your
device:

- Your wallet: seed, keys and settings, encrypted with your password
  (Argon2id with 64 MiB, then XChaCha20-Poly1305). It is never stored
  unencrypted.
- Scan progress (the outputs and payments found so far), encrypted with
  the same key.
- In plain form: the wallet's network (mainnet, stagenet or testnet), its
  random id, and the address of the node you chose.

Your password is never stored. Closing the extension or pressing Lock
removes the decrypted keys from memory. Uninstalling the extension deletes
its storage; keep your seed written down, because it is the only way to
restore the wallet.

## What goes over the network

The extension talks only to the Monero node you choose: one from the
community list it ships with, or your own. It asks the node for blocks,
block headers and transaction pool entries, and scans them on your device.
It never sends your seed, keys, password, addresses or balance.

The node can see your IP address, your browser's user agent, and which
blocks you ask for. The extension removes the `Origin` header from these
requests, so the node cannot tell they come from Kilonova. Requests carry
no cookies or credentials. For the most privacy, use a node you run
yourself.

Community nodes are run by third parties, not by Dhiva Labs. Their own
policies apply to what they log.

## Permissions

- **Storage:** keeps the encrypted wallet, the encrypted scan progress and
  your node choice.
- **Access to a node's address:** asked for when you pick a node, one node
  at a time. Nothing is granted at install.
- **Declarative net request with host access:** one rule that removes the
  `Origin` header from the extension's own requests to that node. It does
  not read, block or change any other traffic.

## Contact

Questions: reachout@dhivalabs.com. Source code:
https://github.com/Dhiva-Labs/kilonova

## Changes

- 2026-11-05: first version, for the extension's first release.
