#!/bin/sh
# Builds "27B Launcher.app" into dist/.
#
# Version numbers come from scripts/version.sh (single source of truth) and are
# stamped into the copy of Info.plist that ships inside the bundle.
#
# Signing is parameterized:
#
#   no SIGNING_IDENTITY (default)      ad-hoc signature, no hardened runtime.
#                                      Local development only. A public user who
#                                      downloads this build sees "app is damaged".
#   SIGNING_IDENTITY="Developer ID ..." hardened runtime + secure timestamp.
#                                      Required for notarization.
#                                      Then run scripts/sign-and-notarize.sh.
#   SIGNING_IDENTITY="-"               explicit ad-hoc (same as the default).
#
# Useful environment variables:
#   REQUIRE_SIGNING=1          Fail instead of silently falling back to ad-hoc.
#   HARDENED_ADHOC=1           Ad-hoc sign with hardened runtime, to reproduce
#                              the notarized runtime environment locally.
#   REQUIRE_VERSION_BUMP=1     Also assert that the build number strictly
#                              increases past the newest v* tag. Set by the
#                              release scripts; off for everyday builds so that
#                              working on main after a release does not fail.
#   ALLOW_VERSION_REGRESSION=1 Skip the version assertions (throwaway builds).
#
# The downgrade floor lives in scripts/version-baseline and is updated with the
# minimum supported marketing version.
set -eu

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="27B Launcher"
APP_DIR="$PROJECT_DIR/dist/$APP_NAME.app"
ICON_FILE="$PROJECT_DIR/.build/27BLauncher-AppIcon.icns"
PLIST_TEMPLATE="$PROJECT_DIR/Resources/Info.plist"
BASELINE_FILE="$PROJECT_DIR/scripts/version-baseline"

# shellcheck source=scripts/version.sh
. "$PROJECT_DIR/scripts/version.sh"

SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
REQUIRE_SIGNING="${REQUIRE_SIGNING:-0}"
HARDENED_ADHOC="${HARDENED_ADHOC:-0}"
REQUIRE_VERSION_BUMP="${REQUIRE_VERSION_BUMP:-0}"
ALLOW_VERSION_REGRESSION="${ALLOW_VERSION_REGRESSION:-0}"

say()  { echo "$*" >&2; }
die()  { echo "error: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Version validation + monotonicity
# ---------------------------------------------------------------------------

validate_version_format() {
    case "$MARKETING_VERSION" in
        ''|*[!0-9.]*) die "MARKETING_VERSION '$MARKETING_VERSION' must contain digits and dots only." ;;
    esac
    case "$MARKETING_VERSION" in
        *.*) ;;
        *) die "MARKETING_VERSION '$MARKETING_VERSION' must look like MAJOR.MINOR[.PATCH]." ;;
    esac
    case "$BUILD_NUMBER" in
        ''|*[!0-9]*) die "BUILD_NUMBER '$BUILD_NUMBER' must be a plain integer." ;;
    esac
    if [ "$BUILD_NUMBER" -lt 1 ]; then
        die "BUILD_NUMBER must be >= 1, got '$BUILD_NUMBER'."
    fi
}

# Echoes gt / eq / lt for version strings such as 1.2.3.
compare_versions() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        n = split(a, A, "."); m = split(b, B, ".")
        count = (n > m) ? n : m
        for (i = 1; i <= count; i++) {
            x = (i <= n) ? A[i] + 0 : 0
            y = (i <= m) ? B[i] + 0 : 0
            if (x > y) { print "gt"; exit }
            if (x < y) { print "lt"; exit }
        }
        print "eq"
    }'
}

plist_value() {
    plutil -extract "$2" raw -o - "$1" 2>/dev/null || true
}

