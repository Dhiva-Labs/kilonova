# Releasing

1. Update the version in `app/pubspec.yaml` (`x.y.z+build`; the build number
   must grow every release) and in
   `packaging/linux/com.dhivalabs.kilonova.metainfo.xml`.
2. Write `docs/release-notes/vX.Y.Z.md`, add a line to `CHANGELOG.md`, and
   add `fastlane/metadata/android/en-US/changelogs/<build>.txt`.
3. Run `tools/check.sh --regtest` with the devnet up.
4. Tag and push: `git tag -s vX.Y.Z -m vX.Y.Z && git push upstream vX.Y.Z`.
5. The `Release` workflow builds every platform and opens a **draft**
   pre-release with the files and `SHA256SUMS`. Install at least the APK and
   one desktop build from the draft, then publish it.

The draft holds, for version `X.Y.Z`:

| Platform | Files |
|---|---|
| Android | `kilonova-X.Y.Z-android-arm64-v8a.apk`, `-armeabi-v7a.apk`, `-x86_64.apk` |
| Linux x64 | `kilonova_X.Y.Z_amd64.deb`, `kilonova-X.Y.Z-linux-x64.tar.gz` |
| Linux arm64 | `kilonova_X.Y.Z_arm64.deb`, `kilonova-X.Y.Z-linux-arm64.tar.gz` |
| Windows x64 | `kilonova-X.Y.Z-windows-x64-setup.exe`, `kilonova-X.Y.Z-windows-x64.zip` |
| Windows arm64 | `kilonova-X.Y.Z-windows-arm64-setup.exe`, `kilonova-X.Y.Z-windows-arm64.zip` |
| Fedora, RHEL, openSUSE | `kilonova-X.Y.Z-1.x86_64.rpm`, `kilonova-X.Y.Z-1.aarch64.rpm` |
| Arch | `kilonova-X.Y.Z-1-x86_64.pkg.tar.zst`, `kilonova-X.Y.Z-1-aarch64.pkg.tar.zst`, `kilonova-bin-X.Y.Z-aur.tar.gz` (AUR recipe) |
| Any Linux | `Kilonova-X.Y.Z-x86_64.AppImage`, `Kilonova-X.Y.Z-aarch64.AppImage`, `kilonova-X.Y.Z-x86_64.flatpak`, `kilonova-X.Y.Z-aarch64.flatpak` |
| All | `SHA256SUMS` |

Each architecture is built on a runner of that architecture
(`ubuntu-24.04`, `ubuntu-24.04-arm`, `windows-2025`, `windows-11-arm`), not
cross-compiled. Every build job checks that the executables and libraries
it made, `libkn_ffi.so` and `kn_ffi.dll` included, are for the right
architecture, and starts the packaged app: the `.deb` is installed and run
under Xvfb, and the Windows installer is run silently and the installed app
started. The `.rpm`, Arch package, AppImage and Flatpak are made from the
same run's `.deb` and tarball (next section) and installed and started on
Fedora, openSUSE, Arch and in the Flatpak sandbox. The `draft` job fails if a
file in the table is missing or an extra one is present.

The same jobs run, without publishing anything, on pull requests that touch
the packaging, and by hand from the Actions tab. Only the last step of the
`draft` job, which creates the release, needs a tag. The Android job needs
the release signing key and so runs on tags and by hand only.

## Android signing key

Release APKs are signed with one key for the life of the app; Android refuses
updates signed with any other. The workflow reads it from repository secrets
and fails rather than publish an APK signed with something else:

| Secret | Value |
|---|---|
| `KN_KEYSTORE_BASE64` | `base64 -w0 release.jks` |
| `KN_KEYSTORE_PASSWORD` | keystore password |
| `KN_KEY_ALIAS` | key alias |
| `KN_KEY_PASSWORD` | key password |

Create the key once, keep an offline backup, and never commit it. The
keystore is PKCS12, so the key password and the store password are the
same value; set both secrets to it:

```sh
keytool -genkeypair -v -keystore release.jks -alias kilonova \
  -keyalg RSA -keysize 4096 -validity 10000 -dname "CN=Dhiva Labs"
```

Publish the certificate's SHA-256 fingerprint in the release notes so users
can check it (`apksigner verify --print-certs <apk>`).

## Snap Store

`snap/snapcraft.yaml` repackages the release's Linux tarball, so the snap
and GitHub ship the same binary. It builds for amd64 and arm64. After the
GitHub release is published:

