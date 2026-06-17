#!/usr/bin/env bats
# Unit tests for hash-chained append-only log integrity

setup() {
    export ASH_LOG_DIR="/tmp/ash_test_$$"
    export ASH_TEMP_DIR="/tmp/ash_test_tmp_$$"
    export ASH_SPOOL_DIR="/tmp/ash_test_spool_$$"
    export ASH_CONFIG_DIR="/tmp/ash_test_conf_$$"
    export ASH_HASH_FILE="$ASH_LOG_DIR/.hash_chain"
    export ASH_EVENTS_FILE="$ASH_LOG_DIR/events.jsonl"
    mkdir -p "$ASH_LOG_DIR" "$ASH_TEMP_DIR" "$ASH_SPOOL_DIR" "$ASH_CONFIG_DIR"
    mkdir -p "$ASH_SPOOL_DIR/pending" "$ASH_SPOOL_DIR/sent"

    source "${BATS_TEST_DIRNAME}/../../src/agent/ash-agent.sh" 2>/dev/null || true
}

teardown() {
    rm -rf "/tmp/ash_test_$$" "/tmp/ash_test_tmp_$$" "/tmp/ash_test_spool_$$" "/tmp/ash_test_conf_$$"
}

@test "hash_chain_init creates genesis hash" {
    hash_chain_init
    [[ -f "$ASH_HASH_FILE" ]]
    local content=$(cat "$ASH_HASH_FILE")
    [[ "$content" == "0000000000000000000000000000000000000000000000000000000000000000" ]]
}

@test "hash_chain_append adds hash to event" {
    hash_chain_init
    local event='{"event_id":"test-1","event_type":"command_start"}'
    local result=$(hash_chain_append "$event")
    [[ "$result" == *"prev_hash"* ]]
    [[ "$result" == *"event_hash"* ]]
}

@test "hash chain is sequential" {
    hash_chain_init
    local event1='{"event_id":"test-1"}'
    local event2='{"event_id":"test-2"}'

    local signed1=$(hash_chain_append "$event1")
    local signed2=$(hash_chain_append "$event2")

    # Extract hashes
    local hash1=$(echo "$signed1" | grep -oP '"event_hash":"[^"]*"' | cut -d'"' -f4)
    local prev2=$(echo "$signed2" | grep -oP '"prev_hash":"[^"]*"' | cut -d'"' -f4)

    # Second event's prev_hash should equal first event's hash
    [[ "$prev2" == "$hash1" ]]
}

@test "verify_hash_chain passes on valid chain" {
    hash_chain_init

    # Write a valid chain
    local event1='{"event_id":"test-1"}'
    local event2='{"event_id":"test-2"}'
    hash_chain_append "$event1" >> "$ASH_EVENTS_FILE"
    hash_chain_append "$event2" >> "$ASH_EVENTS_FILE"

    local output=$(verify_hash_chain "$ASH_EVENTS_FILE")
    [[ "$output" == *"PASS"* ]]
}
