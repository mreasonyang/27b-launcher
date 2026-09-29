#!/bin/sh
# Signs, notarizes, staples and packages a public release of 27B Launcher.
#
#   ./scripts/sign-and-notarize.sh --check     # validate the setup, change nothing
#   ./scripts/sign-and-notarize.sh             # the real thing
#
# What a real run does, in order:
#   1. rebuild the app with a Developer ID signature, hardened runtime and
#      secure timestamp (scripts/build-app.sh)
#   2. verify signature / hardened runtime and that the version
#      advances past the last v* tag
#   3. zip the .app into .build/ (outside dist/) and submit it with notarytool
#   4. staple the .app, then validate the staple and Gatekeeper verdict
#   5. build the DMG from the STAPLED app, sign it, notarize it, staple it
#   6. write the final ZIP (of the stapled app) and DMG plus SHA-256 sidecars
#   7. prove the shipped ZIP really is accepted by Gatekeeper by extracting it
#      to a temp dir and running stapler validate + spctl on the copy
#
# A ZIP cannot hold a notarization ticket, and an ad-hoc signed app can never be
# notarized, which is why the .app is stapled before it is zipped.
#
# Credentials - never hardcoded, never written to disk by this script:
#   NOTARYTOOL_PROFILE   name of a `xcrun notarytool store-credentials` profile
#                        (preferred). Store it once with:
#                          xcrun notarytool store-credentials "$NOTARYTOOL_PROFILE" \
#                              --apple-id <you@example.com> --team-id <TEAMID> \
#                              --password <app-specific-password>
#   or, instead of a profile:
#   AC_API_KEY_PATH + AC_API_KEY_ID [+ AC_API_ISSUER_ID]   App Store Connect API key
#   AC_APPLE_ID + AC_TEAM_ID + AC_PASSWORD                 Apple ID + app password
#
# Other environment variables:
#   SIGNING_IDENTITY   "Developer ID Application: Name (TEAMID)"  (required)
#   NOTARYTOOL_KEYCHAIN  optional keychain path for the profile
#   NOTARY_TIMEOUT     notarytool --wait timeout (default 30m)
#   SKIP_DMG=1         skip DMG creation/notarization
#   SKIP_BUILD=1       reuse the existing dist/ app (it must already be signed)
#   ALLOW_VERSION_REGRESSION=1  bypass the version monotonicity assertions
set -eu

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="27B Launcher"
APP_DIR="$PROJECT_DIR/dist/$APP_NAME.app"
WORK_DIR="$PROJECT_DIR/.build/notarize"

# shellcheck source=scripts/version.sh
. "$PROJECT_DIR/scripts/version.sh"

# Dist artifact base name, identical to the one scripts/package-release.sh uses.
ARTIFACT_BASENAME="27B-Launcher-$MARKETING_VERSION-macOS-$SUPPORTED_ARCHS"

SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-}"
NOTARYTOOL_KEYCHAIN="${NOTARYTOOL_KEYCHAIN:-}"
AC_API_KEY_PATH="${AC_API_KEY_PATH:-}"
AC_API_KEY_ID="${AC_API_KEY_ID:-}"
AC_API_ISSUER_ID="${AC_API_ISSUER_ID:-}"
AC_APPLE_ID="${AC_APPLE_ID:-}"
AC_TEAM_ID="${AC_TEAM_ID:-}"
AC_PASSWORD="${AC_PASSWORD:-}"
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-30m}"
SKIP_DMG="${SKIP_DMG:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"
ALLOW_VERSION_REGRESSION="${ALLOW_VERSION_REGRESSION:-0}"

MODE="release"          # release | check
MISSING_COUNT=0
CREDENTIAL_SOURCE=""

say()  { echo "$*" >&2; }
step() { echo "" >&2; echo "==> $*" >&2; }

