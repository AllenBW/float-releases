#!/usr/bin/env bash
#
# Diagnose why Float won't open. Captures system info, process state,
# install integrity, startup log, and any crash reports — all into a
# single output stream you can paste back to whoever is helping you.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/AllenBW/float-releases/main/scripts/diagnose-float.sh | bash

set +e  # don't abort on missing files / non-zero exits — we want all the info

OUT=/tmp/float-diagnostic-$(date +%s).txt
exec > >(tee "$OUT") 2>&1

section() { printf "\n\033[1;36m===== %s =====\033[0m\n" "$1"; }

section "1. System info"
sw_vers
echo "Architecture: $(uname -m)"
echo "Hostname:     $(hostname)"
echo "User:         $(whoami)"

section "2. Float app installed?"
APP=/Applications/Float.app
if [ -d "$APP" ]; then
  echo "Found: $APP"
  echo "Version: $(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist" 2>/dev/null)"
  echo "Build:   $(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist" 2>/dev/null)"
  echo "Binary arch: $(file "$APP/Contents/MacOS/float" 2>/dev/null | sed 's|.*: ||')"
  echo ""
  echo "--- Code signature ---"
  codesign -dv "$APP" 2>&1 | head -10
  echo ""
  echo "--- Gatekeeper assessment ---"
  spctl -a -t exec -vv "$APP" 2>&1 | head -5
  echo ""
  echo "--- Quarantine attribute (should be absent) ---"
  xattr -l "$APP" 2>&1 | head -5
else
  echo "MISSING: $APP — Float is not installed in /Applications"
fi

section "3. Already-running Float processes"
PROCS=$(ps aux | grep -iE 'Float\.app|app\.filefloat' | grep -v grep | grep -v diagnose-float)
if [ -n "$PROCS" ]; then
  echo "$PROCS"
  echo ""
  echo "→ Float is ALREADY running. A second invocation will be silently"
  echo "  rejected by the single-instance plugin, which is why direct launches"
  echo "  exit cleanly with no panel showing. Kill them first:"
  echo "      pkill -9 -i float"
else
  echo "(none — clean state)"
fi

section "4. Persisted state on disk"
for path in \
  "$HOME/Library/WebKit/app.filefloat" \
  "$HOME/Library/Caches/app.filefloat" \
  "$HOME/Library/Application Support/app.filefloat" \
  "$HOME/Library/Preferences/app.filefloat.plist" \
  "$HOME/Library/LaunchAgents/Float.plist" \
  "$HOME/Library/Saved Application State/app.filefloat.savedState"; do
  if [ -e "$path" ]; then
    echo "EXISTS  $path"
  else
    echo "absent  $path"
  fi
done

section "5. Keychain entries"
for svc in "app.filefloat" "app.filefloat.license" "app.filefloat.install_date" "Float" "Float.license"; do
  if security find-generic-password -s "$svc" > /dev/null 2>&1; then
    echo "EXISTS  service=$svc"
  fi
done
echo "(absent entries not listed)"

section "6. Recent crash reports"
CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"
RECENT=$(ls -t "$CRASH_DIR"/Float* "$CRASH_DIR"/float* 2>/dev/null | head -3)
if [ -n "$RECENT" ]; then
  for f in $RECENT; do
    echo ""
    echo "--- $f ---"
    head -50 "$f"
  done
else
  echo "(no Float-related crash reports)"
fi

section "7. Live startup capture (5 second test launch)"
if [ ! -d "$APP" ]; then
  echo "skipped — Float not installed"
else
  pkill -9 -i float 2>/dev/null
  sleep 1
  rm -f /tmp/float-startup.log
  "$APP/Contents/MacOS/float" > /tmp/float-startup.log 2>&1 &
  PID=$!
  sleep 5
  if ps -p $PID > /dev/null 2>&1; then
    PROC_STATE="ALIVE (good — app is running normally; tray icon should be visible)"
    kill -9 $PID 2>/dev/null
  else
    PROC_STATE="EXITED (the launch failed; see startup log below)"
  fi
  echo "Process state after 5s: $PROC_STATE"
  echo ""
  echo "--- Full startup log ---"
  if [ -s /tmp/float-startup.log ]; then
    cat /tmp/float-startup.log
  else
    echo "(empty — process produced no stdout/stderr at all)"
  fi
fi

section "8. tccd entitlement requests (last 1 min)"
log show --last 1m --predicate 'eventMessage CONTAINS "filefloat"' 2>&1 | head -20

section "9. WebKit ActivityState (was the panel rendered?)"
log show --last 1m --predicate 'process == "float" AND eventMessage CONTAINS "isViewVisible"' 2>&1 | head -10

section "DONE"
echo ""
echo "Full output saved to: $OUT"
echo ""
echo "Paste the COMPLETE output above into the conversation so we can diagnose."
