#!/usr/bin/env bash
# ASH monitoring stack initializer.
#
# Renders the runtime secrets/configuration that must not be committed:
#   alertmanager.yml         0600, owned by the Alertmanager UID (65534)
#   api_metrics_token        0600, owned by the Prometheus UID (65534)
#   grafana_admin_password   0600, owned by the Grafana UID (472)
#
# It also creates the persistent state directories with the UIDs the pinned
# images run as, so Docker does not create root-owned volumes that the
# services cannot write.
#
# It fails closed. Missing/invalid ASH_ALERTMANAGER_WEBHOOK_URL, disabled API
# metrics, or an empty/weak ASH_METRICS_TOKEN is an error, not a warning: a
# null receiver or unauthenticated metrics endpoint would silently discard
# pages or expose process data.
#
# Usage:
#   sudo scripts/monitoring-init.sh [--env-file FILE] [--runtime-dir DIR]
#                                   [--data-dir DIR]
#
# Environment domains:
#   ASH_METRICS_ENABLED            must be true for the monitoring stack
#   ASH_METRICS_TOKEN              API /metrics bearer secret, 16+ characters
#                                  from [A-Za-z0-9._~+/=-]
#   ASH_ALERTMANAGER_WEBHOOK_URL   absolute http/https URL, host required,
#                                  no userinfo, quotes, backslashes, or controls
#   ASH_GRAFANA_ADMIN_PASSWORD     optional; generated when absent, 12+ chars
#   ASH_MONITORING_RUNTIME_DIR     optional absolute runtime directory
#   ASH_MONITORING_DATA_DIR        optional absolute persistent state directory
#
# The env file is parsed as data (never sourced), so a value cannot execute a
# command. Existing environment variables take precedence over the file.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly PROMETHEUS_UID=65534
readonly ALERTMANAGER_UID=65534
readonly GRAFANA_UID=472
readonly LOKI_UID=10001
readonly TEMPO_UID=10001

RUNTIME_DIR="${ASH_MONITORING_RUNTIME_DIR:-}"
DATA_DIR="${ASH_MONITORING_DATA_DIR:-}"
ENV_FILE=""
MONITORING_DIR=""

usage() {
    cat <<'EOF'
Usage: monitoring-init.sh [options]

Options:
  --env-file FILE       Read ASH_* values from FILE (parsed, not sourced).
  --runtime-dir DIR     Absolute directory for rendered 0600 files.
  --data-dir DIR        Absolute directory for persistent service state.
  -h, --help            Show this help.

Run as root so the rendered files and state directories can be owned by the
container users that read/write them (Prometheus/Alertmanager 65534, Grafana
472, Loki/Tempo 10001). The runtime directory is created 0711 and every secret
file 0600; the state directories are 0750. Both are git-ignored.
EOF
}

error() {
    echo "ERROR: $*" >&2
    exit 1
}

warn() {
    echo "WARNING: $*" >&2
}

# is_true VALUE -> 0 when VALUE is one of 1/true/yes/on (case-insensitive).
is_true() {
    case "${1,,}" in
        1 | true | yes | on) return 0 ;;
        *) return 1 ;;
    esac
}

