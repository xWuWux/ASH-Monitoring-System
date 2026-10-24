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

@test "emit_event returns success for the first event" {
    # The counter used to be incremented with ((EVENTS_LOGGED++)), whose
    # status is the pre-increment value: the first event returned 1 after
    # being written successfully (and killed set -e callers).
    run emit_event "command_start" '{"command":"true"}'
    [[ $status -eq 0 ]]
    [[ $(wc -l <"$ASH_EVENTS_FILE") -eq 1 ]]
}

@test "safe_log_write reports failure when the target is not writable" {
    # A directory makes the append fail even when the suite runs as root
    # (which bypasses permission bits). The successful `rm` used to mask
    # the failed `cat`, so the function returned success and dropped the
    # event instead of taking its fallback path.
    local target="$BATS_TEST_TMPDIR/not-a-file"
    mkdir -p "$target"

    run safe_log_write "should not disappear" "$target"
    [[ $status -ne 0 ]]
}

@test "emit_event records a clean tty fallback without a terminal" {
    emit_event "command_start" '{"command":"true"}'

    run jq -r '.tty' "$ASH_EVENTS_FILE"
    [[ $status -eq 0 ]]
    [[ $output == "unknown" ]]
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

@test "concurrent processes cannot fork the hash chain" {
    # Every terminal session on a host appends to the same hash file. Before
    # the lock was added, 20 parallel emitters forked the chain and produced
    # dozens of integrity errors.
    local agent="${BATS_TEST_DIRNAME}/../../src/agent/ash-agent.sh"
    local emitter="$BATS_TEST_TMPDIR/emit.sh"

    cat >"$emitter" <<'SCRIPT'
#!/usr/bin/env bash
source "$1" --functions-only 2>/dev/null || true
trap - DEBUG RETURN ERR EXIT 2>/dev/null || true
set +e
hash_chain_init
load_redaction_rules
spool_init
emit_event "command_start" "{\"command\":\"echo child-$2\"}"
SCRIPT
    chmod +x "$emitter"

    local pids=()
    for i in $(seq 1 20); do
        bash "$emitter" "$agent" "$i" &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do
        wait "$pid" || true
    done

    [[ $(wc -l <"$ASH_EVENTS_FILE" | tr -d ' ') -eq 20 ]]
    run verify_hash_chain "$ASH_EVENTS_FILE"
    [[ $status -eq 0 ]]
    [[ $output == *"PASS: All 20 entries verified successfully"* ]]
}

@test "background subshells sharing one PID cannot corrupt the chain" {
    # Background subshells inherit the parent's $$; the temp-file name in
    # safe_log_write() used to be based on $$ and could collide here.
    local pids=()
    for i in $(seq 1 10); do
        (
            emit_event "command_start" "{\"command\":\"echo background-$i\"}"
        ) &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do
        wait "$pid" || true
    done

    [[ $(wc -l <"$ASH_EVENTS_FILE" | tr -d ' ') -eq 10 ]]
    run verify_hash_chain "$ASH_EVENTS_FILE"
    [[ $status -eq 0 ]]
}

@test "concurrent safe_log_write calls do not lose or duplicate lines" {
    local target="$BATS_TEST_TMPDIR/concurrent.log"
    local pids=()

    for i in $(seq 1 20); do
        (
            safe_log_write "line-$i" "$target"
        ) &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do
        wait "$pid" || true
    done

    [[ $(wc -l <"$target" | tr -d ' ') -eq 20 ]]
    [[ $(sort -u "$target" | wc -l | tr -d ' ') -eq 20 ]]
}

@test "verify_hash_chain detects content tampering" {
    emit_event "command_start" '{"command":"echo original"}'
    emit_event "command_start" '{"command":"echo second"}'

    sed -i 's/echo original/echo tampered/' "$ASH_EVENTS_FILE"

    run verify_hash_chain "$ASH_EVENTS_FILE"
    [[ $status -ne 0 ]]
    [[ $output == *"Hash mismatch"* ]]
}

@test "verify_hash_chain fails when the error count is a multiple of 256" {
    # 128 entries with a wrong prev_hash and a wrong event_hash produce 256
    # errors. Returning the raw count used to wrap to exit status 0.
    for i in $(seq 1 128); do
        printf '{"event_id":"bad-%s","prev_hash":"bad-%s","event_hash":"bad-%s"}\n' \
            "$i" "$i" "$i"
    done >"$ASH_EVENTS_FILE"

    run verify_hash_chain "$ASH_EVENTS_FILE"
    [[ $status -ne 0 ]]
    [[ $output == *"FAIL: 256 integrity errors"* ]]
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