# macOS 26 prints the combined form "flags=0x10002(adhoc,runtime)", older
# releases print "flags=0x10000(runtime)"; match both.
has_hardened_runtime() {
    codesign -dv --verbose=4 "$1" 2>&1 | grep -Eq 'flags=0x[0-9a-f]+\([^)]*runtime'
}
die()  { echo "" >&2; echo "error: $*" >&2; exit 1; }
missing() { MISSING_COUNT=$((MISSING_COUNT + 1)); echo "MISSING  $*" >&2; }
ok()      { echo "ok       $*" >&2; }
warn()    { echo "WARNING  $*" >&2; }

# macOS has no `timeout(1)`. Some informational checks below are network calls
# (`stapler validate` can fetch a ticket, `spctl` can consult Apple), and a
# `--check` dry run must not block on them, so each gets a deadline.
#
# Usage: bounded_capture <seconds> <output-file> <command> [args...]
# Returns the command's exit status, or 124 when it was killed at the deadline.
bounded_capture() {
    seconds="$1"
    outfile="$2"
    shift 2
    : > "$outfile"
    "$@" >"$outfile" 2>&1 &
    bounded_pid=$!
    bounded_ticks=0
    bounded_limit=$((seconds * 5))
    while kill -0 "$bounded_pid" 2>/dev/null; do
        if [ "$bounded_ticks" -ge "$bounded_limit" ]; then
            kill -TERM "$bounded_pid" 2>/dev/null || true
            kill -KILL "$bounded_pid" 2>/dev/null || true
            wait "$bounded_pid" 2>/dev/null || true
            return 124
        fi
        sleep 0.2
        bounded_ticks=$((bounded_ticks + 1))
    done
    wait "$bounded_pid" 2>/dev/null
}

usage() {
    sed -n '2,40p' "$0"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --check|--dry-run|-n) MODE="check" ;;
        --skip-dmg) SKIP_DMG=1 ;;
        --skip-build) SKIP_BUILD=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------

resolve_credential_source() {
    if [ -n "$NOTARYTOOL_PROFILE" ]; then
        CREDENTIAL_SOURCE="profile"
        return 0
    fi
    if [ -n "$AC_API_KEY_PATH" ] && [ -n "$AC_API_KEY_ID" ]; then
        CREDENTIAL_SOURCE="api-key"
        return 0
    fi
    if [ -n "$AC_APPLE_ID" ] && [ -n "$AC_TEAM_ID" ] && [ -n "$AC_PASSWORD" ]; then
        CREDENTIAL_SOURCE="apple-id"
        return 0
    fi
    CREDENTIAL_SOURCE=""
}

# Appends the credential flags to a notarytool invocation.
# Usage: notarytool submit <file> --wait <credential flags>
notarytool() {
    case "$CREDENTIAL_SOURCE" in
        profile)
            if [ -n "$NOTARYTOOL_KEYCHAIN" ]; then
                xcrun notarytool "$@" --keychain-profile "$NOTARYTOOL_PROFILE" --keychain "$NOTARYTOOL_KEYCHAIN"
            else
                xcrun notarytool "$@" --keychain-profile "$NOTARYTOOL_PROFILE"
            fi
            ;;
        api-key)
            if [ -n "$AC_API_ISSUER_ID" ]; then
                xcrun notarytool "$@" --key "$AC_API_KEY_PATH" --key-id "$AC_API_KEY_ID" --issuer "$AC_API_ISSUER_ID"
            else
                xcrun notarytool "$@" --key "$AC_API_KEY_PATH" --key-id "$AC_API_KEY_ID"
            fi
            ;;
        apple-id)
            xcrun notarytool "$@" --apple-id "$AC_APPLE_ID" --team-id "$AC_TEAM_ID" --password "$AC_PASSWORD"
            ;;
        *)
            die "internal error: no credential source resolved"
            ;;
    esac
}

describe_credential_plan() {
    case "$CREDENTIAL_SOURCE" in
        profile)  echo "notarytool --keychain-profile <profile>" ;;
        api-key)  echo "notarytool --key <private key> --key-id <key id>" ;;
        apple-id) echo "notarytool --apple-id <apple id> --team-id <team id> --password <app-specific password>" ;;
        *)        echo "(no credentials configured)" ;;
    esac
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

