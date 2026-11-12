#!/usr/bin/env bash
# Starts the app and waits for its window and for the wallet folder that the
# Dart start-up code creates through the Rust library. Seeing both proves the
# release build's Dart code ran and loaded libkn_ffi.so on this machine; the
# window alone would only prove the native GTK runner started.
#
# Needs a display and a session bus:
#   xvfb-run -a dbus-run-session -- tools/ci/smoke-linux.sh <command>
set -u

cmd="$1"
log="$(mktemp)"
"$cmd" > "$log" 2>&1 &
pid=$!

for i in $(seq 1 90); do
  window=0
  wallets=0
  xdotool search --name 'Kilonova' > /dev/null 2>&1 && window=1
  find "${XDG_DATA_HOME:-$HOME/.local/share}" -type d -name wallets 2> /dev/null | grep -q . && wallets=1
  if [ "$window" = 1 ] && [ "$wallets" = 1 ]; then
    echo "window and wallet folder are up after ${i}s"
    sleep 5
    if ! kill -0 "$pid" 2> /dev/null; then
      echo "$cmd died after showing its window"
      cat "$log"
      exit 1
    fi
    kill "$pid"
    cat "$log"
    exit 0
  fi
  if ! kill -0 "$pid" 2> /dev/null; then
    echo "$cmd exited early"
    cat "$log"
    exit 1
  fi
  sleep 1
done

echo "no window and wallet folder after 90s (window=$window wallets=$wallets)"
cat "$log"
kill "$pid" 2> /dev/null
exit 1
