# Contributing to Kilonova

Thanks for helping. This guide covers how to set up, how changes get in, and
what reviewers look for.

## Ground rules

- Be kind and assume good faith. The [Code of Conduct](CODE_OF_CONDUCT.md)
  applies everywhere in the project.
- Security problems go through [SECURITY.md](SECURITY.md), never a public
  issue.
- Every change reaches `main` through a pull request, including the
  maintainers' own. `main` is protected: it needs a review, and maintainers
  merge only when every workflow is green.

## Set up

Follow "Build from source" in the [README](README.md). Then build the Rust
core once, because the Flutter widget tests load it:

```sh
cd core && cargo build
```

For work on syncing or sending, start a local test network:
[tools/devnet/README.md](tools/devnet/README.md).

## Making a change

1. Find or open an issue first for anything bigger than a small fix, so we
   can agree on the approach before you write it.
2. Fork the repository and create a branch from `main`:
   `feat/short-name`, `fix/short-name`, `docs/short-name` or
   `chore/short-name`.
3. Make the change, with tests.
4. Run the checks below.
5. Open a pull request against `Dhiva-Labs/kilonova:main` and fill in the
   template.

Keep pull requests small and about one thing. A reviewer should be able to
understand a PR in one sitting.

### Checks

```sh
cd core
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
cargo build

cd ../app
flutter analyze
flutter test

cd ..
dart run tools/design_lint/bin/design_lint.dart
```

### Commits

- Use [Conventional Commits](https://www.conventionalcommits.org/) for the
  PR title: `feat(sync): scan subaddresses with lookahead`. PRs are
  squash-merged, so the title becomes the commit on `main`.
- Sign off each commit to certify the
  [Developer Certificate of Origin](https://developercertificate.org/):
  `git commit -s`. There is no CLA.

## What reviewers look for

**Correctness first.** Code in `core/` that touches keys, signing, wallet
files or anything a remote server sends us needs tests that cover the failure
cases, not just the happy path. These paths have required reviewers listed
in [.github/CODEOWNERS](.github/CODEOWNERS).

**Readable code.**

- Comments explain why, not what.
- No commented-out code, dead code or unused dependencies.
- No `TODO` without a linked issue: `// TODO(#42): ...`.
- New dependencies need a reason in the PR description. A wallet should
  carry as little third-party code as possible.

**Design rules.** UI changes follow [docs/DESIGN.md](docs/DESIGN.md). The
design lint catches the mechanical rules; reviewers check the rest. Attach
light and dark screenshots for desktop and Android width.

**Decisions.** If your change makes an architectural choice that others will
have to live with, add a short record in [docs/adr/](docs/adr/).

## Working on specific areas

### Rust core and the bridge

The Dart side of the bridge in `app/lib/src/rust/` and
`core/kn-ffi/src/frb_generated.rs` are generated. After changing anything in
`core/kn-ffi/src/api/`, regenerate them:

```sh
cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked
cd app && flutter_rust_bridge_codegen generate
```

The Bindings workflow fails if the generated files are out of date.

### Android biometric unlock

The biometric test in `app/integration_test/app_test.dart` exercises the real
Keystore and BiometricPrompt. On an emulator, set a PIN
(`adb shell locksettings set-pin 1234`), enroll a fingerprint in Settings
using `adb emu finger touch 1`, then run the test while touching the sensor
from a second terminal:

```sh
while true; do adb emu finger touch 1; sleep 2; done
```

### Text and translations

All user-facing strings live in `app/lib/l10n/app_en.arb`. Never hard-code
text in widgets. To add a language, copy `app_en.arb` to `app_<locale>.arb`
and translate the values. Keep the tone short and literal, and follow the
copy rules in [docs/DESIGN.md](docs/DESIGN.md).

### Privacy policy

[PRIVACY.md](PRIVACY.md) at the repo root is the source. The app bundles a
copy at `app/assets/legal/PRIVACY.md`; a test fails if they differ. Any
change to what the app sends over the network must update the policy in the
same PR, with the `privacy` label and a dated changelog line.

### App icon

The icon is drawn by [`tools/icon/generate_icons.py`](tools/icon/generate_icons.py).
Change the script, not the PNG files.

## Labels

| Label | Meaning |
|---|---|
| `good first issue` | Small, well-defined, a good start |
| `help wanted` | Maintainers would welcome a PR |
| `area:core`, `area:ui` | Rust core or Flutter app |
| `platform:linux`, `platform:windows`, `platform:android` | Platform-specific |
| `security-sensitive` | Touches keys, signing or wallet files; needs a CODEOWNERS review |
| `privacy` | Changes what the app shares; must update PRIVACY.md |