PREFLIGHT_FAILURES=0

check_toolchain() {
    step "toolchain"
    for tool in xcrun codesign spctl hdiutil stapler; do
        if command -v "$tool" >/dev/null 2>&1; then
            ok "$tool ($(command -v "$tool"))"
        else
            missing "$tool not found in PATH"
            PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1))
        fi
    done

    if xcrun -f notarytool >/dev/null 2>&1; then
        ok "notarytool $(xcrun notarytool --version 2>/dev/null | head -n 1) ($(xcrun -f notarytool))"
    else
        missing "notarytool (needs Xcode 13+; xcrun -f notarytool fails)"
        PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1))
    fi

    if xcode-select -p 2>/dev/null | grep -q 'CommandLineTools$'; then
        warn "xcode-select points at CommandLineTools; full Xcode is required for notarization."
    fi
}

check_signing_identity() {
    step "signing identity"
    if [ -z "$SIGNING_IDENTITY" ]; then
        missing "SIGNING_IDENTITY is not set"
        say "         Set it to a 'Developer ID Application' certificate, e.g."
        say "         SIGNING_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\""
        say "         Create one at https://developer.apple.com/account/resources/certificates"
        say "         (Certificates, Identifiers & Profiles -> Certificates -> Developer ID Application)."
        PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1))
    elif [ "$SIGNING_IDENTITY" = "-" ]; then
        missing "SIGNING_IDENTITY is '-' (ad-hoc): ad-hoc signed apps cannot be notarized"
        PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1))
    elif security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGNING_IDENTITY"; then
        ok "keychain identity: $SIGNING_IDENTITY"
        case "$SIGNING_IDENTITY" in
            "Developer ID Application:"*|"Developer ID Application "*)
                ok "certificate type looks like Developer ID Application" ;;
            *)
                missing "\"$SIGNING_IDENTITY\" is not a 'Developer ID Application' certificate; the notary service rejects other types"
                PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1)) ;;
        esac
    else
        missing "no keychain identity matches \"$SIGNING_IDENTITY\""
        say "         Identities currently in the keychain:"
        security find-identity -v -p codesigning 2>/dev/null | sed 's/^/         /' >&2 || true
        PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1))
    fi
}

check_credentials() {
    step "notarization credentials"
    resolve_credential_source
    case "$CREDENTIAL_SOURCE" in
        profile)
            ok "NOTARYTOOL_PROFILE=<name> ($(describe_credential_plan))"
            if command -v security >/dev/null 2>&1; then
                if security find-generic-password -s "com.apple.gke.notary.tool" -a "$NOTARYTOOL_PROFILE" >/dev/null 2>&1; then
                    ok "keychain profile \"$NOTARYTOOL_PROFILE\" exists (com.apple.gke.notary.tool)"
                else
                    missing "keychain has no stored notarytool profile named \"$NOTARYTOOL_PROFILE\""
                    say "         Store it once (not committed, lives in your login keychain):"
                    say "           xcrun notarytool store-credentials \"$NOTARYTOOL_PROFILE\" \\"
                    say "               --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific-password>"
                    PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1))
                fi
            fi
            ;;
        api-key)
            ok "App Store Connect API key credentials from environment"
            [ -f "$AC_API_KEY_PATH" ] || { missing "AC_API_KEY_PATH does not point at a file: $AC_API_KEY_PATH"; PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1)); }
            ;;
        apple-id)
            ok "Apple ID credentials from environment"
            warn "AC_PASSWORD must be an app-specific password, not your Apple ID password."
            ;;
        *)
            missing "no notarization credentials configured (NOTARYTOOL_PROFILE, AC_API_KEY_PATH/AC_API_KEY_ID or AC_APPLE_ID/AC_TEAM_ID/AC_PASSWORD)"
            say "         Nothing is ever read from the repository: credentials only come from"
            say "         the environment or from a notarytool keychain profile."
            PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1))
            ;;
    esac
}

