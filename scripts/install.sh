#!/bin/sh
set -eu

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="27B Launcher"
SOURCE_APP="$PROJECT_DIR/dist/$APP_NAME.app"
DESTINATION_DIR="$HOME/Applications"
DESTINATION_APP="$DESTINATION_DIR/$APP_NAME.app"
STAGING_ROOT=""

cleanup() {
    if [ -n "$STAGING_ROOT" ] && [ -d "$STAGING_ROOT" ]; then
        case "$STAGING_ROOT" in
            "$DESTINATION_DIR"/.launcher27b-install.*) rm -rf "$STAGING_ROOT" ;;
            *) echo "Refusing to clean unexpected staging path: $STAGING_ROOT" >&2 ;;
        esac
    fi
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

terminate_if_running() {
    executable_path="$1"
    running_pid="$(ps -axo pid=,comm= | awk -v expected="$executable_path" '{ pid=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, ""); if ($0 == expected) { print pid; exit } }')"
    if [ -z "$running_pid" ]; then
        return
    fi

    kill -TERM "$running_pid"

    attempts=0
    while kill -0 "$running_pid" 2>/dev/null && [ "$attempts" -lt 50 ]; do
        sleep 0.1
        attempts=$((attempts + 1))
    done

    if kill -0 "$running_pid" 2>/dev/null; then
        echo "27B Launcher is still running; quit it and retry installation." >&2
        exit 1
    fi
}

"$PROJECT_DIR/scripts/build-app.sh"
mkdir -p "$DESTINATION_DIR"

terminate_if_running "$DESTINATION_APP/Contents/MacOS/Launcher27B"

STAGING_ROOT="$(mktemp -d "$DESTINATION_DIR/.launcher27b-install.XXXXXX")"
STAGED_APP="$STAGING_ROOT/$APP_NAME.app"
PREVIOUS_APP="$STAGING_ROOT/Previous.app"
ditto "$SOURCE_APP" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

if [ -e "$DESTINATION_APP" ]; then
    case "$DESTINATION_APP" in
        "$HOME"/Applications/*.app) mv "$DESTINATION_APP" "$PREVIOUS_APP" ;;
        *) echo "Refusing to replace unexpected path: $DESTINATION_APP" >&2; exit 1 ;;
    esac
fi

if ! mv "$STAGED_APP" "$DESTINATION_APP"; then
    if [ -e "$PREVIOUS_APP" ] && [ ! -e "$DESTINATION_APP" ]; then
        mv "$PREVIOUS_APP" "$DESTINATION_APP"
    fi
    echo "Installation failed; the previous app was restored." >&2
    exit 1
fi

if ! codesign --verify --deep --strict "$DESTINATION_APP"; then
    rm -rf "$DESTINATION_APP"
    if [ -e "$PREVIOUS_APP" ]; then
        mv "$PREVIOUS_APP" "$DESTINATION_APP"
    fi
    echo "Installed app failed signature verification; the previous app was restored." >&2
    exit 1
fi

# Tell the user which Gatekeeper state they just installed. Ad-hoc builds open
# fine here but are rejected on other Macs.
installed_signature="$(codesign -dv --verbose=4 "$DESTINATION_APP" 2>&1 || true)"
case "$installed_signature" in
    *"Developer ID Application"*)
        echo "Installed app is signed with a Developer ID."
        ;;
    *)
        echo "note: the installed app has an ad-hoc signature (no Developer ID)." >&2
        echo "      It runs on this Mac; other Macs will refuse it until it is built" >&2
        echo "      with scripts/sign-and-notarize.sh." >&2
        ;;
esac

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DESTINATION_APP"
open "$DESTINATION_APP"

echo "$DESTINATION_APP"
