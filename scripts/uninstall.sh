#!/bin/sh
# Uninstalls 27B Launcher and removes the state it left behind.
#
# SAFE BY DEFAULT: with no flags this only REPORTS what it would remove and how
# much space that would free. Nothing is deleted until you pass --yes.
#
#   ./scripts/uninstall.sh                  # dry run: show the plan and the sizes
#   ./scripts/uninstall.sh --yes            # actually delete
#   ./scripts/uninstall.sh --yes --trash    # move to ~/.Trash instead of deleting
#   ./scripts/uninstall.sh --yes --keep-data
#   ./scripts/uninstall.sh --keep-app --keep-preferences --yes
#   ./scripts/uninstall.sh --kill --yes     # stop the launcher/model server first
#
# What it touches (and nothing else): the app in ~/Applications, the Bonsai2
# support and log directories, this app's caches/saved state/preferences files,
# a matching LaunchAgent plist, its UserDefaults domain, and its Keychain API key.
# --keep-preferences preserves both preferences and the API key.
#
# What it cannot do from a shell: unregister the SMAppService login item. macOS
# only allows the app itself to do that, so remove it in System Settings ->
# General -> Login Items & Extensions.
set -eu

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="27B Launcher"
BUNDLE_ID="com.zenxiv.Launcher27B"

HOME_DIR="${HOME:-}"
DRY_RUN=1
USE_TRASH=0
KILL_FIRST=0
REMOVE_APP=1
REMOVE_DATA=1
REMOVE_PREFERENCES=1
ALLOW_ROOT=0

say()  { echo "$*" >&2; }
step() { echo "" ; echo "==> $*" ; }
die()  { echo "" >&2; echo "error: $*" >&2; exit 1; }
refuse() { echo "    REFUSED: $*" >&2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y) DRY_RUN=0 ;;
        --dry-run) DRY_RUN=1 ;;
        --trash) USE_TRASH=1 ;;
        --kill) KILL_FIRST=1 ;;
        --keep-app) REMOVE_APP=0 ;;
        --keep-data) REMOVE_DATA=0 ;;
        --keep-preferences) REMOVE_PREFERENCES=0 ;;
        --allow-root) ALLOW_ROOT=1 ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------

