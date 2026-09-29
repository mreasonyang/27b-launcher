#!/bin/sh
# One-command release: checks, tests, signed build, notarization, packaging.
#
#   ./scripts/release.sh --check      # everything except signing/submitting
#   ./scripts/release.sh              # the real release (needs a Developer ID)
#
# This is a thin, opinionated wrapper around scripts/sign-and-notarize.sh. It
# never tags, pushes or uploads anything: it tells you the exact commands to run
# once the artifacts exist.
#
# --check does not sign, submit, or write release artifacts, but it is NOT
# completely side-effect-free: it runs `swift test`, which compiles into
# .build/. Pass --skip-tests to skip that. It also exits non-zero on a machine
# with no Developer ID identity and no notarization credentials, which is the
# honest result.
set -eu

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=scripts/version.sh
. "$PROJECT_DIR/scripts/version.sh"

CHANGELOG="$PROJECT_DIR/CHANGELOG.md"
NOTES_DIR="$PROJECT_DIR/.build"
SKIP_TESTS=0
MODE="release"

say()  { echo "$*" >&2; }
step() { echo "" >&2; echo "==> $*" >&2; }
die()  { echo "" >&2; echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --check|--dry-run|-n) MODE="check" ;;
        --skip-tests) SKIP_TESTS=1 ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

FAILURES=0

check_version() {
    step "version"
    say "    version.sh says $MARKETING_VERSION ($BUILD_NUMBER), min macOS $MINIMUM_SYSTEM_VERSION, arch $SUPPORTED_ARCHS"
    baseline="$("$PROJECT_DIR/scripts/version.sh" baseline 2>/dev/null || true)"
    if [ -n "$baseline" ]; then
        say "    version-baseline (downgrade floor): $baseline"
    else
        say "    WARNING: scripts/version-baseline is missing or malformed; build-app.sh will refuse to build"
        FAILURES=$((FAILURES + 1))
    fi

    case "$MARKETING_VERSION" in
        *[!0-9.]*|'') die "MARKETING_VERSION '$MARKETING_VERSION' is malformed" ;;
    esac

    if [ ! -f "$CHANGELOG" ]; then
        say "    no CHANGELOG.md; release notes will be generated from git history"
    elif grep -q "^## \[$MARKETING_VERSION\]" "$CHANGELOG"; then
        say "    CHANGELOG.md has a section for $MARKETING_VERSION"
        CHANGELOG_ENTRY_PRESENT=1
    else
        say "    MISSING: CHANGELOG.md has no '## [$MARKETING_VERSION]' section"
        FAILURES=$((FAILURES + 1))
    fi
}

check_package_swift() {
    step "toolchain floor"
    declared="$(sed -n 's/.*\.macOS(\.v\([0-9][0-9]*\)).*/\1/p' "$PROJECT_DIR/Package.swift" | head -n 1)"
    if [ -n "$declared" ] && [ "$declared" != "$(echo "$MINIMUM_SYSTEM_VERSION" | cut -d. -f1)" ]; then
        say "    WARNING: Package.swift targets macOS $declared, version.sh declares $MINIMUM_SYSTEM_VERSION"
    else
        say "    Package.swift and version.sh agree on the minimum macOS version"
    fi
    tools_version="$(sed -n 's|^// swift-tools-version: *\([0-9.]*\).*|\1|p' "$PROJECT_DIR/Package.swift" | head -n 1)"
    say "    Package.swift requires swift-tools-version $tools_version ($(swift --version 2>/dev/null | head -n 1))"
}

check_git_state() {
    step "git state"
    if ! git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        say "    not a git checkout; skipping repository checks"
        return 0
    fi

    tag="$(git -C "$PROJECT_DIR" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
    if [ -n "$tag" ]; then
        say "    latest release tag: $tag"
    else
        say "    no v* tag yet: this would be the first tagged release"
    fi

    if [ -n "$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null || true)" ]; then
        say "    WARNING: the working tree has uncommitted changes."
        say "             A release should be cut from a committed revision: the artifacts"
        say "             cannot be reproduced from the tag otherwise."
        FAILURES=$((FAILURES + 1))
    else
        say "    working tree is clean"
    fi

    if [ -z "$(git -C "$PROJECT_DIR" remote 2>/dev/null || true)" ]; then
        say "    WARNING: no Git remote is configured; configure one before publishing a release."
    fi
}

