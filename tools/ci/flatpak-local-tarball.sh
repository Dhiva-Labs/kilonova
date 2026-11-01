#!/usr/bin/env bash
# Points the Flatpak manifest at a Linux tarball built in this run.
#
# packaging/flatpak/com.dhivalabs.kilonova.yml downloads the tarball of a
# published release and checks it against a recorded checksum, which is what
# Flathub builds. The Release workflow cannot use that before a release
# exists (and an architecture's first tarball is never in the previous
# release), so it rewrites a throwaway copy, as snap-local-tarball.py does for
# the snap: the release archive source becomes the local tarball, with its
# own checksum. Every other line of the manifest stays as committed. With one
# release source per architecture (`only-arches`), every one of them is
# pointed at the tarball; flatpak-builder uses only the one for the
# architecture it builds.
#
#   tools/ci/flatpak-local-tarball.sh <manifest> <tarball>
set -euo pipefail

manifest="$1"
tarball="$2"
dir="$(cd "$(dirname "$manifest")" && pwd)"
# flatpak-builder resolves `path` against the manifest's directory.
rel="$(realpath --relative-to="$dir" "$tarball")"
sha="$(sha256sum "$tarball" | cut -d' ' -f1)"

awk -v rel="$rel" -v sha="$sha" '
  /^ *url: https:\/\/github\.com\/Dhiva-Labs\/kilonova\/releases\/download\// {
    sub(/url: .*/, "path: " rel)
    n++
    pending = 1
    print
    next
  }
  pending && /^ *sha256: / { sub(/sha256: .*/, "sha256: " sha); pending = 0 }
  { print }
  END {
    if (n < 1 || pending) {
      print "expected release tarball sources, each followed by its sha256; found " n > "/dev/stderr"
      exit 1
    }
  }
' "$manifest" > "$manifest.local"
mv "$manifest.local" "$manifest"
sed -n '/^modules:/,$p' "$manifest"
