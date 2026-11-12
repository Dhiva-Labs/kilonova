#!/usr/bin/env bash
# Fails unless every ELF file under <path> is built for the given
# architecture, and unless each listed file exists under <path>. CI runs it on
# the Flutter bundle, so the Rust library (libkn_ffi.so), the Dart AOT
# snapshot (libapp.so) and the plugins are all checked, not just the runner.
#
#   tools/ci/assert-elf-arch.sh <path> <x64|arm64> [required file ...]
set -euo pipefail

path="$1"
arch="$2"
shift 2

case "$arch" in
  x64) machine="x86-64" ;;
  arm64) machine="ARM aarch64" ;;
  *)
    echo "error: unknown architecture '$arch' (x64 or arm64)" >&2
    exit 2
    ;;
esac

for f in "$@"; do
  if [ ! -f "$path/$f" ]; then
    echo "::error::missing $path/$f"
    exit 1
  fi
done

checked=0
bad=0
while IFS= read -r -d '' f; do
  desc="$(file -b "$f")"
  case "$desc" in ELF*) ;; *) continue ;; esac
  echo "$f: $desc"
  checked=$((checked + 1))
  case "$desc" in
    *"$machine"*) ;;
    *)
      echo "::error file=$f::not $machine"
      bad=1
      ;;
  esac
done < <(find "$path" -type f -print0)

echo "checked $checked ELF files for $machine"
[ "$checked" -gt 0 ] && [ "$bad" -eq 0 ]