run_tests() {
    step "tests"
    if [ "$SKIP_TESTS" -eq 1 ]; then
        say "    skipped (--skip-tests)"
        return 0
    fi
    swift test --package-path "$PROJECT_DIR"
    say "    swift test passed"
}

write_release_notes() {
    notes_path="$NOTES_DIR/release-notes-$MARKETING_VERSION.md"
    mkdir -p "$NOTES_DIR"
    if [ -f "$CHANGELOG" ]; then
        awk -v version="$MARKETING_VERSION" '
            $0 ~ "^## \\[" version "\\]" { capture = 1 }
            capture && $0 ~ "^## \\[" && $0 !~ "^## \\[" version "\\]" { exit }
            capture { print }
        ' "$CHANGELOG" > "$notes_path"
    else
        {
            echo "## $MARKETING_VERSION"
            echo ""
            if git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
                last_tag="$(git -C "$PROJECT_DIR" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
                if [ -n "$last_tag" ]; then
                    git -C "$PROJECT_DIR" log --no-merges --pretty='- %s' "$last_tag"..HEAD
                else
                    git -C "$PROJECT_DIR" log --no-merges --pretty='- %s'
                fi
            else
                echo "- 27B Launcher $MARKETING_VERSION"
            fi
        } > "$notes_path"
    fi
    say "    release notes for $MARKETING_VERSION written to $notes_path"
}

print_next_steps() {
    cat >&2 <<EOF

Next steps (nothing below has been executed for you):

    git add -A && git commit -m "Release $MARKETING_VERSION"
    git tag -a v$MARKETING_VERSION -m "27B Launcher $MARKETING_VERSION"
    git push origin main --tags

Publishing the tag triggers a GitHub Actions release workflow only if one is
configured for the repository. Otherwise publish by hand:

    gh release create v$MARKETING_VERSION \\
        "dist/27B-Launcher-$MARKETING_VERSION-macOS-$SUPPORTED_ARCHS.dmg" \\
        "dist/27B-Launcher-$MARKETING_VERSION-macOS-$SUPPORTED_ARCHS.zip" \\
        "dist/27B-Launcher-$MARKETING_VERSION-macOS-$SUPPORTED_ARCHS.zip.sha256" \\
        "dist/27B-Launcher-$MARKETING_VERSION-macOS-$SUPPORTED_ARCHS.dmg.sha256" \\
        --title "27B Launcher $MARKETING_VERSION" \\
        --notes-file ".build/release-notes-$MARKETING_VERSION.md"
EOF
}

# ---------------------------------------------------------------------------

check_package_swift
check_git_state
check_version

if [ "$MODE" = "check" ]; then
    step "release notes (preview only)"
    say "    would write .build/release-notes-$MARKETING_VERSION.md"
    step "signing / notarization preflight"
    set +e
    "$PROJECT_DIR/scripts/sign-and-notarize.sh" --check
    notarize_status=$?
    set -e
    if [ "$notarize_status" -ne 0 ]; then
        FAILURES=$((FAILURES + 1))
    fi
    run_tests
    echo "" >&2
    if [ "$FAILURES" -eq 0 ]; then
        echo "READY to release $MARKETING_VERSION ($BUILD_NUMBER)." >&2
        exit 0
    fi
    echo "NOT READY: $FAILURES problem(s) above." >&2
    exit 1
fi

if [ "$FAILURES" -gt 0 ]; then
    die "$FAILURES blocking problem(s) above; fix them and re-run (or use --check)."
fi

write_release_notes
run_tests

step "signing, notarizing and packaging"
"$PROJECT_DIR/scripts/sign-and-notarize.sh"

print_next_steps
