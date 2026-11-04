#!/bin/bash
# Build deterministic ASH release assets: source archive, SHA256SUMS, and
# release notes extracted from CHANGELOG.md.
#
# The archive contains the source tree needed to install and operate ASH. It
# deliberately excludes .git, runtime state, secrets, caches, and build output.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

VERSION=""
OUTPUT_DIR="dist"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-}"

usage() {
    cat <<'EOF'
Usage: scripts/build-release.sh [--version X.Y.Z[-rc.N]] [--output-dir DIR] [--root DIR]

Build ash-monitor-<version>.tar.gz, SHA256SUMS, and release-notes.md.

Options:
  --version VERSION  Version to package (default: ASH_VERSION from the agent).
  --output-dir DIR   Destination directory (default: dist).
  --root DIR         Repository root (default: parent of this script).
  -h, --help         Show this help.

The output is deterministic for a given source tree and SOURCE_DATE_EPOCH.
If SOURCE_DATE_EPOCH is unset, the git commit timestamp is used.
EOF
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            [[ $# -ge 2 && -n "$2" ]] || fail "--version requires a value"
            VERSION="$2"
            shift 2
            ;;
        --output-dir)
            [[ $# -ge 2 && -n "$2" ]] || fail "--output-dir requires a value"
            OUTPUT_DIR="$2"
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

if [[ -z "$VERSION" ]]; then
    VERSION="$(sed -n 's/^readonly ASH_VERSION="\([^"]*\)"$/\1/p' "${ROOT_DIR}/src/agent/ash-agent.sh" | head -n 1)"
fi
[[ -n "$VERSION" ]] || fail "cannot determine version; pass --version"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

# Reuse the release validator so version, README, and changelog checks have a
# single implementation. The tag does not need to exist locally for this check.
"${SCRIPT_DIR}/validate-release.sh" \
    --root "$ROOT_DIR" \
    --tag "v${VERSION}" \
    --notes-file "${OUTPUT_DIR}/release-notes.md"

FILES=(
    src
    config
    deployments
    scripts
    tests
    docs
    README.md
    LICENSE
    CHANGELOG.md
)

for entry in "${FILES[@]}"; do
    [[ -e "${ROOT_DIR}/${entry}" ]] || fail "missing release input: ${entry}"
done

if [[ -z "$SOURCE_DATE_EPOCH" ]]; then
    SOURCE_DATE_EPOCH="$(git -C "$ROOT_DIR" log -1 --format=%ct 2>/dev/null || echo 0)"
fi
[[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] || fail "SOURCE_DATE_EPOCH must be an integer: ${SOURCE_DATE_EPOCH}"

ARCHIVE="ash-monitor-${VERSION}.tar.gz"

export LC_ALL=C
export TZ=UTC

tar \
    --sort=name \
    --mtime="@${SOURCE_DATE_EPOCH}" \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    --format=gnu \
    --exclude='*__pycache__*' \
    --exclude='*.pyc' \
    --exclude='.pytest_cache' \
    --exclude='.coverage' \
    --exclude='coverage.xml' \
    --exclude='*.log' \
    --exclude='*.pid' \
    --exclude='*.tmp' \
    --exclude='*.swp' \
    --exclude='.DS_Store' \
    --exclude='Thumbs.db' \
    --exclude='.env' \
    --exclude='secrets.conf' \
    --exclude='venv' \
    --exclude='.idea' \
    --exclude='.vscode' \
    --exclude='*.bak' \
    --exclude='*.retry' \
    --exclude='deployments/monitoring/runtime' \
    --exclude='deployments/monitoring/data' \
    -C "$ROOT_DIR" \
    -cf - \
    "${FILES[@]}" | gzip -9n >"${OUTPUT_DIR}/${ARCHIVE}"

(
    cd "$OUTPUT_DIR"
    sha256sum "$ARCHIVE" >SHA256SUMS
)

[[ -s "${OUTPUT_DIR}/release-notes.md" ]] || fail "release notes are empty"

echo "Built ${OUTPUT_DIR}/${ARCHIVE}"
echo "Wrote ${OUTPUT_DIR}/SHA256SUMS"
echo "Wrote ${OUTPUT_DIR}/release-notes.md"
