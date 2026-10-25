#!/usr/bin/env bash
# End-to-end Kafka test: agent -> kafka-console-producer -> broker ->
# Python consumer -> PostgreSQL.
#
# This is deliberately a real-service test. The BATS degradation suite uses
# a fake producer to make failure injection deterministic; this script proves
# the real wire path and the consumer's database write work together.
#
# Required environment:
#   ASH_DATABASE_URL   PostgreSQL URL (schema is created if needed)
#
# Optional environment (defaults in parentheses):
#   ASH_KAFKA_BROKER       broker advertised to this host (127.0.0.1:9092)
#   ASH_KAFKA_TOPIC        topic name (ash-e2e-<epoch>-<pid>)
#   ASH_KAFKA_GROUP        consumer group (ash-e2e-group-<epoch>-<pid>)
#   ASH_E2E_TIMEOUT        seconds per wait stage (90)
#   ASH_E2E_METRICS_PORT   consumer Prometheus port (19090)
#
# Requires kafka-console-producer.sh on PATH (the agent's real producer) and
# kafka-topics.sh/kafka-consumer-groups.sh for setup/readiness checks.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
AGENT="$ROOT/src/agent/ash-agent.sh"

: "${ASH_DATABASE_URL:?ASH_DATABASE_URL is required}"

BROKER="${ASH_KAFKA_BROKER:-127.0.0.1:9092}"
TOPIC="${ASH_KAFKA_TOPIC:-ash-e2e-$(date +%s)-$$}"
GROUP="${ASH_KAFKA_GROUP:-ash-e2e-group-$(date +%s)-$$}"
TIMEOUT="${ASH_E2E_TIMEOUT:-90}"
METRICS_PORT="${ASH_E2E_METRICS_PORT:-19090}"

for value_name in TIMEOUT METRICS_PORT; do
    value="${!value_name}"
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "${value_name} must be a non-negative integer, got '${value}'" >&2
        exit 2
    fi
done
if ((TIMEOUT < 1)); then
    echo "TIMEOUT must be at least 1 second" >&2
    exit 2
fi
if ((METRICS_PORT < 1 || METRICS_PORT > 65535)); then
    echo "METRICS_PORT must be between 1 and 65535" >&2
    exit 2
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ash-kafka-e2e.XXXXXX")
CONSUMER_PID=""
EVENT_ID=""