latest_release_tag() {
    git -C "$PROJECT_DIR" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true
}

# Rebuilding the tagged release commit (CI, or a retried notarization) must not
# trip the build-number bump check.
head_is_release_tag() {
    [ -n "$(git -C "$PROJECT_DIR" describe --tags --exact-match --match 'v[0-9]*' HEAD 2>/dev/null || true)" ]
}

check_version() {
    step "version"
    ok "scripts/version.sh: $MARKETING_VERSION ($BUILD_NUMBER), min macOS $MINIMUM_SYSTEM_VERSION, arch $SUPPORTED_ARCHS"
    if [ "$ALLOW_VERSION_REGRESSION" -eq 1 ]; then
        warn "ALLOW_VERSION_REGRESSION=1: version monotonicity checks are disabled."
        return 0
    fi
    tag="$(latest_release_tag)"
    if [ -z "$tag" ]; then
        warn "no v* git tag exists yet, so build-number monotonicity cannot be checked here."
        return 0
    fi
    if head_is_release_tag; then
        ok "HEAD is the tagged release $tag; skipping the build-number bump check."
        return 0
    fi
    released_build="$(
        git -C "$PROJECT_DIR" show "$tag:scripts/version.sh" 2>/dev/null \
            | sed -n 's/^BUILD_NUMBER="\([0-9][0-9]*\)".*/\1/p' | head -n 1
    )"
    released_marketing="$(
        git -C "$PROJECT_DIR" show "$tag:scripts/version.sh" 2>/dev/null \
            | sed -n 's/^MARKETING_VERSION="\([0-9.]*\)".*/\1/p' | head -n 1
    )"
    if [ -z "$released_build" ]; then
        warn "$tag predates scripts/version.sh; cannot check monotonicity against it."
        return 0
    fi
    if [ "$MARKETING_VERSION" = "$released_marketing" ] && [ "$BUILD_NUMBER" -le "$released_build" ]; then
        missing "$tag already shipped $released_marketing ($released_build); BUILD_NUMBER must strictly increase (currently $BUILD_NUMBER)"
        PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1))
    else
        ok "version advances past $tag ($released_marketing, build $released_build)"
    fi
}

check_existing_app() {
    step "existing app bundle"
    if [ ! -d "$APP_DIR" ]; then
        say "         dist/$APP_NAME.app does not exist yet; the release run builds it."
        return 0
    fi
    existing_version="$(plutil -extract CFBundleShortVersionString raw -o - "$APP_DIR/Contents/Info.plist" 2>/dev/null || echo '?')"
    existing_build="$(plutil -extract CFBundleVersion raw -o - "$APP_DIR/Contents/Info.plist" 2>/dev/null || echo '?')"
    say "         dist app: $existing_version ($existing_build)"

    details="$(codesign -dv --verbose=4 "$APP_DIR" 2>&1 || true)"
    case "$details" in
        *"TeamIdentifier=not set"*) say "         signature: ad-hoc (TeamIdentifier not set)" ;;
        *) say "         signature: $(echo "$details" | sed -n 's/^Authority=//p' | head -n 1)" ;;
    esac
    if has_hardened_runtime "$APP_DIR"; then
        say "         hardened runtime: on"
    else
        say "         hardened runtime: off (set by a Developer ID build)"
    fi
    # Both of these can go out to the network (stapler may download a ticket,
    # spctl may consult Apple), so bound them: --check must never hang.
    probe_out="$(mktemp "${TMPDIR:-/tmp}/27blauncher-probe.XXXXXX")"

    staple_rc=0
    bounded_capture 20 "$probe_out" xcrun stapler validate "$APP_DIR" || staple_rc=$?
    if [ "$staple_rc" -eq 124 ]; then
        say "         stapler validate: no answer within 20s (network?); skipped"
    elif [ "$staple_rc" -eq 0 ]; then
        say "         stapler validate: ok (note: stapler can also fetch a ticket online, so this is not proof of a local staple)"
    else
        say "         stapler validate: no ticket (expected until notarized)"
    fi

    spctl_rc=0
    bounded_capture 20 "$probe_out" spctl --assess --type execute "$APP_DIR" || spctl_rc=$?
    if [ "$spctl_rc" -eq 124 ]; then
        say "         spctl: no answer within 20s (network?); skipped"
    else
        say "         spctl: $(head -n 1 "$probe_out")"
    fi
    rm -f "$probe_out"
}

