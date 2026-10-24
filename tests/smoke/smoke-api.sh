#!/usr/bin/env bash
# Smoke test the REST API against a real PostgreSQL instance.
#
# Required environment:
#   ASH_DATABASE_URL  postgresql://...
#   ASH_JWT_SECRET
#   ASH_ADMIN_USER
#   ASH_ADMIN_PASS
#
# Optional: ASH_API_PORT (default 8080)
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PORT="${ASH_API_PORT:-8080}"
export ASH_API_PORT="$PORT"
export ASH_API_HOST="${ASH_API_HOST:-127.0.0.1}"

: "${ASH_DATABASE_URL:?ASH_DATABASE_URL is required}"
: "${ASH_JWT_SECRET:?ASH_JWT_SECRET is required}"
: "${ASH_ADMIN_USER:?ASH_ADMIN_USER is required}"
: "${ASH_ADMIN_PASS:?ASH_ADMIN_PASS is required}"

API_LOG=$(mktemp)
API_PID=""

cleanup() {
    local exit_status=$?
    if [[ -n "$API_PID" ]]; then
        kill "$API_PID" 2>/dev/null || true
        wait "$API_PID" 2>/dev/null || true
    fi
    if [[ $exit_status -ne 0 && -s "$API_LOG" ]]; then
        echo "--- API server log ---" >&2
        cat "$API_LOG" >&2
    fi
    rm -f "$API_LOG"
}
trap cleanup EXIT

echo "Creating schema..."
python3 "$ROOT/tests/smoke/init_schema.py"

echo "Inserting a smoke event..."
python3 - "$ASH_DATABASE_URL" <<'PY'
import sys
import uuid

import psycopg2

conn = psycopg2.connect(sys.argv[1])
try:
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO command_logs
                (event_id, hostname, source, event_type, username, command,
                 log_timestamp)
            VALUES (%s, %s, %s, %s, %s, %s, now())
            ON CONFLICT (event_id) DO NOTHING
            """,
            (
                str(uuid.uuid4()),
                "smoke-host",
                "bash-debug",
                "command_start",
                "smoke-user",
                "ash-smoke-command",
            ),
        )
    conn.commit()
finally:
    conn.close()
PY

echo "Starting API on ${ASH_API_HOST}:${PORT}..."
python3 "$ROOT/src/consumer/api_server.py" >"$API_LOG" 2>&1 &
API_PID=$!

BASE_URL="http://${ASH_API_HOST}:${PORT}"
health=""
for attempt in $(seq 1 30); do
    if health=$(curl -fsS "${BASE_URL}/health" 2>/dev/null); then
        break
    fi
    if ! kill -0 "$API_PID" 2>/dev/null; then
        echo "API process exited before becoming healthy" >&2
        exit 1
    fi
    if [[ $attempt -eq 30 ]]; then
        echo "API did not become healthy in time" >&2
        exit 1
    fi
    sleep 1
done

python3 - "$health" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert data["status"] == "healthy", data
assert data["database"] == "connected", data
print("health: healthy / database connected")
PY

echo "Requesting an admin token..."
token_response=$(
    curl -fsS -X POST "${BASE_URL}/api/v1/auth/token" \
        -H "Content-Type: application/json" \
        --data "$(
            python3 -c '
import json
import os

print(json.dumps({
    "username": os.environ["ASH_ADMIN_USER"],
    "password": os.environ["ASH_ADMIN_PASS"],
}))
'
        )"
)
token=$(
    python3 -c '
import json
import sys

print(json.load(sys.stdin)["token"])
' <<<"$token_response"
)
[[ -n "$token" ]]
echo "auth: admin token issued"

echo "Searching events..."
events_response=$(
    curl -fsS -H "Authorization: Bearer ${token}" \
        "${BASE_URL}/api/v1/events?command=ash-smoke-command&limit=1"
)
python3 - "$events_response" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
assert isinstance(data["events"], list), data
assert isinstance(data["total"], int), data
assert data["total"] >= 1, data
assert data["events"][0]["command"] == "ash-smoke-command", data
assert data["events"][0]["hostname"] == "smoke-host", data
print(f"events: query ok ({data['total']} matching)")
PY

echo "Checking unauthenticated access is rejected..."
status=$(
    curl -sS -o /dev/null -w '%{http_code}' \
        "${BASE_URL}/api/v1/events?limit=1"
)
if [[ "$status" != "401" ]]; then
    echo "expected 401 without a token, got ${status}" >&2
    exit 1
fi
echo "auth: unauthenticated request rejected"

echo "API smoke test passed"