1. In `snap/snapcraft.yaml`, set `version` and the two `sha256` values in
   the `kilonova` part's `override-build` script, one per architecture
   (from the release's `SHA256SUMS`: the `linux-x64` and `linux-arm64`
   tarballs). The download URL is built from `version`. The arm64 value is
   a placeholder of zeros until the first release that ships a
   `linux-arm64` tarball; replace it then.
2. Build and upload each architecture from a machine of that architecture
   (or `snapcraft remote-build`, which builds on Launchpad):

   ```sh
   snapcraft pack --use-lxd
   snapcraft upload --release=stable kilonova_X.Y.Z_amd64.snap
   snapcraft upload --release=stable kilonova_X.Y.Z_arm64.snap
   ```

The `Release` workflow builds the snap on both architectures but never
uploads it. The amd64 and arm64 builds use the Linux tarball that the same
run just made, so they show what the commit would ship; a third build uses
the recipe exactly as committed, which downloads and checks the published
release. The first two are kept as workflow artifacts (`snap-amd64`,
`snap-arm64`).

New cryptocurrency wallet snaps go through manual review at the store
before they appear, so the first upload waited for a reviewer. While a
revision waits in review, later uploads of the same snap cannot be
released; check `snapcraft revisions kilonova` and `snapcraft status
kilonova` before assuming an upload shipped.

## Reproducibility verification

The goal is that anyone who checks out a tag gets byte-identical Linux and
Android builds. That is not fully true yet; the list further down says which
files still differ. What is in place, inside `.github/workflows/release.yml`:

