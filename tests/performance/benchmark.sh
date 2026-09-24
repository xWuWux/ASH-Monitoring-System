#!/usr/bin/env bash
# Measures the throughput/latency metrics docs/REMAINING_GAPS.md lists as
# "Not measured": event latency and events/sec for the hash-chain + redaction
# pipeline that every emitted event goes through.
#
# Deliberately narrow scope: this measures the self-contained bash pipeline
# (hash_chain_append + redact_sensitive_data) via --functions-only, not a live
# agent session. Agent CPU/memory overhead under a real interactive shell is
# a separate, longer-running measurement this script does not attempt --
# report-only, no pass/fail gate, since docs/REMAINING_GAPS.md's targets have
# never been measured against and a threshold picked now would be a guess.
set -euo pipefail

EVENT_COUNT="${1:-1000}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_SCRIPT="${SCRIPT_DIR}/../../src/agent/ash-agent.sh"

export ASH_LOG_DIR
ASH_LOG_DIR="$(mktemp -d)"
export ASH_TEMP_DIR="${ASH_LOG_DIR}/tmp"
export ASH_SPOOL_DIR="${ASH_LOG_DIR}/spool"
export ASH_CONFIG_DIR="${ASH_LOG_DIR}/conf"
mkdir -p "$ASH_TEMP_DIR" "$ASH_SPOOL_DIR" "$ASH_CONFIG_DIR" "$ASH_SPOOL_DIR/pending" "$ASH_SPOOL_DIR/sent"
trap 'rm -rf "$ASH_LOG_DIR"' EXIT

# shellcheck source=../../src/agent/ash-agent.sh
source "$AGENT_SCRIPT" --functions-only
trap - DEBUG RETURN ERR EXIT 2>/dev/null || true
trap 'rm -rf "$ASH_LOG_DIR"' EXIT

hash_chain_init
load_redaction_rules

SAMPLE_COMMAND='mysql --password=secret123 -u root -h prod-db-1.internal'

start_ns=$(date +%s%N)
for ((i = 0; i < EVENT_COUNT; i++)); do
    redacted=$(redact_sensitive_data "$SAMPLE_COMMAND")
    event="{\"event_id\":\"bench-${i}\",\"event_type\":\"command_start\",\"command\":\"${redacted}\"}"
    hash_chain_append "$event" >/dev/null
done
end_ns=$(date +%s%N)

elapsed_ns=$((end_ns - start_ns))
elapsed_ms=$((elapsed_ns / 1000000))
avg_latency_us=$((elapsed_ns / EVENT_COUNT / 1000))
if [[ "$elapsed_ms" -gt 0 ]]; then
    events_per_sec=$((EVENT_COUNT * 1000 / elapsed_ms))
else
    events_per_sec="N/A (elapsed time too short to measure)"
fi

echo "=== ASH hash-chain + redaction pipeline benchmark ==="
echo "Events processed:     ${EVENT_COUNT}"
echo "Total wall time:      ${elapsed_ms} ms"
echo "Average latency:      ${avg_latency_us} us/event"
echo "Throughput:           ${events_per_sec} events/sec"
echo
echo "docs/REMAINING_GAPS.md targets (NFR-02) for comparison, not enforced here:"
echo "  Event latency (local): <100ms   -- this measures the redact+hash-chain"
echo "                                     slice of that path only, not the"
echo "                                     full DEBUG-trap-to-disk latency"
echo "  Throughput: >1000 events/s"
echo
echo "NOT measured by this script (needs a live agent session, not just this"
echo "pipeline in isolation): agent CPU overhead, agent memory usage, Kafka"
echo "event latency."
