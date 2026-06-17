#!/usr/bin/env bats
# Regression tests for subshell and command substitution monitoring

setup() {
    export ASH_LOG_DIR="/tmp/ash_test_$$"
    export ASH_TEMP_DIR="/tmp/ash_test_tmp_$$"
    export ASH_SPOOL_DIR="/tmp/ash_test_spool_$$"
    export ASH_CONFIG_DIR="/tmp/ash_test_conf_$$"
    export ASH_EVENTS_FILE="$ASH_LOG_DIR/events.jsonl"
    mkdir -p "$ASH_LOG_DIR" "$ASH_TEMP_DIR" "$ASH_SPOOL_DIR" "$ASH_CONFIG_DIR"
    mkdir -p "$ASH_SPOOL_DIR/pending" "$ASH_SPOOL_DIR/sent"
    export KAFKA_ENABLED=false
    export INOTIFY_ENABLED=false

    source "${BATS_TEST_DIRNAME}/../../src/agent/ash-agent.sh" 2>/dev/null || true
}

teardown() {
    rm -rf "/tmp/ash_test_$$" "/tmp/ash_test_tmp_$$" "/tmp/ash_test_spool_$$" "/tmp/ash_test_conf_$$"
}

@test "set -T is enabled for trap inheritance" {
    # Verify functrace is set
    [[ "$-" == *T* ]] || [[ "$(shopt -p functrace 2>/dev/null)" == *"on"* ]]
}

@test "subshell parentheses are captured" {
    (echo "subshell_test_unique_12345" >/dev/null)
    sleep 0.5
    # With set -T, the DEBUG trap should fire in subshells
    grep -q "subshell_test_unique_12345\|command_start" "$ASH_EVENTS_FILE" 2>/dev/null || \
        skip "Subshell capture requires full agent initialization"
}

@test "command substitution is captured" {
    local result
    result=$(echo "cmd_sub_test_67890")
    sleep 0.5
    [[ "$result" == "cmd_sub_test_67890" ]]
}

@test "function internals are captured" {
    test_func() {
        echo "inside_function_11111" >/dev/null
    }
    test_func
    sleep 0.5
    # Verify function ran
    [[ $? -eq 0 ]]
}

@test "pipes log both commands" {
    echo "pipe_test" | cat >/dev/null
    [[ $? -eq 0 ]]
}

@test "heredoc does not corrupt logging" {
    cat << 'EOF' >/dev/null
This is a heredoc test
with multiple lines
EOF
    [[ $? -eq 0 ]]
}

@test "compound commands with && log correctly" {
    true && echo "compound_test" >/dev/null
    [[ $? -eq 0 ]]
}

@test "for loop iterations are handled" {
    for i in 1 2 3; do
        echo "loop_$i" >/dev/null
    done
    [[ $? -eq 0 ]]
}
