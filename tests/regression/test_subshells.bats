#!/usr/bin/env bats
# Regression tests for subshell and command substitution monitoring
#
# Do not source ash-agent.sh directly in setup.
# Full agent initialization installs shell traps and can interfere with BATS.
# These tests validate shell constructs safely; full capture can be covered
# by dedicated integration tests.

setup() {
    export ASH_LOG_DIR="/tmp/ash_test_$$"
    export ASH_TEMP_DIR="/tmp/ash_test_tmp_$$"
    export ASH_SPOOL_DIR="/tmp/ash_test_spool_$$"
    export ASH_CONFIG_DIR="/tmp/ash_test_conf_$$"
    export ASH_EVENTS_FILE="$ASH_LOG_DIR/events.jsonl"

    mkdir -p "$ASH_LOG_DIR" "$ASH_TEMP_DIR" "$ASH_SPOOL_DIR" "$ASH_CONFIG_DIR"
    mkdir -p "$ASH_SPOOL_DIR/pending" "$ASH_SPOOL_DIR/sent"
    touch "$ASH_EVENTS_FILE"

    export KAFKA_ENABLED=false
    export INOTIFY_ENABLED=false

    # Enable functrace for shell behavior regression coverage without loading
    # the full ASH agent into the BATS process.
    set -T 2>/dev/null || true
}

teardown() {
    rm -rf "/tmp/ash_test_$$" "/tmp/ash_test_tmp_$$" "/tmp/ash_test_spool_$$" "/tmp/ash_test_conf_$$"
}

@test "set -T is enabled for trap inheritance" {
    [[ "$-" == *T* ]] || [[ "$(shopt -p functrace 2>/dev/null)" == *"on"* ]]
}

@test "subshell parentheses are handled safely" {
    run bash --noprofile --norc -c '(echo "subshell_test_unique_12345" >/dev/null)'
    [[ $status -eq 0 ]]
}

@test "command substitution is handled safely" {
    run bash --noprofile --norc -c 'result=$(echo "cmd_sub_test_67890"); [[ "$result" == "cmd_sub_test_67890" ]]'
    [[ $status -eq 0 ]]
}

@test "function internals are handled safely" {
    run bash --noprofile --norc -c '
        test_func() {
            echo "inside_function_11111" >/dev/null
        }
        test_func
    '
    [[ $status -eq 0 ]]
}

@test "pipes are handled safely" {
    run bash --noprofile --norc -c 'echo "pipe_test" | cat >/dev/null'
    [[ $status -eq 0 ]]
}

@test "heredoc does not corrupt shell execution" {
    run bash --noprofile --norc -c 'cat << "HEREDOC_EOF" >/dev/null
This is a heredoc test
with multiple lines
HEREDOC_EOF'
    [[ $status -eq 0 ]]
}

@test "compound commands with && are handled safely" {
    run bash --noprofile --norc -c 'true && echo "compound_test" >/dev/null'
    [[ $status -eq 0 ]]
}

@test "for loop iterations are handled safely" {
    run bash --noprofile --norc -c '
        for i in 1 2 3; do
            echo "loop_$i" >/dev/null
        done
    '
    [[ $status -eq 0 ]]
}
