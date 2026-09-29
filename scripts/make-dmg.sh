#!/bin/sh
# Builds a distributable DMG containing the .app and an /Applications symlink.
#
#   make-dmg.sh --app <path/to/App.app> --output <path/to/out.dmg> [--volume-name NAME]
#   make-dmg.sh --app ... --output ... --check
#
# The DMG is NOT signed or notarized here: scripts/sign-and-notarize.sh signs,
# notarizes and staples it. scripts/package-release.sh uses this script for a
# local, unsigned DMG.
#
# create-dmg is deliberately not used (it is not installed on stock macOS and
# pulls in AppleScript/Finder automation that fails headless). hdiutil is part
# of macOS and works in CI.
set -eu

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH=""
OUTPUT_DMG=""
VOLUME_NAME=""
CHECK_ONLY=0
STAGING_DIR=""

die() { echo "error: $*" >&2; exit 1; }
say() { echo "$*" >&2; }

cleanup() {
    if [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
        case "$STAGING_DIR" in
            "${TMPDIR:-/tmp}"/27blauncher-dmg.*|/tmp/27blauncher-dmg.*) rm -rf "$STAGING_DIR" ;;
            *) say "refusing to clean unexpected staging path: $STAGING_DIR" ;;
        esac
    fi
}
trap cleanup EXIT HUP INT TERM

while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP_PATH="${2:-}"; shift 2 ;;
        --output) OUTPUT_DMG="${2:-}"; shift 2 ;;
        --volume-name) VOLUME_NAME="${2:-}"; shift 2 ;;
        --check) CHECK_ONLY=1; shift ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

[ -n "$APP_PATH" ] || die "--app is required"
[ -n "$OUTPUT_DMG" ] || die "--output is required"
[ -d "$APP_PATH" ] || die "app bundle not found: $APP_PATH"
[ -f "$APP_PATH/Contents/Info.plist" ] || die "not an app bundle: $APP_PATH"

command -v hdiutil >/dev/null 2>&1 || die "hdiutil is not available"

APP_NAME="$(basename "$APP_PATH" .app)"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
[ -n "$VERSION" ] || VERSION="0.0.0"
if [ -z "$VOLUME_NAME" ]; then
    VOLUME_NAME="$APP_NAME $VERSION"
fi

# A DMG volume name may not contain a colon.
VOLUME_NAME="$(echo "$VOLUME_NAME" | tr -d ':')"

if [ "$CHECK_ONLY" -eq 1 ]; then
    say "app          : $APP_PATH"
    say "version      : $VERSION"
    say "volume name  : $VOLUME_NAME"
    say "output       : $OUTPUT_DMG"
    say "hdiutil      : $(command -v hdiutil)"
    say "layout       : $APP_NAME.app + 'Applications' symlink -> /Applications, compressed (UDZO)"
    exit 0
fi

OUTPUT_DIR="$(dirname "$OUTPUT_DMG")"
mkdir -p "$OUTPUT_DIR"
[ -d "$OUTPUT_DIR" ] || die "cannot create output directory: $OUTPUT_DIR"

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/27blauncher-dmg.XXXXXX")"

# ditto preserves the signature, symlinks and extended attributes that the
# notarization ticket lives in. cp -R would not.
ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

if [ ! -L "$STAGING_DIR/Applications" ]; then
    die "failed to stage the /Applications symlink"
fi

rm -f "$OUTPUT_DMG"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    -quiet \
    "$OUTPUT_DMG"

[ -f "$OUTPUT_DMG" ] || die "hdiutil did not produce $OUTPUT_DMG"

hdiutil verify "$OUTPUT_DMG" >/dev/null || die "hdiutil verify failed for $OUTPUT_DMG"

# Sanity check the volume layout without mounting anything writable.
mount_point="$(mktemp -d "${TMPDIR:-/tmp}/27blauncher-dmg-verify.XXXXXX")"
if hdiutil attach "$OUTPUT_DMG" -nobrowse -readonly -mountpoint "$mount_point" >/dev/null 2>&1; then
    if [ ! -d "$mount_point/$APP_NAME.app" ]; then
        hdiutil detach "$mount_point" >/dev/null 2>&1 || true
        rm -rf "$mount_point"
        die "the DMG does not contain $APP_NAME.app at its root"
    fi
    if [ ! -L "$mount_point/Applications" ]; then
        hdiutil detach "$mount_point" >/dev/null 2>&1 || true
        rm -rf "$mount_point"
        die "the DMG does not contain the /Applications symlink"
    fi
    hdiutil detach "$mount_point" >/dev/null 2>&1 || die "failed to detach $mount_point"
fi
rm -rf "$mount_point"

say "wrote $OUTPUT_DMG ($(du -h "$OUTPUT_DMG" | cut -f1))"
echo "$OUTPUT_DMG"
