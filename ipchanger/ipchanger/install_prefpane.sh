#!/bin/bash
# Install ipchanger.prefPane into ~/Library/PreferencePanes and IPChangerMenuBar.app
# into /Applications when possible (the usual Finder sidebar “Applications” folder).
# Falls back to ~/Applications if /Applications is not writable (this script avoids sudo).
#
# Usage (from Terminal):
#   cd .../gr33n37-ip-changer/ipchanger
#   ./ipchanger/install_prefpane.sh
#
# Optional first argument: build configuration (default Debug). Example: Release
#
# Or: double-click won't work by default — run from Terminal or `chmod +x` and run.
#
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "error: do not run this script with sudo." >&2
  echo "  Builds must run as your login user so Xcode can code-sign with your Apple Development cert." >&2
  echo "  ~/Library/PreferencePanes is writable without sudo." >&2
  exit 1
fi

# This file lives in …/ipchanger/ipchanger/ — project root is one level up (contains .xcodeproj).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

CONFIGURATION="${1:-Debug}"

MENU_SYS="/Applications/IPChangerMenuBar.app"
MENU_USER="${HOME}/Applications/IPChangerMenuBar.app"

echo "==> Removing existing ipchanger pref pane / stray copies (before build)…"
USER_PP="${HOME}/Library/PreferencePanes/ipchanger.prefPane"
if [[ -e "$USER_PP" || -L "$USER_PP" ]]; then
  rm -rf "$USER_PP"
  echo "   removed: $USER_PP"
fi

for m in "$MENU_SYS" "$MENU_USER"; do
  if [[ -e "$m" || -L "$m" ]]; then
    if rm -rf "$m" 2>/dev/null; then
      echo "   removed: $m"
    else
      echo "   warning: could not remove $m (may be replaced on copy)" >&2
    fi
  fi
done

# Broken or stale symlinks / bundles next to the project confuse installs and Xcode paths.
for stray in \
  "${PROJECT_ROOT}/ipchanger.prefPane" \
  "${PROJECT_ROOT}/Release/ipchanger.prefPane" \
  "${PROJECT_ROOT}/build/ipchanger.prefPane"; do
  if [[ -e "$stray" || -L "$stray" ]]; then
    rm -rf "$stray"
    echo "   removed stray: $stray"
  fi
done

# If someone copied a standalone .app named ipchanger, drop the user-local copy only.
for app in "${HOME}/Applications/ipchanger.app" "${HOME}/Applications/IP Changer.app"; do
  if [[ -e "$app" ]]; then
    rm -rf "$app"
    echo "   removed: $app"
  fi
done

if [[ -e "/Library/PreferencePanes/ipchanger.prefPane" ]]; then
  echo "   note: system copy exists at /Library/PreferencePanes/ipchanger.prefPane — remove with sudo if you installed it there." >&2
fi

echo "==> Building pref pane ($CONFIGURATION)…"
xcodebuild -scheme ipchanger -configuration "$CONFIGURATION" -destination 'platform=macOS' build

SETTINGS="$(xcodebuild -scheme ipchanger -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null)"
# macOS awk is BSD: avoid \s in patterns (GNU-ism). sed is portable here.
BUILT_PRODUCTS_DIR="$(printf '%s\n' "$SETTINGS" | sed -n 's/^[[:space:]]*BUILT_PRODUCTS_DIR = //p' | head -1)"
TARGET_BUILD_DIR="$(printf '%s\n' "$SETTINGS" | sed -n 's/^[[:space:]]*TARGET_BUILD_DIR = //p' | head -1)"
WRAPPER_NAME="$(printf '%s\n' "$SETTINGS" | sed -n 's/^[[:space:]]*WRAPPER_NAME = //p' | head -1)"
WRAP="${WRAPPER_NAME:-ipchanger.prefPane}"

SRC="${BUILT_PRODUCTS_DIR}/${WRAP}"
DEST="${HOME}/Library/PreferencePanes"