# Sourced once before the downgrade guard. The file is shell syntax so it can be
# read in place; its variables are BASELINE_-prefixed and cannot collide with
# the values sourced from scripts/version.sh.
#
# A hand-edited file must fail with an actionable message rather than a shell
# error: with `set -u`, a file that has no variables would otherwise abort with
# "BASELINE_MARKETING_VERSION: unbound variable", and a syntax typo aborts
# inside `.` before the checks below can run. So validate the syntax first and
# read the two variables defensively.
load_version_baseline() {
    if [ ! -f "$BASELINE_FILE" ]; then
        die "missing $BASELINE_FILE (the checked-in version floor used by the downgrade guard)."
    fi
    if ! sh -n "$BASELINE_FILE" 2>/dev/null; then
        die "$BASELINE_FILE is not valid shell syntax (expected BASELINE_MARKETING_VERSION=\"x.y.z\" and BASELINE_BUILD_NUMBER=\"n\")."
    fi
    # shellcheck source=scripts/version-baseline
    . "$BASELINE_FILE"
    BASELINE_MARKETING_VERSION="${BASELINE_MARKETING_VERSION:-}"
    BASELINE_BUILD_NUMBER="${BASELINE_BUILD_NUMBER:-}"

    case "$BASELINE_MARKETING_VERSION" in
        ''|*[!0-9.]*) die "$BASELINE_FILE: BASELINE_MARKETING_VERSION '${BASELINE_MARKETING_VERSION}' must be set to digits and dots only (MAJOR.MINOR[.PATCH])." ;;
    esac
    case "$BASELINE_BUILD_NUMBER" in
        ''|*[!0-9]*) die "$BASELINE_FILE: BASELINE_BUILD_NUMBER '${BASELINE_BUILD_NUMBER}' must be set to a plain integer." ;;
    esac
    if [ "$BASELINE_BUILD_NUMBER" -lt 1 ]; then
        die "$BASELINE_FILE: BASELINE_BUILD_NUMBER must be >= 1, got '$BASELINE_BUILD_NUMBER'."
    fi
}

# The highest vX.Y.Z tag, if this checkout has any.
latest_release_tag() {
    git -C "$PROJECT_DIR" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true
}

# True when HEAD is exactly the tagged release commit. Rebuilding a release
# (CI does this, and a failed notarization run is retried the same way) must not
# trip the "build number must strictly increase" assertion.
head_is_release_tag() {
    [ -n "$(git -C "$PROJECT_DIR" describe --tags --exact-match --match 'v[0-9]*' HEAD 2>/dev/null || true)" ]
}

assert_version_advances_past_last_release() {
    tag="$(latest_release_tag)"
    if [ -z "$tag" ]; then
        return 0
    fi
    if head_is_release_tag; then
        say "note: building the tagged release $tag; skipping the build-number bump check."
        return 0
    fi

    # Tags created from now on carry scripts/version.sh, so the released build
    # number can be read straight out of the tag.
    released_build="$(
        git -C "$PROJECT_DIR" show "$tag:scripts/version.sh" 2>/dev/null \
            | sed -n 's/^BUILD_NUMBER="\([0-9][0-9]*\)".*/\1/p' | head -n 1
    )"
    released_marketing="$(
        git -C "$PROJECT_DIR" show "$tag:scripts/version.sh" 2>/dev/null \
            | sed -n 's/^MARKETING_VERSION="\([0-9.]*\)".*/\1/p' | head -n 1
    )"
    if [ -z "$released_build" ]; then
        say "note: $tag predates scripts/version.sh; cannot check build-number monotonicity against it."
        return 0
    fi

    if [ "$MARKETING_VERSION" = "$released_marketing" ]; then
        if [ "$BUILD_NUMBER" -le "$released_build" ]; then
            die "BUILD_NUMBER $BUILD_NUMBER must strictly increase: $tag already shipped $released_marketing ($released_build).
Bump BUILD_NUMBER in scripts/version.sh (or set ALLOW_VERSION_REGRESSION=1 for a throwaway local build)."
        fi
    elif [ "$(compare_versions "$MARKETING_VERSION" "$released_marketing")" = "lt" ]; then
        die "MARKETING_VERSION $MARKETING_VERSION is lower than the released $tag ($released_marketing)."
    elif [ "$BUILD_NUMBER" -le "$released_build" ]; then
        die "BUILD_NUMBER $BUILD_NUMBER must still strictly increase after a version bump: $tag shipped $released_build."
    fi
}