cleanup() {
    local status=$?

    if [[ -n "$CONSUMER_PID" ]] && kill -0 "$CONSUMER_PID" 2>/dev/null; then
        kill "$CONSUMER_PID" 2>/dev/null || true
        for _ in $(seq 1 10); do
            kill -0 "$CONSUMER_PID" 2>/dev/null || break
            sleep 1
        done
        kill -9 "$CONSUMER_PID" 2>/dev/null || true
        wait "$CONSUMER_PID" 2>/dev/null || true
    fi

    if [[ $status -ne 0 ]]; then
        echo "--- consumer log ---" >&2
        tail -n 100 "$WORK_DIR/consumer.log" 2>/dev/null || true
        echo "--- consumer stderr ---" >&2
        tail -n 40 "$WORK_DIR/consumer.err" 2>/dev/null || true
        echo "--- agent events ---" >&2
        tail -n 10 "$WORK_DIR/log/events.jsonl" 2>/dev/null || true
    fi

    if [[ -n "$EVENT_ID" ]]; then
        python3 - "$ASH_DATABASE_URL" "$EVENT_ID" <<'PY' >/dev/null 2>&1 || true
import sys

import psycopg2

conn = psycopg2.connect(sys.argv[1])
try:
    with conn.cursor() as cursor:
        cursor.execute("DELETE FROM command_logs WHERE event_id = %s", (sys.argv[2],))
    conn.commit()
finally:
    conn.close()
PY
    fi

    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

for command in kafka-console-producer.sh kafka-topics.sh kafka-consumer-groups.sh; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "$command not found on PATH; install the Kafka CLI first" >&2
        exit 2
    fi
done

mkdir -p "$WORK_DIR/log" "$WORK_DIR/tmp" "$WORK_DIR/spool/pending" "$WORK_DIR/spool/sent" "$WORK_DIR/conf"

echo "Creating ASH schema..."
ASH_DATABASE_URL="$ASH_DATABASE_URL" python3 "$ROOT/tests/smoke/init_schema.py"

echo "Creating topic ${TOPIC}..."
created=0
for attempt in $(seq 1 10); do
    if kafka-topics.sh \
        --bootstrap-server "$BROKER" \
        --create --if-not-exists \
        --topic "$TOPIC" \
        --partitions 1 \
        --replication-factor 1 >/dev/null 2>&1; then
        created=1
        break
    fi
    if [[ $attempt -eq 10 ]]; then
        break
    fi
    sleep 2
done
if [[ $created -ne 1 ]]; then
    echo "could not create Kafka topic ${TOPIC} on ${BROKER}" >&2
    exit 1
fi

python3 - "$WORK_DIR/consumer.conf" "$BROKER" "$TOPIC" "$GROUP" \
    "$WORK_DIR/log" "$ASH_DATABASE_URL" "$METRICS_PORT" <<'PY'
import json
import sys

path, broker, topic, group, log_dir, database_url, metrics_port = sys.argv[1:]
config = {
    "kafka_brokers": [broker],
    "kafka_topic": topic,
    "kafka_group_id": group,
    "log_dir": log_dir,
    "database_enabled": True,
    "database_url": database_url,
    "batch_size": 1,
    "batch_timeout": 1.0,
    "max_dedup_cache": 10000,
    "retention_days": 90,
    "archive_days": 30,
    "archive_path": f"{log_dir}/archive",
    "alerting_enabled": False,
    "metrics_host": "127.0.0.1",
    "metrics_port": int(metrics_port),
    "log_max_bytes": 1048576,
    "log_backup_count": 2,
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(config, handle)
PY

echo "Starting consumer..."
# Application JSON logs go to stdout.  Keep stderr separate: third-party
# libraries (for example kafka-python's deserializer warning) write there,
# and merging the two would make the JSON-per-line assertion invalid.
python3 "$ROOT/src/consumer/ash-consumer.py" "$WORK_DIR/consumer.conf" \
    >"$WORK_DIR/consumer.log" 2>"$WORK_DIR/consumer.err" &
CONSUMER_PID=$!

wait_for_log() {
    local pattern="$1"
    local deadline=$((SECONDS + TIMEOUT))
    while ((SECONDS < deadline)); do
        if grep -Fq "$pattern" "$WORK_DIR/consumer.log" 2>/dev/null; then
            return 0
        fi
        if ! kill -0 "$CONSUMER_PID" 2>/dev/null; then
            echo "consumer exited before logging '${pattern}'" >&2
            return 1
        fi
        sleep 1
    done
    echo "timed out after ${TIMEOUT}s waiting for '${pattern}'" >&2
    return 1
}

wait_for_log "Kafka consumer initialized"

echo "Waiting for consumer readiness endpoint..."
python3 - "$METRICS_PORT" "$TIMEOUT" <<'PY'
import json
import sys
import time
import urllib.error
import urllib.request

port, timeout = int(sys.argv[1]), int(sys.argv[2])
url = f"http://127.0.0.1:{port}/health/ready"
deadline = time.monotonic() + timeout
last_error = None
while time.monotonic() < deadline:
    try:
        with urllib.request.urlopen(url, timeout=2) as response:
            payload = json.load(response)
        assert payload["status"] == "ready", payload
        assert payload["checks"]["database"] == "connected", payload
        assert payload["checks"]["flush"] == "ok", payload
        print(f"health: ready ({payload['checks']})")
        break
    except Exception as error:  # noqa: BLE001 - retry loop
        last_error = error
        time.sleep(1)
else:
    print(f"consumer did not become ready in {timeout}s: {last_error}", file=sys.stderr)
    sys.exit(1)
PY

# KafkaConsumer assigns partitions on its first poll. Producing before that
# can lose the message with auto_offset_reset=latest, so wait for the group's
# member assignment to include our topic.
echo "Waiting for consumer group assignment..."
assigned=0
for _ in $(seq 1 30); do
    # Match the assignment column ("topic(0)"), not the bare topic name.
    # The group is named "ash-e2e-group-<...>" and the topic "ash-e2e-<...>",
    # so a bare-topic grep matched the group name in the CLI header and
    # returned before the consumer had any partition. The event was then
    # produced before assignment, and auto_offset_reset=latest skipped it.
    if kafka-consumer-groups.sh \
        --bootstrap-server "$BROKER" \
        --describe --group "$GROUP" --members --verbose 2>/dev/null |
        grep -Fq "${TOPIC}("; then
        assigned=1
        break
    fi
    sleep 1
done
if [[ $assigned -ne 1 ]]; then
    echo "warning: could not confirm partition assignment; proceeding anyway" >&2
fi

RUN_TAG="$(date +%s)-$$"
COMMAND="kafka-e2e-command-${RUN_TAG}"
HOSTNAME_VALUE=$(hostname)

echo "Emitting event through the real agent producer..."
EVENT_ID=$(
    ASH_LOG_DIR="$WORK_DIR/log" \
        ASH_TEMP_DIR="$WORK_DIR/tmp" \
        ASH_SPOOL_DIR="$WORK_DIR/spool" \
        ASH_CONFIG_DIR="$WORK_DIR/conf" \
        ASH_HASH_FILE="$WORK_DIR/log/.hash_chain" \
        ASH_EVENTS_FILE="$WORK_DIR/log/events.jsonl" \
        ASH_AGENT_LOG="$WORK_DIR/log/agent.log" \
        ASH_SSH_CONNECTION="none" \
        KAFKA_ENABLED=true \
        KAFKA_BROKER="$BROKER" \
        KAFKA_TOPIC="$TOPIC" \
        KAFKA_SEND_TIMEOUT=15 \
        INOTIFY_ENABLED=false \
        bash -c '
            source "$1" --functions-only 2>/dev/null || true
            trap - DEBUG RETURN ERR EXIT 2>/dev/null || true
            set +e
            hash_chain_init
            load_redaction_rules
            spool_init
            emit_event "command_start" "{\"command\":\"$2\"}"
            emit_rc=$?
            if [[ $emit_rc -ne 0 ]]; then
                echo "emit_event failed with status ${emit_rc}" >&2
                exit 1
            fi
            spool_flush
            flush_rc=$?
            if [[ $flush_rc -ne 0 ]]; then
                echo "spool_flush failed with status ${flush_rc}" >&2
                exit 1
            fi
            jq -r ".event_id" "$ASH_EVENTS_FILE" | tail -1
        ' _ "$AGENT" "$COMMAND"
)

if [[ -z "$EVENT_ID" ]]; then
    echo "agent did not return an event_id" >&2
    exit 1
fi
echo "Event ${EVENT_ID} produced; waiting for PostgreSQL row..."

python3 - "$ASH_DATABASE_URL" "$EVENT_ID" "$COMMAND" "$HOSTNAME_VALUE" "$TIMEOUT" <<'PY'
import hashlib
import re
import sys
import time

import psycopg2

database_url, event_id, expected_command, expected_host, timeout = sys.argv[1:]
timeout = int(timeout)

conn = psycopg2.connect(database_url)
try:
    deadline = time.monotonic() + timeout
    row = None
    while time.monotonic() < deadline:
        with conn.cursor() as cursor:
            cursor.execute(
                """
                SELECT command, hostname, prev_hash, event_hash,
                       raw_event_text
                FROM command_logs
                WHERE event_id = %s
                """,
                (event_id,),
            )
            row = cursor.fetchone()
        if row:
            break
        conn.rollback()
        time.sleep(1)

    if row is None:
        print(f"event {event_id} was not written to PostgreSQL in {timeout}s", file=sys.stderr)
        sys.exit(1)

    command, hostname, prev_hash, event_hash, raw_event_text = row
    assert command == expected_command, (command, expected_command)
    assert hostname == expected_host, (hostname, expected_host)
    assert prev_hash and len(prev_hash) == 64, prev_hash
    assert event_hash and len(event_hash) == 64, event_hash
    assert raw_event_text, "raw_event_text was not stored"

    # The agent signs sha256(prev_hash || unsigned_event_json) and then
    # appends ,"prev_hash":...,"event_hash":... before producing the line.
    # Recover those exact bytes from the stored raw text (JSONB cannot
    # reproduce them) and recompute the hash. This proves the value that
    # crossed Kafka is verifiable, not merely that some JSONB exists.
    match = re.match(
        r'^(.*),"prev_hash":"([0-9a-f]{64})","event_hash":"([0-9a-f]{64})"}$',
        raw_event_text,
        re.DOTALL,
    )
    assert match, (
        "raw_event_text does not end with the agent's signed fields: "
        f"{raw_event_text[:200]!r}"
    )
    unsigned, signed_prev, signed_hash = match.groups()
    # The regex consumed the closing brace that the agent replaced with the
    # two hash fields; put it back to recover the exact hashed JSON.
    unsigned += "}"
    assert signed_prev == prev_hash, (signed_prev, prev_hash)
    assert signed_hash == event_hash, (signed_hash, event_hash)
    recomputed = hashlib.sha256(
        (prev_hash + unsigned).encode("utf-8")
    ).hexdigest()
    assert recomputed == event_hash, (recomputed, event_hash)
    assert f'"event_id":"{event_id}"' in unsigned, unsigned[:200]

    print(
        f"Kafka E2E passed: {event_id} -> {hostname} -> "
        f"{command!r} (raw text hash verified)"
    )
finally:
    conn.close()
PY

echo "Checking consumer metrics and structured logs..."
python3 - "$METRICS_PORT" "$WORK_DIR/consumer.log" <<'PY'
import json
import re
import sys
import urllib.request

port, log_path = int(sys.argv[1]), sys.argv[2]

with urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics", timeout=5) as response:
    metrics = response.read().decode("utf-8")

def value(name):
    match = re.search(rf"^{re.escape(name)} ([0-9.eE+-]+)$", metrics, re.MULTILINE)
    assert match, f"metric {name} missing"
    return float(match.group(1))

assert value("ash_consumer_events_processed_total") >= 1
assert value("ash_consumer_database_available") == 1
assert value("ash_consumer_ready") == 1
assert value("ash_consumer_last_flush_success_timestamp_seconds") > 0

required = {"timestamp", "severity", "component", "logger", "message", "pid"}
records = []
with open(log_path, encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        record = json.loads(line)
        assert required <= set(record), record
        assert record["component"] == "ash-consumer", record
        records.append(record)
assert any("Kafka consumer initialized" in record["message"] for record in records)
print(f"observability: metrics present; {len(records)} JSON log records validated")
PY
