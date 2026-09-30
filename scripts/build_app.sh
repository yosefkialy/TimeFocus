#!/bin/bash
# Builds TimeFocus.app (release flags) into ./build and signs it.
#
#   scripts/build_app.sh             # build/TimeFocus.app
#   scripts/build_app.sh --install   # also copy to /Applications (or ~/Applications)
#
# Signing: ad-hoc by default. macOS ties privacy permissions (Accessibility…) to the signature, so after a
# rebuild you may need to re-enable TimeFocus in System Settings. To keep permissions across rebuilds, sign with
# a stable identity: TIMEFOCUS_SIGN_IDENTITY="My Code Signing Cert" scripts/build_app.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/build.sh" TFWatchdog TimeFocusApp

APP="$ROOT/build/TimeFocus.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build-swiftc/bin/TimeFocusApp" "$APP/Contents/MacOS/TimeFocus"
cp "$ROOT/.build-swiftc/bin/tf-watchdog" "$APP/Contents/MacOS/tf-watchdog"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
  echo "==> generating app icon"
  TMP="$(mktemp -d)"
  xcrun swift "$ROOT/scripts/make_icon.swift" "$TMP/AppIcon.iconset" >/dev/null
  iconutil -c icns "$TMP/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"
  rm -rf "$TMP"
fi
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${TIMEFOCUS_SIGN_IDENTITY:--}"
codesign --force --deep --sign "$IDENTITY" "$APP" 2>&1 | grep -v "replacing existing signature" || true
codesign --verify "$APP" && echo "==> signed ($IDENTITY)"
echo "==> $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="/Applications"
  [[ -w "$DEST" ]] || DEST="$HOME/Applications"
  mkdir -p "$DEST"
  if pgrep -xq TimeFocus; then osascript -e 'tell application id "com.timefocus.app" to quit' || true; sleep 1; fi
  rm -rf "$DEST/TimeFocus.app"
  cp -R "$APP" "$DEST/"
  echo "==> installed to $DEST/TimeFocus.app"
fi
