# Security policy

Kilonova is a wallet. A bug here can lose people's money or expose what they
own, so security reports get priority over everything else.

## Reporting a vulnerability

**Do not open a public issue, discussion or pull request for a security
problem.**

Report it privately in one of these ways:

1. GitHub private vulnerability reporting: open the repository's
   **Security** tab and choose **Report a vulnerability**.
2. Email reachout@dhivalabs.com with "Kilonova security" in the subject.

Please include what you found, how to reproduce it, which version or commit
you tested, and what an attacker could do with it.

## What to expect

- We acknowledge your report within 3 days.
- We tell you whether we can reproduce it within 10 days.
- We fix it privately, publish a release, and then publish an advisory.
  With your permission, the advisory credits you.

We will not take legal action against anyone who reports a problem in good
faith, avoids harming users, and gives us reasonable time to fix it before
disclosing.

## Scope

In scope: everything in this repository, including the Rust core, the
Flutter app, the build and release workflows, and the devnet configuration.

Of special interest:

- anything that lets an attacker learn or use a seed, spend key or view key;
- transaction construction or signing bugs;
- wallet file encryption and password handling;
- a malicious node or light wallet server tricking the wallet into showing a
  wrong balance, accepting a fake payment or leaking data;
- supply-chain risks in dependencies or CI.

Out of scope: problems in monerod, monero-lws or other upstream projects
(report those upstream), and attacks that need an already-compromised
device.

## Supported versions

Until 1.0, only the latest release and the `main` branch get security fixes.
Kilonova has not been audited yet; see the status note in the README.
