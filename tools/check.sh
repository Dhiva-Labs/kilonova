#!/usr/bin/env bash
# Runs every check CI runs, stopping at the first failure.
#
#   tools/check.sh            formatting, lints, unit and widget tests
#   tools/check.sh --regtest  also the regtest suites (start tools/devnet first)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

step() { printf '\n== %s\n' "$*"; }

step "Rust format, lints, tests"
cd "$root/core"
cargo fmt --check
cargo clippy --quiet --workspace --all-targets -- -D warnings
# Widget tests load the debug library, which `cargo test` does not rebuild.
cargo build --quiet
cargo test --quiet --workspace

step "Flutter analyze and tests"
cd "$root/app"
flutter analyze
flutter test

step "Design lint"
cd "$root/tools/design_lint"
dart run bin/design_lint.dart ../..

if [[ "${1:-}" == "--regtest" ]]; then
  step "Regtest"
  cd "$root/core"
  for t in "kn-sync regtest" "kn-sync regtest_lws" "kn-tx regtest_send" \
           "kn-tx regtest_lws_send" "kn-tx regtest_full_lws" "kn-sync lws_dishonest_server"; do
    set -- $t
    cargo test --quiet -p "$1" --test "$2" -- --ignored --test-threads 1
  done
  cd "$root/app"
  KN_REGTEST=1 flutter test test/features/sync_regtest_test.dart
fi

step "All checks passed"