check_build_inputs() {
    step "build inputs"
    if [ "$SKIP_BUILD" -eq 1 ]; then
        warn "SKIP_BUILD=1: dist/ app is reused as-is; it will NOT be re-signed."
    else
        ok "swift: $(swift --version 2>/dev/null | head -n 1)"
        if [ -f "$PROJECT_DIR/design/27b-launcher-icon-1024.png" ]; then
            ok "icon master present (headless icon build)"
        else
            missing "design/27b-launcher-icon-1024.png is missing; the icon build needs it (see scripts/build-icon.sh --regenerate-master)"
            PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1))
        fi
    fi
}

print_plan() {
    step "what a real run would do"
    cat >&2 <<EOF
  1. SIGNING_IDENTITY=... REQUIRE_SIGNING=1 REQUIRE_VERSION_BUMP=1 ./scripts/build-app.sh
       -> rebuild + sign with hardened runtime and secure timestamp
  2. verify signature and hardened runtime
  3. ditto -c -k --keepParent "$APP_DIR" "$WORK_DIR/submission.zip"
  4. $(describe_credential_plan) submit "$WORK_DIR/submission.zip" --wait --timeout $NOTARY_TIMEOUT
  5. xcrun stapler staple "$APP_DIR"   (then stapler validate + spctl)
  6. scripts/make-dmg.sh -> dist/$ARTIFACT_BASENAME.dmg
  7. codesign the DMG, submit it, staple it, spctl --assess --type open
  8. write $ARTIFACT_BASENAME.zip (of the stapled app) + .sha256
  9. extract that ZIP in a temp dir and prove stapler validate + spctl accept it
EOF
}

preflight() {
    check_toolchain
    check_signing_identity
    check_credentials
    check_version
    check_build_inputs
    check_existing_app

    if [ "$MODE" = "check" ]; then
        print_plan
        echo "" >&2
        if [ "$PREFLIGHT_FAILURES" -eq 0 ]; then
            echo "READY: everything required for signing + notarization is present." >&2
            exit 0
        fi
        echo "NOT READY: $PREFLIGHT_FAILURES blocking problem(s) listed above." >&2
        echo "Nothing was signed, submitted or modified." >&2
        exit 1
    fi

    if [ "$PREFLIGHT_FAILURES" -gt 0 ]; then
        die "$PREFLIGHT_FAILURES blocking problem(s) above; run --check after fixing them."
    fi
}

# ---------------------------------------------------------------------------
# Release steps
# ---------------------------------------------------------------------------

assert_signed_app() {
    step "verifying the signed app"
    codesign --verify --deep --strict --verbose=2 "$APP_DIR" >&2
    details="$(codesign -dv --verbose=4 "$APP_DIR" 2>&1 || true)"
    if has_hardened_runtime "$APP_DIR"; then
        ok "hardened runtime is enabled"
    else
        die "hardened runtime is not enabled on $APP_DIR"
    fi
    if echo "$details" | grep -q 'TeamIdentifier=not set'; then
        die "$APP_DIR is ad-hoc signed; notarization would reject it"
    fi
    case "$details" in
        *"Developer ID Application"*) ;;
        *) die "$APP_DIR is not signed with a Developer ID Application certificate" ;;
    esac
    applied="$(codesign -d --entitlements - "$APP_DIR" 2>/dev/null || true)"
    case "$applied" in
        *com.apple.security.cs.disable-library-validation*|*com.apple.security.app-sandbox*)
            die "unexpected code-signing entitlement found; the launcher must not grant library validation bypass or app sandbox"
            ;;
    esac
    ok "Developer ID signature, hardened runtime, no unnecessary entitlements"
}

