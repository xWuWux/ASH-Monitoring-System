#!/bin/bash
# Validate ASH release metadata without creating a tag or a release.
#
# The script is fail-closed: every mismatch is an error. It is used in two
# places:
#   - pull requests: no --tag, checks that the version constants agree and
#     that CHANGELOG.md has a usable section for the current version;
#   - release workflow: --tag vX.Y.Z, additionally checks the tag format and
#     that the tag version equals ASH_VERSION.
#
# Version domain: MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-rc.N.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc\.[1-9][0-9]*)?$'
TAG_RE='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc\.[1-9][0-9]*)?$'
RELEASE_HEADING_RE='^## \[([^]]+)\] - ([0-9]{4}-[0-9]{2}-[0-9]{2})$'

TAG=""
NOTES_FILE=""

usage() {
    cat <<'EOF'
Usage: scripts/validate-release.sh [--tag vX.Y.Z] [--notes-file PATH] [--root DIR]

Validate ASH version constants, README version literals, and CHANGELOG.md.

Options:
  --tag vX.Y.Z      Validate a release tag against ASH_VERSION.
  --notes-file PATH Write the matching changelog section to PATH.
                    Requires --tag.
  --root DIR        Repository root (default: parent of this script).
  -h, --help        Show this help.

Exit status:
  0  metadata is valid
  1  metadata is invalid
  2  invalid command-line usage
EOF
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)
            [[ $# -ge 2 && -n "$2" ]] || fail "--tag requires a value"
            TAG="$2"
            shift 2
            ;;
        --notes-file)
            [[ $# -ge 2 && -n "$2" ]] || fail "--notes-file requires a value"
            NOTES_FILE="$2"
            shift 2
            ;;
        --root)
            [[ $# -ge 2 && -n "$2" ]] || fail "--root requires a value"
            ROOT_DIR="$2"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ -d "$ROOT_DIR" ]] || fail "repository root does not exist: $ROOT_DIR"
ROOT_DIR="$(cd "$ROOT_DIR" && pwd)"

AGENT_FILE="${ROOT_DIR}/src/agent/ash-agent.sh"
INSTALL_FILE="${ROOT_DIR}/scripts/install.sh"
CHANGELOG_FILE="${ROOT_DIR}/CHANGELOG.md"

[[ -f "$AGENT_FILE" ]] || fail "missing agent file: $AGENT_FILE"
[[ -f "$INSTALL_FILE" ]] || fail "missing installer: $INSTALL_FILE"
[[ -f "$CHANGELOG_FILE" ]] || fail "missing changelog: $CHANGELOG_FILE"

if [[ -n "$NOTES_FILE" && -z "$TAG" ]]; then
    fail "--notes-file requires --tag"
fi

read_version() {
    local file="$1"
    sed -n 's/^readonly ASH_VERSION="\([^"]*\)"$/\1/p' "$file" | head -n 1
}

read_installer_version() {
    local file="$1"
    sed -n 's/^VERSION="\([^"]*\)"$/\1/p' "$file" | head -n 1
}

ASH_VERSION="$(read_version "$AGENT_FILE")"
[[ -n "$ASH_VERSION" ]] || fail "cannot read ASH_VERSION from $AGENT_FILE"
[[ "$ASH_VERSION" =~ $VERSION_RE ]] || fail "ASH_VERSION '${ASH_VERSION}' is not MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-rc.N"

INSTALL_VERSION="$(read_installer_version "$INSTALL_FILE")"
[[ -n "$INSTALL_VERSION" ]] || fail "cannot read VERSION from $INSTALL_FILE"
[[ "$INSTALL_VERSION" == "$ASH_VERSION" ]] ||
    fail "version drift: scripts/install.sh has VERSION='${INSTALL_VERSION}', ASH_VERSION='${ASH_VERSION}'"

check_version_literals() {
    local file="$1"
    local line line_no content value found=0

    while IFS= read -r line; do
        line_no="${line%%:*}"
        content="${line#*:}"
        case "$content" in
            "# Version: "*) value="${content#\# Version: }" ;;
            "Version: "*) value="${content#Version: }" ;;
            'VERSION="'*)
                value="${content#VERSION=\"}"
                value="${value%\"}"
                ;;
            *) continue ;;
        esac

        found=1
        [[ "$value" == "$ASH_VERSION" ]] ||
            fail "${file}:${line_no}: version '${value}' does not match ASH_VERSION '${ASH_VERSION}'"
    done < <(grep -nE '^(# Version: |Version: |VERSION=")' "$file" || true)

    [[ "$found" -eq 1 ]] ||
        fail "${file}: no version literal found (expected '# Version:', 'Version:', or 'VERSION=\"...\"')"
}

