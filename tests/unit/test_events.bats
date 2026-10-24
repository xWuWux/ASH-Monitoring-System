#!/usr/bin/env bats
# Unit tests for structured event emission and hash-chain integrity.
#
# These exercise the same --functions-only entry point used by the shell
# integrations, without installing the interactive DEBUG trap.

setup() {
    export ASH_LOG_DIR="$BATS_TEST_TMPDIR/log"
    export ASH_TEMP_DIR="$BATS_TEST_TMPDIR/tmp"
    export ASH_SPOOL_DIR="$BATS_TEST_TMPDIR/spool"
    export ASH_CONFIG_DIR="$BATS_TEST_TMPDIR/conf"
    export ASH_HASH_FILE="$ASH_LOG_DIR/.hash_chain"
    export ASH_EVENTS_FILE="$ASH_LOG_DIR/events.jsonl"
    export ASH_AGENT_LOG="$ASH_LOG_DIR/agent.log"

    mkdir -p "$ASH_LOG_DIR" "$ASH_TEMP_DIR" "$ASH_CONFIG_DIR"
    mkdir -p "$ASH_SPOOL_DIR/pending" "$ASH_SPOOL_DIR/sent"

    export KAFKA_ENABLED=false
    export INOTIFY_ENABLED=false
    export MAX_COMMANDS_PER_SECOND=50
    export MAX_OUTPUT_SIZE=1048576

    source "${BATS_TEST_DIRNAME}/../../src/agent/ash-agent.sh" --functions-only 2>/dev/null || true
    trap - DEBUG RETURN ERR EXIT 2>/dev/null || true
    set +e

    hash_chain_init
    spool_init
    load_redaction_rules
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
}

pending_count() {
    find "$ASH_SPOOL_DIR/pending" -maxdepth 1 -type f | wc -l | tr -d ' '
}

@test "emit_event writes one valid JSON object with the required schema fields" {
    emit_event "command_start" '{"command":"ls -la","exit_code":0}'

    [[ -s "$ASH_EVENTS_FILE" ]]
    run jq -e '
        .event_id and
        .schema_version and
        .timestamp and
        .hostname and
        .source and
        .event_type and
        .session_id and
        .command and
        .prev_hash and
        .event_hash
    ' "$ASH_EVENTS_FILE"
    [[ $status -eq 0 ]]
}

@test "emit_event preserves caller-supplied extra fields" {
    emit_event "command_start" '{"command":"cat /etc/hosts","bash_subshell":2,"lineno":42}'

    run jq -e '.command == "cat /etc/hosts" and .bash_subshell == 2 and .lineno == 42' \
        "$ASH_EVENTS_FILE"
    [[ $status -eq 0 ]]
}

@test "emit_event does not spool when Kafka is disabled" {
    export KAFKA_ENABLED=false
    emit_event "command_start" '{"command":"true"}'
    [[ $(pending_count) -eq 0 ]]
}

@test "emit_event spools signed events when Kafka is enabled" {
    export KAFKA_ENABLED=true
    emit_event "command_start" '{"command":"true"}'

    [[ $(pending_count) -eq 1 ]]
    spooled=$(cat "$ASH_SPOOL_DIR"/pending/*)
    run jq -e '.event_hash and .prev_hash and .command == "true"' <<<"$spooled"
    [[ $status -eq 0 ]]
}

@test "multiple events form a valid hash chain" {
    emit_event "session_start" '{}'
    emit_event "command_start" '{"command":"echo one"}'
    emit_event "command_end" '{"exit_code":0}'

    run verify_hash_chain "$ASH_EVENTS_FILE"
    [[ $status -eq 0 ]]
    [[ $output == *"PASS: All 3 entries verified successfully"* ]]
}

@test "verify_hash_chain detects content tampering" {
    emit_event "command_start" '{"command":"echo original"}'
    emit_event "command_start" '{"command":"echo second"}'

    sed -i 's/echo original/echo tampered/' "$ASH_EVENTS_FILE"

    run verify_hash_chain "$ASH_EVENTS_FILE"
    [[ $status -ne 0 ]]
    [[ $output == *"Hash mismatch"* ]]
}

@test "verify_hash_chain detects a missing link in the chain" {
    hash_chain_init
    signed_one=$(hash_chain_append '{"event_id":"chain-1"}')
    signed_two=$(hash_chain_append '{"event_id":"chain-2"}')

    # Drop the first event while keeping the second: its prev_hash now points
    # at an entry that is no longer present.
    printf '%s\n' "$signed_two" >"$ASH_EVENTS_FILE"

    run verify_hash_chain "$ASH_EVENTS_FILE"
    [[ $status -ne 0 ]]
    [[ $output == *"Chain broken"* ]]
}

@test "hash_chain_append links each event to the previous hash" {
    hash_chain_init
    first=$(hash_chain_append '{"event_id":"chain-3"}')
    second=$(hash_chain_append '{"event_id":"chain-4"}')

    first_hash=$(jq -r '.event_hash' <<<"$first")
    second_prev=$(jq -r '.prev_hash' <<<"$second")
    [[ "$second_prev" == "$first_hash" ]]
}

@test "save_state writes a machine-readable state file" {
    save_state
    [[ -s "$ASH_STATE_FILE" ]]
    run jq -e '.pid and .session_id and .events_logged' "$ASH_STATE_FILE"
    [[ $status -eq 0 ]]
}
