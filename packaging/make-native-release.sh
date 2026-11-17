#!/bin/sh
# Builds the release files the in-app updater reads: ZIP (Zalolite.app at its root), DMG and SHA256SUMS.txt.
# Run after packaging/package-native-macos.sh; prints the command that publishes the GitHub Release.
set -eu
cd "$(dirname "$0")/.."
APP=dist/Zalolite.app
[ -d "$APP" ] || { echo "Missing $APP; run packaging/package-native-macos.sh first." >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
NAME="Zalolite-$VERSION-macos-arm64"
STAGE="dist/zalolite-dmg-$VERSION"
codesign --verify --deep --strict "$APP"
rm -rf "dist/$NAME.zip" "dist/$NAME.dmg" "$STAGE"
ditto -c -k --keepParent "$APP" "dist/$NAME.zip"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Zalolite.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Zalolite $VERSION" -srcfolder "$STAGE" -ov -format UDZO "dist/$NAME.dmg"
(cd dist && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt)
cat dist/SHA256SUMS.txt
echo
echo "Publish with:"
echo "  gh release create v$VERSION --repo lebad280324/zalolite --title \"Zalolite v$VERSION — macOS Apple Silicon\" \\"
echo "    --notes-file docs/releases/v$VERSION.md dist/$NAME.zip dist/$NAME.dmg dist/SHA256SUMS.txt"