for doc in "${ROOT_DIR}/README.md" "${ROOT_DIR}/ash_documentation.md"; do
    if [[ -f "$doc" ]]; then
        check_version_literals "$doc"
    fi
done

unreleased_count="$(grep -c '^## \[Unreleased\]$' "$CHANGELOG_FILE" || true)"
[[ "$unreleased_count" -eq 1 ]] ||
    fail "CHANGELOG.md must contain exactly one '## [Unreleased]' heading (found ${unreleased_count})"

declare -A seen_versions=()
while IFS= read -r entry; do
    line_no="${entry%%:*}"
    heading="${entry#*:}"

    if [[ "$heading" == "## [Unreleased]" ]]; then
        continue
    fi

    [[ "$heading" =~ $RELEASE_HEADING_RE ]] ||
        fail "CHANGELOG.md:${line_no}: malformed release heading (expected '## [X.Y.Z] - YYYY-MM-DD'): ${heading}"

    version="${BASH_REMATCH[1]}"
    release_date="${BASH_REMATCH[2]}"

    [[ "$version" =~ $VERSION_RE ]] ||
        fail "CHANGELOG.md:${line_no}: invalid version '${version}' in release heading"

    normalized_date="$(date -u -d "$release_date" +%Y-%m-%d 2>/dev/null || true)"
    [[ "$normalized_date" == "$release_date" ]] ||
        fail "CHANGELOG.md:${line_no}: invalid release date '${release_date}'"

    if [[ -n "${seen_versions[$version]:-}" ]]; then
        fail "CHANGELOG.md:${line_no}: duplicate section for version ${version} (first at line ${seen_versions[$version]})"
    fi
    seen_versions[$version]="$line_no"
done < <(grep -nE '^## \[' "$CHANGELOG_FILE" || true)

changelog_section() {
    local version="$1"
    awk -v ver="$version" '
        index($0, "## [" ver "]") == 1 { found = 1; next }
        found && (/^## / || /^\[[^]]+\]: /) { exit }
        found && NF && !started { started = 1 }
        found && started { print }
    ' "$CHANGELOG_FILE"
}

require_changelog_section() {
    local version="$1"
    if ! changelog_section "$version" | awk 'NF && $0 !~ /^### / { found = 1 } END { exit(found ? 0 : 1) }'; then
        fail "CHANGELOG.md has no non-empty section for version ${version}"
    fi
}

require_changelog_section "$ASH_VERSION"

if [[ -n "$TAG" ]]; then
    [[ "$TAG" =~ $TAG_RE ]] || fail "tag '${TAG}' is not vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-rc.N"

    TAG_VERSION="${TAG#v}"
    [[ "$TAG_VERSION" == "$ASH_VERSION" ]] ||
        fail "tag/version mismatch: tag is '${TAG}', ASH_VERSION is '${ASH_VERSION}'"

    if [[ -n "$NOTES_FILE" ]]; then
        notes_dir="$(dirname "$NOTES_FILE")"
        [[ -d "$notes_dir" ]] || fail "notes directory does not exist: $notes_dir"
        changelog_section "$TAG_VERSION" >"$NOTES_FILE"
        [[ -s "$NOTES_FILE" ]] || fail "wrote an empty notes file: $NOTES_FILE"
    fi
fi

echo "Release metadata OK: ASH_VERSION=${ASH_VERSION}${TAG:+ tag=${TAG}}"