# load_env_file FILE -> set only unset variables from a Compose-style env file.
# Domain: FILE is a readable regular file; keys match ^[A-Z_][A-Z0-9_]*$;
# values are literal (no shell evaluation). The last assignment in the file
# wins; a variable already present in the environment wins over the file.
load_env_file() {
    local file="$1" line key value
    local -A file_values=()
    [[ -f "$file" && -r "$file" ]] || error "env file is not readable: $file"

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" == *"="* ]] || error "invalid env line (missing '='): $line"

        key="${line%%=*}"
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        key="${key#export }"
        key="${key//[[:space:]]/}"
        [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || error "invalid env key: $key"

        value="${line#*=}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if [[ "$value" == \"*\" && "$value" == *\" ]]; then
            value="${value:1:${#value}-2}"
        elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
            value="${value:1:${#value}-2}"
        fi

        file_values["$key"]="$value"
    done <"$file"

    for key in "${!file_values[@]}"; do
        # Existing environment wins, matching Compose's precedence.
        if [[ -z "${!key+x}" ]]; then
            printf -v "$key" '%s' "${file_values[$key]}"
        fi
    done
}

# resolve_monitoring_dir -> locate the in-repo or installed monitoring assets.
resolve_monitoring_dir() {
    if [[ -d "${SCRIPT_DIR}/../deployments/monitoring" ]]; then
        MONITORING_DIR="$(cd "${SCRIPT_DIR}/../deployments/monitoring" && pwd)"
    elif [[ -d "/usr/local/share/ash/deployments/monitoring" ]]; then
        MONITORING_DIR="/usr/local/share/ash/deployments/monitoring"
    else
        error "cannot find deployments/monitoring; install the monitoring assets or run from a checkout"
    fi
}

# validate_webhook_url URL -> reject anything that is not an absolute
# http/https URL with a host and no userinfo. The URL is rendered inside a
# double-quoted YAML scalar, so quotes, backslashes, and control characters
# are rejected as well. The value is never printed.
validate_webhook_url() {
    local url="$1"
    [[ -n "$url" ]] || error "ASH_ALERTMANAGER_WEBHOOK_URL is required; refusing to render a null receiver"
    [[ "$url" != *[[:cntrl:]]* ]] || error "ASH_ALERTMANAGER_WEBHOOK_URL must not contain control characters"
    [[ "$url" != *'"'* && "$url" != *\\* ]] ||
        error "ASH_ALERTMANAGER_WEBHOOK_URL must not contain quotes or backslashes"
    [[ "$url" != *"@"* ]] || error "ASH_ALERTMANAGER_WEBHOOK_URL must not contain userinfo or '@'"
    [[ "$url" =~ ^https?://[^/?#[:space:]]+([/?#][^[:space:]]*)?$ ]] ||
        error "ASH_ALERTMANAGER_WEBHOOK_URL must be an absolute http(s) URL with a host"
}

# validate_metrics_token TOKEN -> require a non-empty Bearer token of at least
# 16 characters from the RFC 6750 b64token alphabet. The value is never printed.
validate_metrics_token() {
    local token="$1"
    [[ -n "$token" ]] || error "ASH_METRICS_TOKEN is required when the monitoring profile is enabled"
    [[ ${#token} -ge 16 ]] || error "ASH_METRICS_TOKEN must be at least 16 characters"
    [[ "$token" =~ ^[A-Za-z0-9._~+/=-]+$ ]] ||
        error "ASH_METRICS_TOKEN must contain only [A-Za-z0-9._~+/=-]"
}

# validate_grafana_password PASSWORD -> 12+ characters, no control characters.
validate_grafana_password() {
    local password="$1"
    [[ ${#password} -ge 12 ]] || error "ASH_GRAFANA_ADMIN_PASSWORD must be at least 12 characters"
    [[ "$password" != *[[:cntrl:]]* ]] || error "ASH_GRAFANA_ADMIN_PASSWORD must not contain control characters"
}

# write_secret FILE VALUE UID -> atomically write VALUE with mode 0600 and
# ownership UID:UID. Domain: FILE is inside the runtime directory; VALUE is
# literal (no shell evaluation); UID is a numeric container UID.
write_secret() {
    local file="$1" value="$2" uid="$3" tmp
    tmp="$(mktemp "${RUNTIME_DIR}/.$(basename "$file").XXXXXX")"
    printf '%s\n' "$value" >"$tmp"
    chmod 0600 "$tmp"
    chown "${uid}:${uid}" "$tmp"
    mv -f "$tmp" "$file"
}

# render_alertmanager TEMPLATE OUTPUT URL -> replace the single placeholder
# with URL and write OUTPUT 0600 owned by the Alertmanager UID. Python is used
# so characters in the URL are not interpreted by sed; the URL is passed in
# the environment, never on the command line.
render_alertmanager() {
    local template="$1" output="$2" url="$3" tmp count
    [[ -f "$template" ]] || error "Alertmanager template not found: $template"
    count="$(grep -o '__ASH_ALERTMANAGER_WEBHOOK_URL__' "$template" | wc -l)" || true
    [[ "$count" -eq 1 ]] || error "Alertmanager template must contain exactly one webhook placeholder"

    tmp="$(mktemp "${RUNTIME_DIR}/.alertmanager.XXXXXX")"
    ASH_ALERTMANAGER_WEBHOOK_URL="$url" python3 - "$template" "$tmp" <<'PY'
import os
import sys

template, output = sys.argv[1], sys.argv[2]
url = os.environ["ASH_ALERTMANAGER_WEBHOOK_URL"]
with open(template, encoding="utf-8") as src:
    rendered = src.read().replace("__ASH_ALERTMANAGER_WEBHOOK_URL__", url)
with open(output, "w", encoding="utf-8") as dst:
    dst.write(rendered)
PY
    chmod 0600 "$tmp"
    chown "${ALERTMANAGER_UID}:${ALERTMANAGER_UID}" "$tmp"
    mv -f "$tmp" "$output"
}

# generate_password -> emit a random base64 password without printing it.
generate_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 24
    else
        head -c 24 /dev/urandom | base64
    fi
}

# require_absolute_dir NAME VALUE -> reject relative, empty, or root paths.
require_absolute_dir() {
    local name="$1" value="$2"
    [[ -n "$value" ]] || error "$name must not be empty"
    [[ "$value" = /* ]] || error "$name must be an absolute path"
    [[ "$value" != "/" ]] || error "$name must not be /"
}

# create_state_dir PATH UID -> create a 0750 directory owned by UID:UID.
create_state_dir() {
    install -d -m 0750 -o "$2" -g "$2" "$1"
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --env-file)
                [[ $# -ge 2 ]] || error "--env-file requires a path"
                ENV_FILE="$2"
                shift 2
                ;;
            --runtime-dir)
                [[ $# -ge 2 ]] || error "--runtime-dir requires a path"
                RUNTIME_DIR="$2"
                shift 2
                ;;
            --data-dir)
                [[ $# -ge 2 ]] || error "--data-dir requires a path"
                DATA_DIR="$2"
                shift 2
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                error "unknown argument: $1"
                ;;
        esac
    done

    if [[ -n "$ENV_FILE" ]]; then
        load_env_file "$ENV_FILE"
    fi

    RUNTIME_DIR="${RUNTIME_DIR:-${ASH_MONITORING_RUNTIME_DIR:-/var/lib/ash-monitoring/runtime}}"
    DATA_DIR="${DATA_DIR:-${ASH_MONITORING_DATA_DIR:-/var/lib/ash-monitoring}}"
    require_absolute_dir ASH_MONITORING_RUNTIME_DIR "$RUNTIME_DIR"
    require_absolute_dir ASH_MONITORING_DATA_DIR "$DATA_DIR"

    # Validate every input before touching the filesystem or requiring root,
    # so a bad configuration is rejected even when the caller is not root.
    is_true "${ASH_METRICS_ENABLED:-false}" ||
        error "ASH_METRICS_ENABLED must be true for the monitoring profile (the API /metrics endpoint is fail-closed)"
    validate_metrics_token "${ASH_METRICS_TOKEN:-}"
    validate_webhook_url "${ASH_ALERTMANAGER_WEBHOOK_URL:-}"

    local grafana_password="${ASH_GRAFANA_ADMIN_PASSWORD:-}"
    if [[ -n "$grafana_password" ]]; then
        validate_grafana_password "$grafana_password"
    elif [[ -f "${RUNTIME_DIR}/grafana_admin_password" ]]; then
        grafana_password="$(cat "${RUNTIME_DIR}/grafana_admin_password")"
        validate_grafana_password "$grafana_password"
    else
        grafana_password="$(generate_password)"
        validate_grafana_password "$grafana_password"
        warn "generated a Grafana admin password; read it from ${RUNTIME_DIR}/grafana_admin_password"
    fi

    [[ $EUID -eq 0 ]] ||
        error "run as root: rendered files and state directories must be owned by the container UIDs"

    resolve_monitoring_dir

    # 0711 lets the container UIDs traverse to their own 0600 file without
    # being able to list the other secrets in the directory.
    install -d -m 0711 -o root -g root "$RUNTIME_DIR"
    install -d -m 0750 -o root -g root "$DATA_DIR"

    create_state_dir "${DATA_DIR}/prometheus" "$PROMETHEUS_UID"
    create_state_dir "${DATA_DIR}/alertmanager" "$ALERTMANAGER_UID"
    create_state_dir "${DATA_DIR}/grafana" "$GRAFANA_UID"
    create_state_dir "${DATA_DIR}/loki" "$LOKI_UID"
    create_state_dir "${DATA_DIR}/tempo" "$TEMPO_UID"

    write_secret "${RUNTIME_DIR}/api_metrics_token" "${ASH_METRICS_TOKEN}" "$PROMETHEUS_UID"
    render_alertmanager \
        "${MONITORING_DIR}/alertmanager/alertmanager.yml.tmpl" \
        "${RUNTIME_DIR}/alertmanager.yml" \
        "${ASH_ALERTMANAGER_WEBHOOK_URL}"
    write_secret "${RUNTIME_DIR}/grafana_admin_password" "$grafana_password" "$GRAFANA_UID"

    echo "Monitoring runtime files rendered in ${RUNTIME_DIR} (mode 0600, secrets not printed):"
    echo "  alertmanager.yml"
    echo "  api_metrics_token"
    echo "  grafana_admin_password"
    echo "Monitoring state directories prepared in ${DATA_DIR} (mode 0750):"
    echo "  prometheus alertmanager grafana loki tempo"
}

main "$@"
