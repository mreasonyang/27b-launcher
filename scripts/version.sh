#!/bin/sh
# SINGLE SOURCE OF TRUTH for the app version.
#
# Everything that needs a version number (scripts/build-app.sh, CI, release
# notes) reads it from here. Never hand-edit the version inside
# Resources/Info.plist: that file only carries placeholders and is stamped at
# build time from the two variables below.
#
# Usage (sourced):   . "$PROJECT_DIR/scripts/version.sh"
# Usage (as a CLI):  scripts/version.sh marketing   -> 0.10.11
#                    scripts/version.sh build       -> 40
#                    scripts/version.sh bundle      -> 0.10.11 (40)
#                    scripts/version.sh tag         -> v0.10.11
#                    scripts/version.sh baseline    -> 0.9.0 (26)  (floor, version-baseline)

# Human-facing marketing version (CFBundleShortVersionString).
# Format: MAJOR[.MINOR[.PATCH]] - digits and dots only.
#
# Current human-facing product version.
MARKETING_VERSION="0.10.14"

# Machine-facing build number (CFBundleVersion). Must STRICTLY INCREASE every
# time a build is handed to anyone, including ad-hoc local builds that later get
# notarized. See assert_version_advances_past_last_release() in
# scripts/build-app.sh; the local downgrade floor is scripts/version-baseline.
BUILD_NUMBER="43"

# Minimum supported macOS version. Must stay in sync with
#   - Package.swift  ->  platforms: [.macOS(.v14)]
#   - Resources/Info.plist -> LSMinimumSystemVersion
#   - the Mach-O load command (-platform_version ... 14.0)
MINIMUM_SYSTEM_VERSION="14.0"

# Supported CPU architectures (arm64-only policy).
SUPPORTED_ARCHS="arm64"

# When executed directly, act as a small query tool.
if [ "$(basename -- "$0")" = "version.sh" ]; then
    case "${1:-bundle}" in
        marketing) echo "$MARKETING_VERSION" ;;
        build)     echo "$BUILD_NUMBER" ;;
        tag)       echo "v$MARKETING_VERSION" ;;
        minimum)   echo "$MINIMUM_SYSTEM_VERSION" ;;
        archs)     echo "$SUPPORTED_ARCHS" ;;
        bundle)    echo "$MARKETING_VERSION ($BUILD_NUMBER)" ;;
        baseline)
            # Version floor enforced by scripts/build-app.sh. Read (not sourced)
            # so this query tool can never clobber the values above.
            baseline_file="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/version-baseline"
            if [ ! -f "$baseline_file" ]; then
                echo "error: missing $baseline_file" >&2
                exit 1
            fi
            baseline_marketing="$(
                sed -n 's/^BASELINE_MARKETING_VERSION="\([0-9.]*\)".*/\1/p' "$baseline_file" | head -n 1
            )"
            baseline_build="$(
                sed -n 's/^BASELINE_BUILD_NUMBER="\([0-9][0-9]*\)".*/\1/p' "$baseline_file" | head -n 1
            )"
            if [ -z "$baseline_marketing" ] || [ -z "$baseline_build" ]; then
                echo "error: $baseline_file is malformed (need BASELINE_MARKETING_VERSION and BASELINE_BUILD_NUMBER)" >&2
                exit 1
            fi
            echo "$baseline_marketing ($baseline_build)"
            ;;
        *)
            echo "usage: $0 [marketing|build|tag|minimum|archs|bundle|baseline]" >&2
            exit 2
            ;;
    esac
fi
