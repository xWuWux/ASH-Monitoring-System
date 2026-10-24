#!/usr/bin/env bats
# Degradation tests: the agent must keep producing a trustworthy local log
# while the Kafka producer is unavailable, and drain its spool afterwards.
#
# See docs/REMAINING_GAPS.md §8 (chaos testing).

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

    export KAFKA_ENABLED=true
    export KAFKA_BROKER="down-broker:9092"
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
    export FAKE_KAFKA_MODE=fail

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

@test "local event log stays complete while Kafka is down" {
    emit_event "command_start" '{"command":"echo survives-kafka-outage"}'
    emit_event "command_end" '{"exit_code":0}'

    [[ $(wc -l <"$ASH_EVENTS_FILE" | tr -d ' ') -eq 2 ]]
    run verify_hash_chain "$ASH_EVENTS_FILE"
    [[ $status -eq 0 ]]
    [[ $output == *"PASS"* ]]
    [[ $(pending_count) -eq 2 ]]
}

@test "Kafka outage does not block local emission beyond the retry budget" {
    emit_event "command_start" '{"command":"echo bounded-retries"}'

    # send_to_kafka_raw() is not called by emit_event() -- events are only
    # spooled there. The retry budget matters when the flush timer runs.
    run spool_flush
    [[ $status -ne 0 ]]
    [[ $(wc -l <"$FAKE_KAFKA_LOG" | tr -d ' ') -eq 3 ]]
    [[ $(pending_count) -eq 1 ]]
}

@test "spooled events drain after Kafka recovers" {
    emit_event "command_start" '{"command":"echo first"}'
    emit_event "command_start" '{"command":"echo second"}'

    run spool_flush
    [[ $status -ne 0 ]]
    [[ $(pending_count) -eq 2 ]]
    [[ $(sent_count) -eq 0 ]]

    export FAKE_KAFKA_MODE=success
    run spool_flush
    [[ $status -eq 0 ]]
    [[ $(pending_count) -eq 0 ]]
    [[ $(sent_count) -eq 2 ]]

    # Every event that reached Kafka is still the exact signed local event.
    run bash -c 'jq -e ".event_hash and .prev_hash" "$1"' _ "$FAKE_KAFKA_MESSAGES"
    [[ $status -eq 0 ]]
}

@test "a missing producer binary is treated as a transient outage" {
    rm -f "$BATS_TEST_TMPDIR/bin/kafka-console-producer.sh"
    emit_event "command_start" '{"command":"echo producer-missing"}'

    run spool_flush
    [[ $status -ne 0 ]]
    [[ $(pending_count) -eq 1 ]]
    run verify_hash_chain "$ASH_EVENTS_FILE"
    [[ $status -eq 0 ]]
}

@test "agent still emits locally when spool writes fail" {
    # Simulate a full/corrupt spool directory by removing the pending
    # directory after startup: spool_write() fails, but the local append-only
    # log is written first and must remain usable for forensics.
    rm -rf "$ASH_SPOOL_DIR/pending"

    emit_event "command_start" '{"command":"echo spool-unavailable"}'

    [[ -s "$ASH_EVENTS_FILE" ]]
    run verify_hash_chain "$ASH_EVENTS_FILE"
    [[ $status -eq 0 ]]
}
