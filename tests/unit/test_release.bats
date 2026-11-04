#!/usr/bin/env bats
# Release metadata and packaging tests.
#
# The scripts resolve the repository root from their own location, so each
# test copies them into a throwaway repository. That keeps the fixtures small
# and proves the checks work without touching the real tree.

setup() {
    REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
    VALIDATOR="${REPO_ROOT}/scripts/validate-release.sh"
    BUILDER="${REPO_ROOT}/scripts/build-release.sh"
    FIXTURE="${BATS_TEST_TMPDIR}/repo"

    make_fixture
}

make_fixture() {
    rm -rf "$FIXTURE"
    mkdir -p "$FIXTURE"/src/agent "$FIXTURE"/scripts "$FIXTURE"/config \
        "$FIXTURE"/deployments "$FIXTURE"/tests "$FIXTURE"/docs

    cp "$VALIDATOR" "$FIXTURE/scripts/validate-release.sh"
    cp "$BUILDER" "$FIXTURE/scripts/build-release.sh"

    printf '#!/bin/bash\nreadonly ASH_VERSION="2.2.0"\n' \
        >"$FIXTURE/src/agent/ash-agent.sh"
    printf '#!/bin/bash\nVERSION="2.2.0"\n' \
        >"$FIXTURE/scripts/install.sh"
    printf 'fixture license\n' >"$FIXTURE/LICENSE"
    printf 'fixture docs\n' >"$FIXTURE/docs/README.md"

    cat >"$FIXTURE/README.md" <<'EOF'
# ASH fixture

# Version: 2.2.0
Version: 2.2.0
VERSION="2.2.0"
EOF

    write_changelog 2.2.0 2026-11-04 "release entry"
}

write_changelog() {
    local version="$1"
    local date="$2"
    local entry="$3"

    cat >"$FIXTURE/CHANGELOG.md" <<EOF
# Changelog

## [Unreleased]

### Added

- next entry

## [${version}] - ${date}

### Added

- ${entry}
EOF
}

@test "validate-release accepts the current metadata" {
    run bash "$FIXTURE/scripts/validate-release.sh"
    [[ $status -eq 0 ]]
    [[ "$output" == *"Release metadata OK"* ]]
}

@test "validate-release accepts a matching tag" {
    run bash "$FIXTURE/scripts/validate-release.sh" --tag v2.2.0
    [[ $status -eq 0 ]]
    [[ "$output" == *"tag=v2.2.0"* ]]
}

@test "validate-release rejects a tag without the v prefix" {
    run bash "$FIXTURE/scripts/validate-release.sh" --tag 2.2.0
    [[ $status -eq 1 ]]
    [[ "$output" == *"not vMAJOR.MINOR.PATCH"* ]]
}

@test "validate-release rejects a tag/version mismatch" {
    run bash "$FIXTURE/scripts/validate-release.sh" --tag v2.2.1
    [[ $status -eq 1 ]]
    [[ "$output" == *"tag/version mismatch"* ]]
}

@test "validate-release rejects installer version drift" {
    printf '#!/bin/bash\nVERSION="2.2.1"\n' \
        >"$FIXTURE/scripts/install.sh"

    run bash "$FIXTURE/scripts/validate-release.sh"
    [[ $status -eq 1 ]]
    [[ "$output" == *"version drift"* ]]
}

@test "validate-release rejects README version drift" {
    sed -i 's/^VERSION="2.2.0"$/VERSION="2.0-1"/' "$FIXTURE/README.md"

    run bash "$FIXTURE/scripts/validate-release.sh"
    [[ $status -eq 1 ]]
    [[ "$output" == *"does not match ASH_VERSION"* ]]
}

@test "validate-release rejects a missing changelog section" {
    cat >"$FIXTURE/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

### Added

- next entry
EOF

    run bash "$FIXTURE/scripts/validate-release.sh"
    [[ $status -eq 1 ]]
    [[ "$output" == *"no non-empty section for version 2.2.0"* ]]
}

@test "validate-release rejects an empty changelog section" {
    cat >"$FIXTURE/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [2.2.0] - 2026-11-04

### Added
EOF

    run bash "$FIXTURE/scripts/validate-release.sh"
    [[ $status -eq 1 ]]
    [[ "$output" == *"no non-empty section for version 2.2.0"* ]]
}

@test "validate-release rejects duplicate changelog sections" {
    cat >"$FIXTURE/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [2.2.0] - 2026-11-04

### Added

- first

## [2.2.0] - 2026-11-05

### Added

- second
EOF

    run bash "$FIXTURE/scripts/validate-release.sh"
    [[ $status -eq 1 ]]
    [[ "$output" == *"duplicate section for version 2.2.0"* ]]
}

@test "validate-release rejects an invalid release date" {
    write_changelog 2.2.0 2026-13-01 "release entry"

    run bash "$FIXTURE/scripts/validate-release.sh"
    [[ $status -eq 1 ]]
    [[ "$output" == *"invalid release date"* ]]
}