if [[ ! -d "$SRC/Contents/MacOS" ]]; then
  SRC="${TARGET_BUILD_DIR}/${WRAP}"
fi
if [[ -z "$SRC" || "$SRC" == "/" || ! -d "$SRC/Contents/MacOS" ]]; then
  echo "error: missing or invalid bundle at $SRC" >&2
  echo "  expected …/${WRAP} with Contents/MacOS (BUILT_PRODUCTS_DIR=${BUILT_PRODUCTS_DIR:-?}, TARGET_BUILD_DIR=${TARGET_BUILD_DIR:-?})" >&2
  exit 1
fi

mkdir -p "$DEST"
rm -rf "${DEST}/ipchanger.prefPane"
# cp -R avoids ditto trying to preserve metadata that macOS may block; runs after build = signed bundle.
cp -R "$SRC" "${DEST}/ipchanger.prefPane"

echo ""
echo "Installed: ${DEST}/ipchanger.prefPane"
echo "Next: Quit System Settings fully (Cmd+Q), reopen, search for “IP Changer”."

echo ""
echo "==> Building menu bar app IPChangerMenuBar ($CONFIGURATION)…"
xcodebuild -scheme IPChangerMenuBar -configuration "$CONFIGURATION" -destination 'platform=macOS' build

MENU_SETTINGS="$(xcodebuild -scheme IPChangerMenuBar -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null)"
MENU_BUILT="$(printf '%s\n' "$MENU_SETTINGS" | sed -n 's/^[[:space:]]*BUILT_PRODUCTS_DIR = //p' | head -1)"
MENU_TARGET="$(printf '%s\n' "$MENU_SETTINGS" | sed -n 's/^[[:space:]]*TARGET_BUILD_DIR = //p' | head -1)"
MENU_WRAP="$(printf '%s\n' "$MENU_SETTINGS" | sed -n 's/^[[:space:]]*WRAPPER_NAME = //p' | head -1)"
MENU_WRAP="${MENU_WRAP:-IPChangerMenuBar.app}"

MENU_SRC="${MENU_BUILT}/${MENU_WRAP}"
if [[ ! -d "$MENU_SRC/Contents/MacOS" ]]; then
  MENU_SRC="${MENU_TARGET}/${MENU_WRAP}"
fi
if [[ -z "$MENU_SRC" || "$MENU_SRC" == "/" || ! -d "$MENU_SRC/Contents/MacOS" ]]; then
  echo "error: missing or invalid IPChangerMenuBar.app at $MENU_SRC" >&2
  echo "  (BUILT_PRODUCTS_DIR=${MENU_BUILT:-?}, TARGET_BUILD_DIR=${MENU_TARGET:-?}, WRAPPER=${MENU_WRAP})" >&2
  exit 1
fi

MENU_APP_DEST=""
# Prefer main /Applications (Finder → Go → Applications, ⌘⇧A) so the app is easy to find.
rm -rf "$MENU_SYS" 2>/dev/null || true
if cp -R "$MENU_SRC" "$MENU_SYS" 2>/dev/null; then
  MENU_APP_DEST="$MENU_SYS"
else
  mkdir -p "${HOME}/Applications"
  rm -rf "$MENU_USER"
  cp -R "$MENU_SRC" "$MENU_USER"
  MENU_APP_DEST="$MENU_USER"
  echo "" >&2
  echo "note: Could not copy to /Applications (permissions). Installed to your *user* Applications folder:" >&2
  echo "      $MENU_APP_DEST" >&2
  echo "      In Finder: Go → Home (⇧⌘H), then open the Applications folder there — not the Mac’s top-level Applications." >&2
fi

echo ""
echo "Installed menu bar app: $MENU_APP_DEST"
echo "Finder: Go → Applications (⌘⇧A) — or reveal in Finder: open -R \"$MENU_APP_DEST\""
echo "Launch: open -a \"$MENU_APP_DEST\""
echo "Optional: System Settings → General → Login Items → add IPChangerMenuBar for launch at login."
