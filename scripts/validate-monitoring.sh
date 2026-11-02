#!/usr/bin/env bash
# Static and schema validation for the optional ASH monitoring stack.
#
# This script never starts the stack and never prints secret values. It uses
# the same pinned images as deployments/docker/docker-compose.yml, so a
# successful run means the committed configs parse under the exact versions
# the stack runs. Docker is required (the tool binaries live in the images);
# no local promtool/amtool/loki/tempo installation is assumed.
#
# Usage:
#   scripts/validate-monitoring.sh [--compose-only] [--skip-pull]
#
#   --compose-only  Validate Compose wiring, JSON, scripts, and init behavior
#                   only; skip the containerized schema checks.
#   --skip-pull     Assume the pinned images are already present.
#
# Environment:
#   DOCKER                      Docker CLI (default: docker)
#   ASH_PROMETHEUS_IMAGE        Override the pinned image (validation only)
#   ASH_ALERTMANAGER_IMAGE      Override the pinned image (validation only)
#   ASH_LOKI_IMAGE              Override the pinned image (validation only)
#   ASH_TEMPO_IMAGE             Override the pinned image (validation only)
#   ASH_OTEL_IMAGE              Override the pinned image (validation only)
#
# Compose interpolation needs the same required variables as the stack. For
# static validation, placeholders are used when a value is unset; they are
# never connected to anything and the rendered Compose file is written to a
# 0600 temporary file that is deleted on exit.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly MONITORING_DIR="${REPO_ROOT}/deployments/monitoring"
readonly COMPOSE_FILE="${REPO_ROOT}/deployments/docker/docker-compose.yml"
readonly DOCKER="${DOCKER:-docker}"

readonly PROMETHEUS_IMAGE="${ASH_PROMETHEUS_IMAGE:-prom/prometheus:v2.55.1}"
readonly ALERTMANAGER_IMAGE="${ASH_ALERTMANAGER_IMAGE:-prom/alertmanager:v0.27.0}"
readonly LOKI_IMAGE="${ASH_LOKI_IMAGE:-grafana/loki:3.2.1}"
readonly TEMPO_IMAGE="${ASH_TEMPO_IMAGE:-grafana/tempo:2.6.1}"
readonly OTEL_IMAGE="${ASH_OTEL_IMAGE:-otel/opentelemetry-collector-contrib:0.115.1}"

COMPOSE_ONLY=false
SKIP_PULL=false
TMP_DIR=""

info() { printf '[validate-monitoring] %s\n' "$*"; }
fail() {
    printf '[validate-monitoring] ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
Usage: validate-monitoring.sh [--compose-only] [--skip-pull]

Validates the optional monitoring stack without starting it:
  * required files and shell/JSON syntax
  * docker compose --profile monitoring config (loopback ports, profiles,
    pinned images, read-only secret mounts)
  * Prometheus config and alert-rule unit tests (promtool)
  * Alertmanager rendered config (amtool check-config)
  * Loki, Tempo, and OpenTelemetry Collector config schemas
  * Grafana provisioning and dashboard datasource references
  * monitoring-init.sh fail-closed behavior

Options:
  --compose-only  Skip the containerized schema checks.
  --skip-pull     Do not pull the pinned images first.
  -h, --help      Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --compose-only) COMPOSE_ONLY=true ;;
        --skip-pull) SKIP_PULL=true ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) fail "unknown argument: $1" ;;
    esac
    shift
done

require_file() {
    [[ -f "$1" ]] || fail "required file missing: $1"
}

require_executable() {
    [[ -x "$1" ]] || fail "required executable missing: $1"
}

