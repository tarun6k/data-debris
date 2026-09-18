#!/bin/zsh
# scripts/drive.sh <profile-dir> <log-file> <app args...>
#
# Launches the Debug build through LaunchServices with APP_SUPPORT_OVERRIDE set
# to <profile-dir>, so a routed run (--screen / --drive…) gets a real GUI
# session (WindowServer, Keychain) and never touches the real profile.
# The log is created by `open` itself: a file created by another process carries
# a com.apple.macl attribute that makes `open --stdout` fail with -10810.
# NOWAIT=1 returns right after launch (the caller tails the log).
set -eu
PROFILE=$1; LOG=$2; shift 2
case $LOG in /*) ;; *) LOG=$PWD/$LOG ;; esac
APP=${APP:-$PWD/build/Build/Products/Debug/DataDebris.app}
if pgrep -xq DataDebris; then echo "DataDebris is already running — quit it first" >&2; exit 1; fi
mkdir -p "$PROFILE"; rm -f "$LOG"
WAIT=(-W); [ "${NOWAIT:-0}" = 1 ] && WAIT=()
open "${WAIT[@]}" -a "$APP" --env "APP_SUPPORT_OVERRIDE=$PROFILE" --stdout "$LOG" --stderr "$LOG" --args "$@"
if [ "${NOWAIT:-0}" = 1 ]; then sleep 2; echo "pid $(pgrep -x DataDebris | tr '\n' ' ')"; exit 0; fi
grep -E "^DRIVE|DEBUG PROFILE|SNAPSHOT" "$LOG" || true
