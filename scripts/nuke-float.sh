#!/usr/bin/env bash
#
# Nuke every trace of Float from a Mac. Run when:
#   - You suspect stale state from an old install is breaking things
#   - You want to test a clean-install path
#   - You're handing the machine off / removing Float for good
#
# Goes further than `Float.app --reset`: also removes the .app bundle,
# Keychain items (license + install date), LaunchServices registration,
# and various macOS-stashed state directories that --reset doesn't touch.
#
# Usage:
#   scripts/nuke-float.sh           # interactive (asks before each step)
#   scripts/nuke-float.sh --force   # don't ask, just nuke everything
#
# Safe to run when Float is not installed — every step is idempotent.

set -e

BUNDLE_ID="app.filefloat"
APP_NAME="Float"
APP_PATH="/Applications/${APP_NAME}.app"

FORCE=0
if [ "${1:-}" = "--force" ] || [ "${1:-}" = "-f" ]; then
  FORCE=1
fi

# Auto-force when run non-interactively (curl ... | bash). Otherwise `read`
# consumes the script body from stdin and every confirm() returns false,
# silently skipping every step — including removing the .app bundle.
if [ ! -t 0 ] && [ "$FORCE" = "0" ]; then
  echo "[nuke] No TTY detected (likely 'curl ... | bash'); running in --force mode."
  FORCE=1
fi

confirm() {
  if [ "$FORCE" = "1" ]; then return 0; fi
  printf "  → %s [y/N] " "$1"
  read -r ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

step() {
  printf "\n\033[1;36m==> %s\033[0m\n" "$1"
}

step "1/6  Stopping running Float processes"
if pgrep -i -f "${APP_NAME}.app/Contents/MacOS/float" > /dev/null 2>&1; then
  if confirm "Kill running Float processes?"; then
    pkill -9 -i -f "${APP_NAME}.app/Contents/MacOS/float" 2>/dev/null || true
    echo "    killed"
  fi
else
  echo "    no running processes"
fi

step "2/6  Unloading + removing the LaunchAgent (autostart)"
LAUNCH_AGENT="${HOME}/Library/LaunchAgents/${APP_NAME}.plist"
if [ -f "$LAUNCH_AGENT" ]; then
  if confirm "Remove $LAUNCH_AGENT?"; then
    launchctl unload "$LAUNCH_AGENT" 2>/dev/null || true
    rm -f "$LAUNCH_AGENT"
    echo "    removed"
  fi
else
  echo "    no LaunchAgent installed"
fi

step "3/6  Removing the application bundle"
if [ -d "$APP_PATH" ]; then
  if confirm "Remove $APP_PATH (may need admin password)?"; then
    if [ -w "/Applications" ]; then
      rm -rf "$APP_PATH"
    else
      sudo rm -rf "$APP_PATH"
    fi
    echo "    removed"
  fi
else
  echo "    no app bundle at $APP_PATH"
fi

step "4/6  Removing filesystem state"
TARGETS=(
  "${HOME}/Library/WebKit/${BUNDLE_ID}"
  "${HOME}/Library/Caches/${BUNDLE_ID}"
  "${HOME}/Library/Application Support/${BUNDLE_ID}"
  "${HOME}/Library/Preferences/${BUNDLE_ID}.plist"
  "${HOME}/Library/Saved Application State/${BUNDLE_ID}.savedState"
  "${HOME}/Library/HTTPStorages/${BUNDLE_ID}"
  "${HOME}/Library/HTTPStorages/${BUNDLE_ID}.binarycookies"
  "${HOME}/Library/Cookies/${BUNDLE_ID}.binarycookies"
  "${HOME}/Library/Containers/${BUNDLE_ID}"
  "${HOME}/Library/Group Containers/${BUNDLE_ID}"
)
removed=0
for path in "${TARGETS[@]}"; do
  if [ -e "$path" ] || [ -L "$path" ]; then
    rm -rf "$path"
    echo "    removed $path"
    removed=$((removed + 1))
  fi
done
[ "$removed" = "0" ] && echo "    nothing to remove"

step "5/6  Removing Keychain items (license + install_date)"
# Float stores its license + install_date in the user's login keychain
# under a few different service names depending on the version. Try all.
KEYCHAIN_SERVICES=(
  "${BUNDLE_ID}"
  "${BUNDLE_ID}.license"
  "${BUNDLE_ID}.install_date"
  "Float"
  "Float.license"
)
for svc in "${KEYCHAIN_SERVICES[@]}"; do
  if security find-generic-password -s "$svc" > /dev/null 2>&1; then
    security delete-generic-password -s "$svc" > /dev/null 2>&1 && \
      echo "    removed keychain item: $svc"
  fi
done
# Belt-and-suspenders: list any remaining filefloat-tagged items
remaining=$(security dump-keychain 2>/dev/null | grep -i filefloat || true)
if [ -n "$remaining" ]; then
  echo ""
  echo "    NOTE: some keychain items mentioning 'filefloat' remain:"
  echo "$remaining" | sed 's/^/        /'
  echo "    Open Keychain Access.app to delete them by hand if needed."
fi

step "6/6  Refreshing LaunchServices registration"
# So macOS forgets the old .app's bundle metadata and re-registers any
# replacement install cleanly.
if confirm "Reset LaunchServices? (~30s, runs as your user)"; then
  /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
    -kill -seed -r -domain local -domain system -domain user > /dev/null 2>&1 || true
  echo "    done"
fi

printf "\n\033[1;32m✓ Float fully nuked.\033[0m\n"
echo ""
echo "Next:"
echo "  1. Download a fresh DMG: https://github.com/AllenBW/float-releases/releases/latest"
echo "  2. Verify the version BEFORE installing:"
echo "       hdiutil attach ~/Downloads/Float_*.dmg"
echo "       plutil -extract CFBundleShortVersionString raw -o - /Volumes/Float/Float.app/Contents/Info.plist"
echo "  3. Drag to /Applications, then: xattr -cr /Applications/Float.app"
echo "  4. Open Float."