assert_version_not_regressed_locally() {
    # The checked-in baseline is authoritative. dist/ is gitignored and may
    # contain artifacts built with another version or from another checkout.
    comparison="$(compare_versions "$MARKETING_VERSION" "$BASELINE_MARKETING_VERSION")"
    if [ "$comparison" = "lt" ] \
        || { [ "$comparison" = "eq" ] && [ "$BUILD_NUMBER" -lt "$BASELINE_BUILD_NUMBER" ]; }; then
        die "refusing to build $MARKETING_VERSION ($BUILD_NUMBER): it is below the recorded baseline $BASELINE_MARKETING_VERSION ($BASELINE_BUILD_NUMBER).
The baseline lives in scripts/version-baseline. If this downgrade is deliberate,
lower it there in the same commit; for a throwaway local build, set ALLOW_VERSION_REGRESSION=1."
    fi

    # Warn before replacing a newer artifact already present in dist/.
    [ -f "$APP_DIR/Contents/Info.plist" ] || return 0

    previous_marketing="$(plist_value "$APP_DIR/Contents/Info.plist" CFBundleShortVersionString)"
    previous_build="$(plist_value "$APP_DIR/Contents/Info.plist" CFBundleVersion)"
    [ -n "$previous_marketing" ] || return 0
    case "$previous_build" in
        ''|*[!0-9]*) previous_build=0 ;;
    esac

    if [ "$(compare_versions "$previous_marketing" "$MARKETING_VERSION")" = "gt" ]; then
        say "note: dist/ holds $previous_marketing ($previous_build), newer than $MARKETING_VERSION ($BUILD_NUMBER); replacing it because the requested version meets the recorded baseline $BASELINE_MARKETING_VERSION ($BASELINE_BUILD_NUMBER)."
    fi
}

stamp_version_into_plist() {
    plist="$1"
    plutil -replace CFBundleShortVersionString -string "$MARKETING_VERSION" "$plist"
    plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$plist"
    plutil -replace LSMinimumSystemVersion -string "$MINIMUM_SYSTEM_VERSION" "$plist"
    plutil -lint "$plist" >/dev/null

    stamped_marketing="$(plist_value "$plist" CFBundleShortVersionString)"
    stamped_build="$(plist_value "$plist" CFBundleVersion)"
    [ "$stamped_marketing" = "$MARKETING_VERSION" ] || die "failed to stamp CFBundleShortVersionString into $plist"
    [ "$stamped_build" = "$BUILD_NUMBER" ] || die "failed to stamp CFBundleVersion into $plist"
}

warn_about_minimum_system_version_drift() {
    declared="$(sed -n 's/.*\.macOS(\.v\([0-9][0-9]*\)).*/\1/p' "$PROJECT_DIR/Package.swift" | head -n 1)"
    expected="$(echo "$MINIMUM_SYSTEM_VERSION" | cut -d. -f1)"
    if [ -n "$declared" ] && [ "$declared" != "$expected" ]; then
        say "warning: Package.swift targets macOS $declared but scripts/version.sh declares $MINIMUM_SYSTEM_VERSION."
    fi
}

# ---------------------------------------------------------------------------
# Signing
# ---------------------------------------------------------------------------