- `SOURCE_DATE_EPOCH` is taken from the tagged commit's own timestamp
  (`git log -1 --format=%ct`), not "now", and used for the tarball's `tar
  --mtime` and the `.deb`'s staged file times.
- The Linux tarball (x64 and arm64 alike) is built with `--sort=name
  --owner=0 --group=0 --numeric-owner` and piped through `gzip -n` so member
  order, ownership and the gzip header are all fixed.
- `RUSTFLAGS` (plain, for the Linux and Windows jobs) or
  `CARGO_ENCODED_RUSTFLAGS` (for Android, since cargokit's own NDK setup
  already uses that form and cargo refuses both being set at once) carries
  `--remap-path-prefix` for both the checkout path and `CARGO_HOME`
  (pinned to a path under the workspace rather than left at its
  machine-dependent default), so the embedded path in `libkn_ffi.so` /
  `kn_ffi.dll`'s debug info and panic strings is the same regardless of
  which runner or directory built it.
- `CARGO_INCREMENTAL=0` throughout, since incremental compilation caches
  are keyed by absolute paths.

Checking it:

- **Locally, Linux only:** `tools/repro-check.sh` builds the Linux release
  bundle for the machine it runs on (x64 or arm64) twice, from two different temporary paths, and diffs the
  resulting tarballs (byte-for-byte if they match; with `diffoscope` if
  it's installed, otherwise a per-file sha256 comparison, if they don't).
  Needs about 6 GB of free disk; it cleans up its own git worktrees and
  build output on exit either way.
- **In CI, both platforms:** `.github/workflows/reproducible.yml` builds
  the x64 Linux tarball and the arm64 APK on two separate runners (a real
  cross-machine test, not just cross-directory) and fails if the two
  runners' output differs. It runs on tags and by hand, and reports rather
  than blocking `release.yml`, since a newly-discovered nondeterminism
  shouldn't itself hold up a release. The Android comparison signs both
  runners' APKs with the same throwaway, freshly-generated-every-run key
  (not the real release key) so a signing-key difference can't be mistaken
  for a build difference; see the `keystore` job's comment in that
  workflow.

**Known gap:** the fix above covers `kn_ffi`, the Rust library (confirmed
with `tools/repro-check.sh`: it was the only shared library byte-identical
between two builds from different paths before this work, and nothing
else needed to change for it). The rest of the Linux bundle, built by
Flutter's own tooling, is not yet reproducible:

- `kilonova` (the GTK runner binary) and `libfile_selector_linux_plugin.so`.
  `app/linux/CMakeLists.txt` maps the app checkout and the pub cache with
  `-ffile-prefix-map`, which made `libflutter_zxing.so` identical across two
  builds from different paths (checked with `tools/repro-check.sh` on
  2026-10-03), but these two still differ. The next step is to run
  `diffoscope` on them, likely a GNU build ID or a path from the
  `flutter/ephemeral` directory that the maps do not cover.
- `libapp.so` is the Dart AOT snapshot of `app/lib`. Whether its bytes are
  path-independent depends on the Dart compiler's own snapshot format and
  is not something a build-script flag fixes; needs investigation on the
  `app/` side (likely starting from Flutter's `--split-debug-info` and
  `--dart-define` handling, or an upstream Flutter issue if the snapshot
  itself embeds the absolute source path).
- The Windows `.zip` and the Inno Setup installer are not reproducible at
  all yet: `Compress-Archive` and Inno Setup both embed file timestamps in
  their output. `RUSTFLAGS` is set for the Windows job too, so `kn_ffi.dll`
  itself has the same property as the Linux `.so`, but that is all this
  change gets on Windows.
- The `.deb`: `build-deb.sh` now accepts `SOURCE_DATE_EPOCH` and pins
  staged file mtimes to it, and `dpkg-deb` itself honors
  `SOURCE_DATE_EPOCH` for the archive's own timestamps, but this hasn't
  been verified end to end with two real builds the way the tarball has.

## Other Linux distributions

The `distros` job of the `Release` workflow unpacks each architecture's
`.deb` and repackages exactly those files (`packaging/linux-distros/pack.sh`,
with nfpm and appimagetool):

- an `.rpm` for Fedora, RHEL and openSUSE. Its library dependencies come
  from the ELF files as sonames, so one file serves both families, plus the
  newest `GLIBC_` version the binaries use, so dnf and zypper refuse a
  distribution that is too old instead of installing an app that cannot
  start;
- an Arch package, depending on `gtk3` and `gcc-libs`, as the `.deb` does on
  GTK 3 and libstdc++;
- an AppImage, with GTK 3 and glibc left to the host as in every GTK
  AppImage.

`packaging/linux-distros/verify.sh` then installs each one on the real
distribution, in containers of the runner's own architecture: the `.rpm` on
Fedora and openSUSE Tumbleweed, the Arch package on Arch Linux, the AppImage
on Fedora. In each it runs `ldd` on every ELF file (a missing library fails
the job) and `tools/ci/smoke-linux.sh`, the same smoke run as the `.deb`'s.
Arch Linux ARM has no official container image, so the aarch64 Arch package
gets a static check only (declared architecture, every ELF file aarch64).

`lib/libdartjni.so` from the Flutter bundle is left out of these formats and
of the Flatpak: it comes from the `jni` package the Android plugins pull in,
is built only because the runner has a JDK, links to that JDK's `libjvm.so`
and is never loaded on the desktop.

The `aur` job renders `packaging/arch/PKGBUILD.in` into the `kilonova-bin`
recipe (it repackages the release `.deb`s) with the version and checksums,
checks it with `makepkg` and `namcap` on Arch and installs it. The draft
carries it as `kilonova-bin-X.Y.Z-aur.tar.gz` (`PKGBUILD` and `.SRCINFO`).
Publishing it on the AUR is by hand, from an AUR account: clone
`ssh://aur@aur.archlinux.org/kilonova-bin.git`, copy the two files in, commit
and push.

## Flatpak

