#!/usr/bin/env bats
# Degradation tests for missing optional dependencies.
#
# jq and inotifywait are optional (scripts/install.sh only warns when they are
# absent). The agent must fall back to its built-in JSON construction and must
# disable file watching instead of refusing to start.

setup() {
    export TEST_ROOT="$BATS_TEST_TMPDIR"
    export ASH_ROOT="$TEST_ROOT/ash"
    export ASH_LOG_DIR="$ASH_ROOT/log"
    export ASH_TEMP_DIR="$ASH_ROOT/tmp"
    export ASH_SPOOL_DIR="$ASH_ROOT/spool"
    export ASH_CONFIG_DIR="$ASH_ROOT/conf"
    export ASH_HASH_FILE="$ASH_LOG_DIR/.hash_chain"
    export ASH_EVENTS_FILE="$ASH_LOG_DIR/events.jsonl"
    export ASH_AGENT_LOG="$ASH_LOG_DIR/agent.log"

    mkdir -p "$ASH_LOG_DIR" "$ASH_TEMP_DIR" "$ASH_CONFIG_DIR"
    mkdir -p "$ASH_SPOOL_DIR/pending" "$ASH_SPOOL_DIR/sent"

    # A PATH containing only the commands the agent's fallback path needs.
    # jq, inotifywait, and tty are deliberately absent.
    export MINIMAL_BIN="$TEST_ROOT/bin"
    mkdir -p "$MINIMAL_BIN"
    for cmd in cat chmod cut date find flock grep hostname ls mkdir rm sed sha256sum tail wc xargs; do
        ln -s "$(command -v "$cmd")" "$MINIMAL_BIN/$cmd"
    done

    export ASH_AGENT="${BATS_TEST_DIRNAME}/../../src/agent/ash-agent.sh"
    export ASH_INOTIFY_ENABLED=true
    export ASH_MAX_COMMANDS_PER_SECOND=50
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
}

run_without_optional_deps() {
    run env -i \
        PATH="$MINIMAL_BIN" \
        ASH_LOG_DIR="$ASH_LOG_DIR" \
        ASH_TEMP_DIR="$ASH_TEMP_DIR" \
        ASH_SPOOL_DIR="$ASH_SPOOL_DIR" \
        ASH_CONFIG_DIR="$ASH_CONFIG_DIR" \
        ASH_AGENT_LOG="$ASH_AGENT_LOG" \
        ASH_HASH_FILE="$ASH_HASH_FILE" \
        ASH_EVENTS_FILE="$ASH_EVENTS_FILE" \
        INOTIFY_ENABLED="$ASH_INOTIFY_ENABLED" \
        KAFKA_ENABLED=false \
        /bin/bash --noprofile --norc -c '
            source "$1" --functions-only
            trap - DEBUG RETURN ERR EXIT 2>/dev/null || true
            set +e

            validate_config
            printf "validate_status=%s\n" "$?"
            printf "inotify_enabled=%s\n" "$INOTIFY_ENABLED"

            hash_chain_init
            spool_init
            load_redaction_rules
            emit_event "command_start" "{\"command\":\"echo no-jq-fallback\"}"
            verify_hash_chain "$ASH_EVENTS_FILE"
        ' _ "$ASH_AGENT"
}

@test "agent starts without jq and still writes valid signed JSON" {
    run_without_optional_deps
    [[ $status -eq 0 ]]
    [[ "$output" == *"validate_status=0"* ]]
    [[ "$output" == *"PASS"* ]]

    run jq -e '
        .event_type == "command_start" and
        .command == "echo no-jq-fallback" and
        .prev_hash and
        .event_hash
    ' "$ASH_EVENTS_FILE"
    [[ $status -eq 0 ]]
}

@test "validate_config disables inotify when inotifywait is missing" {
    run_without_optional_deps
    [[ $status -eq 0 ]]
    [[ "$output" == *"inotify_enabled=false"* ]]
    run grep -q 'inotifywait not found' "$ASH_AGENT_LOG"
    [[ $status -eq 0 ]]
}

@test "missing jq fallback produces a chain that verifies in both modes" {
    run_without_optional_deps
    [[ $status -eq 0 ]]

    # The parent has jq available; verify the fallback-written file with the
    # jq-based verifier as a second, independent implementation.
    source "$ASH_AGENT" --functions-only 2>/dev/null || true
    trap - DEBUG RETURN ERR EXIT 2>/dev/null || true
    run verify_hash_chain "$ASH_EVENTS_FILE"
    [[ $status -eq 0 ]]
    [[ "$output" == *"PASS"* ]]
}
