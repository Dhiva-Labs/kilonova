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
and GitHub ship the same binary. After the GitHub release is published:

1. In `snap/snapcraft.yaml`, set `version`, the tarball URL and its
   `source-checksum` (from the release's `SHA256SUMS`).
2. Build and upload:

   ```sh
   snapcraft pack --use-lxd
   snapcraft upload --release=stable kilonova_X.Y.Z_amd64.snap
   ```

New cryptocurrency wallet snaps go through manual review at the store
before they appear, so the first upload waited for a reviewer. While a
revision waits in review, later uploads of the same snap cannot be
released; check `snapcraft revisions kilonova` and `snapcraft status
kilonova` before assuming an upload shipped.

## Not automated yet

- Windows code signing (installers currently trigger SmartScreen).
- Snap uploads (manual, above), Flatpak and PPA; the AppStream file in `packaging/linux` is
  ready for Flatpak.
- F-Droid: the metadata in `fastlane/` is ready; submitting needs a merge
  request to fdroiddata.
