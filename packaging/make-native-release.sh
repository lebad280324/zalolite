#!/bin/sh
# Builds the release files the in-app updater reads: ZIP (Zalolite.app at its root), DMG and SHA256SUMS.txt.
# Run after packaging/package-native-macos.sh; when dist/macos13/Zalolite.app exists (package-native-macos.sh
# --macos13), its files are added under the -macos13- name. Prints the command that publishes the GitHub Release.
set -eu
cd "$(dirname "$0")/.."
APP=dist/Zalolite.app
LEGACY_APP=dist/macos13/Zalolite.app
[ -d "$APP" ] || { echo "Missing $APP; run packaging/package-native-macos.sh first." >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
FILES=""
TITLE=""

# package <app> <edition segment>
package() {
    app=$1; edition=$2
    archs=$(lipo -archs "$app/Contents/MacOS/CTDoNative")
    case "$archs" in
        *arm64*x86_64*|*x86_64*arm64*) flavor=universal; title="macOS Apple Silicon và Intel" ;;
        arm64) flavor=arm64; title="macOS Apple Silicon" ;;
        x86_64) flavor=x86_64; title="macOS Intel" ;;
        *) echo "Unexpected architectures: $archs" >&2; exit 1 ;;
    esac
    name="Zalolite-$VERSION-$edition-$flavor"
    stage="dist/zalolite-dmg-$VERSION-$edition"
    codesign --verify --deep --strict "$app"
    rm -f dist/Zalolite-"$VERSION"-"$edition"-*.zip dist/Zalolite-"$VERSION"-"$edition"-*.dmg
    rm -rf "$stage"
    ditto -c -k --keepParent "$app" "dist/$name.zip"
    FILES="$FILES $name.dmg $name.zip"
    if [ "$edition" = macos ] && [ "$flavor" = universal ]; then
        # Zalolite 0.0.11 only looks for the -macos-arm64.zip name; the same bytes keep its updater working.
        cp "dist/$name.zip" "dist/Zalolite-$VERSION-macos-arm64.zip"
        FILES="$FILES Zalolite-$VERSION-macos-arm64.zip"
    fi
    mkdir -p "$stage"
    ditto "$app" "$stage/Zalolite.app"
    ln -s /Applications "$stage/Applications"
    hdiutil create -quiet -volname "Zalolite $VERSION" -srcfolder "$stage" -ov -format UDZO "dist/$name.dmg"
    rm -rf "$stage"
    [ -n "$TITLE" ] || TITLE=$title
}

package "$APP" macos
if [ -d "$LEGACY_APP" ]; then
    LEGACY_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$LEGACY_APP/Contents/Info.plist")
    [ "$LEGACY_VERSION" = "$VERSION" ] || { echo "$LEGACY_APP is $LEGACY_VERSION, expected $VERSION." >&2; exit 1; }
    package "$LEGACY_APP" macos13
fi
FILES=${FILES# }
# shellcheck disable=SC2086 # FILES is a fixed list of names without spaces.
(cd dist && shasum -a 256 $FILES > SHA256SUMS.txt)
cat dist/SHA256SUMS.txt
echo
echo "Publish with:"
echo "  gh release create v$VERSION --repo lebad280324/zalolite --title \"Zalolite v$VERSION — $TITLE\" \\"
printf '    --notes-file docs/releases/v%s.md' "$VERSION"
for file in $FILES; do printf ' dist/%s' "$file"; done
echo ' dist/SHA256SUMS.txt'