`packaging/flatpak/com.dhivalabs.kilonova.yml` repackages the release's
x64 Linux tarball (`type: archive`, with the URL and sha256 from that
release's `SHA256SUMS`), the same way the Snap does, rather than building
from source inside the Flatpak sandbox. Update its `url` and `sha256`
after each GitHub release, the same step as the Snap's `source-checksum`.

The `flatpak` job of the `Release` workflow builds the manifest three
times, in the `flatpak-github-actions:gnome-51` image:

- on x86_64 and on aarch64 with the tarball the same run made, swapped in
  for the download by `tools/ci/flatpak-local-tarball.sh`. These give the
  `.flatpak` bundles in the draft;
- on x86_64 exactly as committed, which downloads the published release.
  That catches a broken manifest or a stale checksum before either reaches
  Flathub.

Each bundle is installed, every ELF file in it is checked with `ldd` inside
the sandbox, and it is started under Xvfb until its window and wallet folder
appear (`tools/ci/smoke-flatpak.sh`). Users install a bundle with
`flatpak install --user ./kilonova-X.Y.Z-<arch>.flatpak`; the GNOME 51
runtime comes from Flathub.

Until a published release carries the arm64 tarball, the manifest as
committed is x86_64 only (a Flathub submission then needs a `flathub.json`
with `"only-arches": ["x86_64"]`). With the first such release, give the
archive source `only-arches: [x86_64]` and add a second one for
`kilonova-X.Y.Z-linux-arm64.tar.gz` with `only-arches: [aarch64]`, both with
their `SHA256SUMS` values.

Submitting to Flathub is a one-time fork-and-PR against
`flathub/flathub`, then routine version-bump PRs against the
`flathub/com.dhivalabs.kilonova` repository Flathub creates once that's
accepted. Full steps, including what a reviewer tends to check, are in
`packaging/flatpak/README.md`.

## F-Droid

`packaging/fdroid/com.dhivalabs.kilonova.yml` is a draft of the recipe
that goes into fdroiddata (F-Droid's own metadata repository; nothing in
this repository reads this file directly). Unlike the Snap and Flatpak,
F-Droid builds from source on its own server, so the recipe has to install
the pinned Rust toolchain and run `cargo`/`flutter build apk` by hand
(`sudo`/`prebuild`/`build` steps) rather than just fetching a release
tarball; see the recipe's own comments and `packaging/fdroid/README.md`
for the submission steps, how to test it locally with `fdroid build`
first, and the open question of whether to ask F-Droid for the same
split-per-ABI APKs the GitHub release ships instead of one universal APK.

Submitting needs a `gitlab.com` account (fdroiddata is hosted there) and a
merge request against `fdroiddata`; after that, `UpdateCheckMode: Tags`
lets F-Droid's own bot propose the version-bump MR for most releases.

## Windows code signing

`release.yml`'s `windows` job has an optional signing step: when
`KN_WIN_CERT_BASE64` is present in repository secrets, it signs
`kilonova.exe` and `kn_ffi.dll` before zipping, and the installer `.exe`
after Inno Setup builds it, both with `signtool /fd SHA256 /tr
http://timestamp.digicert.com /td SHA256`. The x64 and arm64 builds are
signed the same way, with the same certificate. When the secret is absent, the
step records that and skips signing entirely; the zip and installer ship
unsigned, as they do today, and SmartScreen keeps warning until a
certificate is added.

**Certificate options.**

- **OV (Organization Validation) vs EV (Extended Validation).** Both
  identify the publisher the same way to signtool; the difference used to
  be that EV got SmartScreen's reputation bar to drop immediately while OV
  had to build reputation over time from download volume. As of the
  CA/Browser Forum's 2023 baseline requirements, private keys for both OV
  and EV code-signing certificates must live in a hardware token or an
  equivalent HSM; the all-software "just a .pfx file" certificate is gone
  for either tier.
- **Cloud HSM signing services.** Because the key must be in an HSM now,
  most issuers sell access to one rather than shipping a USB token:
  Azure Trusted Signing (Microsoft's own, integrates with `signtool`
  directly) and SSL.com's eSigner are the two most commonly mentioned for
  this. Evaluate current pricing and jurisdiction requirements directly
  with the vendor; nothing here should be taken as a quote, since prices
  and terms move and weren't independently verified for this change.
- **A physical hardware token**, shipped by the CA, is still offered by
  some issuers as an alternative to a cloud HSM and plugs into a build
  machine (or a machine someone runs `signtool` on by hand, copying the
  artifacts there) rather than CI directly, since GitHub Actions runners
  can't have a USB device attached.

**Key custody.** Whichever option is chosen, write down here, before
buying anything: who holds the credentials to the HSM/signing service (one
named person, not a shared login), where the recovery/backup credentials
for that account live, and what happens if that person is unavailable.
For a cloud HSM service this is an account password plus MFA plus
whatever API credential signtool or the CI job needs; for a physical
token, a PIN and the token itself, kept somewhere that survives one
person's laptop dying.

**Adding the secrets.** Once a certificate exists:

| Secret | Value |
|---|---|
| `KN_WIN_CERT_BASE64` | `base64 -w0 your-cert.pfx` (or the export process your HSM/signing service's tooling gives you) |
| `KN_WIN_CERT_PASSWORD` | the certificate's password/PIN |

Add both under the repository's Settings → Secrets and variables →
Actions, the same place the Android keystore secrets live. The next
tagged release signs automatically; nothing else changes.
