#!/usr/bin/env bash
# Starts the installed Flatpak and waits for its window and for the wallet
# folder the Dart start-up code creates through the Rust library, the same
# proof smoke-linux.sh asks of the .deb, here from inside the sandbox. The
# folder is in the Flatpak's own data directory, ~/.var/app/<id>. The window
# is looked up with x11-window.py, since the Flatpak builder image has no
# xdotool.
#
# Needs a display and a session bus:
#   xvfb-run -a dbus-run-session -- tools/ci/smoke-flatpak.sh com.dhivalabs.kilonova
set -u

app="$1"
here="$(cd "$(dirname "$0")" && pwd)"
data="$HOME/.var/app/$app/data"
log="$(mktemp)"
flatpak run "$app" > "$log" 2>&1 &
pid=$!

for i in $(seq 1 120); do
  window=0
  wallets=0
  python3 "$here/x11-window.py" Kilonova && window=1
  find "$data" -type d -name wallets 2> /dev/null | grep -q . && wallets=1
  if [ "$window" = 1 ] && [ "$wallets" = 1 ]; then
    echo "window and wallet folder are up after ${i}s"
    sleep 5
    if ! kill -0 "$pid" 2> /dev/null; then
      echo "$app died after showing its window"
      cat "$log"
      exit 1
    fi
    kill "$pid"
    cat "$log"
    exit 0
  fi
  if ! kill -0 "$pid" 2> /dev/null; then
    echo "$app exited early"
    cat "$log"
    exit 1
  fi
  sleep 1
done

echo "no window and wallet folder after 120s (window=$window wallets=$wallets)"
cat "$log"
kill "$pid" 2> /dev/null
exit 1
