#!/usr/bin/env bats
# Degradation tests for crash recovery and duplicate-agent protection.

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

    export KAFKA_ENABLED=true
    export KAFKA_BROKER="recovery-broker:9092"
    export KAFKA_TOPIC="ash-test"
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

@test "recover_state is a no-op when no state file exists" {
    run recover_state
    [[ $status -eq 0 ]]
}

@test "recover_state flushes the spool from a previous run and clears state" {
    dead_pid=999999
    while kill -0 "$dead_pid" 2>/dev/null; do
        dead_pid=$((dead_pid - 1))
    done
    printf '{"pid":%s,"session_id":"old","events_logged":1}\n' \
        "$dead_pid" >"$ASH_STATE_FILE"
    spool_write '{"event_id":"recover-1","event_type":"command_start"}'

    run recover_state
    [[ $status -eq 0 ]]
    [[ ! -f "$ASH_STATE_FILE" ]]
    [[ $(pending_count) -eq 0 ]]
    [[ $(sent_count) -eq 1 ]]
}

@test "recover_state refuses to start when the previous agent is still alive" {
    printf '{"pid":%s,"session_id":"alive","events_logged":1}\n' "$$" >"$ASH_STATE_FILE"

    run recover_state
    [[ $status -ne 0 ]]
    [[ -f "$ASH_STATE_FILE" ]]
}

@test "recover_state kills orphaned watcher PIDs recorded by a dead agent" {
    dead_pid=999999
    while kill -0 "$dead_pid" 2>/dev/null; do
        dead_pid=$((dead_pid - 1))
    done
    printf '{"pid":%s}\n' "$dead_pid" >"$ASH_STATE_FILE"

    orphan_pid_file="$ASH_TEMP_DIR/inotify.pid"
    sleep 60 &
    orphan=$!
    echo "$orphan" >"$orphan_pid_file"

    run recover_state
    [[ $status -eq 0 ]]
    wait "$orphan" 2>/dev/null || true
    run kill -0 "$orphan"
    [[ $status -ne 0 ]]
    [[ ! -f "$orphan_pid_file" ]]
}