@test "validate-release accepts an rc tag" {
    printf '#!/bin/bash\nreadonly ASH_VERSION="2.2.0-rc.1"\n' \
        >"$FIXTURE/src/agent/ash-agent.sh"
    printf '#!/bin/bash\nVERSION="2.2.0-rc.1"\n' \
        >"$FIXTURE/scripts/install.sh"
    sed -i 's/2\.2\.0/2.2.0-rc.1/g' "$FIXTURE/README.md"
    write_changelog 2.2.0-rc.1 2026-11-04 "release candidate"

    run bash "$FIXTURE/scripts/validate-release.sh" --tag v2.2.0-rc.1
    [[ $status -eq 0 ]]
    [[ "$output" == *"tag=v2.2.0-rc.1"* ]]
}

@test "validate-release rejects rc.0" {
    printf '#!/bin/bash\nreadonly ASH_VERSION="2.2.0-rc.0"\n' \
        >"$FIXTURE/src/agent/ash-agent.sh"

    run bash "$FIXTURE/scripts/validate-release.sh"
    [[ $status -eq 1 ]]
    [[ "$output" == *"is not MAJOR.MINOR.PATCH"* ]]
}

@test "validate-release writes release notes for a tag" {
    run bash "$FIXTURE/scripts/validate-release.sh" \
        --tag v2.2.0 \
        --notes-file "$BATS_TEST_TMPDIR/notes.md"
    [[ $status -eq 0 ]]
    grep -q "release entry" "$BATS_TEST_TMPDIR/notes.md"
}

@test "validate-release requires --tag when writing notes" {
    run bash "$FIXTURE/scripts/validate-release.sh" \
        --notes-file "$BATS_TEST_TMPDIR/notes.md"
    [[ $status -eq 1 ]]
    [[ "$output" == *"--notes-file requires --tag"* ]]
}

@test "build-release creates a deterministic archive and checksums" {
    run bash "$FIXTURE/scripts/build-release.sh" --output-dir "$FIXTURE/dist"
    [[ $status -eq 0 ]]
    [[ -f "$FIXTURE/dist/ash-monitor-2.2.0.tar.gz" ]]
    [[ -f "$FIXTURE/dist/SHA256SUMS" ]]
    [[ -f "$FIXTURE/dist/release-notes.md" ]]

    (
        cd "$FIXTURE/dist"
        sha256sum -c SHA256SUMS
    )

    tar -tzf "$FIXTURE/dist/ash-monitor-2.2.0.tar.gz" >"$BATS_TEST_TMPDIR/contents.txt"
    grep -qx "README.md" "$BATS_TEST_TMPDIR/contents.txt"
    grep -qx "LICENSE" "$BATS_TEST_TMPDIR/contents.txt"
    grep -qx "CHANGELOG.md" "$BATS_TEST_TMPDIR/contents.txt"

    first_hash="$(sha256sum "$FIXTURE/dist/ash-monitor-2.2.0.tar.gz" | cut -d' ' -f1)"
    rm -rf "$FIXTURE/dist"
    run bash "$FIXTURE/scripts/build-release.sh" --output-dir "$FIXTURE/dist"
    [[ $status -eq 0 ]]
    second_hash="$(sha256sum "$FIXTURE/dist/ash-monitor-2.2.0.tar.gz" | cut -d' ' -f1)"
    [[ "$first_hash" == "$second_hash" ]]
}

@test "build-release writes the changelog section as release notes" {
    run bash "$FIXTURE/scripts/build-release.sh" --output-dir "$FIXTURE/dist"
    [[ $status -eq 0 ]]
    grep -q "release entry" "$FIXTURE/dist/release-notes.md"
}

@test "build-release excludes caches and runtime state" {
    mkdir -p "$FIXTURE/src/consumer/__pycache__" \
        "$FIXTURE/deployments/monitoring/runtime"
    printf 'cache\n' >"$FIXTURE/src/consumer/__pycache__/event.pyc"
    printf 'runtime\n' >"$FIXTURE/deployments/monitoring/runtime/secret.env"

    run bash "$FIXTURE/scripts/build-release.sh" --output-dir "$FIXTURE/dist"
    [[ $status -eq 0 ]]

    tar -tzf "$FIXTURE/dist/ash-monitor-2.2.0.tar.gz" >"$BATS_TEST_TMPDIR/contents.txt"
    ! grep -q "__pycache__" "$BATS_TEST_TMPDIR/contents.txt"
    ! grep -q "\.pyc$" "$BATS_TEST_TMPDIR/contents.txt"
    ! grep -q "deployments/monitoring/runtime" "$BATS_TEST_TMPDIR/contents.txt"
}

@test "build-release rejects a version that does not match ASH_VERSION" {
    run bash "$FIXTURE/scripts/build-release.sh" \
        --version 9.9.9 \
        --output-dir "$FIXTURE/dist"
    [[ $status -eq 1 ]]
    [[ "$output" == *"tag/version mismatch"* ]]
}

@test "build-release --help works without a repository" {
    run bash "$BUILDER" --help
    [[ $status -eq 0 ]]
    [[ "$output" == *"build-release.sh"* ]]
}
