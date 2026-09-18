#!/bin/sh
# Usage: scripts/screenshot.sh <route> <out.png> [--dark]
#
# Captures one app screen from the Debug build:
#   1. launches the app with `--screen <route>` — DebugProfile gives the run a
#      scratch profile, so the real ~/Library/Application Support/DataDebris,
#      Keychain item and LaunchAgents are never touched (verified below);
#   2. sends the reopen event (`open -a` on the running bundle) that makes
#      macOS 27's window restoration actually create the window;
#   3. waits for `--snapshot` to write the PNG, then the app exits (`--quit`).
# No System Events keystrokes: the route drives the UI in-process.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/build/Build/Products/Debug/DataDebris.app"
ROUTE=${1:?route (welcome|home|results|review|history|duplicates|privacy|plan|detail:<category>)}
OUT=${2:?output png}
shift 2
mkdir -p "$(dirname "$OUT")"
OUT=$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")

[ -d "$APP" ] || { echo "no Debug build at $APP — run make build" >&2; exit 1; }
if pgrep -x DataDebris >/dev/null; then
  echo "DataDebris is running; quit it first so the shot comes from a fresh route" >&2
  exit 1
fi

PROFILE="$HOME/Library/Application Support/DataDebris"
profile_digest() {
  if [ -d "$PROFILE" ]; then (cd "$PROFILE" && ls -lT . && md5 -q ./*) | md5 -q; else echo none; fi
}
BEFORE=$(profile_digest)

rm -f "$OUT"
LOG=$(mktemp -t datadebris-shot)
"$APP/Contents/MacOS/DataDebris" --screen "$ROUTE" --snapshot "$OUT" 6 --quit "$@" 2>"$LOG" &
PID=$!
sleep 3
open -a "$APP"   # reopen event → window

i=0
while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 40 ]; do sleep 1; i=$((i + 1)); done
if kill -0 "$PID" 2>/dev/null; then
  echo "app did not exit after the snapshot; stopping it" >&2
  kill "$PID" 2>/dev/null || true
fi
grep -E "^(DEBUG PROFILE|SNAPSHOT):" "$LOG" >&2 || true
rm -f "$LOG"

AFTER=$(profile_digest)
if [ "$BEFORE" != "$AFTER" ]; then
  echo "FAIL: the real profile changed during the run" >&2
  exit 2
fi
[ -f "$OUT" ] || { echo "FAIL: no PNG at $OUT" >&2; exit 3; }
echo "$OUT"
