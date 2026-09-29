#!/bin/sh
# Builds Resources/AppIcon.icns (.build/27BLauncher-AppIcon.icns by default).
#
# The release path is deliberately headless: it consumes the pre-rendered
# 1024x1024 master PNG committed at design/27b-launcher-icon-1024.png and only
# uses sips + iconutil, both of which work in CI and over SSH. Rendering the SVG
# requires qlmanage, a GUI-subsystem QuickLook service that silently produces
# nothing when no window server is available - that is why it is opt-in here.
#
#   build-icon.sh [--regenerate-master] [output.icns]
#
#   --regenerate-master   Re-render design/27b-launcher-icon-1024.png from the SVG
#                         using qlmanage. Developer-only, needs a GUI session;
#                         commit the result so CI and other machines do not have to.
#   --check               Validate inputs and print what would be built, then exit.
#
# The SVG stays the design source of truth. Known icon issues: baked-in drop
# shadow, non-square artwork, text-as-font glyphs.
set -eu

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_SVG="$PROJECT_DIR/design/27b-launcher-icon.svg"
MASTER_PNG="$PROJECT_DIR/design/27b-launcher-icon-1024.png"
ICONSET_DIR="$PROJECT_DIR/.build/27BLauncher.iconset"
OUTPUT_ICON="$PROJECT_DIR/.build/27BLauncher-AppIcon.icns"
REGENERATE_MASTER=0
CHECK_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --regenerate-master) REGENERATE_MASTER=1 ;;
        --check) CHECK_ONLY=1 ;;
        -h|--help)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 2
            ;;
        *) OUTPUT_ICON="$1" ;;
    esac
    shift
done

render_master_from_svg() {
    if ! command -v qlmanage >/dev/null 2>&1; then
        echo "qlmanage is not available; cannot re-render the icon master PNG." >&2
        echo "Run this on a Mac with a GUI session, or restore $MASTER_PNG from git." >&2
        exit 1
    fi

    render_dir="$(mktemp -d "${TMPDIR:-/tmp}/27blauncher-icon.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$render_dir'" EXIT HUP INT TERM

    if ! qlmanage -t -s 1024 -o "$render_dir" "$SOURCE_SVG" >/dev/null 2>&1; then
        echo "qlmanage failed to render $SOURCE_SVG." >&2
        echo "Note: qlmanage needs a GUI session and is not usable headless/in CI." >&2
        exit 1
    fi

    rendered="$render_dir/$(basename "$SOURCE_SVG").png"
    if [ ! -f "$rendered" ]; then
        echo "qlmanage did not produce an image for $SOURCE_SVG." >&2
        exit 1
    fi

    mkdir -p "$(dirname "$MASTER_PNG")"
    mv "$rendered" "$MASTER_PNG"

    trap - EXIT HUP INT TERM
    rm -rf "$render_dir"
    echo "Re-rendered icon master: $MASTER_PNG"
    echo "Commit that file: it is what every other machine and CI builds from." >&2
}

if [ "$REGENERATE_MASTER" -eq 1 ]; then
    render_master_from_svg
fi

if [ ! -f "$MASTER_PNG" ]; then
    cat >&2 <<EOF
Missing icon master PNG: $MASTER_PNG

The icon build no longer renders the SVG at build time (qlmanage is unreliable
headless). Restore the committed master, or regenerate it on a machine with a
GUI session:

    ./scripts/build-icon.sh --regenerate-master
EOF
    exit 1
fi

master_size="$(sips -g pixelWidth -g pixelHeight "$MASTER_PNG" 2>/dev/null | awk '/pixelWidth|pixelHeight/ {print $2}' | tr '\n' ' ')"
case "$master_size" in
    "1024 1024 ") ;;
    *)
        echo "Icon master must be 1024x1024, got: $master_size" >&2
        echo "Regenerate with: ./scripts/build-icon.sh --regenerate-master" >&2
        exit 1
        ;;
esac

if [ "$CHECK_ONLY" -eq 1 ]; then
    echo "icon master : $MASTER_PNG (1024x1024)"
    echo "design source: $SOURCE_SVG"
    echo "would write : $OUTPUT_ICON"
    exit 0
fi

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

for spec in \
    "16 icon_16x16.png" \
    "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" \
    "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" \
    "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" \
    "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" \
    "1024 icon_512x512@2x.png"
do
    size="${spec%% *}"
    output="${spec#* }"
    sips -z "$size" "$size" "$MASTER_PNG" --out "$ICONSET_DIR/$output" >/dev/null
done

mkdir -p "$(dirname "$OUTPUT_ICON")"
iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_ICON"
echo "$OUTPUT_ICON"