run_tool() {
    local description="$1"
    shift
    info "$description"
    if ! "$@"; then
        fail "$description failed"
    fi
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ash-monitoring-validate.XXXXXX")"
chmod 0700 "$TMP_DIR"

info "checking required files"
for file in \
    "${COMPOSE_FILE}" \
    "${MONITORING_DIR}/otel-collector/config.yml" \
    "${MONITORING_DIR}/tempo/tempo.yml" \
    "${MONITORING_DIR}/loki/loki.yml" \
    "${MONITORING_DIR}/prometheus/prometheus.yml" \
    "${MONITORING_DIR}/prometheus/rules.yml" \
    "${MONITORING_DIR}/prometheus/rules_test.yml" \
    "${MONITORING_DIR}/alertmanager/alertmanager.yml.tmpl" \
    "${MONITORING_DIR}/grafana/provisioning/datasources/datasources.yml" \
    "${MONITORING_DIR}/grafana/provisioning/dashboards/dashboards.yml" \
    "${MONITORING_DIR}/grafana/provisioning/dashboards/ash-overview.json" \
    "${MONITORING_DIR}/grafana/provisioning/dashboards/ash-traces-logs.json" \
    "${REPO_ROOT}/scripts/monitoring-init.sh"; do
    require_file "$file"
done
require_executable "${REPO_ROOT}/scripts/monitoring-init.sh"
require_executable "${REPO_ROOT}/scripts/validate-monitoring.sh"

info "checking shell syntax"
bash -n "${REPO_ROOT}/scripts/monitoring-init.sh"
bash -n "${REPO_ROOT}/scripts/validate-monitoring.sh"

info "checking dashboard JSON and datasource references"
python3 - "$MONITORING_DIR" <<'PY'
import json
import pathlib
import sys

monitoring = pathlib.Path(sys.argv[1])
known = {"prometheus", "loki", "tempo", "-- Grafana --"}
dashboards = sorted((monitoring / "grafana/provisioning/dashboards").glob("*.json"))
if not dashboards:
    raise SystemExit("no Grafana dashboards found")

uids = set()
for path in dashboards:
    try:
        dashboard = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise SystemExit(f"{path}: invalid JSON: {exc}") from exc

    uid = dashboard.get("uid")
    title = dashboard.get("title")
    panels = dashboard.get("panels")
    if not isinstance(uid, str) or not uid:
        raise SystemExit(f"{path}: missing non-empty uid")
    if uid in uids:
        raise SystemExit(f"{path}: duplicate uid {uid!r}")
    uids.add(uid)
    if not isinstance(title, str) or not title:
        raise SystemExit(f"{path}: missing non-empty title")
    if not isinstance(panels, list) or not panels:
        raise SystemExit(f"{path}: no panels")

    stack = list(panels)
    while stack:
        panel = stack.pop()
        if not isinstance(panel, dict):
            raise SystemExit(f"{path}: panel is not an object")
        stack.extend(panel.get("panels", []))
        targets = panel.get("targets", [])
        if not isinstance(targets, list):
            raise SystemExit(f"{path}: targets is not a list")
        for target in targets:
            data = target.get("datasource")
            if data:
                target_uid = data.get("uid") if isinstance(data, dict) else data
                if target_uid not in known:
                    raise SystemExit(
                        f"{path}: target references unknown datasource uid {target_uid!r}"
                    )
        data = panel.get("datasource")
        if data:
            panel_uid = data.get("uid") if isinstance(data, dict) else data
            if panel_uid not in known:
                raise SystemExit(
                    f"{path}: panel references unknown datasource uid {panel_uid!r}"
                )

expected = {"ash-overview", "ash-traces-logs"}
if not expected.issubset(uids):
    raise SystemExit(f"missing dashboards: {sorted(expected - uids)}")

provisioning = (monitoring / "grafana/provisioning/datasources/datasources.yml").read_text()
for uid in ("prometheus", "loki", "tempo"):
    if f"uid: {uid}" not in provisioning:
        raise SystemExit(f"datasource {uid} not provisioned")
print(f"validated {len(dashboards)} dashboards and 3 datasource UIDs")
PY

info "checking monitoring-init.sh fail-closed behavior"
run_init_expect_failure() {
    local description="$1"
    shift
    if "$@" >"$TMP_DIR/init.out" 2>"$TMP_DIR/init.err"; then
        fail "monitoring-init.sh unexpectedly succeeded: $description"
    fi
    if [[ ! -s "$TMP_DIR/init.err" ]]; then
        fail "monitoring-init.sh did not explain the failure: $description"
    fi
    info "  rejected: $description"
}

run_init_expect_failure "missing webhook" \
    env -u ASH_ALERTMANAGER_WEBHOOK_URL \
    ASH_METRICS_ENABLED=true ASH_METRICS_TOKEN=abcdef0123456789 \
    bash "${REPO_ROOT}/scripts/monitoring-init.sh" \
    --runtime-dir "$TMP_DIR/should-not-exist-runtime" \
    --data-dir "$TMP_DIR/should-not-exist-data"

run_init_expect_failure "disabled API metrics" \
    ASH_METRICS_ENABLED=false ASH_METRICS_TOKEN=abcdef0123456789 \
    ASH_ALERTMANAGER_WEBHOOK_URL=https://example.invalid/ash \
    bash "${REPO_ROOT}/scripts/monitoring-init.sh" \
    --runtime-dir "$TMP_DIR/should-not-exist-runtime" \
    --data-dir "$TMP_DIR/should-not-exist-data"

run_init_expect_failure "short metrics token" \
    ASH_METRICS_ENABLED=true ASH_METRICS_TOKEN=short \
    ASH_ALERTMANAGER_WEBHOOK_URL=https://example.invalid/ash \
    bash "${REPO_ROOT}/scripts/monitoring-init.sh" \
    --runtime-dir "$TMP_DIR/should-not-exist-runtime" \
    --data-dir "$TMP_DIR/should-not-exist-data"

run_init_expect_failure "webhook with userinfo" \
    ASH_METRICS_ENABLED=true ASH_METRICS_TOKEN=abcdef0123456789 \
    ASH_ALERTMANAGER_WEBHOOK_URL=https://user:pass@example.invalid/ash \
    bash "${REPO_ROOT}/scripts/monitoring-init.sh" \
    --runtime-dir "$TMP_DIR/should-not-exist-runtime" \
    --data-dir "$TMP_DIR/should-not-exist-data"

if [[ -e "$TMP_DIR/should-not-exist-runtime" || -e "$TMP_DIR/should-not-exist-data" ]]; then
    fail "monitoring-init.sh created directories for a rejected configuration"
fi
info "  no runtime directories created for rejected configurations"

info "checking monitoring-init.sh does not source the env file"
cat >"$TMP_DIR/malicious.env" <<'EOF'
ASH_METRICS_ENABLED=true
ASH_METRICS_TOKEN=abcdef0123456789
ASH_ALERTMANAGER_WEBHOOK_URL=$(touch /tmp/ash-monitoring-init-sourced)
EOF
rm -f /tmp/ash-monitoring-init-sourced
run_init_expect_failure "command substitution in env file" \
    bash "${REPO_ROOT}/scripts/monitoring-init.sh" \
    --env-file "$TMP_DIR/malicious.env" \
    --runtime-dir "$TMP_DIR/should-not-exist-runtime" \
    --data-dir "$TMP_DIR/should-not-exist-data"
if [[ -e /tmp/ash-monitoring-init-sourced ]]; then
    fail "the env file was sourced instead of parsed"
fi
info "  env file parsed as data"

info "checking monitoring-init.sh environment precedence"
cat >"$TMP_DIR/precedence.env" <<'EOF'
ASH_METRICS_ENABLED=true
ASH_METRICS_TOKEN=abcdef0123456789
ASH_ALERTMANAGER_WEBHOOK_URL=https://example.invalid/from-file
EOF
run_init_expect_failure "exported value wins over env file" \
    env ASH_ALERTMANAGER_WEBHOOK_URL=ftp://invalid \
    bash "${REPO_ROOT}/scripts/monitoring-init.sh" \
    --env-file "$TMP_DIR/precedence.env" \
    --runtime-dir "$TMP_DIR/should-not-exist-runtime" \
    --data-dir "$TMP_DIR/should-not-exist-data"
info "  exported value takes precedence"

if [[ $EUID -eq 0 ]]; then
    info "checking monitoring-init.sh full render (root)"
    local_state="$TMP_DIR/state"
    ASH_METRICS_ENABLED=true ASH_METRICS_TOKEN=abcdef0123456789abcdef \
        ASH_ALERTMANAGER_WEBHOOK_URL=https://example.invalid/ash \
        ASH_GRAFANA_ADMIN_PASSWORD=test-password-1234 \
        bash "${REPO_ROOT}/scripts/monitoring-init.sh" \
        --runtime-dir "$local_state/runtime" \
        --data-dir "$local_state/data" >"$TMP_DIR/render.out"
    for file in alertmanager.yml api_metrics_token grafana_admin_password; do
        mode="$(stat -c '%a' "$local_state/runtime/$file")"
        [[ "$mode" == "600" ]] || fail "runtime file $file has mode $mode, expected 600"
    done
    [[ "$(stat -c '%a' "$local_state/runtime")" == "711" ]] ||
        fail "runtime directory is not 0711"
    for dir in prometheus alertmanager grafana loki tempo; do
        [[ -d "$local_state/data/$dir" ]] || fail "missing state directory $dir"
        [[ "$(stat -c '%a' "$local_state/data/$dir")" == "750" ]] ||
            fail "state directory $dir is not 0750"
    done
    info "  rendered files are 0600 and state directories are 0750"
else
    info "skipping full render check (not root)"
fi

info "checking docker compose wiring"
if ! command -v "$DOCKER" >/dev/null 2>&1; then
    fail "docker is required (set DOCKER=/path/to/docker)"
fi

# Static validation only: placeholders satisfy ${VAR:?} guards and are never
# connected to a service. Do not print the rendered Compose file.
export ASH_DB_PASSWORD="${ASH_DB_PASSWORD:-validation-placeholder}"
export ASH_JWT_SECRET="${ASH_JWT_SECRET:-validation-placeholder}"
export ASH_ADMIN_USER="${ASH_ADMIN_USER:-validation-placeholder}"
export ASH_ADMIN_PASS="${ASH_ADMIN_PASS:-validation-placeholder}"

if ! (cd "$(dirname "$COMPOSE_FILE")" && "$DOCKER" compose -f "$COMPOSE_FILE" --profile monitoring config --format json) >"$TMP_DIR/compose.json"; then
    fail "docker compose config failed"
fi
chmod 0600 "$TMP_DIR/compose.json"

python3 - "$TMP_DIR/compose.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)

services = config.get("services", {})
expected = {
    "otel-collector": {"4317", "4318"},
    "tempo": {"3200"},
    "loki": set(),
    "prometheus": {"9091"},
    "alertmanager": {"9093"},
    "grafana": {"3000"},
}
for name, published in expected.items():
    service = services.get(name)
    if not service:
        raise SystemExit(f"service {name} missing")
    if service.get("profiles") != ["monitoring"]:
        raise SystemExit(f"service {name} is not in the monitoring profile")
    if service.get("restart") not in ("unless-stopped", "always"):
        raise SystemExit(f"service {name} has no restart policy")
    logging = service.get("logging", {})
    if logging.get("driver") != "json-file":
        raise SystemExit(f"service {name} does not cap its Docker log")
    if service.get("network_mode"):
        raise SystemExit(f"service {name} uses network_mode; bind loopback ports instead")

    ports = service.get("ports", [])
    actual = set()
    for port in ports:
        if port.get("host_ip") != "127.0.0.1":
            raise SystemExit(
                f"service {name} publishes {port.get('published')} without 127.0.0.1"
            )
        actual.add(str(port.get("published")))
    if actual != published:
        raise SystemExit(f"service {name} publishes {sorted(actual)}, expected {sorted(published)}")

images = {name: service.get("image", "") for name, service in services.items()}
for name in expected:
    image = images[name]
    if not image or image.endswith(":latest") or "@sha256:" not in image and ":" not in image.rsplit("/", 1)[-1]:
        raise SystemExit(f"service {name} does not use a pinned image: {image!r}")

prometheus_volumes = services["prometheus"].get("volumes", [])
token_mounts = [
    volume
    for volume in prometheus_volumes
    if volume.get("target") == "/etc/prometheus/ash-api-token"
]
if len(token_mounts) != 1:
    raise SystemExit("Prometheus does not mount the API metrics token")
token = token_mounts[0]
if not token.get("read_only"):
    raise SystemExit("the API metrics token mount is writable")
if not str(token.get("source", "")).endswith("/api_metrics_token"):
    raise SystemExit("the API metrics token mount does not use the rendered token file")

alertmanager_mounts = {
    volume.get("target"): volume
    for volume in services["alertmanager"].get("volumes", [])
}
am_config = alertmanager_mounts.get("/etc/alertmanager/alertmanager.yml")
if not am_config or not am_config.get("read_only"):
    raise SystemExit("Alertmanager config is not mounted read-only")

grafana_mounts = {
    volume.get("target"): volume
    for volume in services["grafana"].get("volumes", [])
}
pw = grafana_mounts.get("/run/ash-monitoring/grafana_admin_password")
if not pw or not pw.get("read_only"):
    raise SystemExit("Grafana admin password is not mounted read-only")

command = services["prometheus"].get("command", [])
if "--web.enable-remote-write-receiver" not in command:
    raise SystemExit("Prometheus remote-write receiver is not enabled")
if not any(str(part).endswith(":9091") for part in command if "listen-address" in str(part)):
    raise SystemExit("Prometheus does not listen on the documented internal port 9091")

for name in ("loki", "tempo", "otel-collector", "prometheus", "alertmanager", "grafana"):
    if not services[name].get("image"):
        raise SystemExit(f"service {name} has no image")
print("compose wiring, profiles, loopback ports, and secret mounts are valid")
PY

# The committed Prometheus config must never contain the bearer token itself.
if grep -Eiq '(^|[^a-z_])(password|token|secret)[[:space:]]*:|Bearer [A-Za-z0-9._~+/=-]{16,}' \
    "${MONITORING_DIR}/prometheus/prometheus.yml" "${MONITORING_DIR}/prometheus/rules.yml"; then
    fail "a secret-like value appears in the committed Prometheus config"
fi
if grep -q 'credentials_file: /etc/prometheus/ash-api-token' "${MONITORING_DIR}/prometheus/prometheus.yml"; then
    info "API metrics token is read from the rendered file, not the config"
else
    fail "Prometheus does not use credentials_file for the API metrics token"
fi

if [[ "$COMPOSE_ONLY" == "true" ]]; then
    info "compose-only validation passed"
    exit 0
fi

for image in "$PROMETHEUS_IMAGE" "$ALERTMANAGER_IMAGE" "$LOKI_IMAGE" "$TEMPO_IMAGE" "$OTEL_IMAGE"; do
    if [[ "$SKIP_PULL" == "false" ]]; then
        info "pulling $image"
        "$DOCKER" pull -q "$image" >/dev/null || fail "could not pull $image"
    fi
done

info "validating Prometheus config and alert rules"
# promtool resolves the credentials_file and rule_files at check time. Copy
# the committed configs to a throwaway directory and add a placeholder token
# there so the checked paths exist without making the committed configs
# writable.
mkdir -p "$TMP_DIR/prometheus"
cp "${MONITORING_DIR}/prometheus/prometheus.yml" \
    "${MONITORING_DIR}/prometheus/rules.yml" \
    "${MONITORING_DIR}/prometheus/rules_test.yml" \
    "$TMP_DIR/prometheus/"
printf 'validation-placeholder-token\n' >"$TMP_DIR/prometheus/ash-api-token"
chmod 0644 "$TMP_DIR"/prometheus/*
run_tool "promtool check config" \
    "$DOCKER" run --rm --entrypoint /bin/promtool \
    -v "$TMP_DIR/prometheus:/etc/prometheus:ro" \
    "$PROMETHEUS_IMAGE" check config /etc/prometheus/prometheus.yml
run_tool "promtool test rules" \
    "$DOCKER" run --rm --entrypoint /bin/promtool \
    -w /etc/prometheus \
    -v "$TMP_DIR/prometheus:/etc/prometheus:ro" \
    "$PROMETHEUS_IMAGE" test rules rules_test.yml

info "validating rendered Alertmanager config"
python3 - "$MONITORING_DIR/alertmanager/alertmanager.yml.tmpl" "$TMP_DIR/alertmanager.yml" <<'PY'
import sys

source, target = sys.argv[1], sys.argv[2]
text = open(source, encoding="utf-8").read()
placeholder = "__ASH_ALERTMANAGER_WEBHOOK_URL__"
if text.count(placeholder) != 1:
    raise SystemExit("Alertmanager template must contain exactly one placeholder")
with open(target, "w", encoding="utf-8") as handle:
    handle.write(text.replace(placeholder, "https://example.invalid/ash"))
PY
chmod 0644 "$TMP_DIR/alertmanager.yml"
run_tool "amtool check-config" \
    "$DOCKER" run --rm --entrypoint /bin/amtool \
    -v "$TMP_DIR/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro" \
    "$ALERTMANAGER_IMAGE" check-config /etc/alertmanager/alertmanager.yml

info "validating Loki config"
run_tool "loki -verify-config" \
    "$DOCKER" run --rm \
    -v "${MONITORING_DIR}/loki/loki.yml:/etc/loki/loki.yml:ro" \
    "$LOKI_IMAGE" -config.file=/etc/loki/loki.yml -verify-config

info "validating Tempo config"
run_tool "tempo -config.verify" \
    "$DOCKER" run --rm \
    -v "${MONITORING_DIR}/tempo/tempo.yml:/etc/tempo/tempo.yml:ro" \
    "$TEMPO_IMAGE" -config.file=/etc/tempo/tempo.yml -config.verify=true

info "validating OpenTelemetry Collector config"
run_tool "otelcol-contrib validate" \
    "$DOCKER" run --rm \
    -v "${MONITORING_DIR}/otel-collector/config.yml:/etc/otel/config.yml:ro" \
    "$OTEL_IMAGE" validate --config=/etc/otel/config.yml

info "all monitoring validation checks passed"
