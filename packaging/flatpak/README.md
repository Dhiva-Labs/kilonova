# Flatpak

`com.dhivalabs.kilonova.yml` repackages the release's Linux tarball (the
same one the Snap uses), so Flathub, the Snap Store and GitHub all ship the
same binary. It does not build Kilonova from source inside the sandbox.

## How CI builds it

The `flatpak` job of `.github/workflows/release.yml` (on pull requests that
touch the packaging, on tags and by hand) builds this manifest in the
`ghcr.io/flathub-infra/flatpak-github-actions:gnome-51` image:

| Build | Source | Result |
|---|---|---|
| x86_64 and aarch64 | the tarball the same run built, swapped in by `tools/ci/flatpak-local-tarball.sh` | `kilonova-<version>-<arch>.flatpak`, attached to the draft release |
| x86_64 | the manifest exactly as committed (the published release's tarball) | nothing kept: it proves what Flathub would build |

Each bundle is installed, every ELF file in it is checked with `ldd` inside
the sandbox, and it is started under Xvfb until its window and wallet folder
appear (`tools/ci/smoke-flatpak.sh`). The bundles carry a reference to the
Flathub repository, so installing one fetches the GNOME runtime from there:

```sh
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user ./kilonova-<version>-x86_64.flatpak
flatpak run com.dhivalabs.kilonova
```

The bundles are not signed and do not update themselves; Flathub, once the
app is there, is the channel that does.

`lib/libdartjni.so` is removed in `build-commands`: it comes from the `jni`
package the Android plugins pull in, is built only because the release
runner has a JDK, links to that JDK's `libjvm.so`, and is never loaded on the
desktop. The `.rpm`, Arch package and AppImage leave it out the same way.

## Try it locally

```sh
flatpak-builder --user --install --force-clean build-dir packaging/flatpak/com.dhivalabs.kilonova.yml
flatpak run com.dhivalabs.kilonova
```

Needs `org.gnome.Platform//51` and `org.gnome.Sdk//51` installed
(`flatpak install flathub org.gnome.Platform//51 org.gnome.Sdk//51`).

## Submitting to Flathub

Flathub builds from a manifest in its own repository, not from this one, so
there is a one-time submission step and then routine version-bump PRs. This
needs a Flathub/GitHub account for whoever submits; the steps below prepare
everything up to that point.

1. **Fork `flathub/flathub`** on GitHub (this is the one-time intake
   repository; Flathub then creates a dedicated
   `flathub/com.dhivalabs.kilonova` repository once the submission is
   accepted).
2. Clone the fork, create a branch (Flathub's convention is
   `new-pr/<app-id>`, e.g. `new-pr/com.dhivalabs.kilonova`).
3. Copy `com.dhivalabs.kilonova.yml` from this directory into the root of
   that branch, with the `url`/`sha256` already pointed at the current
   tagged release (keep this file and the one in this repository in sync;
   update both on every release). While the release it points at has no
   arm64 tarball (0.4.0 has none), add a `flathub.json` next to it with
   `{"only-arches": ["x86_64"]}`. Once a release ships
   `kilonova-<version>-linux-arm64.tar.gz`, give the archive source
   `only-arches: [x86_64]`, add a second archive source for the arm64
   tarball with `only-arches: [aarch64]`, and drop `flathub.json`.
4. Open a PR against `flathub/flathub` from that branch. Flathub's bot runs
   a build and basic checks; a human reviewer looks at the manifest
   (permissions especially: ours asks for network, Wayland/X11, IPC and
   DRI only, no filesystem access, which reviewers generally wave through
   quickly) and the metainfo file's completeness.
5. Once accepted, Flathub creates `flathub/com.dhivalabs.kilonova` as its
   own repository and the submission PR's contents become its initial
   commit. Future releases are PRs against that repository: bump `url` and
   `sha256`, and add a `<release>` entry to
   `packaging/linux/com.dhivalabs.kilonova.metainfo.xml` in this repo (the
   file Flathub's copy mirrors) in the same PR that tags the release.
6. Flathub's own build server does the reproducibility check Flathub cares
   about: that *their* build matches what's declared, not that our tarball
   is itself reproducible (that's a separate goal; see
   docs/RELEASING.md#reproducibility and `tools/repro-check.sh`).

## Screenshots

Flathub's review expects at least one screenshot referenced from the
metainfo file's `<screenshots>` section. None are included yet; add
`<screenshot>` entries pointing at hosted images (Flathub accepts URLs, so
these can live on the GitHub repo or a release asset) to
`packaging/linux/com.dhivalabs.kilonova.metainfo.xml` before submitting,
since this is the one thing in the current metainfo file a reviewer is
likely to ask for.

## Validating the manifest and metainfo

```sh
appstreamcli validate packaging/linux/com.dhivalabs.kilonova.metainfo.xml
flatpak run org.flatpak.Builder --help   # or: flatpak-builder --help
```

The Release workflow's `flatpak` job (see above) builds this manifest as
committed on pull requests that touch `packaging/flatpak/`, so a broken
manifest or a stale checksum shows up before a Flathub submission.
