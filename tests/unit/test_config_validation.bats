#!/usr/bin/env bats
# Unit tests for configuration validation

setup() {
    export ASH_LOG_DIR="/tmp/ash_test_$$"
    export ASH_TEMP_DIR="/tmp/ash_test_tmp_$$"
    export ASH_SPOOL_DIR="/tmp/ash_test_spool_$$"
    export ASH_CONFIG_DIR="/tmp/ash_test_conf_$$"
    mkdir -p "$ASH_LOG_DIR" "$ASH_TEMP_DIR" "$ASH_SPOOL_DIR" "$ASH_CONFIG_DIR"
    mkdir -p "$ASH_SPOOL_DIR/pending" "$ASH_SPOOL_DIR/sent"

    export KAFKA_ENABLED=false
    export INOTIFY_ENABLED=false
    export MAX_COMMANDS_PER_SECOND=50
    export MAX_OUTPUT_SIZE=1048576
}

teardown() {
    rm -rf "/tmp/ash_test_$$" "/tmp/ash_test_tmp_$$" "/tmp/ash_test_spool_$$" "/tmp/ash_test_conf_$$"
}

@test "validate_config passes with valid config" {
    source "${BATS_TEST_DIRNAME}/../../src/agent/ash-agent.sh" 2>/dev/null || true
    run validate_config
    [[ $status -eq 0 ]]
}

@test "validate_config fails with unwritable log dir" {
    export ASH_LOG_DIR="/nonexistent/path/that/cannot/be/created"
    source "${BATS_TEST_DIRNAME}/../../src/agent/ash-agent.sh" 2>/dev/null || true
    run validate_config
    [[ $status -ne 0 ]]
}

@test "validate_config warns when Kafka enabled without broker" {
    export KAFKA_ENABLED=true
    export KAFKA_BROKER=""
    source "${BATS_TEST_DIRNAME}/../../src/agent/ash-agent.sh" 2>/dev/null || true
    run validate_config
    [[ $status -ne 0 ]]
    [[ "$output" == *"KAFKA_BROKER"* ]]
}

@test "validate_config fails with invalid MAX_COMMANDS_PER_SECOND" {
    export MAX_COMMANDS_PER_SECOND=0
    source "${BATS_TEST_DIRNAME}/../../src/agent/ash-agent.sh" 2>/dev/null || true
    run validate_config
    [[ $status -ne 0 ]]
}
