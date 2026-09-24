#!/usr/bin/env bats
# Unit tests for configuration validation
#
# Important:
# Do not source ash-agent.sh directly into the BATS runner shell.
# The agent installs shell traps/debug hooks which can interfere with BATS.
# Run validation in an isolated child bash process instead.

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

run_validate_config() {
    local agent_path="${BATS_TEST_DIRNAME}/../../src/agent/ash-agent.sh"

    run timeout 10s bash --noprofile --norc -c '
        set +e
        # --functions-only: define validate_config et al without running
        # main() (which starts background watchers, the hash chain, spool
        # flush timer, ...). Without this, sourcing runs the full agent
        # startup and this whole isolated-child-process trick still hangs
        # or silently swallows the real validate_config() result inside it.
        source "$1" --functions-only >/dev/null 2>&1 || true

        # Avoid leaking agent DEBUG/RETURN/ERR/EXIT traps into validation execution.
        trap - DEBUG RETURN ERR EXIT 2>/dev/null || true
        set +T 2>/dev/null || true

        if ! declare -F validate_config >/dev/null 2>&1; then
            echo "validate_config function not found"
            exit 127
        fi

        validate_config
    ' _ "$agent_path"
}

@test "validate_config passes with valid config" {
    run_validate_config
    [[ $status -eq 0 ]]
}

@test "validate_config fails with unwritable log dir" {
    export ASH_LOG_DIR="/nonexistent/path/that/cannot/be/created"
    run_validate_config
    [[ $status -ne 0 ]]
}

@test "validate_config warns when Kafka enabled without broker" {
    export KAFKA_ENABLED=true
    export KAFKA_BROKER=""
    run_validate_config
    [[ $status -ne 0 ]]
    [[ "$output" == *"KAFKA_BROKER"* ]]
}

@test "validate_config fails with invalid MAX_COMMANDS_PER_SECOND" {
    export MAX_COMMANDS_PER_SECOND=0
    run_validate_config
    [[ $status -ne 0 ]]
}
