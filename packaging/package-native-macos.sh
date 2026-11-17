#!/usr/bin/env bash
# Package the SwiftUI frontend and its private Rust worker without replacing egui.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION=release
BUILD=1
WITH_HELPERS=1
# Releases are Universal (Apple Silicon + Intel); --host-arch is a faster local build.
ARCHS=(arm64 x86_64)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug) CONFIGURATION=debug ;;
        --no-build) BUILD=0 ;;
        --without-legacy-helpers) WITH_HELPERS=0 ;;
        --host-arch) ARCHS=("$(uname -m)") ;;
        --help)
            printf 'Usage: %s [--debug] [--no-build] [--without-legacy-helpers] [--host-arch]\n' "$0"
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done
[[ "$(uname -s)" == Darwin ]] || { printf 'This package requires macOS.\n' >&2; exit 2; }
cd "$ROOT_DIR"

# Keep build and module caches inside the checkout, including under a sandbox.
export CMAKE_POLICY_VERSION_MINIMUM="${CMAKE_POLICY_VERSION_MINIMUM:-3.5}"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/target/native-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$ROOT_DIR/dist"
CARGO_COMMAND="${CARGO:-cargo}"
if ! command -v "$CARGO_COMMAND" >/dev/null 2>&1 && [[ -x "${HOME:-}/.cargo/bin/cargo" ]]; then
    CARGO_COMMAND="${HOME}/.cargo/bin/cargo"
fi
SWIFT_PACKAGE="$ROOT_DIR/native/macos/CTDoNative"
SWIFT_BUILD="$ROOT_DIR/target/swift-native"
SWIFT_BUILD_OPTIONS=()
# Allow a local SDK build-service failure to use SwiftPM's native engine.
if [[ -n "${CTDOZLITE_SWIFT_BUILD_SYSTEM:-}" ]]; then
    SWIFT_BUILD_OPTIONS+=(--build-system "$CTDOZLITE_SWIFT_BUILD_SYSTEM")
fi
# Each slice is kept apart because SwiftPM reuses one product path for every --arch.
SLICES="$ROOT_DIR/target/native-slices/$CONFIGURATION"
export MACOSX_DEPLOYMENT_TARGET=14.0
for arch in "${ARCHS[@]}"; do
    case "$arch" in
        arm64) RUST_TARGET=aarch64-apple-darwin ;;
        x86_64) RUST_TARGET=x86_64-apple-darwin ;;
        *) printf 'Unsupported architecture: %s\n' "$arch" >&2; exit 2 ;;
    esac
    if [[ "$BUILD" == 1 ]]; then
        CARGO_OPTIONS=(build --locked --bin ctdozlite-core --target "$RUST_TARGET")
        if [[ "$CONFIGURATION" == release ]]; then CARGO_OPTIONS+=(--release); fi
        "$CARGO_COMMAND" "${CARGO_OPTIONS[@]}"
        SWIFT_ARGS=(${SWIFT_BUILD_OPTIONS[@]+"${SWIFT_BUILD_OPTIONS[@]}"} --package-path "$SWIFT_PACKAGE" --scratch-path "$SWIFT_BUILD"
            --configuration "$CONFIGURATION" --arch "$arch" --disable-sandbox)
        xcrun swift build "${SWIFT_ARGS[@]}"
        mkdir -p "$SLICES/$arch"
        cp "$("$CARGO_COMMAND" metadata --locked --no-deps --format-version 1 \
            | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')/$RUST_TARGET/$CONFIGURATION/ctdozlite-core" \
            "$SLICES/$arch/ctdozlite-core"
        cp "$(xcrun swift build "${SWIFT_ARGS[@]}" --show-bin-path)/CTDoNative" "$SLICES/$arch/CTDoNative"
    fi
    for binary in CTDoNative ctdozlite-core; do
        [[ -x "$SLICES/$arch/$binary" ]] && lipo "$SLICES/$arch/$binary" -verify_arch "$arch" || {
            printf 'Missing %s slice of %s; build before packaging.\n' "$arch" "$binary" >&2; exit 1;
        }
    done
done
lipo_all() { local inputs=(); for arch in "${ARCHS[@]}"; do inputs+=("$SLICES/$arch/$1"); done; lipo -create "${inputs[@]}" -output "$2"; }
VERSION="$("$CARGO_COMMAND" metadata --locked --no-deps --format-version 1 \
    | python3 -c 'import json,sys; print(next(p["version"] for p in json.load(sys.stdin)["packages"] if p["name"] == "ctdozlite"))')"
STAGE_DIR="$(mktemp -d "$ROOT_DIR/dist/.native-stage.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
APP="$STAGE_DIR/Zalolite.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
lipo_all CTDoNative "$APP/Contents/MacOS/CTDoNative"
lipo_all ctdozlite-core "$APP/Contents/Helpers/ctdozlite-core"
cp packaging/macos/Native-Info.plist "$APP/Contents/Info.plist"
cp LICENSE-MIT LICENSE-APACHE NOTICE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$(date -u +%Y%m%d%H%M%S)" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ "$WITH_HELPERS" == 1 ]]; then
    HELPER_TARGETS="$(printf '%s-apple-macosx14.0,' "${ARCHS[@]}")"
    env -u HISTORY_CODEC_ASSETS SWIFT_TARGETS="${HELPER_TARGETS%,}" \
        bash native/macos/build-native-helpers.sh "$APP"
    cp sync_v2_helper.js zproto_lib.js "$APP/Contents/Resources/"
fi
# Zalolite has its own logo; the egui app keeps src/assets/app_icon.png.
ICON_SOURCE="packaging/macos/zalolite_icon.png"
ICONSET="$STAGE_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -s format png -z "$size" "$size" "$ICON_SOURCE" \
        --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -s format png -z "$doubled" "$doubled" "$ICON_SOURCE" \
        --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
if ! iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"; then
    # Some SDK/sandbox combinations reject valid iconsets; ImageIO can still
    # encode the source icon directly without dropping the application icon.
    sips -s format icns "$ICON_SOURCE" \
        --out "$APP/Contents/Resources/AppIcon.icns" >/dev/null
fi
SIGNING_IDENTITY="${CTDOZLITE_CODESIGN_IDENTITY:--}"
codesign --force --sign "$SIGNING_IDENTITY" "$APP/Contents/Helpers/ctdozlite-core"
if [[ -d "$APP/Contents/Helpers/DailyNotifier.app" ]]; then
    codesign --force --sign "$SIGNING_IDENTITY" "$APP/Contents/Helpers/DailyNotifier.app"
fi
codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP"
python3 packaging/macos/validate-swiftui-bundle.py "$APP"
DESTINATION="$ROOT_DIR/dist/Zalolite.app"
# Only replace this script's build artifact; never the installed application.
if [[ -e "$DESTINATION" ]]; then rm -rf "$DESTINATION"; fi
mv "$APP" "$DESTINATION"
printf 'Built %s (%s)\n' "$DESTINATION" "$(lipo -archs "$DESTINATION/Contents/MacOS/CTDoNative")"
