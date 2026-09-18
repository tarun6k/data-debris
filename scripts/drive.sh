#!/bin/zsh
# scripts/drive.sh <profile-dir> <log-file> <app args...>
#
# Launches the Debug build on a scratch profile (APP_SUPPORT_OVERRIDE), sends
# the reopen event macOS 27 needs before the window shows, and prints the
# DRIVE: lines when the routed run exits. The real profile under
# ~/Library/Application Support/DataDebris is never opened.
#
#   NOWAIT=1  return right after the reopen event (the route stays alive, e.g.
#             --drive-purchase waits for the browser checkout); prints the pid.
set -eu

PROFILE=$1
LOG=$2
shift 2
APP=${APP:-$PWD/build/Build/Products/Debug/DataDebris.app}

if pgrep -xq DataDebris; then
    echo "DataDebris is already running — quit it first" >&2
    exit 1
fi
mkdir -p "$PROFILE"

APP_SUPPORT_OVERRIDE="$PROFILE" "$APP/Contents/MacOS/DataDebris" "$@" >"$LOG" 2>&1 &
PID=$!
sleep 3
open -a "$APP"

if [ "${NOWAIT:-0}" = 1 ]; then
    echo "pid $PID"
    exit 0
fi

STATUS=0
wait $PID || STATUS=$?
grep -E "^DRIVE|DEBUG PROFILE|SNAPSHOT" "$LOG" || true
exit $STATUS
