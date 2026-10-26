#!/usr/bin/env bats
# Smoke test for the agent's event pipeline: session lifecycle, redaction,
# hash-chain signing, local append-only logging, and Kafka spooling.
#
# This is intentionally a black-box run of the public --functions-only entry
# point in a child bash, so it does not depend on the interactive DEBUG trap.

setup() {
    export ASH_LOG_DIR="$BATS_TEST_TMPDIR/log"
    export ASH_TEMP_DIR="$BATS_TEST_TMPDIR/tmp"
    export ASH_SPOOL_DIR="$BATS_TEST_TMPDIR/spool"
    export ASH_CONFIG_DIR="$BATS_TEST_TMPDIR/conf"
    export ASH_HASH_FILE="$ASH_LOG_DIR/.hash_chain"
    export ASH_EVENTS_FILE="$ASH_LOG_DIR/events.jsonl"
    export ASH_AGENT_LOG="$ASH_LOG_DIR/agent.log"
    export ASH_STATE_FILE="$ASH_TEMP_DIR/agent_state.json"

    mkdir -p "$ASH_LOG_DIR" "$ASH_TEMP_DIR" "$ASH_CONFIG_DIR"
    mkdir -p "$ASH_SPOOL_DIR/pending" "$ASH_SPOOL_DIR/sent"

    export KAFKA_ENABLED=false
    export KAFKA_BROKER="smoke-broker:9092"
    export KAFKA_TOPIC="ash-smoke"
    export INOTIFY_ENABLED=false

    source "${BATS_TEST_DIRNAME}/../../src/agent/ash-agent.sh" --functions-only 2>/dev/null || true
    trap - DEBUG RETURN ERR EXIT 2>/dev/null || true
    set +e

    hash_chain_init
    spool_init
    load_redaction_rules

    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cp "${BATS_TEST_DIRNAME}/../helpers/fake-kafka-producer.sh" \
        "$BATS_TEST_TMPDIR/bin/kafka-console-producer.sh"
    chmod +x "$BATS_TEST_TMPDIR/bin/kafka-console-producer.sh"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    export FAKE_KAFKA_LOG="$BATS_TEST_TMPDIR/kafka.log"
    export FAKE_KAFKA_MESSAGES="$BATS_TEST_TMPDIR/kafka.messages"
    export FAKE_KAFKA_MODE=success

    sleep() { :; }
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
}

pending_count() {
    find "$ASH_SPOOL_DIR/pending" -maxdepth 1 -type f | wc -l | tr -d ' '
}

sent_count() {
    find "$ASH_SPOOL_DIR/sent" -maxdepth 1 -type f | wc -l | tr -d ' '
}

@test "end-to-end pipeline emits a redacted, signed session" {
    emit_session_start

    redacted=$(redact_sensitive_data 'mysql --password=hunter2 -u root -h db.internal')
    extra=$(jq -n -c --arg cmd "$redacted" '{command: $cmd, exit_code: 0}')
    emit_event "command_start" "$extra"

    emit_session_end

    [[ $(wc -l <"$ASH_EVENTS_FILE" | tr -d ' ') -eq 3 ]]
    run verify_hash_chain "$ASH_EVENTS_FILE"
    [[ $status -eq 0 ]]
    [[ "$output" == *"PASS: All 3 entries verified successfully"* ]]

    run jq -r '.event_type' "$ASH_EVENTS_FILE"
    [[ "$output" == *"session_start"* ]]
    [[ "$output" == *"command_start"* ]]
    [[ "$output" == *"session_end"* ]]

    run grep -q 'hunter2' "$ASH_EVENTS_FILE"
    [[ $status -ne 0 ]]
    run grep -q 'REDACTED' "$ASH_EVENTS_FILE"
    [[ $status -eq 0 ]]
}

@test "smoke event carries schema metadata and source information" {
    emit_event "command_start" '{"command":"echo smoke"}'

    run jq -e '
        .schema_version == "1.0" and
        .source == "bash-debug" and
        .event_type == "command_start" and
        .hostname != "" and
        .session_id != "" and
        (.event_id | test("^[0-9a-f-]{36}$")) and
        (.trace_id | test("^[a-f0-9]{32}$")) and
        (.span_id | test("^[a-f0-9]{16}$"))
    ' "$ASH_EVENTS_FILE"
    [[ $status -eq 0 ]]
}

@test "smoke path spools and delivers an event to Kafka when enabled" {
    export KAFKA_ENABLED=true
    emit_event "command_start" '{"command":"echo kafka-smoke"}'
    [[ $(pending_count) -eq 1 ]]

    run spool_flush
    [[ $status -eq 0 ]]
    [[ $(pending_count) -eq 0 ]]
    [[ $(sent_count) -eq 1 ]]

    run grep -q '"command":"echo kafka-smoke"' "$FAKE_KAFKA_MESSAGES"
    [[ $status -eq 0 ]]
}

@test "smoke path keeps local events when Kafka is down" {
    export KAFKA_ENABLED=true
    export FAKE_KAFKA_MODE=fail
    emit_event "command_start" '{"command":"echo outage-smoke"}'

    run spool_flush
    [[ $status -ne 0 ]]
    [[ $(pending_count) -eq 1 ]]

    run verify_hash_chain "$ASH_EVENTS_FILE"
    [[ $status -eq 0 ]]
    run jq -e '.command == "echo outage-smoke"' "$ASH_EVENTS_FILE"
    [[ $status -eq 0 ]]
}

@test "smoke path writes one valid JSON object per line" {
    emit_event "command_start" '{"command":"true"}'
    emit_event "command_end" '{"exit_code":0}'

    while IFS= read -r line; do
        jq -e . <<<"$line" >/dev/null || return 1
    done <"$ASH_EVENTS_FILE"
}