notarize() {
    artifact="$1"
    label="$2"

    step "submitting $label to the notary service"
    say "    this uploads to Apple and usually takes 1-15 minutes"
    if output="$(notarytool submit "$artifact" --wait --timeout "$NOTARY_TIMEOUT" --output-format plist)"; then
        :
    else
        echo "$output" >&2 || true
        die "notarytool submit failed for $artifact"
    fi

    submission_id="$(printf '%s' "$output" | plutil -extract id raw -o - - 2>/dev/null || true)"
    status="$(printf '%s' "$output" | plutil -extract status raw -o - - 2>/dev/null || true)"
    if [ -z "$status" ]; then
        printf '%s\n' "$output" >&2
        die "could not parse the notarytool response for $artifact"
    fi
    say "    submission $submission_id: $status"

    if [ "$status" != "Accepted" ]; then
        say "    fetching the notary log:"
        notarytool log "$submission_id" >&2 || true
        die "notarization of $label was not accepted (status: $status)"
    fi
}

staple_and_validate_app() {
    step "stapling the app"
    xcrun stapler staple "$APP_DIR" >&2
    xcrun stapler validate "$APP_DIR" >&2
    staple_output="$(xcrun stapler validate "$APP_DIR" 2>&1 || true)"
    case "$staple_output" in
        *"Downloaded ticket"*)
            warn "stapler had to download the ticket, which suggests the ticket is not stored locally."
            warn "The app is still accepted online, but offline first launch may differ." ;;
        *) ok "ticket is present locally on the .app" ;;
    esac

    verdict="$(spctl --assess --type execute -vv "$APP_DIR" 2>&1 || true)"
    say "$verdict" | sed 's/^/    /' >&2
    case "$verdict" in
        *accepted*) ok "Gatekeeper accepts the app" ;;
        *) die "spctl rejected the stapled app: $verdict" ;;
    esac
}

build_and_notarize_dmg() {
    step "building the DMG from the stapled app"
    dmg_path="$PROJECT_DIR/dist/$ARTIFACT_BASENAME.dmg"
    rm -f "$dmg_path"
    "$PROJECT_DIR/scripts/make-dmg.sh" \
        --app "$APP_DIR" \
        --output "$dmg_path" \
        --volume-name "$APP_NAME $MARKETING_VERSION" >/dev/null
    size_before="$(stat -f %z "$dmg_path")"

    step "signing the DMG"
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$dmg_path"
    codesign --verify --strict --verbose=2 "$dmg_path" >&2

    notarize "$dmg_path" "the DMG"

    step "stapling the DMG"
    xcrun stapler staple "$dmg_path" >&2
    xcrun stapler validate "$dmg_path" >&2
    size_after="$(stat -f %z "$dmg_path")"
    if [ "$size_after" -le "$size_before" ]; then
        warn "the DMG did not grow after stapling ($size_before -> $size_after); the ticket may be missing."
    else
        ok "ticket appended to the DMG (+$((size_after - size_before)) bytes)"
    fi

    verdict="$(spctl --assess --type open --context context:primary-signature -vv "$dmg_path" 2>&1 || true)"
    say "$verdict" | sed 's/^/    /' >&2
    case "$verdict" in
        *accepted*) ok "Gatekeeper accepts the DMG" ;;
        *) die "spctl rejected the DMG: $verdict" ;;
    esac

    echo "$dmg_path"
}

