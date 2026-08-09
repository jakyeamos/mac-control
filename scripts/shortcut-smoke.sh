#!/bin/sh
set -eu

MACCTL_BIN=${MACCTL_BIN:-$HOME/.local/bin/macctl}

if [ ! -x "$MACCTL_BIN" ]; then
  echo "macctl executable not found at $MACCTL_BIN" >&2
  echo "Set MACCTL_BIN or run: swift run macctl install" >&2
  exit 2
fi

"$MACCTL_BIN" capabilities --json

for app in "Finder" "Google Chrome" "Cursor" "Xcode"; do
  "$MACCTL_BIN" shortcut audit --app "$app" --json
done