resolve_signing_mode() {
    if [ -z "$SIGNING_IDENTITY" ] || [ "$SIGNING_IDENTITY" = "-" ]; then
        if [ "$REQUIRE_SIGNING" -eq 1 ]; then
            cat >&2 <<'EOF'
error: REQUIRE_SIGNING=1 but no SIGNING_IDENTITY was provided.

Set the Developer ID Application identity to sign with, for example:

    SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
    REQUIRE_SIGNING=1 ./scripts/build-app.sh

List the identities in your keychain with:

    security find-identity -v -p codesigning

Obtain a Developer ID Application certificate from your Apple Developer account,
then install it in your login keychain.
EOF
            exit 1
        fi
        SIGNING_MODE="adhoc"
        return 0
    fi

    if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGNING_IDENTITY"; then
        cat >&2 <<EOF
error: no code-signing identity matching "$SIGNING_IDENTITY" in the keychain.

Available identities:

$(security find-identity -v -p codesigning 2>/dev/null | sed 's/^/    /')

Install a matching "Developer ID Application" certificate in your login keychain.
EOF
        exit 1
    fi

    case "$SIGNING_IDENTITY" in
        "Developer ID Application:"*|"Developer ID Application "*)
            SIGNING_MODE="developer-id"
            ;;
        *)
            SIGNING_MODE="developer-id"
            say "warning: \"$SIGNING_IDENTITY\" is not a Developer ID Application certificate."
            say "warning: notarization will reject anything signed with it."
            ;;
    esac
}

sign_nested_code() {
    # Inside-out signing: nested code first, bundle last. --deep is not used for
    # signing because it applies the same flags to everything it finds. There
    # is no nested code today; the loop keeps the script correct if a framework
    # or helper is ever added.
    nested="$(
        find "$APP_DIR/Contents" -mindepth 1 \
            \( -name '*.app' -o -name '*.framework' -o -name '*.bundle' -o -name '*.xpc' -o -name '*.dylib' \) \
            ! -path '*/_CodeSignature/*' -print 2>/dev/null | sort -r || true
    )"
    [ -n "$nested" ] || return 0

    # Here-document instead of a pipe: the loop stays in this shell, so a failing
    # codesign aborts the whole build.
    while IFS= read -r item; do
        [ -n "$item" ] || continue
        say "signing nested code: ${item#"$APP_DIR"/}"
        sign_one "$item"
    done <<EOF
$nested
EOF
}

sign_one() {
    target="$1"

    if [ "$SIGNING_MODE" = "adhoc" ]; then
        if [ "$HARDENED_ADHOC" -eq 1 ]; then
            codesign --force --sign - --timestamp=none --options runtime "$target"
        else
            # Local development builds stay ad-hoc unless hardened mode is
            # requested.
            codesign --force --sign - --timestamp=none "$target"
        fi
        return 0
    fi

    codesign --force --sign "$SIGNING_IDENTITY" \
        --options runtime \
        --timestamp \
        "$target"
}

# Hardened runtime shows up in the CodeDirectory flags line. macOS 26 prints the
# combined form "flags=0x10002(adhoc,runtime)", older releases print a separate
# "flags=0x10000(runtime)"; match both.
has_hardened_runtime() {
    codesign -dv --verbose=4 "$1" 2>&1 | grep -Eq 'flags=0x[0-9a-f]+\([^)]*runtime'
}

print_signature_summary() {
    codesign -dv --verbose=4 "$APP_DIR" 2>&1 \
        | grep -E 'Identifier=|Authority=|TeamIdentifier=|Timestamp=|^CodeDirectory|Sealed Resources' \
        | sed 's/^/    /' >&2 || true
}

verify_signature() {
    codesign --verify --deep --strict --verbose=2 "$APP_DIR" >&2

    if [ "$SIGNING_MODE" = "adhoc" ] && [ "$HARDENED_ADHOC" -ne 1 ]; then
        say "ad-hoc signed without hardened runtime (local development build)."
        say "This build cannot be notarized and Gatekeeper rejects it on other Macs."
        print_signature_summary
        return 0
    fi

    if ! has_hardened_runtime "$APP_DIR"; then
        die "hardened runtime flag is missing from the signature of $APP_DIR"
    fi

    print_signature_summary

    if [ "$SIGNING_MODE" = "developer-id" ]; then
        # Notarization requires a secure timestamp; "Timestamp=none" means the
        # signature would be rejected.
        case "$(codesign -dv --verbose=4 "$APP_DIR" 2>&1 || true)" in
            *Timestamp=none*)
                die "the signature has no secure timestamp (Timestamp=none); notarization would reject it.
