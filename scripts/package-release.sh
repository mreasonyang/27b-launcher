#!/bin/sh
# Builds the local release artifacts into dist/:
#
#   27B-Launcher-<version>-macOS-arm64.zip        + .sha256
#   27B-Launcher-<version>-macOS-arm64.dmg        + .sha256
#
# These artifacts are UNSIGNED-FOR-DISTRIBUTION unless you built with
# SIGNING_IDENTITY set: without a Developer ID certificate the app is ad-hoc
# signed and a public user sees "the app is damaged". Run
# ./scripts/sign-and-notarize.sh for the real, notarized, stapled release.
set -eu

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="27B Launcher"
APP_DIR="$PROJECT_DIR/dist/$APP_NAME.app"

# shellcheck source=scripts/version.sh
. "$PROJECT_DIR/scripts/version.sh"

die() { echo "error: $*" >&2; exit 1; }

# build-app.sh enforces the version monotonicity assertions and prints the
# stamped version into the bundle's Info.plist.
"$PROJECT_DIR/scripts/build-app.sh" >/dev/null

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP_DIR/Contents/Info.plist")"
BUILD_NUMBER="$(plutil -extract CFBundleVersion raw -o - "$APP_DIR/Contents/Info.plist")"

# arm64-only policy: the runtime download in
# Sources/Launcher27B/InstallationCatalog.swift is hardcoded to macos-arm64, so a
# universal build would hand Intel users a launcher that cannot install its own
# runtime. Reintroducing universal means changing that catalog first.
ARCH="$(lipo -archs "$APP_DIR/Contents/MacOS/Launcher27B")"
if [ "$ARCH" != "$SUPPORTED_ARCHS" ]; then
    die "executable architectures are '$ARCH' but the policy in scripts/version.sh is '$SUPPORTED_ARCHS' (arm64-only)."
fi
PACKAGE_ARCH="$ARCH"

BASENAME="27B-Launcher-$VERSION-macOS-$PACKAGE_ARCH"
ZIP_PATH="$PROJECT_DIR/dist/$BASENAME.zip"
ZIP_CHECKSUM_PATH="$ZIP_PATH.sha256"
DMG_PATH="$PROJECT_DIR/dist/$BASENAME.dmg"
DMG_CHECKSUM_PATH="$DMG_PATH.sha256"

codesign --verify --deep --strict "$APP_DIR" >&2

# --- ZIP -------------------------------------------------------------------
rm -f "$ZIP_PATH" "$ZIP_CHECKSUM_PATH"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$APP_DIR" "$ZIP_PATH"
(
    cd "$(dirname "$ZIP_PATH")"
    shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$ZIP_CHECKSUM_PATH")"
)

if unzip -Z1 "$ZIP_PATH" | grep -q '^__MACOSX/'; then
    die "package contains unexpected __MACOSX metadata."
fi

# --- DMG -------------------------------------------------------------------
rm -f "$DMG_PATH" "$DMG_CHECKSUM_PATH"
"$PROJECT_DIR/scripts/make-dmg.sh" \
    --app "$APP_DIR" \
    --output "$DMG_PATH" \
    --volume-name "$APP_NAME $VERSION" >/dev/null
(
    cd "$(dirname "$DMG_PATH")"
    shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_CHECKSUM_PATH")"
)

echo "$ZIP_PATH"
echo "$ZIP_CHECKSUM_PATH"
echo "$DMG_PATH"
echo "$DMG_CHECKSUM_PATH"
echo "version $VERSION ($BUILD_NUMBER), arch $PACKAGE_ARCH" >&2

if [ -z "${SIGNING_IDENTITY:-}" ] || [ "${SIGNING_IDENTITY:-}" = "-" ]; then
    cat >&2 <<'EOF'

NOTE: these artifacts are ad-hoc signed and NOT notarized. They are fine for this
Mac and for testing, but a user who downloads them sees "「27B Launcher」已损坏"
with no "Open Anyway" escape hatch. For a public release:

    SIGNING_IDENTITY="Developer ID Application: ..." ./scripts/sign-and-notarize.sh
EOF
fi
