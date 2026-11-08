#!/usr/bin/env bash
# Nightly resilience test: PostgreSQL outage/recovery and API->PostgreSQL
# latency injection through Toxiproxy.
#
# This uses the disposable Docker Compose stack and the resilience override
# (deployments/docker/docker-compose.resilience.yml). It is not a production
# failover test: Compose has one PostgreSQL and no replica. It verifies that
# the API returns 503 while the database is unreachable, recovers without a
# process restart, and does not hang when DB latency is injected.
#
# Required environment:
#   ASH_DB_PASSWORD, ASH_JWT_SECRET, ASH_ADMIN_USER, ASH_ADMIN_PASS
# Optional:
#   ASH_API_BASE_URL (default http://127.0.0.1:8080)
#   TOXIPROXY_URL    (default http://127.0.0.1:8474)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

BASE_URL="${ASH_API_BASE_URL:-http://127.0.0.1:8080}"
TOXIPROXY_URL="${TOXIPROXY_URL:-http://127.0.0.1:8474}"
COMPOSE=(docker compose
    -f deployments/docker/docker-compose.yml
    -f deployments/docker/docker-compose.resilience.yml)

: "${ASH_DB_PASSWORD:?ASH_DB_PASSWORD must be set}"
: "${ASH_ADMIN_USER:?ASH_ADMIN_USER must be set}"
: "${ASH_ADMIN_PASS:?ASH_ADMIN_PASS must be set}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

wait_for_http() {
    local url="$1" expected="$2" timeout="${3:-60}" i status
    for ((i = 0; i < timeout; i++)); do
        status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$url" || true)
        if [[ "$status" == "$expected" ]]; then
            return 0
        fi
        sleep 1
    done
    fail "timed out waiting for $url to return $expected (last: ${status:-none})"
}

auth_token() {
    local payload
    # Build the JSON with Python instead of string interpolation: a password
    # containing a quote or backslash would otherwise produce invalid JSON.
    payload=$(python3 -c '
import json
import os
print(json.dumps({
    "username": os.environ["ASH_ADMIN_USER"],
    "password": os.environ["ASH_ADMIN_PASS"],
}))
')
    curl -fsS --max-time 10 \
        -X POST "${BASE_URL}/api/v1/auth/token" \
        -H 'Content-Type: application/json' \
        -d "$payload" |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])'
}

api_status() {
    local token="$1" path="$2"
    curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
        -H "Authorization: Bearer ${token}" \
        "${BASE_URL}${path}" || true
}

cleanup() {
    curl -fsS -X DELETE "${TOXIPROXY_URL}/proxies/postgres/toxics/latency" \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== ASH resilience: PostgreSQL outage + Toxiproxy latency ==="

echo "Waiting for the API and Toxiproxy..."
wait_for_http "${BASE_URL}/health/ready" 200 90
wait_for_http "${TOXIPROXY_URL}/version" 200 60

token=$(auth_token)
[[ -n "$token" ]] || fail "auth token is empty"

baseline_status=$(api_status "$token" "/api/v1/events?limit=5")
[[ "$baseline_status" == "200" ]] ||
    fail "baseline /api/v1/events returned $baseline_status, expected 200"
echo "baseline: API and database are healthy"

# ─── Latency injection ───────────────────────────────────────────────────────
echo "Injecting 200 ms ± 50 ms latency on API -> PostgreSQL..."
curl -fsS --max-time 10 -X DELETE \
    "${TOXIPROXY_URL}/proxies/postgres/toxics/latency" \
    >/dev/null 2>&1 || true
curl -fsS --max-time 10 \
    -X POST "${TOXIPROXY_URL}/proxies/postgres/toxics" \
    -H 'Content-Type: application/json' \
    -d '{"name":"latency","type":"latency","attributes":{"latency":200,"jitter":50}}' \
    >/dev/null

total=0
for _ in 1 2 3 4 5; do
    result=$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' --max-time 15 \
        -H "Authorization: Bearer ${token}" \
        "${BASE_URL}/api/v1/events?limit=5")
    code="${result%% *}"
    elapsed="${result##* }"
    [[ "$code" == "200" ]] ||
        fail "latency run returned HTTP $code, expected 200"
    total=$(awk -v a="$total" -v b="$elapsed" 'BEGIN { printf "%.6f", a + b }')
done
average=$(awk -v total="$total" 'BEGIN { printf "%.6f", total / 5 }')
echo "latency run: average ${average}s across 5 requests"
awk -v average="$average" 'BEGIN { exit !(average > 0.10) }' ||
    fail "injected latency did not increase response time (average ${average}s)"
awk -v average="$average" 'BEGIN { exit !(average < 1.00) }' ||
    fail "latency run hung (average ${average}s, expected < 1.00s)"

cleanup
wait_for_http "${BASE_URL}/health/ready" 200 60
echo "latency toxic removed; API recovered"

# ─── PostgreSQL outage ───────────────────────────────────────────────────────
echo "Stopping PostgreSQL..."
"${COMPOSE[@]}" stop postgres >/dev/null

wait_for_http "${BASE_URL}/health/ready" 503 60
outage_status=$(api_status "$token" "/api/v1/events?limit=5")
[[ "$outage_status" == "503" ]] ||
    fail "/api/v1/events returned $outage_status during outage, expected 503"
echo "outage: readiness and data endpoint return 503"

echo "Starting PostgreSQL..."
"${COMPOSE[@]}" start postgres >/dev/null
wait_for_http "${BASE_URL}/health/ready" 200 90

recovery_status=$(api_status "$token" "/api/v1/events?limit=5")
[[ "$recovery_status" == "200" ]] ||
    fail "/api/v1/events returned $recovery_status after recovery, expected 200"
echo "recovery: API returned 200 without a restart"

echo "PASS: PostgreSQL outage/recovery and latency injection behaved correctly"
