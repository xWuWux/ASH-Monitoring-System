#!/usr/bin/env bats
# Security regression tests: secrets must never reach the event log, the
# agent log, the spool, Kafka payloads, or file-change diffs.
#
# The canaries below are fake values that match the agent's built-in
# redaction patterns. They exist only so the tests can prove the patterns
# fire before anything is written to disk.

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
    export KAFKA_BROKER="leak-test:9092"
    export KAFKA_TOPIC="ash-leak-test"
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

# "raw command|canary that must not survive"
leak_cases() {
    cat <<'EOF'
mysql --password=PASSWORD_CANARY_9f3a -u root|PASSWORD_CANARY_9f3a
mysql -pDBPASS_CANARY_1a2b -u root|DBPASS_CANARY_1a2b
curl -H "Authorization: Bearer BEARER_CANARY_7c1d" https://example.test|BEARER_CANARY_7c1d
export AWS_ACCESS_KEY_ID=AKIAABCDEFGHIJKLMNOP|AKIAABCDEFGHIJKLMNOP
export api_key=APIKEY_CANARY_4f2a|APIKEY_CANARY_4f2a
psql postgresql://user:URL_CANARY_2b8e@db.internal/app|URL_CANARY_2b8e
curl -H "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJjYW5hcnkifQ.JWT_CANARY_sig" https://example.test|JWT_CANARY_sig
EOF
}

assert_no_canary() {
    local file="$1"
    local canary="$2"
    if grep -Fq "$canary" "$file"; then
        echo "secret ${canary} leaked into ${file}" >&2
        return 1
    fi
}

@test "redaction removes every supported secret form" {
    while IFS='|' read -r command canary; do
        [[ -z "$command" ]] && continue
        result=$(redact_sensitive_data "$command")
        if [[ "$result" == *"$canary"* ]]; then
            echo "not redacted: ${command} -> ${result}" >&2
            return 1
        fi
    done < <(leak_cases)
}

@test "events, spool files, agent log, and Kafka payloads contain no secrets" {
    while IFS='|' read -r command canary; do
        [[ -z "$command" ]] && continue
        redacted=$(redact_sensitive_data "$command")
        extra=$(jq -n -c --arg cmd "$redacted" '{command: $cmd}')
        emit_event "command_start" "$extra"
    done < <(leak_cases)

    run spool_flush
    [[ $status -eq 0 ]]

    local files=("$ASH_EVENTS_FILE" "$ASH_AGENT_LOG" "$FAKE_KAFKA_MESSAGES")
    while IFS= read -r -d '' spooled; do
        files+=("$spooled")
    done < <(find "$ASH_SPOOL_DIR" -type f -print0)

    for file in "${files[@]}"; do
        [[ -f "$file" ]] || continue
        while IFS='|' read -r _ canary; do
            [[ -z "$canary" ]] && continue
            assert_no_canary "$file" "$canary"
        done < <(leak_cases)
    done
}

@test "commands with secrets never reach the agent log" {
    export KAFKA_ENABLED=false
    raw='mysql --password=AGENT_LOG_CANARY_6a7b -u root'
    redacted=$(redact_sensitive_data "$raw")
    extra=$(jq -n -c --arg cmd "$redacted" '{command: $cmd}')
    emit_event "command_start" "$extra"

    [[ -f "$ASH_AGENT_LOG" ]] || return 0
    assert_no_canary "$ASH_AGENT_LOG" "AGENT_LOG_CANARY_6a7b"
    assert_no_canary "$ASH_EVENTS_FILE" "AGENT_LOG_CANARY_6a7b"
}

@test "file-change diffs are redacted before they are emitted" {
    local tracked="$BATS_TEST_TMPDIR/tracked.conf"
    local snapshot="$BATS_TEST_TMPDIR/snapshot"

    printf 'old\n' >"$tracked"
    cp "$tracked" "$snapshot"
    printf 'old\napi_key=FILE_CANARY_8d2c\nmysql --password=FILE_PASS_CANARY_3e4f\n' >"$tracked"

    ASH_PENDING_SNAPSHOTS=("${tracked}|${snapshot}")
    check_pending_file_changes 'printf "api_key=FILE_CANARY_8d2c" > tracked.conf'

    assert_no_canary "$ASH_EVENTS_FILE" "FILE_CANARY_8d2c"
    assert_no_canary "$ASH_EVENTS_FILE" "FILE_PASS_CANARY_3e4f"

    run jq -e '
        select(.event_type == "file_modify") |
        .diff_content | contains("[REDACTED]")
    ' "$ASH_EVENTS_FILE"
    [[ $status -eq 0 ]]
}

@test "stored events still carry the redaction marker and a valid hash chain" {
    command='mysql --password=CHAIN_CANARY_5c9d -u root'
    redacted=$(redact_sensitive_data "$command")
    extra=$(jq -n -c --arg cmd "$redacted" '{command: $cmd}')
    emit_event "command_start" "$extra"

    assert_no_canary "$ASH_EVENTS_FILE" "CHAIN_CANARY_5c9d"
    run grep -Fq 'REDACTED' "$ASH_EVENTS_FILE"
    [[ $status -eq 0 ]]
    run verify_hash_chain "$ASH_EVENTS_FILE"
    [[ $status -eq 0 ]]
}
