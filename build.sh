#!/usr/bin/env bash
#
# Builds Folio.app without Xcode (Command Line Tools are enough).
#
#   ./build.sh              build build/Folio.app
#   ./build.sh --install    also copy it to /Applications and register it
#   ./build.sh --install --set-default
#                           ... and make it the default app for diffs and Markdown
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Folio.app"
CONFIG=release

DO_INSTALL=0
DO_SET_DEFAULT=0
for arg in "$@"; do
  case "$arg" in
    --install) DO_INSTALL=1 ;;
    --set-default) DO_SET_DEFAULT=1; DO_INSTALL=1 ;;
    --debug) CONFIG=debug ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 64 ;;
  esac
done

echo "==> Compiling ($CONFIG)"
swift build -c "$CONFIG" --product Folio
swift build -c "$CONFIG" --product folio-register
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Folio" "$APP/Contents/MacOS/Folio"
cp "$BIN/folio-register" "$APP/Contents/MacOS/folio-register"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Vendored web assets: mermaid is loaded from here, never from the network.
if [[ -f "$ROOT/Resources/Web/mermaid.min.js" ]]; then
  cp "$ROOT/Resources/Web/mermaid.min.js" "$APP/Contents/Resources/mermaid.min.js"
  echo "    bundled mermaid.min.js ($(du -h "$ROOT/Resources/Web/mermaid.min.js" | cut -f1))"
else
  echo "    WARNING: Resources/Web/mermaid.min.js missing — diagrams will show their source"
fi

echo "==> Building icon"
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
if swift "$ROOT/Tools/make-icon.swift" "$ICONSET" >/dev/null 2>&1 \
   && command -v iconutil >/dev/null 2>&1 \
   && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
  echo "    AppIcon.icns"
else
  echo "    skipped (icon generation unavailable — the app still builds)"
fi

echo "==> Signing (ad-hoc)"
codesign --force --sign - --identifier com.robinwijnen.Folio "$APP" >/dev/null 2>&1 \
  && echo "    signed" \
  || echo "    codesign failed; the app will still run locally"

echo "==> Built $APP"

if [[ "$DO_INSTALL" == 1 ]]; then
  TARGET_DIR=/Applications
  if ! mkdir -p "$TARGET_DIR" 2>/dev/null || [[ ! -w "$TARGET_DIR" ]]; then
    TARGET_DIR="$HOME/Applications"
    mkdir -p "$TARGET_DIR"
    echo "==> /Applications is not writable; installing to $TARGET_DIR"
  fi
  INSTALLED="$TARGET_DIR/Folio.app"
  echo "==> Installing to $INSTALLED"
  rm -rf "$INSTALLED"
  cp -R "$APP" "$INSTALLED"

  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$INSTALLED"
    echo "==> Registered with Launch Services"
  fi

  if [[ "$DO_SET_DEFAULT" == 1 ]]; then
    echo "==> Setting Folio as the default app for diffs and Markdown"
    # Launch Services' current API only answers from inside a registered bundle, so
    # borrow the app for a moment (it opens briefly and quits by itself).
    if ! "$INSTALLED/Contents/MacOS/Folio" --set-default-handler 2>/dev/null; then
      echo "    falling back to the Launch Services API"
      "$INSTALLED/Contents/MacOS/folio-register" "$INSTALLED" || true
    fi
  fi
fi