write_final_artifacts() {
    step "writing final artifacts"
    zip_path="$PROJECT_DIR/dist/$ARTIFACT_BASENAME.zip"
    rm -f "$zip_path" "$zip_path.sha256"
    COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$APP_DIR" "$zip_path"
    if unzip -Z1 "$zip_path" | grep -q '^__MACOSX/'; then
        die "package contains unexpected __MACOSX metadata."
    fi
    (
        cd "$(dirname "$zip_path")"
        shasum -a 256 "$(basename "$zip_path")" > "$(basename "$zip_path").sha256"
    )
    ok "wrote $zip_path (+ .sha256)"

    if [ "$SKIP_DMG" -eq 0 ]; then
        dmg_path="$PROJECT_DIR/dist/$ARTIFACT_BASENAME.dmg"
        (
            cd "$(dirname "$dmg_path")"
            shasum -a 256 "$(basename "$dmg_path")" > "$(basename "$dmg_path").sha256"
        )
        ok "wrote $dmg_path (+ .sha256)"
    fi

    echo "$zip_path"
}

verify_shipped_zip() {
    step "verifying the ZIP a user would download"
    zip_path="$1"
    verify_dir="$WORK_DIR/zip-verify"
    rm -rf "$verify_dir"
    mkdir -p "$verify_dir"
    ditto -x -k "$zip_path" "$verify_dir"

    extracted="$verify_dir/$APP_NAME.app"
    [ -d "$extracted" ] || die "the ZIP does not contain $APP_NAME.app at its root"

    codesign --verify --deep --strict --verbose=2 "$extracted" >&2
    if ! xcrun stapler validate "$extracted" >&2; then
        die "the app extracted from the ZIP has no usable ticket"
    fi
    verdict="$(spctl --assess --type execute -vv "$extracted" 2>&1 || true)"
    say "$verdict" | sed 's/^/    /' >&2
    case "$verdict" in
        *accepted*) ok "the shipped ZIP contains a Gatekeeper-accepted, stapled app" ;;
        *) die "the app inside the ZIP is not accepted by Gatekeeper: $verdict" ;;
    esac
    rm -rf "$verify_dir"
}

# ---------------------------------------------------------------------------

preflight

mkdir -p "$WORK_DIR"
case "$WORK_DIR" in
    "$PROJECT_DIR"/.build/*) ;;
    *) die "refusing to use unexpected work directory: $WORK_DIR" ;;
esac

if [ "$SKIP_BUILD" -eq 1 ]; then
    say "SKIP_BUILD=1: reusing the existing dist/$APP_NAME.app"
else
    step "building and signing"
    SIGNING_IDENTITY="$SIGNING_IDENTITY" REQUIRE_SIGNING=1 REQUIRE_VERSION_BUMP=1 \
        ALLOW_VERSION_REGRESSION="$ALLOW_VERSION_REGRESSION" \
        "$PROJECT_DIR/scripts/build-app.sh"
fi

assert_signed_app

step "preparing the notarization archive"
rm -f "$WORK_DIR/submission.zip"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$APP_DIR" "$WORK_DIR/submission.zip"
ls -lh "$WORK_DIR/submission.zip" >&2

notarize "$WORK_DIR/submission.zip" "the app"
staple_and_validate_app

dmg_path=""
if [ "$SKIP_DMG" -eq 0 ]; then
    dmg_path="$(build_and_notarize_dmg)"
else
    warn "SKIP_DMG=1: no DMG was produced or notarized."
fi

zip_path="$(write_final_artifacts)"
verify_shipped_zip "$zip_path"

step "done"
ok "notarized and stapled: $APP_DIR"
if [ -n "$dmg_path" ]; then
    ok "notarized and stapled: $dmg_path"
fi
say ""
say "Next steps (nothing below is executed for you):"
say "  git tag -a v$MARKETING_VERSION -m \"27B Launcher $MARKETING_VERSION\""
say "  git push origin main --tags"
say "  gh release create v$MARKETING_VERSION \\"
say "      \"dist/$ARTIFACT_BASENAME.dmg\" \\"
say "      \"dist/$ARTIFACT_BASENAME.zip\" \\"
say "      \"dist/$ARTIFACT_BASENAME.zip.sha256\" \\"
say "      --title \"27B Launcher $MARKETING_VERSION\" --generate-notes"
say ""
say "Pushing the tag can trigger a GitHub Actions release workflow if one is"
say "configured for the repository."
