#!/bin/sh
# Builds the release files the in-app updater reads: ZIP (Zalolite.app at its root), DMG and SHA256SUMS.txt.
# Run after packaging/package-native-macos.sh; prints the command that publishes the GitHub Release.
set -eu
cd "$(dirname "$0")/.."
APP=dist/Zalolite.app
[ -d "$APP" ] || { echo "Missing $APP; run packaging/package-native-macos.sh first." >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
ARCHS=$(lipo -archs "$APP/Contents/MacOS/CTDoNative")
case "$ARCHS" in
    *arm64*x86_64*|*x86_64*arm64*) FLAVOR=universal; TITLE="macOS Apple Silicon và Intel" ;;
    arm64) FLAVOR=arm64; TITLE="macOS Apple Silicon" ;;
    x86_64) FLAVOR=x86_64; TITLE="macOS Intel" ;;
    *) echo "Unexpected architectures: $ARCHS" >&2; exit 1 ;;
esac
NAME="Zalolite-$VERSION-macos-$FLAVOR"
STAGE="dist/zalolite-dmg-$VERSION"
codesign --verify --deep --strict "$APP"
rm -f dist/Zalolite-"$VERSION"-macos-*.zip dist/Zalolite-"$VERSION"-macos-*.dmg
rm -rf "$STAGE"
ditto -c -k --keepParent "$APP" "dist/$NAME.zip"
FILES="$NAME.dmg $NAME.zip"
if [ "$FLAVOR" = universal ]; then
    # Zalolite 0.0.11 only looks for the -macos-arm64.zip name; the same bytes keep its updater working.
    cp "dist/$NAME.zip" "dist/Zalolite-$VERSION-macos-arm64.zip"
    FILES="$FILES Zalolite-$VERSION-macos-arm64.zip"
fi
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Zalolite.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Zalolite $VERSION" -srcfolder "$STAGE" -ov -format UDZO "dist/$NAME.dmg"
rm -rf "$STAGE"
# shellcheck disable=SC2086 # FILES is a fixed list of names without spaces.
(cd dist && shasum -a 256 $FILES > SHA256SUMS.txt)
cat dist/SHA256SUMS.txt
echo
echo "Publish with:"
echo "  gh release create v$VERSION --repo lebad280324/zalolite --title \"Zalolite v$VERSION — $TITLE\" \\"
printf '    --notes-file docs/releases/v%s.md' "$VERSION"
for file in $FILES; do printf ' dist/%s' "$file"; done
echo ' dist/SHA256SUMS.txt'
