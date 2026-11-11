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
    local url="$1" expected="$2" deadline="${3:-60}" start="$SECONDS" status
    while ((SECONDS - start < deadline)); do
        status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$url" || true)
        if [[ "$status" == "$expected" ]]; then
            return 0
        fi
        sleep 1
    done
    fail "timed out waiting for $url to return $expected within ${deadline}s (last: ${status:-none})"
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

measure_events_avg() {
    local token="$1" total=0 i result code elapsed
    for i in 1 2 3 4 5; do
        result=$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' --max-time 15 \
            -H "Authorization: Bearer ${token}" \
            "${BASE_URL}/api/v1/events?limit=5")
        code="${result%% *}"
        elapsed="${result##* }"
        [[ "$code" == "200" ]] ||
            fail "events request returned HTTP $code, expected 200"
        total=$(awk -v a="$total" -v b="$elapsed" 'BEGIN { printf "%.6f", a + b }')
    done
    awk -v total="$total" 'BEGIN { printf "%.6f", total / 5 }'
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

# /health/ready only proves DB connectivity; the consumer owns schema
# creation and may still be creating tables when the API is already ready.
# Wait for the authenticated data path before measuring a baseline.
echo "Waiting for the authenticated data path (schema creation)..."
schema_start="$SECONDS"
schema_status=""
while ((SECONDS - schema_start < 60)); do
    schema_status=$(api_status "$token" "/api/v1/events?limit=1")
    [[ "$schema_status" == "200" ]] && break
    sleep 1
done
[[ "$schema_status" == "200" ]] ||
    fail "authenticated /api/v1/events did not become ready (last: ${schema_status:-none})"

baseline_status=$(api_status "$token" "/api/v1/events?limit=5")
[[ "$baseline_status" == "200" ]] ||
    fail "baseline /api/v1/events returned $baseline_status, expected 200"
baseline_avg=$(measure_events_avg "$token")
echo "baseline: API and database are healthy (average ${baseline_avg}s across 5 requests)"

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

# Prove the toxic exists; a missing proxy/toxic would otherwise make the
# timing assertion pass or fail for the wrong reason.
curl -fsS --max-time 10 "${TOXIPROXY_URL}/proxies/postgres/toxics" |
    python3 -c '
import json
import sys
toxics = json.load(sys.stdin)
if not any(t.get("name") == "latency" for t in toxics):
    raise SystemExit("latency toxic is not present")
'

injected_avg=$(measure_events_avg "$token")
echo "latency run: average ${injected_avg}s across 5 requests (baseline ${baseline_avg}s)"
awk -v injected="$injected_avg" -v baseline="$baseline_avg" \
    'BEGIN { exit !(injected >= baseline + 0.10) }' ||
    fail "injected latency did not increase response time (baseline ${baseline_avg}s, injected ${injected_avg}s)"
# The API opens a new PostgreSQL connection per request and runs two
# queries; one 200 ms +/- 50 ms toxic on that path measures ~1.4 s in
# practice. A 1 s ceiling is not reachable for this endpoint; 3 s bounds a
# hang without pretending the injected latency is a single round trip.
awk -v injected="$injected_avg" 'BEGIN { exit !(injected < 3.00) }' ||
    fail "latency run hung (average ${injected_avg}s, expected < 3.00s)"

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
