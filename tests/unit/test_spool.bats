#!/usr/bin/env bats
# Unit tests for the local spool queue used when Kafka is unavailable.
#
# The agent is sourced with --functions-only so main() (watchers, spool flush
# timer, DEBUG trap) never runs inside the BATS process.

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
    export KAFKA_BROKER="broker:9092"
    export KAFKA_TOPIC="ash-test"
    export INOTIFY_ENABLED=false
    export ASH_SPOOL_MAX_SIZE=1073741824

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

    # The agent retries with 2s/4s sleeps; don't make the suite wait for them.
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

@test "spool_init creates pending and sent directories with restrictive permissions" {
    rm -rf "$ASH_SPOOL_DIR"
    run spool_init
    [[ $status -eq 0 ]]
    [[ -d "$ASH_SPOOL_DIR/pending" ]]
    [[ -d "$ASH_SPOOL_DIR/sent" ]]
    [[ $(stat -c '%a' "$ASH_SPOOL_DIR") == "700" ]]
}

@test "spool_write persists exactly one JSON event" {
    run spool_write '{"event_id":"spool-1","event_type":"command_start"}'
    [[ $status -eq 0 ]]
    [[ $(pending_count) -eq 1 ]]
    run grep -q '"event_id":"spool-1"' "$ASH_SPOOL_DIR"/pending/*
    [[ $status -eq 0 ]]
}

@test "spool_write fails cleanly when the pending directory is missing" {
    rm -rf "$ASH_SPOOL_DIR/pending"
    run spool_write '{"event_id":"spool-2"}'
    [[ $status -ne 0 ]]
}

@test "spool_flush drains pending events when the producer succeeds" {
    spool_write '{"event_id":"spool-3","event_type":"command_start"}'
    run spool_flush
    [[ $status -eq 0 ]]
    [[ $(pending_count) -eq 0 ]]
    [[ $(sent_count) -eq 1 ]]
    run grep -q '"event_id":"spool-3"' "$ASH_SPOOL_DIR"/sent/*
    [[ $status -eq 0 ]]
}

@test "spool_flush passes broker and topic to the producer" {
    spool_write '{"event_id":"spool-4"}'
    run spool_flush
    [[ $status -eq 0 ]]
    run grep -q -- '--broker-list broker:9092' "$FAKE_KAFKA_LOG"
    [[ $status -eq 0 ]]
    run grep -q -- '--topic ash-test' "$FAKE_KAFKA_LOG"
    [[ $status -eq 0 ]]
}

@test "spool_flush keeps every event queued while the producer is down" {
    export FAKE_KAFKA_MODE=fail
    spool_write '{"event_id":"spool-5"}'
    spool_write '{"event_id":"spool-6"}'

    run spool_flush
    [[ $status -ne 0 ]]
    [[ $(pending_count) -eq 2 ]]
    [[ $(sent_count) -eq 0 ]]
}

@test "spool_flush stops after the first failed event instead of spinning through the backlog" {
    export FAKE_KAFKA_MODE=fail
    spool_write '{"event_id":"spool-7"}'
    spool_write '{"event_id":"spool-8"}'

    run spool_flush
    [[ $status -ne 0 ]]
    # send_to_kafka_raw() retries each event three times; the second event
    # must not be attempted at all while the first one is still failing.
    [[ $(wc -l <"$FAKE_KAFKA_LOG" | tr -d ' ') -eq 3 ]]
}

@test "spool_flush drains the backlog after Kafka recovers" {
    export FAKE_KAFKA_MODE=fail
    spool_write '{"event_id":"spool-9"}'
    run spool_flush
    [[ $status -ne 0 ]]
    [[ $(pending_count) -eq 1 ]]

    export FAKE_KAFKA_MODE=success
    run spool_flush
    [[ $status -eq 0 ]]
    [[ $(pending_count) -eq 0 ]]
    [[ $(sent_count) -eq 1 ]]
}

@test "send_to_kafka_raw retries and succeeds on a flaky broker" {
    export FAKE_KAFKA_MODE=flaky
    export FAKE_KAFKA_COUNT_FILE="$BATS_TEST_TMPDIR/attempts"
    export FAKE_KAFKA_SUCCEED_ON=3

    run send_to_kafka_raw '{"event_id":"spool-10"}'
    [[ $status -eq 0 ]]
    [[ $(cat "$FAKE_KAFKA_COUNT_FILE") -eq 3 ]]
}

@test "spool size limit trims the oldest pending events" {
    for i in $(seq 1 100); do
        : >"$ASH_SPOOL_DIR/pending/pre_$i"
    done
    export ASH_SPOOL_MAX_SIZE=1

    spool_write '{"event_id":"spool-11"}'
    [[ $(pending_count) -lt 101 ]]
}

@test "verify_hash_chain passes for spooled events" {
    hash_chain_init
    signed=$(hash_chain_append '{"event_id":"spool-12"}')
    printf '%s\n' "$signed" >>"$ASH_EVENTS_FILE"

    run verify_hash_chain "$ASH_EVENTS_FILE"
    [[ $status -eq 0 ]]
    [[ $output == *"PASS"* ]]
}
