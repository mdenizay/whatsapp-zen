#!/bin/bash
# Builds the app, publishes it as a GitHub release and updates the Homebrew
# cask in the tap repository. Needs `gh auth login` and an existing
# mdenizay/homebrew-tap repository.
# Usage: tools/release.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="mdenizay/whatsapp-zen"
TAP="mdenizay/homebrew-tap"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/app/Info.plist")"
ZIP="$ROOT/dist/WhatsApp-Zen-$VERSION.zip"

"$ROOT/build.sh"
rm -f "$ZIP"
ditto -c -k --keepParent "$ROOT/dist/WhatsApp Zen.app" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

gh release create "v$VERSION" "$ZIP" --repo "$REPO" --title "v$VERSION" --generate-notes

WORK="$(mktemp -d)"
gh repo clone "$TAP" "$WORK/tap"
mkdir -p "$WORK/tap/Casks"
sed -e "s/VERSION/$VERSION/" -e "s/SHA256/$SHA/" "$ROOT/packaging/whatsapp-zen.rb" \
    | grep -v '^# ' > "$WORK/tap/Casks/whatsapp-zen.rb"
git -C "$WORK/tap" add Casks/whatsapp-zen.rb
git -C "$WORK/tap" commit -m "whatsapp-zen $VERSION"
git -C "$WORK/tap" push
rm -rf "$WORK"
echo "Released v$VERSION"