Check network access to Apple's timestamp server, or drop --timestamp only for local experiments." ;;
            *) say "secure timestamp present" ;;
        esac
        say "hardened runtime enabled. Gatekeeper will still reject this build"
        say "until it is notarized and stapled: run ./scripts/sign-and-notarize.sh."
    else
        say "ad-hoc signed with hardened runtime (HARDENED_ADHOC=1): local reproduction only."
    fi
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

validate_version_format
warn_about_minimum_system_version_drift
if [ "$ALLOW_VERSION_REGRESSION" -ne 1 ]; then
    load_version_baseline
    # The strict "must be newer than the last release" rule belongs to the
    # release path (REQUIRE_VERSION_BUMP=1, passed by sign-and-notarize.sh):
    # enforcing it on every build would fail every commit on main after a tag
    # until somebody bumps the version.
    if [ "$REQUIRE_VERSION_BUMP" -eq 1 ]; then
        assert_version_advances_past_last_release
    fi
    assert_version_not_regressed_locally
fi
resolve_signing_mode

cd "$PROJECT_DIR"
"$PROJECT_DIR/scripts/build-icon.sh" "$ICON_FILE" >/dev/null
swift build -c release
BUILD_PRODUCTS="$(swift build -c release --show-bin-path)"

if [ -e "$APP_DIR" ]; then
    case "$APP_DIR" in
        "$PROJECT_DIR"/dist/*.app) rm -rf "$APP_DIR" ;;
        *) die "Refusing to replace unexpected path: $APP_DIR" ;;
    esac
fi

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_PRODUCTS/Launcher27B" "$APP_DIR/Contents/MacOS/Launcher27B"
cp "$PLIST_TEMPLATE" "$APP_DIR/Contents/Info.plist"
stamp_version_into_plist "$APP_DIR/Contents/Info.plist"
cp "$ICON_FILE" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/Resources/webui-config.json" "$APP_DIR/Contents/Resources/webui-config.json"
cp "$PROJECT_DIR/Resources/PrivacyInfo.xcprivacy" "$APP_DIR/Contents/Resources/PrivacyInfo.xcprivacy"
RESOURCE_BUNDLE="$BUILD_PRODUCTS/Launcher27B_Launcher27B.bundle"
[ -d "$RESOURCE_BUNDLE" ] || die "SwiftPM localization bundle missing: $RESOURCE_BUNDLE"
ditto "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/Launcher27B_Launcher27B.bundle"
# SwiftPM's command-line accessor resolves resources beside Bundle.main.bundleURL.
# Keep the canonical macOS resource location and provide the expected in-bundle alias.
ln -s "Contents/Resources/Launcher27B_Launcher27B.bundle" "$APP_DIR/Launcher27B_Launcher27B.bundle"


# Apple requires the privacy manifest to be inside the bundle, not only in the
# repository, and it must survive packaging.
if [ ! -f "$APP_DIR/Contents/Resources/PrivacyInfo.xcprivacy" ]; then
    die "PrivacyInfo.xcprivacy was not copied into the bundle"
fi
plutil -lint "$APP_DIR/Contents/Resources/PrivacyInfo.xcprivacy" >/dev/null

built_arch="$(lipo -archs "$APP_DIR/Contents/MacOS/Launcher27B")"
if [ "$built_arch" != "$SUPPORTED_ARCHS" ]; then
    die "built executable is '$built_arch' but scripts/version.sh declares SUPPORTED_ARCHS='$SUPPORTED_ARCHS' (arm64-only policy)."
fi

sign_nested_code
sign_one "$APP_DIR"
verify_signature

say "built $APP_NAME $MARKETING_VERSION ($BUILD_NUMBER) [$SIGNING_MODE]"
echo "$APP_DIR"
