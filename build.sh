#!/bin/bash
# Builds the Go core, the Swift app, and assembles "dist/WhatsApp Zen.app".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/WhatsApp Zen.app"

echo "==> core (Go)"
(cd "$ROOT/core" && CGO_ENABLED=1 MACOSX_DEPLOYMENT_TARGET=14.0 CGO_CFLAGS="-O2 -w" \
    go build -buildmode=c-archive -trimpath -ldflags="-s -w" -o build/libwacore.a .)

echo "==> app (Swift)"
# Use Xcode when it is installed, even if xcode-select still points at the
# Command Line Tools (switching that needs sudo). The macOS 27 SDK implements
# @State with a macro plugin that only ships with Xcode, so without Xcode fall
# back to the 26 SDK.
SDK_ARGS=()
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if ! xcodebuild -version >/dev/null 2>&1; then
    SDK26="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.[0-9]*.sdk 2>/dev/null | sort -V | tail -1)"
    [ -n "$SDK26" ] && SDK_ARGS=(--sdk "$SDK26")
fi
(cd "$ROOT/app" && swift build -c release ${SDK_ARGS[@]+"${SDK_ARGS[@]}"})

echo "==> bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/app/.build/release/WhatsAppZen" "$APP/Contents/MacOS/"
cp "$ROOT/app/Info.plist" "$APP/Contents/"
[ -f "$ROOT/app/AppIcon.icns" ] && cp "$ROOT/app/AppIcon.icns" "$APP/Contents/Resources/"
cp -R "$ROOT/app/Resources/"* "$APP/Contents/Resources/"
cp "$ROOT/CHANGELOG.md" "$APP/Contents/Resources/"
# With a Developer ID certificate in the keychain, sign for distribution
# (hardened runtime, as notarization requires); otherwise sign ad hoc, which
# runs fine locally but is blocked by Gatekeeper on other Macs.
IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
if [ -n "$IDENTITY" ]; then
    codesign --force --options runtime --timestamp --entitlements "$ROOT/app/WhatsAppZen.entitlements" --sign "$IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
echo "==> $APP"