[ -n "$HOME_DIR" ] || die "HOME is not set; refusing to guess what to delete."
[ "$HOME_DIR" != "/" ] || die "HOME is /; refusing to run."
[ -d "$HOME_DIR" ] || die "HOME does not exist: $HOME_DIR"
case "$HOME_DIR" in
    /*) ;;
    *) die "HOME is not an absolute path: $HOME_DIR" ;;
esac
# A home directory directly under / (e.g. /Users) would make the allowlist below
# far too broad.
depth="$(printf '%s' "$HOME_DIR" | awk -F/ '{print NF - 1}')"
[ "$depth" -ge 2 ] || die "HOME looks too close to the filesystem root: $HOME_DIR"

if [ "$(id -u)" -eq 0 ] && [ "$ALLOW_ROOT" -ne 1 ]; then
    die "refusing to run as root (HOME would be root's home). Re-run as your own user, or pass --allow-root."
fi

# Every path we are willing to remove must sit under one of these patterns AND
# have one of the expected leaf names. Anything else is refused.
path_is_allowed() {
    path="$1"
    case "$path" in
        "$HOME_DIR"/Applications/*.app) ;;
        "$HOME_DIR"/Library/Application\ Support/*) ;;
        "$HOME_DIR"/Library/Logs/*) ;;
        "$HOME_DIR"/Library/Caches/*) ;;
        "$HOME_DIR"/Library/Preferences/*.plist) ;;
        "$HOME_DIR"/Library/Saved\ Application\ State/*) ;;
        "$HOME_DIR"/Library/HTTPStorages/*) ;;
        "$HOME_DIR"/Library/WebKit/*) ;;
        "$HOME_DIR"/Library/LaunchAgents/*.plist) ;;
        *) return 1 ;;
    esac

    case "$(basename "$path")" in
        "$APP_NAME.app"|Bonsai2|"$BUNDLE_ID"|"$BUNDLE_ID".*|"$BUNDLE_ID.plist") ;;
        *) return 1 ;;
    esac

    # The path's parent directory must still resolve inside HOME. If it cannot be
    # resolved at all, the pattern checks above are the whole guarantee.
    resolved="$(cd "$(dirname "$path")" 2>/dev/null && pwd || true)"
    if [ -n "$resolved" ]; then
        case "$resolved" in
            "$HOME_DIR"|"$HOME_DIR"/*) ;;
            *) return 1 ;;
        esac
    fi
    return 0
}

human_kb() {
    awk -v kb="$1" 'BEGIN {
        split("KB MB GB TB", unit, " ")
        value = kb
        index_ = 1
        while (value >= 1024 && index_ < 4) { value = value / 1024; index_++ }
        printf (index_ == 1 ? "%d %s" : "%.2f %s"), value, unit[index_]
    }'
}

size_of_kb() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        du -sk "$1" 2>/dev/null | awk '{print $1}' || echo 0
    else
        echo 0
    fi
}

# `sfltool dumpbtm` queries the Background Task Management daemon and has no
# timeout of its own: it has been measured anywhere from ~3 s to still running
# after 15 s on this machine, and it can block indefinitely. macOS has no
# `timeout(1)`, so bound it by hand. The default dry run must never hang here.
SFLTOOL_TIMEOUT_SECONDS="${SFLTOOL_TIMEOUT_SECONDS:-10}"

# Writes `sfltool dumpbtm` output to $1. Returns 0 when the command finished
# before the deadline, 1 when it was killed at the deadline (output is then
# whatever it had produced, not trustworthy).
sfltool_dump_with_deadline() {
    output="$1"
    : > "$output"
    sfltool dumpbtm >"$output" 2>/dev/null &
    sfltool_pid=$!
    deadline_ticks=$((SFLTOOL_TIMEOUT_SECONDS * 5))
    ticks=0
    while kill -0 "$sfltool_pid" 2>/dev/null; do
        if [ "$ticks" -ge "$deadline_ticks" ]; then
            kill -TERM "$sfltool_pid" 2>/dev/null || true
            kill -KILL "$sfltool_pid" 2>/dev/null || true
            wait "$sfltool_pid" 2>/dev/null || true
            return 1
        fi
        sleep 0.2
        ticks=$((ticks + 1))
    done
    wait "$sfltool_pid" 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------------
# Running processes
# ---------------------------------------------------------------------------

running_pids() {
    ps -axo pid=,comm= | awk \
        -v app="$HOME_DIR/Applications/$APP_NAME.app/Contents/MacOS/Launcher27B" \
        -v server="$HOME_DIR/Library/Application Support/Bonsai2/runtime/mac/llama-server" '
        { pid=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, ""); if ($0 == app || $0 == server) print pid }'
}

check_running_processes() {
    pids="$(running_pids | sort -u | tr '\n' ' ')"
    [ -n "$pids" ] || return 0

    say "    still running: $pids"
    if [ "$DRY_RUN" -eq 1 ]; then
        say "    a real run would refuse until these are stopped (or you pass --kill)"
        return 0
    fi
    if [ "$KILL_FIRST" -ne 1 ]; then
        die "27B Launcher or its model server is still running (PIDs: $pids).
Quit the launcher and stop the model server first, or re-run with --kill."
    fi
    for pid in $pids; do
        running_pids | grep -qx "$pid" || continue
        kill -TERM "$pid" 2>/dev/null || true
    done
    attempts=0
    while [ -n "$(running_pids | sort -u | tr '\n' ' ')" ] && [ "$attempts" -lt 50 ]; do
        sleep 0.2
        attempts=$((attempts + 1))
    done
    remaining="$(running_pids | sort -u | tr '\n' ' ')"
    [ -z "$remaining" ] || die "processes are still running after SIGTERM: $remaining"
    say "    stopped $pids"
}

# ---------------------------------------------------------------------------
# The plan
# ---------------------------------------------------------------------------

build_item_list() {
    if [ "$REMOVE_APP" -eq 1 ]; then
        printf 'app|%s\n' "$HOME_DIR/Applications/$APP_NAME.app"
    fi
    if [ "$REMOVE_DATA" -eq 1 ]; then
        printf 'dir|%s\n' "$HOME_DIR/Library/Application Support/Bonsai2"
        printf 'dir|%s\n' "$HOME_DIR/Library/Logs/Bonsai2"
    fi
    if [ "$REMOVE_PREFERENCES" -eq 1 ]; then
        printf 'dir|%s\n'  "$HOME_DIR/Library/Caches/$BUNDLE_ID"
        printf 'dir|%s\n'  "$HOME_DIR/Library/Saved Application State/$BUNDLE_ID.savedState"
        printf 'dir|%s\n'  "$HOME_DIR/Library/HTTPStorages/$BUNDLE_ID"
        printf 'dir|%s\n'  "$HOME_DIR/Library/WebKit/$BUNDLE_ID"
        printf 'file|%s\n' "$HOME_DIR/Library/Preferences/$BUNDLE_ID.plist"
        printf 'file|%s\n' "$HOME_DIR/Library/LaunchAgents/$BUNDLE_ID.plist"
    fi
}

verify_app_bundle() {
    app_path="$1"
    if [ ! -f "$app_path/Contents/Info.plist" ]; then
        refuse "$app_path has no Contents/Info.plist; not touching it"
        return 1
    fi
    found_id="$(plutil -extract CFBundleIdentifier raw -o - "$app_path/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$found_id" != "$BUNDLE_ID" ]; then
        refuse "$app_path has bundle id '$found_id', expected '$BUNDLE_ID'"
        return 1
    fi
    return 0
}

verify_launch_agent() {
    plist_path="$1"
    found_id="$(plutil -extract Label raw -o - "$plist_path" 2>/dev/null || true)"
    case "$found_id" in
        "$BUNDLE_ID") return 0 ;;
        *)
            refuse "$plist_path has Label '$found_id', expected one of ours"
            return 1 ;;
    esac
}

remove_path() {
    path="$1"
    if [ "$USE_TRASH" -eq 1 ]; then
        trash_dir="$HOME_DIR/.Trash"
        mkdir -p "$trash_dir" || die "cannot create $trash_dir"
        trash_target="$trash_dir/$(basename "$path")-uninstalled-$$"
        i=1
        while [ -e "$trash_target" ]; do
            trash_target="$trash_dir/$(basename "$path")-uninstalled-$$-$i"
            i=$((i + 1))
        done
        mv "$path" "$trash_target" || die "failed to move $path to $trash_target"
        say "    moved to Trash: $trash_target"
    else
        rm -rf "$path" || die "failed to remove $path"
        say "    removed: $path"
    fi
}

# ---------------------------------------------------------------------------
# Report / execute
# ---------------------------------------------------------------------------

ITEMS="$(build_item_list)"

say "27B Launcher uninstaller"
say "  home        : $HOME_DIR"
say "  mode        : $([ "$DRY_RUN" -eq 1 ] && echo 'DRY RUN (nothing will be deleted)' || echo 'DELETE')"
say "  disposition : $([ "$USE_TRASH" -eq 1 ] && echo 'move to ~/.Trash' || echo 'delete permanently')"

step "running processes"
check_running_processes

step "planned removals"
total_kb=0
removable=""
skipped=""
while IFS='|' read -r kind path; do
    [ -n "$kind" ] || continue
    if ! path_is_allowed "$path"; then
        refuse "$path is outside the locations this script is allowed to touch"
        skipped="$skipped$path (outside allowlist)
"
        continue
    fi
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        continue
    fi

    case "$kind" in
        app)
            verify_app_bundle "$path" || { skipped="$skipped$path (bundle id mismatch)
"; continue; } ;;
        file)
            # Dispatch on the directory, not the file name: the preferences plist
            # and the LaunchAgent plist can share a name.
            case "$(dirname "$path")" in
                "$HOME_DIR/Library/Preferences")
                    case "$(basename "$path")" in
                        "$BUNDLE_ID.plist") ;;
                        *)
                            refuse "unexpected preferences file: $path"
                            skipped="$skipped$path (unexpected preferences file)
"
                            continue ;;
                    esac ;;
                "$HOME_DIR/Library/LaunchAgents")
                    verify_launch_agent "$path" || {
                        skipped="$skipped$path (not our LaunchAgent)
"
                        continue
                    } ;;
                *)
                    refuse "unexpected file location: $path"
                    skipped="$skipped$path (unexpected location)
"
                    continue ;;
            esac ;;
    esac

    item_kb="$(size_of_kb "$path")"
    total_kb=$((total_kb + item_kb))
    removable="$removable$kind|$path|$item_kb
"

    if [ -L "$path" ]; then
        say "  $(human_kb "$item_kb")  $path"
        say "            (symlink to $(readlink "$path") - only the link is removed)"
    else
        say "  $(human_kb "$item_kb")  $path"
    fi
done <<EOF
$ITEMS
EOF

location_record="$HOME_DIR/Library/Application Support/Bonsai2/model-location.json"
if [ "$REMOVE_DATA" -eq 1 ] && [ -f "$location_record" ]; then
    external_models="$(plutil -extract path raw -o - "$location_record" 2>/dev/null || true)"
    say "  configured models outside the support directory are preserved: $external_models"
fi

if [ "$REMOVE_PREFERENCES" -eq 1 ]; then
    step "preferences and credentials"
    say "  defaults delete $BUNDLE_ID"
    say "  delete Keychain item: $BUNDLE_ID / llama-server-api-key"
fi

step "login item (cannot be done from a shell)"
if command -v sfltool >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
    btm_dump="$(mktemp "${TMPDIR:-/tmp}/27blauncher-btm.XXXXXX")"
    if sfltool_dump_with_deadline "$btm_dump"; then
        btm_hits="$(grep -c "$BUNDLE_ID" "$btm_dump" || true)"
        if [ "${btm_hits:-0}" -gt 0 ]; then
            say "  SMAppService still has a record for $BUNDLE_ID."
        else
            say "  no SMAppService record found for $BUNDLE_ID (or sfltool needs sudo to show it)."
        fi
    else
        say "  could not determine Background Task Management records: sfltool dumpbtm did not finish within ${SFLTOOL_TIMEOUT_SECONDS}s and was stopped."
        say "  this check is informational; look under System Settings -> General -> Login Items & Extensions instead."
    fi
    rm -f "$btm_dump"
else
    say "  sfltool not available; cannot inspect Background Task Management records."
fi
say "  Remove it manually: System Settings -> General -> Login Items & Extensions"
say "  -> remove \"$APP_NAME\" from 'Open at Login'."

step "summary"
say "  space freed by a real run: $(human_kb "$total_kb")"
if [ -n "$skipped" ]; then
    say "  skipped:"
    printf '%s' "$skipped" | sed 's/^/    /' >&2
fi
if [ "$USE_TRASH" -eq 1 ]; then
    say "  NOTE: moved items still occupy space until you empty the Trash."
fi

if [ "$DRY_RUN" -eq 1 ]; then
    cat >&2 <<EOF

DRY RUN: nothing was deleted.

Run it for real with:

    ./scripts/uninstall.sh --yes

Add --keep-data to keep ~/Library/Application Support/Bonsai2 (the model and
runtime, several GB), or --trash to move things to the Trash instead.
EOF
    exit 0
fi

step "removing"
while IFS='|' read -r kind path item_kb; do
    [ -n "$kind" ] || continue
    remove_path "$path"
done <<EOF
$removable
EOF

if [ "$REMOVE_PREFERENCES" -eq 1 ]; then
    step "preferences and credentials"
    defaults delete "$BUNDLE_ID" 2>/dev/null || true
    if security delete-generic-password -s "$BUNDLE_ID" -a "llama-server-api-key" >/dev/null 2>&1; then
        say "    removed API key from Keychain"
    else
        keychain_status=$?
        [ "$keychain_status" -eq 44 ] || die "Keychain deletion failed; remove the launcher API key in Keychain Access."
    fi
fi

step "done"
say "  freed approximately $(human_kb "$total_kb")"
say "  the app is gone; remove the login item in System Settings if it remains."
