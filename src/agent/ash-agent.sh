#!/bin/bash
# ASH (Again SHell) Monitoring Agent v2.2
# Production-grade shell activity monitoring with structured events,
# tamper-evident logging, crash recovery, and multi-layer monitoring.

# This file is used in two very different ways:
#
#   1. Executed by systemd (`ExecStart=/usr/local/bin/ash-agent`), or run
#      directly by an operator. It owns the process and may exit on error.
#   2. `source`d from /etc/profile.d/ash.sh into a user's login shell, or
#      from BASH_ENV into a child bash. It must never terminate or mutate
#      the caller's shell options on *any* path, including failures.
#
# The original implementation enabled `set -euo pipefail` at file scope,
# installed traps at file scope, and relied on `main()` returning non-zero
# to disable monitoring. That is unsafe when sourced: errexit remains in the
# caller after the file finishes, so the first unrelated failing command in
# the user's shell exits it. It also made a failed validation look like a
# caller failure, which is exactly the login-shell-death bug in issue #5.
#
# Do not use `$(set +o)` to capture caller options: command substitution
# runs in a subshell where errexit is cleared unless `shopt -s
# inherit_errexit` is set, so it silently records "errexit off" for a
# caller that had it on. Capture the flags directly instead.
_ASH_CALLER_ERREXIT=0
[[ $- == *e* ]] && _ASH_CALLER_ERREXIT=1
_ASH_CALLER_NOUNSET=0
[[ $- == *u* ]] && _ASH_CALLER_NOUNSET=1
_ASH_CALLER_PIPEFAIL=0
[[ -o pipefail ]] && _ASH_CALLER_PIPEFAIL=1
_ASH_CALLER_FUNCTRACE=0
[[ $- == *T* ]] && _ASH_CALLER_FUNCTRACE=1
_ASH_CALLER_ERRTRACE=0
[[ $- == *E* ]] && _ASH_CALLER_ERRTRACE=1
_ASH_CALLER_XTRACE=0
[[ $- == *x* ]] && _ASH_CALLER_XTRACE=1
_ASH_CALLER_NOGLOB=0
[[ $- == *f* ]] && _ASH_CALLER_NOGLOB=1
_ASH_CALLER_ALLEXPORT=0
[[ $- == *a* ]] && _ASH_CALLER_ALLEXPORT=1

readonly ASH_VERSION="2.2.0"

# ─── Configuration ───────────────────────────────────────────────────────────
ASH_CONFIG_DIR="${ASH_CONFIG_DIR:-/etc/ash}"
ASH_LOG_DIR="${ASH_LOG_DIR:-/var/log/ash}"
ASH_TEMP_DIR="${ASH_TEMP_DIR:-}"
ASH_SPOOL_DIR="${ASH_SPOOL_DIR:-/var/spool/ash}"

# Per-user fallback roots. The installer creates these as sticky,
# write+execute-only directories (`1733`) so every local user can create
# their own `$UID` subdirectory but cannot list or delete anyone else's.
ASH_USER_LOG_ROOT="${ASH_USER_LOG_ROOT:-/var/log/ash/users}"
ASH_USER_SPOOL_ROOT="${ASH_USER_SPOOL_ROOT:-/var/spool/ash/users}"

# When true, an unwritable configured directory is a fatal error instead of
# triggering the per-user fallback. The systemd unit sets this for the root
# agent so a broken deployment fails loudly instead of silently writing to a
# different location.
ASH_STRICT_PERMISSIONS="${ASH_STRICT_PERMISSIONS:-false}"

# Last-resort fallback when neither the configured directory nor the
# per-user system directory is writable. This keeps monitoring alive for a
# user whose host has no /var/log/ash at all; the resulting log is local to
# that user and must be collected by root if it needs to be central.
ASH_ALLOW_HOME_FALLBACK="${ASH_ALLOW_HOME_FALLBACK:-true}"

# These are resolved from ASH_LOG_DIR/ASH_TEMP_DIR by ash_resolve_paths().
# Tests and operators may override them explicitly; an explicit value is
# preserved instead of being recomputed.
ASH_HASH_FILE="${ASH_HASH_FILE:-}"
ASH_STATE_FILE="${ASH_STATE_FILE:-}"
ASH_AGENT_LOG="${ASH_AGENT_LOG:-}"
ASH_EVENTS_FILE="${ASH_EVENTS_FILE:-}"
ASH_REDACTION_CONFIG="${ASH_CONFIG_DIR}/redaction_rules.conf"

# Runtime state for the sourced-shell contract and the DEBUG trap.
ASH_AGENT_MODE="${ASH_AGENT_MODE:-}"
ASH_INIT_FAILED=0
ASH_INITIALIZED="${ASH_INITIALIZED:-}"
ASH_DISABLED="${ASH_DISABLED:-false}"
ASH_SESSION_ENDED=0
ASH_SESSION_STARTED=0
ASH_CLEANUP_DONE=0
ASH_DEBUG_DEPTH=0
ASH_TEMP_DIR_IS_SESSION=0
_ASH_PREV_BASH_ENV=""
ASH_PREV_TRAP_EXIT=""
ASH_PREV_TRAP_DEBUG=""
ASH_PREV_TRAP_ERR=""
ASH_PREV_TRAP_INT=""
ASH_PREV_TRAP_TERM=""

KAFKA_ENABLED="${KAFKA_ENABLED:-false}"
# No colon: default only when truly unset. An operator (or a validation
# test) explicitly setting KAFKA_BROKER/KAFKA_TOPIC to "" to represent
# "not configured" must stay empty here, or validate_config's "KAFKA_ENABLED
# but broker/topic is empty" check below can never fire -- ${VAR:-default}
# would silently replace that empty string with the default first.
KAFKA_BROKER="${KAFKA_BROKER-localhost:9092}"
KAFKA_TOPIC="${KAFKA_TOPIC-ash-logs}"

INOTIFY_ENABLED="${INOTIFY_ENABLED:-true}"
AUDITD_ENABLED="${AUDITD_ENABLED:-false}"
DOCKER_MONITOR_ENABLED="${DOCKER_MONITOR_ENABLED:-false}"

MAX_COMMANDS_PER_SECOND="${MAX_COMMANDS_PER_SECOND:-50}"
MAX_OUTPUT_SIZE="${MAX_OUTPUT_SIZE:-1048576}"
ASH_SPOOL_MAX_SIZE="${ASH_SPOOL_MAX_SIZE:-1073741824}"
# Domain: integer seconds >= 1. Must stay comfortably below the unit's
# WatchdogSec=30 so one missed kick does not trigger a restart.
ASH_WATCHDOG_INTERVAL="${ASH_WATCHDOG_INTERVAL:-10}"

WATCHED_FILES=(
    "/etc/passwd"
    "/etc/shadow"
    "/etc/ssh/sshd_config"
    "/etc/sudoers"
    "/etc/hosts"
    "/root/.ssh/authorized_keys"
    "/etc/crontab"
)

# ─── Performance State ──���────────────────────────────────────────────────────
COMMAND_COUNTER=0
LAST_SECOND=$(date +%s)
EVENTS_LOGGED=0
ASH_START_TIME=$(date +%s)

# ─── Session Tracking ───────���────────────────────────────────────────────────
if [[ -z "${ASH_SESSION_ID:-}" ]]; then
    export ASH_SESSION_ID
    ASH_SESSION_ID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || date +%s%N)"
    export ASH_SESSION_START
    ASH_SESSION_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi
ASH_SSH_CONNECTION="${SSH_CONNECTION:-none}"
ASH_SSH_TTY="${SSH_TTY:-none}"

# ─── W3C Trace Context ───────────────────────────────────────────────────────
# The agent deliberately does not run an OpenTelemetry SDK. It emits the two
# IDs from a W3C traceparent (16-byte trace-id, 8-byte span-id) and the
# consumer reconstructs the spans. All IDs are lowercase hex.
ASH_CURRENT_TRACE_ID=""
ASH_LAST_COMMAND_TRACE_ID=""
ASH_LAST_COMMAND_SPAN_ID=""
ASH_LAST_EVENT_SPAN_ID=""
ASH_LAST_LOGGED_COMMAND=""
ASH_LAST_LOGGED_US=""

# ─── Load Configuration ───────���──────────────────────────────────────────────
[[ -f "${ASH_CONFIG_DIR}/ash.conf" ]] && source "${ASH_CONFIG_DIR}/ash.conf"

# ─── Agent Self-Logging ──────────────────────────────────────────────────────
_ash_note() {
    local level="$1"
    shift
    local message="$*"
    printf 'ASH %s: %s\n' "$level" "$message" >&2
    agent_log "$level" "$message"
}

agent_log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

    local log_entry
    if command -v jq >/dev/null 2>&1; then
        log_entry=$(jq -n -c \
            --arg ts "$timestamp" \
            --arg lvl "$level" \
            --arg msg "$message" \
            --arg pid "$$" \
            '{timestamp: $ts, level: $lvl, message: $msg, pid: $pid}')
    else
        log_entry="{\"timestamp\":\"$timestamp\",\"level\":\"$level\",\"message\":\"$message\",\"pid\":$$}"
    fi
    [[ -n "${ASH_AGENT_LOG:-}" ]] || return 0
    echo "$log_entry" >>"${ASH_AGENT_LOG}" 2>/dev/null || true
}

# ─── Permission Resolution ───────────────────────────────────────────────────
# The old model required every user to write to root-owned /var/log/ash and
# /tmp/ash. That is the root cause of issue #5. The model below is layered:
#
#   * root (and the `ash` service account) keeps the shared, host-wide log at
#     /var/log/ash, which is what the systemd unit and log shipping expect;
#   * every other user gets a private, lazily-created directory under the
#     sticky /var/log/ash/users/<uid> (mode 0700), so one user cannot read,
#     modify, or delete another user's local events;
#   * if that directory is unavailable, a home-directory fallback keeps the
#     agent running locally instead of silently disabling monitoring;
#   * if even that fails, validation fails and the sourced-shell wrapper
#     disables monitoring for this session without touching the caller.
#
# A single host-wide log writable by every user cannot be made tamper-proof:
# group/world write permission lets any writer truncate or rewrite it. Per-user
# directories preserve cross-user isolation at the cost of splitting the local
# log. Kafka/PostgreSQL remains the central, cross-host record; without Kafka,
# root must collect the per-user files (documented in docs/PERMISSIONS.md).

_ash_dir_writable() {
    [[ -d "$1" && -w "$1" && -x "$1" ]]
}

_ash_stat() {
    # stat(1) is GNU coreutils on every supported platform (Linux only).
    stat -c "$1" "$2" 2>/dev/null || true
}

# Create a directory that only the current user can access. If it already
# exists, reject it when another user owns it or when it is group/world
# writable. This matters for /var/log/ash/users: the parent is sticky but a
# malicious user can still pre-create another uid's directory name first.
_ash_ensure_private_dir() {
    local dir="$1" owner mode
    [[ -n "$dir" ]] || return 1

    if [[ -e "$dir" ]]; then
        [[ -d "$dir" ]] || return 1
        owner=$(_ash_stat '%u' "$dir")
        mode=$(_ash_stat '%a' "$dir")
        if [[ -n "$owner" && "$owner" != "$EUID" && "$EUID" -ne 0 ]]; then
            _ash_note "WARN" "Refusing $dir: owned by uid $owner, not $EUID"
            return 1
        fi
        if [[ -n "$mode" ]] && (((8#$mode & 8#022) != 0)) && [[ "$EUID" -ne 0 ]]; then
            _ash_note "WARN" "Refusing $dir: mode $mode is group/world writable"
            return 1
        fi
        _ash_dir_writable "$dir" || return 1
        return 0
    fi

    mkdir -p "$dir" 2>/dev/null || return 1
    chmod 700 "$dir" 2>/dev/null || return 1
    return 0
}

# Resolve one directory variable: keep the configured path when writable,
# otherwise use the supplied per-user fallback. Never prints here; the caller
# owns the final diagnostic so a failed fallback does not look like a hard
# error in the middle of a successful fallback chain.
_ash_resolve_dir() {
    local var="$1" desired="$2" fallback="$3" strict="$4"
    local current="${!var}"

    if _ash_dir_writable "$current"; then
        return 0
    fi

    if [[ "$strict" == "true" ]]; then
        return 1
    fi

    if [[ -n "$fallback" ]] && _ash_ensure_private_dir "$fallback" && _ash_dir_writable "$fallback"; then
        printf -v "$var" '%s' "$fallback"
        _ash_note "WARN" "$var=$current is not writable; using $fallback"
        return 0
    fi

    return 1
}

_ash_home_state_root() {
    [[ -n "${HOME:-}" ]] || return 1
    printf '%s/ash' "${XDG_STATE_HOME:-${HOME}/.local/state}"
}

ash_resolve_temp_dir() {
    local candidate="${ASH_TEMP_DIR:-}" fallback

    if [[ -n "$candidate" ]] && _ash_dir_writable "$candidate"; then
        ASH_TEMP_DIR_IS_SESSION=0
        return 0
    fi

    if [[ -n "$candidate" ]]; then
        _ash_note "WARN" "ASH_TEMP_DIR=$candidate is not writable; using a per-session directory"
    fi

    fallback=$(mktemp -d "${TMPDIR:-/tmp}/ash.${EUID}.XXXXXXXX" 2>/dev/null) || {
        printf 'ERROR: cannot create a writable session temp directory\n' >&2
        return 1
    }
    if ! chmod 700 "$fallback" 2>/dev/null; then
        rm -rf "$fallback" 2>/dev/null || true
        printf 'ERROR: cannot secure session temp directory %s\n' "$fallback" >&2
        return 1
    fi

    ASH_TEMP_DIR="$fallback"
    ASH_TEMP_DIR_IS_SESSION=1
    return 0
}

ash_resolve_log_dir() {
    local fallback="${ASH_USER_LOG_ROOT}/${EUID}" home_root

    if _ash_resolve_dir ASH_LOG_DIR "$ASH_LOG_DIR" "$fallback" "$ASH_STRICT_PERMISSIONS"; then
        return 0
    fi

    if [[ "$ASH_STRICT_PERMISSIONS" != "true" && "$ASH_ALLOW_HOME_FALLBACK" == "true" ]]; then
        home_root=$(_ash_home_state_root) || return 1
        fallback="${home_root}/log"
        if _ash_ensure_private_dir "$fallback" && _ash_dir_writable "$fallback"; then
            ASH_LOG_DIR="$fallback"
            _ash_note "WARN" "ASH_LOG_DIR is using the home-directory fallback $ASH_LOG_DIR"
            return 0
        fi
    fi

    return 1
}

ash_resolve_spool_dir() {
    local fallback="${ASH_USER_SPOOL_ROOT}/${EUID}" home_root

    if _ash_resolve_dir ASH_SPOOL_DIR "$ASH_SPOOL_DIR" "$fallback" "$ASH_STRICT_PERMISSIONS"; then
        return 0
    fi

    if [[ "$ASH_STRICT_PERMISSIONS" != "true" && "$ASH_ALLOW_HOME_FALLBACK" == "true" ]]; then
        home_root=$(_ash_home_state_root) || return 1
        fallback="${home_root}/spool"
        if _ash_ensure_private_dir "$fallback" && _ash_dir_writable "$fallback"; then
            ASH_SPOOL_DIR="$fallback"
            _ash_note "WARN" "ASH_SPOOL_DIR is using the home-directory fallback $ASH_SPOOL_DIR"
            return 0
        fi
    fi

    return 1
}

ash_resolve_paths() {
    [[ -n "${ASH_EVENTS_FILE:-}" ]] || ASH_EVENTS_FILE="${ASH_LOG_DIR}/events.jsonl"
    [[ -n "${ASH_HASH_FILE:-}" ]] || ASH_HASH_FILE="${ASH_LOG_DIR}/.hash_chain"
    [[ -n "${ASH_AGENT_LOG:-}" ]] || ASH_AGENT_LOG="${ASH_LOG_DIR}/agent.log"
    [[ -n "${ASH_STATE_FILE:-}" ]] || ASH_STATE_FILE="${ASH_LOG_DIR}/agent_state.json"
}

# Pre-create the append targets with the narrowest mode that still lets the
# intended reader in. Without this, the first writer's umask decides whether
# events.jsonl is world-readable, and a later writer inherits that mode.
ash_prepare_log_files() {
    local file old_umask mode

    old_umask=$(umask)
    if [[ "$EUID" -eq 0 ]]; then
        umask 027
    else
        umask 077
    fi

    for file in "$ASH_EVENTS_FILE" "$ASH_AGENT_LOG"; do
        if [[ ! -e "$file" ]]; then
            : >"$file" 2>/dev/null || {
                umask "$old_umask"
                return 1
            }
        fi
        if [[ "$(stat -c '%u' "$file" 2>/dev/null || echo '')" == "$EUID" ]]; then
            mode=$(_ash_stat '%a' "$file")
            if [[ -n "$mode" ]] && (((8#$mode & 8#022) != 0)); then
                if [[ "$EUID" -eq 0 && "$ASH_LOG_DIR" == "/var/log/ash" ]]; then
                    chmod 640 "$file" 2>/dev/null || true
                else
                    chmod 600 "$file" 2>/dev/null || true
                fi
            fi
        fi
    done

    umask "$old_umask"
    return 0
}

# ─── Configuration Validation ────────────────────────────────────────────────
validate_config() {
    local errors=0

    if ! ash_resolve_temp_dir; then
        errors=$((errors + 1))
    fi

    if ! ash_resolve_log_dir; then
        echo "ERROR: ASH_LOG_DIR=$ASH_LOG_DIR is not writable and no per-user or home fallback is available" >&2
        errors=$((errors + 1))
    fi

    if ! ash_resolve_spool_dir; then
        echo "ERROR: ASH_SPOOL_DIR=$ASH_SPOOL_DIR is not writable and no per-user or home fallback is available" >&2
        errors=$((errors + 1))
    fi

    ash_resolve_paths

    if [[ "${ASH_LOG_DIR}" == *'*'* || "${ASH_TEMP_DIR}" == *'*'* || "${ASH_SPOOL_DIR}" == *'*'* ]]; then
        echo "ERROR: ASH directories must not contain shell glob characters" >&2
        errors=$((errors + 1))
    fi

    if [[ -L "${ASH_LOG_DIR}" || -L "${ASH_SPOOL_DIR}" ]]; then
        echo "ERROR: ASH_LOG_DIR and ASH_SPOOL_DIR must not be symlinks" >&2
        errors=$((errors + 1))
    fi

    # These are required for the hash chain and for serialising concurrent
    # writers. Missing tools used to fail silently inside a subshell.
    local required_cmd
    for required_cmd in flock sha256sum; do
        if ! command -v "$required_cmd" >/dev/null 2>&1; then
            echo "ERROR: required command not found: $required_cmd" >&2
            errors=$((errors + 1))
        fi
    done

    if [[ "${KAFKA_ENABLED}" == "true" ]]; then
        if [[ -z "${KAFKA_BROKER:-}" ]]; then
            echo "ERROR: KAFKA_ENABLED=true but KAFKA_BROKER is empty" >&2
            errors=$((errors + 1))
        fi
        if [[ -z "${KAFKA_TOPIC:-}" ]]; then
            echo "ERROR: KAFKA_ENABLED=true but KAFKA_TOPIC is empty" >&2
            errors=$((errors + 1))
        fi
        if ! command -v kafka-console-producer.sh >/dev/null 2>&1; then
            _ash_note "WARN" "kafka-console-producer.sh not found; events will stay in the local spool"
        fi
    fi

    # Require digits before the numeric comparison: `[[ abc -lt 1 ]]` fails
    # with status 2, which the old `2>/dev/null` silently treated as "valid".
    if ! [[ "${MAX_COMMANDS_PER_SECOND}" =~ ^[0-9]+$ ]] ||
        [[ "${MAX_COMMANDS_PER_SECOND}" -lt 1 ]]; then
        echo "ERROR: MAX_COMMANDS_PER_SECOND must be an integer >= 1" >&2
        errors=$((errors + 1))
    fi

    if ! [[ "${MAX_OUTPUT_SIZE}" =~ ^[0-9]+$ ]] ||
        [[ "${MAX_OUTPUT_SIZE}" -lt 1024 ]]; then
        echo "ERROR: MAX_OUTPUT_SIZE must be an integer >= 1024" >&2
        errors=$((errors + 1))
    fi

    if ! [[ "${ASH_WATCHDOG_INTERVAL}" =~ ^[0-9]+$ ]] ||
        [[ "${ASH_WATCHDOG_INTERVAL}" -lt 1 ]]; then
        echo "ERROR: ASH_WATCHDOG_INTERVAL must be an integer >= 1" >&2
        errors=$((errors + 1))
    fi

    if [[ "${INOTIFY_ENABLED}" == "true" ]] && ! command -v inotifywait >/dev/null 2>&1; then
        agent_log "WARN" "inotifywait not found — file watching disabled"
        INOTIFY_ENABLED="false"
    fi

    if ! command -v jq >/dev/null 2>&1; then
        agent_log "WARN" "jq not found — JSON construction will use fallback method"
    fi

    if [[ $errors -gt 0 ]]; then
        echo "FATAL: $errors configuration errors. ASH cannot start." >&2
        return 1
    fi
    return 0
}

# ─── Atomic Log Writes ────���──────────────────────────────────────────────────
safe_log_write() {
    local content="$1"
    local target_file="${2:-${ASH_EVENTS_FILE}}"
    # BASHPID, not $$: background subshells and command substitutions share
    # the parent's $$, so two concurrent writers could pick the same temp
    # path and one would truncate the other's content before it was appended.
    local temp_file="${ASH_TEMP_DIR}/write.${BASHPID:-$$}.tmp"

    printf '%s\n' "$content" >"$temp_file" 2>/dev/null || return 1
    # The temp file lives in a 0700 directory, but an explicit ASH_TEMP_DIR
    # may be shared. Never leave an event readable by another local user.
    chmod 600 "$temp_file" 2>/dev/null || true

    (
        flock -x 200
        # `|| exit 1` is required: without it a failed cat is masked by the
        # successful rm below, the subshell reports success, and the fallback
        # append is skipped -- silently losing the event.
        cat "$temp_file" >>"$target_file" || exit 1
        rm -f "$temp_file"
    ) 200>"${target_file}.lock" 2>/dev/null

    if [[ $? -ne 0 ]]; then
        printf '%s\n' "$content" >>"$target_file" 2>/dev/null || return 1
        rm -f "$temp_file"
    fi
    return 0
}

# ─── Sensitive Data Redaction ────────────────────────────────────────────────
REDACTION_PATTERNS=()
REDACTION_REPLACEMENTS=()

load_redaction_rules() {
    # Built-in patterns
    REDACTION_PATTERNS+=(
        '(password|passwd|pwd|passphrase)[[:space:]]*=[[:space:]]*[^[:space:];|&]+'
        '(-p|--password|--pass)[[:space:]]+[^[:space:];|&]+'
        '(Authorization:[[:space:]]*Bearer)[[:space:]]+[^[:space:];|&]+'
        '(Authorization:[[:space:]]*Basic)[[:space:]]+[^[:space:];|&]+'
        '(api_key|apikey|api-key|token|secret_key|access_key)[[:space:]]*=[[:space:]]*[^[:space:];|&]+'
        '(mysql|mysqldump)[[:space:]]+[^[:space:]]*-p[^[:space:]]*'
        'AKIA[A-Z0-9]{16}'
        '-----BEGIN[[:space:]]+(RSA|DSA|EC|OPENSSH)[[:space:]]+PRIVATE[[:space:]]+KEY-----'
        '-----BEGIN[[:space:]]+PRIVATE[[:space:]]+KEY-----'
        'eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'
        '([a-zA-Z][a-zA-Z0-9+.-]*://[^:/[:space:]@]+):[^@[:space:]]+@'
    )
    REDACTION_REPLACEMENTS+=(
        '\1=[REDACTED]'
        '\1 [REDACTED]'
        '\1 [REDACTED]'
        '\1 [REDACTED]'
        '\1=[REDACTED]'
        '\1 -p[REDACTED]'
        'AKIA[REDACTED]'
        '-----BEGIN [REDACTED] PRIVATE KEY-----'
        '-----BEGIN [REDACTED] PRIVATE KEY-----'
        '[JWT_REDACTED]'
        '\1:[REDACTED]@'
    )

    # Load user-defined rules
    if [[ -f "${ASH_REDACTION_CONFIG}" ]]; then
        while IFS='|' read -r pattern replacement; do
            [[ "$pattern" =~ ^# ]] && continue
            [[ -z "$pattern" ]] && continue
            REDACTION_PATTERNS+=("$pattern")
            REDACTION_REPLACEMENTS+=("$replacement")
        done <"${ASH_REDACTION_CONFIG}"
    fi

    _validate_redaction_patterns
}

# redact_sensitive_data() applies every pattern in a single sed invocation
# (see below) instead of one sed process per pattern, for throughput -- but
# that means a single malformed regex (most likely from a hand-edited
# redaction_rules.conf, not the built-ins above) would now fail the *whole*
# sed command and skip every pattern's redaction, not just the broken one.
# Validate once here, at load time, and drop anything that doesn't compile,
# so the fast path in redact_sensitive_data can assume every pattern in
# REDACTION_PATTERNS is safe to run together.
_validate_redaction_patterns() {
    local -a valid_patterns=() valid_replacements=()
    local i pat

    for i in "${!REDACTION_PATTERNS[@]}"; do
        pat="${REDACTION_PATTERNS[$i]//\//\\/}"
        if printf '' | sed -E "s/${pat}/x/" >/dev/null 2>&1; then
            valid_patterns+=("${REDACTION_PATTERNS[$i]}")
            valid_replacements+=("${REDACTION_REPLACEMENTS[$i]}")
        else
            agent_log "WARN" "Dropping invalid redaction pattern: ${REDACTION_PATTERNS[$i]}"
        fi
    done

    REDACTION_PATTERNS=("${valid_patterns[@]}")
    REDACTION_REPLACEMENTS=("${valid_replacements[@]}")
}

redact_sensitive_data() {
    local input="$1"
    local -a sed_args=()
    local i pat rep

    for i in "${!REDACTION_PATTERNS[@]}"; do
        # sed's `s/pattern/replacement/` uses '/' as the delimiter. Patterns
        # matching URLs (e.g. `scheme://user:pass@host`) contain literal '/'
        # characters that would otherwise be misread as extra delimiters,
        # silently corrupting the substitution. Escape '/' in both pattern
        # and replacement before building the sed command.
        pat="${REDACTION_PATTERNS[$i]//\//\\/}"
        rep="${REDACTION_REPLACEMENTS[$i]//\//\\/}"
        sed_args+=(-e "s/${pat}/${rep}/gI")
    done

    if [[ ${#sed_args[@]} -eq 0 ]]; then
        echo "$input"
        return
    fi

    # One sed process applying every -e expression in sequence (each
    # operating on the previous one's output, same net effect as the old
    # per-pattern loop) instead of one sed process per pattern -- this was
    # the dominant cost in tests/performance/benchmark.sh's ~89ms/event
    # reading, going from ~11 forks to 1 for a typical rule set.
    echo "$input" | sed -E "${sed_args[@]}" 2>/dev/null || echo "$input"
}

# ─── Hash-Chained Append-Only Logs ─────────────────────────────��────────────
hash_chain_init() {
    local hash_dir
    hash_dir=$(dirname "${ASH_HASH_FILE}")
    mkdir -p "$hash_dir" 2>/dev/null || return 1

    if [[ ! -f "${ASH_HASH_FILE}" ]]; then
        (
            # Two sessions can start at the same time on a host that has
            # never run ASH. Without the lock both can see the missing file
            # and one can truncate the genesis value the other just wrote.
            exec {lock_fd}>"${ASH_HASH_FILE}.lock" || exit 1
            flock -x "$lock_fd" || exit 1
            if [[ ! -f "${ASH_HASH_FILE}" ]]; then
                printf '%s\n' "0000000000000000000000000000000000000000000000000000000000000000" >"${ASH_HASH_FILE}" || exit 1
                # 600, not 400: hash_chain_append() must keep appending to this
                # file for the life of the process. 400 (no write bit, even for
                # the owner) blocks that on every non-root run and only ever
                # "worked" because DAC checks don't apply to root, which is how
                # this agent has always been deployed so far (see
                # deployments/systemd/*).
                chmod 600 "${ASH_HASH_FILE}" 2>/dev/null || true
            fi
        )
        return $?
    fi
    return 0
}

# Read the last hash, sign the event, and append the new hash to the chain
# file. Callers must hold the ${ASH_HASH_FILE}.lock that hash_chain_append()
# and emit_event() take. Keeping this separate lets emit_event() hold one lock
# across both the hash append and the event-log append, so the two files stay
# in the same order.
_hash_chain_append_unlocked() {
    local event_json="$1"
    local prev_hash
    # Re-read the file on every call rather than caching the last hash in a
    # variable: this file is shared across every concurrent session on the
    # host (ASH_HASH_FILE is per-host, not per-process), so the only correct
    # "previous hash" is whatever is actually on disk right now. Caching it
    # in memory would silently break chain integrity the moment a second
    # terminal session appends an event first.
    prev_hash=$(tail -1 "${ASH_HASH_FILE}" 2>/dev/null || echo "")
    # An empty or missing chain file must behave like the genesis value; an
    # empty prev_hash would sign an event that verify_hash_chain() can never
    # validate.
    [[ -n "$prev_hash" ]] || prev_hash="0000000000000000000000000000000000000000000000000000000000000000"
    local combined="${prev_hash}${event_json}"
    local current_hash
    # sha256sum's own output ("<hash>  -") already has the hash first;
    # trimming it with a parameter expansion instead of piping through an
    # extra `cut` process saves one fork per event.
    current_hash=$(printf '%s' "$combined" | sha256sum)
    current_hash="${current_hash%% *}"

    # Add hash fields to event JSON
    local signed_event
    if command -v jq >/dev/null 2>&1; then
        signed_event=$(echo "$event_json" | jq -c --arg ph "$prev_hash" --arg eh "$current_hash" '. + {prev_hash: $ph, event_hash: $eh}')
    else
        signed_event="${event_json%\}},\"prev_hash\":\"${prev_hash}\",\"event_hash\":\"${current_hash}\"}"
    fi

    echo "$current_hash" >>"${ASH_HASH_FILE}"
    echo "$signed_event"
}

hash_chain_append() {
    (
        # Re-reading the file is not enough on its own: two sessions can
        # both read the same prev_hash before either appends, producing two
        # events that fork the chain. Serialize the read/compute/append
        # sequence across every process sharing this host's chain.
        exec {lock_fd}>"${ASH_HASH_FILE}.lock" || exit 1
        flock -x "$lock_fd" || exit 1
        _hash_chain_append_unlocked "$1"
    )
}

verify_hash_chain() {
    local log_file="${1:-${ASH_EVENTS_FILE}}"
    local prev_hash="0000000000000000000000000000000000000000000000000000000000000000"
    local line_num=0
    local errors=0

    while IFS= read -r line; do
        line_num=$((line_num + 1))
        local stored_hash stored_prev

        if command -v jq >/dev/null 2>&1; then
            stored_hash=$(echo "$line" | jq -r '.event_hash // empty')
            stored_prev=$(echo "$line" | jq -r '.prev_hash // empty')
        else
            stored_hash=$(echo "$line" | grep -oP '"event_hash":"[^"]*"' | cut -d'"' -f4)
            stored_prev=$(echo "$line" | grep -oP '"prev_hash":"[^"]*"' | cut -d'"' -f4)
        fi

        [[ -z "$stored_hash" ]] && continue

        if [[ "$stored_prev" != "$prev_hash" ]]; then
            echo "LINE $line_num: Chain broken — expected prev_hash $prev_hash, got $stored_prev"
            errors=$((errors + 1))
        fi

        # Strip hash fields and recompute
        local stripped
        if command -v jq >/dev/null 2>&1; then
            stripped=$(echo "$line" | jq -c 'del(.prev_hash, .event_hash)')
        else
            stripped=$(echo "$line" | sed 's/,"prev_hash":"[^"]*","event_hash":"[^"]*"//')
        fi
        local computed
        computed=$(printf '%s' "${prev_hash}${stripped}" | sha256sum | cut -d' ' -f1)

        if [[ "$computed" != "$stored_hash" ]]; then
            echo "LINE $line_num: Hash mismatch — content was modified"
            errors=$((errors + 1))
        fi
        prev_hash="$stored_hash"
    done <"$log_file"

    if [[ $errors -eq 0 ]]; then
        echo "PASS: All $line_num entries verified successfully"
        return 0
    fi
    echo "FAIL: $errors integrity errors found in $line_num entries"
    # Do not `return $errors`: shell exit statuses are 0-255, so a log with
    # exactly 256 (or 512, ...) errors would wrap to 0 and look like a pass.
    return 1
}

# ─── Local Spool Queue ───────────────────────────────────────────────────────
spool_init() {
    mkdir -p "${ASH_SPOOL_DIR}/pending" "${ASH_SPOOL_DIR}/sent" 2>/dev/null || return 1
    chmod 700 "${ASH_SPOOL_DIR}" 2>/dev/null || return 1
    chmod 700 "${ASH_SPOOL_DIR}/pending" "${ASH_SPOOL_DIR}/sent" 2>/dev/null || return 1
    return 0
}

spool_write() {
    local event_json="$1"
    # BASHPID, not $$: background subshells inherit $$ and two events emitted
    # in the same nanosecond would otherwise overwrite each other's spool file.
    local spool_file="${ASH_SPOOL_DIR}/pending/$(date +%s%N)_${BASHPID:-$$}"
    printf '%s\n' "$event_json" >"$spool_file" 2>/dev/null || return 1
    chmod 600 "$spool_file" 2>/dev/null || true

    # Enforce max spool size
    local spool_size
    spool_size=$(du -sb "${ASH_SPOOL_DIR}/pending" 2>/dev/null | cut -f1)
    if [[ ${spool_size:-0} -gt ${ASH_SPOOL_MAX_SIZE} ]]; then
        ls -t "${ASH_SPOOL_DIR}/pending/" | tail -n +100 |
            xargs -I{} rm -f "${ASH_SPOOL_DIR}/pending/{}" 2>/dev/null || true
    fi
}

spool_flush() {
    local sent=0
    local failed=0

    for spool_file in "${ASH_SPOOL_DIR}/pending/"*; do
        [[ -f "$spool_file" ]] || continue
        local event_data
        event_data=$(cat "$spool_file")

        if send_to_kafka_raw "$event_data"; then
            mv "$spool_file" "${ASH_SPOOL_DIR}/sent/" 2>/dev/null || rm -f "$spool_file"
            sent=$((sent + 1))
        else
            failed=$((failed + 1))
            break
        fi
    done

    # Clean sent files older than 1 hour
    find "${ASH_SPOOL_DIR}/sent/" -type f -mmin +60 -delete 2>/dev/null || true
    return $failed
}

spool_flush_timer() {
    {
        while true; do
            sleep 30
            spool_flush 2>/dev/null || true
        done
    } >/dev/null 2>&1 &
    echo $! >"${ASH_TEMP_DIR}/spool_flush.pid"
}

send_to_kafka_raw() {
    local message="$1"
    local max_retries=3
    local retry=0
    local -a producer=(kafka-console-producer.sh)
    local send_timeout="${KAFKA_SEND_TIMEOUT:-10}"

    # Fail immediately instead of retrying with backoff for ~12 seconds when
    # the producer is not installed. A non-root user is unlikely to have the
    # Kafka CLI on PATH; keeping events queued is the correct outcome.
    command -v kafka-console-producer.sh >/dev/null 2>&1 || return 1

    # A producer that connects but never returns (broker accepts the TCP
    # connection and then stops responding) would otherwise block spool_flush
    # forever: the retry loop never advances because the command never exits.
    # timeout(1) turns that hang into an ordinary failed attempt.
    if command -v timeout >/dev/null 2>&1; then
        producer=(timeout "${send_timeout}" kafka-console-producer.sh)
    fi

    while [[ $retry -lt $max_retries ]]; do
        if printf '%s\n' "$message" | "${producer[@]}" \
            --broker-list "${KAFKA_BROKER}" \
            --topic "${KAFKA_TOPIC}" \
            --request-required-acks 1 \
            2>/dev/null; then
            return 0
        fi
        retry=$((retry + 1))
        sleep $((retry * 2))
    done
    return 1
}

# ─── W3C Trace Identifier Generation ────────────────────────────────────────
# Domains: trace_id is 32 lowercase hex characters, span_id and parent_span_id
# are 16 lowercase hex characters. A UUID supplies 128 random bits; od is the
# fallback when /proc and uuidgen are unavailable. Neither function returns an
# all-zero value in practice, and the consumer rejects one if it ever occurs.
new_trace_id() {
    local value=""
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        value=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)
    elif command -v uuidgen >/dev/null 2>&1; then
        value=$(uuidgen 2>/dev/null || true)
    fi
    if [[ -n "$value" ]]; then
        printf '%s' "${value//-/}" | tr 'A-F' 'a-f'
        return 0
    fi
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | tr 'A-F' 'a-f'
}

new_span_id() {
    local value=""
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        value=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)
    elif command -v uuidgen >/dev/null 2>&1; then
        value=$(uuidgen 2>/dev/null || true)
    fi
    if [[ -n "$value" ]]; then
        value="${value//-/}"
        printf '%s' "${value:0:16}" | tr 'A-F' 'a-f'
        return 0
    fi
    od -An -N8 -tx1 /dev/urandom | tr -d ' \n' | tr 'A-F' 'a-f'
}

# ─── Structured Event Emission ───��───────────────────────────────────────────
emit_event() {
    local event_type="$1"
    shift
    local extra_fields="${1:-}"

    local event_id timestamp hostname user uid session_id pid ppid tty cwd
    local trace_id span_id
    event_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "$$-$(date +%s%N)")
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
    hostname=$(hostname)
    user="${USER:-unknown}"
    uid="${EUID:-$(id -u)}"
    session_id="${ASH_SESSION_ID:-unknown}"
    pid="$$"
    ppid="${PPID:-1}"
    # `tty` prints "not a tty" and exits 1 when stdin is not a terminal.
    # Assign the fallback instead of appending it, which used to produce a
    # multi-line "not a tty\nunknown" value in every non-interactive event.
    tty=$(tty 2>/dev/null) || tty="unknown"
    cwd="${PWD}"
    trace_id="${ASH_CURRENT_TRACE_ID}"
    if [[ -z "$trace_id" ]]; then
        trace_id=$(new_trace_id)
    fi
    span_id=$(new_span_id)

    local event
    if command -v jq >/dev/null 2>&1; then
        event=$(jq -n -c \
            --arg eid "$event_id" \
            --arg sv "1.0" \
            --arg ts "$timestamp" \
            --arg hn "$hostname" \
            --arg src "bash-debug" \
            --arg et "$event_type" \
            --arg u "$user" \
            --argjson uid "$uid" \
            --arg sid "$session_id" \
            --argjson pid "$pid" \
            --argjson ppid "$ppid" \
            --arg tty "$tty" \
            --arg cwd "$cwd" \
            --arg ssh "$ASH_SSH_CONNECTION" \
            --arg tid "$trace_id" \
            --arg spid "$span_id" \
            '{
                event_id: $eid,
                schema_version: $sv,
                timestamp: $ts,
                hostname: $hn,
                source: $src,
                event_type: $et,
                user: $u,
                uid: $uid,
                session_id: $sid,
                pid: $pid,
                ppid: $ppid,
                tty: $tty,
                cwd: $cwd,
                ssh_connection: $ssh,
                trace_id: $tid,
                span_id: $spid
            }')

        # Merge extra fields if provided
        if [[ -n "$extra_fields" ]]; then
            event=$(echo "$event" | jq -c --argjson extra "$extra_fields" '. + $extra')
        fi
    else
        event="{\"event_id\":\"$event_id\",\"schema_version\":\"1.0\",\"timestamp\":\"$timestamp\",\"hostname\":\"$hostname\",\"source\":\"bash-debug\",\"event_type\":\"$event_type\",\"user\":\"$user\",\"uid\":$uid,\"session_id\":\"$session_id\",\"pid\":$pid,\"ppid\":$ppid,\"tty\":\"$tty\",\"cwd\":\"$cwd\",\"ssh_connection\":\"$ASH_SSH_CONNECTION\",\"trace_id\":\"$trace_id\",\"span_id\":\"$span_id\"}"

        # Merge extra fields (non-jq fallback). Without this, every
        # event-specific field built by callers (command, file_path,
        # diff_content, exit_code, ...) was silently dropped whenever jq
        # is unavailable — and jq is only an optional dependency per
        # install.sh, so this path is reachable in production. Splice the
        # extra object's members in by trimming the base object's trailing
        # '}' and the extra object's leading '{', matching the same
        # delimiter-splicing approach already used in hash_chain_append().
        if [[ -n "$extra_fields" ]]; then
            event="${event%\}},${extra_fields#\{}"
        fi
    fi

    # Callers that emit a related span (privilege escalation, command_end,
    # file changes) use this as parent_span_id.
    ASH_LAST_EVENT_SPAN_ID="$span_id"

    # Hash chain signing and the event-log append must happen under the same
    # lock. Taking the lock inside hash_chain_append() alone keeps the hash
    # file consistent, but releases it before safe_log_write() runs, so two
    # sessions can append their hashes in one order and their events in the
    # other, breaking verify_hash_chain() even though every hash is correct.
    #
    # This function is called from the DEBUG trap. It must never return a
    # non-zero status to the caller: under the caller's `set -e` that would
    # abort the user's command, and in the trap handler it can abort the
    # shell itself.
    local signed_event lock_fd
    if ! exec {lock_fd}>"${ASH_HASH_FILE}.lock" 2>/dev/null; then
        _ash_note "ERROR" "Cannot open hash-chain lock ${ASH_HASH_FILE}.lock"
        return 0
    fi
    if ! flock -x "$lock_fd" 2>/dev/null; then
        _ash_note "ERROR" "Cannot lock ${ASH_HASH_FILE}.lock"
        exec {lock_fd}>&-
        return 0
    fi

    signed_event=$(_hash_chain_append_unlocked "$event") || signed_event=""
    if [[ -n "$signed_event" ]]; then
        if ! safe_log_write "$signed_event"; then
            _ash_note "ERROR" "Failed to append event to ${ASH_EVENTS_FILE}"
        fi
    fi

    flock -u "$lock_fd" 2>/dev/null || true
    exec {lock_fd}>&-

    # Forward to Kafka spool. A failed spool write must not lose the local
    # event or abort the caller; the next flush retries whatever is queued.
    if [[ "${KAFKA_ENABLED}" == "true" && -n "$signed_event" ]]; then
        if ! spool_write "$signed_event"; then
            _ash_note "ERROR" "Failed to write Kafka spool event to ${ASH_SPOOL_DIR}"
        fi
    fi

    # Assignment, not `((EVENTS_LOGGED++))`: post-increment evaluates to the
    # old value, so the first event made this function return status 1 --
    # and under `set -e` it aborted the caller after a successful write.
    EVENTS_LOGGED=$((EVENTS_LOGGED + 1))
    return 0
}

# ─── Session Events ���─────────────────────────���──────────────────────────────
emit_session_start() {
    local extra
    if command -v jq >/dev/null 2>&1; then
        extra=$(jq -n -c \
            --arg ssh_tty "$ASH_SSH_TTY" \
            --arg shell "$SHELL" \
            --arg bash_ver "$BASH_VERSION" \
            '{ssh_tty: $ssh_tty, shell: $shell, bash_version: $bash_ver}')
    else
        extra="{\"ssh_tty\":\"$ASH_SSH_TTY\",\"shell\":\"$SHELL\",\"bash_version\":\"$BASH_VERSION\"}"
    fi
    emit_event "session_start" "$extra"
}

emit_session_end() {
    local duration=$(($(date +%s) - ${ASH_START_TIME}))
    local extra
    if command -v jq >/dev/null 2>&1; then
        extra=$(jq -n -c \
            --arg started "$ASH_SESSION_START" \
            --argjson duration "$duration" \
            --argjson events "$EVENTS_LOGGED" \
            '{session_start: $started, duration_seconds: $duration, events_in_session: $events}')
    else
        extra="{\"session_start\":\"$ASH_SESSION_START\",\"duration_seconds\":$duration,\"events_in_session\":$EVENTS_LOGGED}"
    fi
    emit_event "session_end" "$extra"
    # Do not flush the Kafka spool synchronously here. send_to_kafka_raw()
    # retries with backoff, so a broker outage would otherwise make closing
    # a terminal take tens of seconds. The pending spool survives the session
    # and is flushed by the next agent start (recover_state) or timer.
}

# ─── Rate Limiting ────────────��──────────────────────────────────────────────
rate_limit_check() {
    local current_second
    current_second=$(date +%s)

    if [[ $current_second -eq $LAST_SECOND ]]; then
        COMMAND_COUNTER=$((COMMAND_COUNTER + 1))
        if [[ $COMMAND_COUNTER -gt $MAX_COMMANDS_PER_SECOND ]]; then
            return 1
        fi
    else
        COMMAND_COUNTER=1
        LAST_SECOND=$current_second
    fi
    return 0
}

# ─── File Change Tracking ────────────────────────────────────────────────────
extract_target_files() {
    local cmd="$1"
    local -n files_ref=$2

    # Text editors
    if [[ "${cmd}" =~ (vim|vi|nano|emacs|gedit|ed)[[:space:]] ]]; then
        local editor_files
        mapfile -t editor_files < <(echo "${cmd}" | awk '{for(i=2;i<=NF;i++) if($i !~ /^-/) print $i}')
        files_ref+=("${editor_files[@]}")
    fi

    # Redirections
    if [[ "${cmd}" =~ (\>|\>\>|2\>|\&\>) ]]; then
        local redir_files
        mapfile -t redir_files < <(echo "${cmd}" | grep -oP '(?<=[>]{1,2}\s{0,3})[^\s;|&]+' 2>/dev/null)
        files_ref+=("${redir_files[@]}")
    fi

    # In-place editing (sed -i, perl -i)
    if [[ "${cmd}" =~ (sed|perl).*[[:space:]]-i ]]; then
        files_ref+=("$(echo "${cmd}" | awk '{print $NF}')")
    fi

    # File manipulation commands
    if [[ "${cmd}" =~ ^(touch|cp|mv|rsync|dd|tee|truncate)[[:space:]] ]]; then
        files_ref+=("$(echo "${cmd}" | awk '{print $NF}')")
    fi
}

track_file_changes() {
    local cmd="$1"
    local potential_files=()

    extract_target_files "${cmd}" potential_files

    for file_path in "${potential_files[@]}"; do
        [[ -z "$file_path" ]] && continue
        [[ ! -f "${file_path}" ]] && continue
        [[ "${file_path}" == "${ASH_TEMP_DIR}"* ]] && continue

        # Symlink safety
        if [[ -L "${file_path}" ]]; then
            agent_log "WARN" "Symlink detected: ${file_path} -> $(readlink "${file_path}")"
            continue
        fi

        local snapshot="${ASH_TEMP_DIR}/pre_$(basename "${file_path}").${BASHPID:-$$}_$(date +%s%N)"
        cp --no-dereference "${file_path}" "${snapshot}" 2>/dev/null || continue

        # Compare after command (deferred via PROMPT_COMMAND)
        ASH_PENDING_SNAPSHOTS+=("${file_path}|${snapshot}")
    done
}

check_pending_file_changes() {
    local cmd="${1:-unknown}"
    # Redact before this ever leaves the process — file-change events were
    # previously emitted with the raw, unredacted command line (see
    # emit_file_event below), bypassing the same redaction applied to
    # command_start events.
    cmd=$(redact_sensitive_data "$cmd")

    # File changes detected at the next prompt belong to the command that
    # caused them, not to a new trace.
    if [[ -n "$ASH_LAST_COMMAND_TRACE_ID" ]]; then
        ASH_CURRENT_TRACE_ID="$ASH_LAST_COMMAND_TRACE_ID"
    fi

    for entry in "${ASH_PENDING_SNAPSHOTS[@]:-}"; do
        [[ -z "$entry" ]] && continue
        local file_path="${entry%%|*}"
        local snapshot="${entry##*|}"

        if [[ ! -f "${file_path}" ]]; then
            emit_file_event "file_delete" "${file_path}" "" "${cmd}" ""
        elif ! diff -q "${snapshot}" "${file_path}" >/dev/null 2>&1; then
            local diff_content
            diff_content=$(diff -u "${snapshot}" "${file_path}" 2>/dev/null | head -c 10240 || true)
            # The diff body itself can contain the exact secret bytes that
            # were written to the file (e.g. `echo "API_KEY=..." >> file`);
            # redact it the same way the command line is redacted.
            diff_content=$(redact_sensitive_data "$diff_content")
            emit_file_event "file_modify" "${file_path}" "" "${cmd}" "${diff_content}"
        fi
        rm -f "${snapshot}"
    done
    ASH_PENDING_SNAPSHOTS=()
    # File events have been emitted; later events are not part of this trace.
    ASH_CURRENT_TRACE_ID=""
}

emit_file_event() {
    local event_type="$1"
    local file_path="$2"
    local file_path_prev="$3"
    local command="$4"
    local diff_content="$5"

    local extra
    if command -v jq >/dev/null 2>&1; then
        extra=$(jq -n -c \
            --arg cmd "$command" \
            --arg fp "$file_path" \
            --arg dc "$diff_content" \
            --arg pspid "$ASH_LAST_COMMAND_SPAN_ID" \
            '{command: $cmd, file_path: $fp, diff_content: $dc, source: "bash-diff"} +
             (if $pspid == "" then {} else {parent_span_id: $pspid} end)')
    else
        local escaped_diff
        escaped_diff=$(echo "$diff_content" | head -c 1024 | tr '\n' ' ' | sed 's/"/\\"/g')
        extra="{\"command\":\"$command\",\"file_path\":\"$file_path\",\"diff_content\":\"$escaped_diff\",\"source\":\"bash-diff\""
        if [[ -n "$ASH_LAST_COMMAND_SPAN_ID" ]]; then
            extra+=",\"parent_span_id\":\"$ASH_LAST_COMMAND_SPAN_ID\""
        fi
        extra+="}"
    fi
    emit_event "$event_type" "$extra"
}

ASH_PENDING_SNAPSHOTS=()

# ─── Main Command Logging ────��───────────────────────────────────────────────
# The DEBUG trap handler and the body are deliberately separate. The handler
# sets ASH_DEBUG_DEPTH before calling the body so the external commands the
# body runs (`date`, `jq`, `sha256sum`, `flock`, `sed`, ...) cannot re-enter
# through the same DEBUG trap. The old prefix-only guard could not cover
# those commands, which is why sourcing the agent hung (issue #6).
_log_command_impl() {
    # Skip ASH's own internal commands. The depth guard already prevents
    # recursion; this is a cheap early-out for the prompt hook and the
    # handler itself, whose names are known.
    [[ "${BASH_COMMAND}" =~ ^(_log_command_impl|log_command|_ash_debug_trap|ash_prompt_command|safe_log_write|emit_event|hash_chain|spool_|agent_log|rate_limit|redact_|check_pending|track_file|return)([[:space:]]|$) ]] && return 0
    [[ "${BASH_COMMAND}" == ":" ]] && return 0

    # Rate limiting
    if ! rate_limit_check; then
        if [[ $((COMMAND_COUNTER % 100)) -eq 0 ]]; then
            agent_log "WARN" "Rate limited: $COMMAND_COUNTER commands/sec"
        fi
        return 0
    fi

    # The EXIT trap's first command fires the DEBUG trap with the last
    # command's stale BASH_COMMAND, which used to produce a duplicate event
    # for the final command of every session. Suppress only an identical
    # command within a very short window; legitimate repeated commands are
    # normally separated by more than this.
    local now_us
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        now_us="${EPOCHREALTIME/./}"
    else
        now_us=$(($(date +%s%N) / 1000))
    fi
    if [[ -n "${ASH_LAST_LOGGED_US:-}" && "${BASH_COMMAND}" == "${ASH_LAST_LOGGED_COMMAND:-}" ]] &&
        ((now_us - ASH_LAST_LOGGED_US < 250000)); then
        return 0
    fi
    ASH_LAST_LOGGED_COMMAND="${BASH_COMMAND}"
    ASH_LAST_LOGGED_US="$now_us"

    local cmd
    cmd=$(redact_sensitive_data "${BASH_COMMAND}")

    # Track potential file changes
    track_file_changes "${BASH_COMMAND}"

    # A command gets one trace. command_start is its root span; related
    # privilege/file events and a failing command_end are children.
    ASH_CURRENT_TRACE_ID=$(new_trace_id)

    # Build extra fields. Capture BASH_SUBSHELL and BASH_LINENO before the
    # command substitution: inside $(jq ...) they report the substitution's
    # own values, which made every event claim bash_subshell: 1.
    local bash_subshell="${BASH_SUBSHELL:-0}"
    local lineno="${BASH_LINENO[0]:-0}"
    local extra
    if command -v jq >/dev/null 2>&1; then
        extra=$(jq -n -c \
            --arg cmd "$cmd" \
            --argjson sub "$bash_subshell" \
            --argjson lineno "$lineno" \
            '{command: $cmd, bash_subshell: $sub, lineno: $lineno}')
    else
        extra="{\"command\":\"$cmd\",\"bash_subshell\":$bash_subshell,\"lineno\":$lineno}"
    fi

    emit_event "command_start" "$extra"
    ASH_LAST_COMMAND_TRACE_ID="$ASH_CURRENT_TRACE_ID"
    ASH_LAST_COMMAND_SPAN_ID="$ASH_LAST_EVENT_SPAN_ID"

    # Privilege escalation detection
    if [[ "${BASH_COMMAND}" =~ ^(sudo|su|doas)[[:space:]] ]]; then
        local priv_extra
        if command -v jq >/dev/null 2>&1; then
            priv_extra=$(jq -n -c \
                --arg cmd "$cmd" \
                --arg pspid "$ASH_LAST_COMMAND_SPAN_ID" \
                '{command: $cmd, risk_flag: "privilege_escalation", parent_span_id: $pspid}')
        else
            priv_extra="{\"command\":\"$cmd\",\"risk_flag\":\"privilege_escalation\",\"parent_span_id\":\"$ASH_LAST_COMMAND_SPAN_ID\"}"
        fi
        emit_event "privilege_escalation" "$priv_extra"
    fi

    # Do not let this trace leak into the next unrelated event (session end,
    # audit or container events). Prompt-time file events re-select it from
    # ASH_LAST_COMMAND_TRACE_ID before emitting.
    ASH_CURRENT_TRACE_ID=""
    return 0
}

log_command() {
    if ((ASH_DEBUG_DEPTH > 0)); then return 0; fi
    ASH_DEBUG_DEPTH=1
    _log_command_impl || true
    return $((ASH_DEBUG_DEPTH = 0))
}

_ash_debug_trap() {
    if ((ASH_DEBUG_DEPTH > 0)); then return 0; fi
    ASH_DEBUG_DEPTH=1
    _log_command_impl || true
    # Run any pre-existing DEBUG trap the caller had. Keep the depth guard
    # active so the previous handler's own commands cannot re-enter ASH.
    _ash_run_prev_trap DEBUG || true
    return $((ASH_DEBUG_DEPTH = 0))
}

# ─── PROMPT_COMMAND Integration ──────────────────────────────────────────────
ash_prompt_command() {
    # The DEBUG trap fires for the prompt hook itself; the handler skips it by
    # name. Guard the hook's internal commands too so they are not logged as
    # user commands.
    if ((ASH_DEBUG_DEPTH > 0)); then return 0; fi
    ASH_DEBUG_DEPTH=1

    local last_exit=$?

    # Check for file changes from last command
    check_pending_file_changes "${BASH_COMMAND:-unknown}"

    # Emit command_end for last command if exit code is non-zero. Reuse the
    # last command's trace and parent the event to its command_start span.
    if [[ $last_exit -ne 0 ]]; then
        if [[ -n "$ASH_LAST_COMMAND_TRACE_ID" ]]; then
            ASH_CURRENT_TRACE_ID="$ASH_LAST_COMMAND_TRACE_ID"
        fi
        local extra
        if command -v jq >/dev/null 2>&1; then
            extra=$(jq -n -c \
                --argjson ec "$last_exit" \
                --arg pspid "$ASH_LAST_COMMAND_SPAN_ID" \
                '{exit_code: $ec, status: "failed"} +
                 (if $pspid == "" then {} else {parent_span_id: $pspid} end)')
        else
            extra="{\"exit_code\":$last_exit,\"status\":\"failed\""
            if [[ -n "$ASH_LAST_COMMAND_SPAN_ID" ]]; then
                extra+=",\"parent_span_id\":\"$ASH_LAST_COMMAND_SPAN_ID\""
            fi
            extra+="}"
        fi
        emit_event "command_end" "$extra"
    fi

    # The command trace ends here; a session end or another root event must
    # start a new trace instead of attaching to the last command.
    ASH_CURRENT_TRACE_ID=""
    return $((ASH_DEBUG_DEPTH = 0))
}

# ─── inotify Background Watcher ─────────────────────────────────────────────
start_file_watcher() {
    [[ "${INOTIFY_ENABLED}" != "true" ]] && return 0
    command -v inotifywait >/dev/null 2>&1 || return 0

    local watched_files_str=""
    for f in "${WATCHED_FILES[@]}"; do
        [[ -f "$f" || -d "$f" ]] && watched_files_str+="$f "
    done
    [[ -z "$watched_files_str" ]] && return 0

    inotifywait -m -e modify,create,delete,move,attrib ${watched_files_str} \
        --format '%T|%e|%w%f' --timefmt '%Y-%m-%dT%H:%M:%SZ' 2>/dev/null |
        while IFS='|' read -r timestamp event file; do
            local extra
            if command -v jq >/dev/null 2>&1; then
                extra=$(jq -n -c \
                    --arg fp "$file" \
                    --arg ev "$event" \
                    --arg src "inotify" \
                    '{file_path: $fp, inotify_event: $ev, source: $src}')
            else
                extra="{\"file_path\":\"$file\",\"inotify_event\":\"$event\",\"source\":\"inotify\"}"
            fi
            emit_event "file_${event,,}" "$extra"
        done >/dev/null 2>&1 &

    echo $! >"${ASH_TEMP_DIR}/inotify.pid"
    agent_log "INFO" "inotify watcher started (PID: $(cat "${ASH_TEMP_DIR}/inotify.pid"))"
}

# ─── Docker Container Monitoring ─────────────────────────────────────────────
start_container_monitor() {
    [[ "${DOCKER_MONITOR_ENABLED}" != "true" ]] && return 0
    command -v docker >/dev/null 2>&1 || return 0

    docker events --format '{{.Time}}|{{.Type}}|{{.Action}}|{{.Actor.ID}}|{{.Actor.Attributes.name}}|{{.Actor.Attributes.image}}' \
        2>/dev/null | while IFS='|' read -r ts type action container_id name image; do
        local extra
        if command -v jq >/dev/null 2>&1; then
            extra=$(jq -n -c \
                --arg src "docker-events" \
                --arg cid "$container_id" \
                --arg cname "$name" \
                --arg cimage "$image" \
                --arg action "$action" \
                '{source: $src, container_id: $cid, container_name: $cname, container_image: $cimage, docker_action: $action}')
        else
            extra="{\"source\":\"docker-events\",\"container_id\":\"$container_id\",\"container_name\":\"$name\",\"container_image\":\"$image\",\"docker_action\":\"$action\"}"
        fi
        emit_event "container_${action}" "$extra"
    done >/dev/null 2>&1 &

    echo $! >"${ASH_TEMP_DIR}/docker_events.pid"
    agent_log "INFO" "Docker event monitor started"
}

# ─── auditd Integration ───────────────────────────���──────────────────────────
start_auditd_monitor() {
    [[ "${AUDITD_ENABLED}" != "true" ]] && return 0
    command -v auditctl >/dev/null 2>&1 || return 0

    local audit_log="/var/log/audit/audit.log"
    [[ -f "$audit_log" ]] || return 0

    tail -F "$audit_log" 2>/dev/null | while read -r line; do
        if echo "$line" | grep -q 'key="ash_'; then
            local auid uid pid exe key
            auid=$(echo "$line" | grep -oP 'auid=\K\d+' || echo "0")
            uid=$(echo "$line" | grep -oP ' uid=\K\d+' || echo "0")
            pid=$(echo "$line" | grep -oP 'pid=\K\d+' || echo "0")
            exe=$(echo "$line" | grep -oP 'exe="\K[^"]*' || echo "unknown")
            key=$(echo "$line" | grep -oP 'key="\K[^"]*' || echo "unknown")

            local username
            username=$(getent passwd "$auid" 2>/dev/null | cut -d: -f1 || echo "uid=$auid")

            local event_type="command_start"
            case "$key" in
                ash_passwd | ash_shadow | ash_sshd | ash_root_ssh) event_type="file_modify" ;;
                ash_sudoers*) event_type="file_modify" ;;
                ash_crontab | ash_cron_d | ash_systemd) event_type="file_modify" ;;
            esac

            local extra
            if command -v jq >/dev/null 2>&1; then
                extra=$(jq -n -c \
                    --arg src "auditd" \
                    --arg u "$username" \
                    --argjson uid "$auid" \
                    --argjson pid "$pid" \
                    --arg cmd "$exe" \
                    --arg key "$key" \
                    '{source: $src, user: $u, uid: $uid, pid: $pid, command: $cmd, audit_key: $key}')
            else
                extra="{\"source\":\"auditd\",\"user\":\"$username\",\"uid\":$auid,\"pid\":$pid,\"command\":\"$exe\",\"audit_key\":\"$key\"}"
            fi
            emit_event "$event_type" "$extra"
        fi
    done >/dev/null 2>&1 &

    echo $! >"${ASH_TEMP_DIR}/auditd_tail.pid"
    agent_log "INFO" "auditd monitor started"
}

# ─── Crash Recovery ──��───────────────────────────────────────────────────────
save_state() {
    local state_json tmp_file

    if command -v jq >/dev/null 2>&1; then
        state_json=$(jq -n -c \
            --argjson pid "$$" \
            --argjson ppid "${PPID:-1}" \
            --arg sid "${ASH_SESSION_ID:-unknown}" \
            --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --argjson events "${EVENTS_LOGGED:-0}" \
            --arg temp "${ASH_TEMP_DIR}" \
            --arg log "${ASH_LOG_DIR}" \
            --arg mode "${ASH_AGENT_MODE:-unknown}" \
            '{pid: $pid, ppid: $ppid, session_id: $sid, started_at: $started, events_logged: $events, temp_dir: $temp, log_dir: $log, mode: $mode}')
    else
        state_json="{\"pid\":$$,\"ppid\":${PPID:-1},\"session_id\":\"${ASH_SESSION_ID}\",\"events_logged\":${EVENTS_LOGGED:-0},\"temp_dir\":\"${ASH_TEMP_DIR}\",\"log_dir\":\"${ASH_LOG_DIR}\",\"mode\":\"${ASH_AGENT_MODE:-unknown}\"}"
    fi

    # Write-then-rename: a concurrent reader must never see a half-written
    # state file, and a crash during the write must not leave a truncated one.
    tmp_file="${ASH_STATE_FILE}.tmp.${BASHPID:-$$}"
    if printf '%s\n' "$state_json" >"$tmp_file" 2>/dev/null; then
        chmod 600 "$tmp_file" 2>/dev/null || true
        mv -f "$tmp_file" "${ASH_STATE_FILE}" 2>/dev/null || rm -f "$tmp_file" 2>/dev/null || true
    fi
    return 0
}

recover_state() {
    # A missing state file is normal on first run. Flush anything a previous
    # session left in the spool and return; this function must not disable a
    # new session.
    if [[ ! -f "${ASH_STATE_FILE}" ]]; then
        spool_flush 2>/dev/null || true
        return 0
    fi

    local prev_pid prev_temp prev_session
    if command -v jq >/dev/null 2>&1; then
        prev_pid=$(jq -r '.pid // empty' "${ASH_STATE_FILE}" 2>/dev/null || echo "")
        prev_temp=$(jq -r '.temp_dir // empty' "${ASH_STATE_FILE}" 2>/dev/null || echo "")
        prev_session=$(jq -r '.session_id // empty' "${ASH_STATE_FILE}" 2>/dev/null || echo "")
    else
        prev_pid=$(grep -oP '"pid":\K\d+' "${ASH_STATE_FILE}" 2>/dev/null || echo "")
        prev_temp=$(grep -oP '"temp_dir":"\K[^"]*' "${ASH_STATE_FILE}" 2>/dev/null || echo "")
        prev_session=$(grep -oP '"session_id":"\K[^"]*' "${ASH_STATE_FILE}" 2>/dev/null || echo "")
    fi

    # Concurrent terminals are normal. The old code treated any live PID in
    # the shared state file as a reason to disable the *new* session, which
    # meant opening a second terminal silently turned monitoring off. Only
    # reap watchers when the previous shell is actually gone.
    if [[ -n "$prev_pid" && "$prev_pid" != "$$" ]] && kill -0 "$prev_pid" 2>/dev/null; then
        agent_log "INFO" "Concurrent ASH session detected (PID $prev_pid); keeping both"
        spool_flush 2>/dev/null || true
        return 0
    fi

    if [[ -n "$prev_temp" && "$prev_temp" != "${ASH_TEMP_DIR}" && -d "$prev_temp" ]]; then
        agent_log "INFO" "Reaping watchers from previous session (PID: ${prev_pid:-unknown}, session: ${prev_session:-unknown})"
        for pid_file in "${prev_temp}"/*.pid; do
            [[ -f "$pid_file" ]] || continue
            local orphan_pid
            orphan_pid=$(cat "$pid_file" 2>/dev/null || true)
            [[ -n "$orphan_pid" ]] && kill "$orphan_pid" 2>/dev/null || true
            rm -f "$pid_file" 2>/dev/null || true
        done
        # Only remove the directory if it is one of ours (mktemp template) or
        # the legacy /tmp/ash; never recursively delete an operator-supplied
        # ASH_TEMP_DIR.
        case "$prev_temp" in
            "${TMPDIR:-/tmp}"/ash.* | /tmp/ash) rm -rf "$prev_temp" 2>/dev/null || true ;;
        esac
    fi

    spool_flush 2>/dev/null || true
    return 0
}

# ─── systemd Watchdog ───────────────────────────────────────────────────────
# The old implementation called systemd-notify only from log_command(), so a
# host that went idle for WatchdogSec was restarted by systemd even though
# the agent was healthy.  A dedicated heartbeat is independent of traffic.
watchdog_kick() {
    [[ -z "${NOTIFY_SOCKET:-}" ]] && return 0
    systemd-notify WATCHDOG=1 2>/dev/null || true
}

start_watchdog() {
    [[ -z "${NOTIFY_SOCKET:-}" ]] && return 0
    command -v systemd-notify >/dev/null 2>&1 || return 0
    # Type=notify waits for this; NotifyAccess=all in the unit allows the
    # helper process to send it.
    systemd-notify --ready 2>/dev/null || true
    (
        while true; do
            watchdog_kick
            sleep "${ASH_WATCHDOG_INTERVAL}"
        done
    ) >/dev/null 2>&1 &
    echo "$!" >"${ASH_TEMP_DIR}/watchdog.pid" 2>/dev/null || true
}

# ─── Cleanup ─────────────────────────────────────────────────────────────────
cleanup_ash() {
    if ((ASH_CLEANUP_DONE > 0)); then return 0; fi
    ASH_CLEANUP_DONE=1

    # Remove the DEBUG trap before doing any work. Cleanup runs from the
    # EXIT/INT/TERM traps, and every command it executes would otherwise
    # re-enter the DEBUG handler, recursively emitting events while the
    # shell is trying to exit.
    ASH_DEBUG_DEPTH=1
    trap - DEBUG 2>/dev/null || true

    if [[ "${ASH_SESSION_STARTED:-0}" -eq 1 && "${ASH_SESSION_ENDED:-0}" -eq 0 ]]; then
        ASH_SESSION_ENDED=1
        emit_session_end 2>/dev/null || true
    fi

    # Kill background processes started by this session.
    for pid_file in "${ASH_TEMP_DIR}"/*.pid; do
        [[ -f "$pid_file" ]] || continue
        kill "$(cat "$pid_file" 2>/dev/null || true)" 2>/dev/null || true
        rm -f "$pid_file" 2>/dev/null || true
    done

    # Only remove a directory this process created. ASH_TEMP_DIR may be an
    # operator-supplied shared path; deleting its contents would destroy
    # unrelated files.
    if [[ "${ASH_TEMP_DIR_IS_SESSION:-0}" -eq 1 && -n "${ASH_TEMP_DIR:-}" ]]; then
        rm -rf "$ASH_TEMP_DIR" 2>/dev/null || true
    fi

    agent_log "INFO" "ASH agent stopped"
    return 0
}

# ─── Trap Management ─────────────────────────────────────────────────────────
# Extract the command portion of `trap -p SIG` without re-installing it.
_ash_prev_trap_cmd() {
    local sig="$1" line
    line=$(trap -p "$sig" 2>/dev/null) || return 1
    [[ -n "$line" ]] || return 1
    line="${line#trap -- }"
    line="${line% "$sig"}"
    eval "printf '%s' $line"
}

_ash_run_prev_trap() {
    local sig="$1" cmd=""

    # Use the trap captured before ASH installed its own handlers. Calling
    # `trap -p SIG` here would return ASH's current handler, which would then
    # call itself recursively (the EXIT handler re-entering on exit, the DEBUG
    # handler re-entering on every command).
    case "$sig" in
        EXIT) cmd="${_ASH_PREV_TRAP_EXIT:-}" ;;
        DEBUG) cmd="${_ASH_PREV_TRAP_DEBUG:-}" ;;
        ERR) cmd="${_ASH_PREV_TRAP_ERR:-}" ;;
        INT) cmd="${_ASH_PREV_TRAP_INT:-}" ;;
        TERM) cmd="${_ASH_PREV_TRAP_TERM:-}" ;;
    esac

    [[ -n "$cmd" ]] || return 0
    eval "$cmd"
}

ash_capture_caller_state() {
    _ASH_PREV_TRAP_EXIT=$(_ash_prev_trap_cmd EXIT) || true
    _ASH_PREV_TRAP_DEBUG=$(_ash_prev_trap_cmd DEBUG) || true
    _ASH_PREV_TRAP_ERR=$(_ash_prev_trap_cmd ERR) || true
    _ASH_PREV_TRAP_INT=$(_ash_prev_trap_cmd INT) || true
    _ASH_PREV_TRAP_TERM=$(_ash_prev_trap_cmd TERM) || true
    _ASH_PREV_BASH_ENV="${BASH_ENV:-}"
}

_ash_restore_previous_traps() {
    if [[ -n "$_ASH_PREV_TRAP_EXIT" ]]; then trap "$_ASH_PREV_TRAP_EXIT" EXIT; else trap - EXIT; fi
    if [[ -n "$_ASH_PREV_TRAP_DEBUG" ]]; then trap "$_ASH_PREV_TRAP_DEBUG" DEBUG; else trap - DEBUG; fi
    if [[ -n "$_ASH_PREV_TRAP_ERR" ]]; then trap "$_ASH_PREV_TRAP_ERR" ERR; else trap - ERR; fi
    if [[ -n "$_ASH_PREV_TRAP_INT" ]]; then trap "$_ASH_PREV_TRAP_INT" INT; else trap - INT; fi
    if [[ -n "$_ASH_PREV_TRAP_TERM" ]]; then trap "$_ASH_PREV_TRAP_TERM" TERM; else trap - TERM; fi
}

ash_restore_caller_options() {
    if ((_ASH_CALLER_ERREXIT)); then set -e; else set +e; fi
    if ((_ASH_CALLER_NOUNSET)); then set -u; else set +u; fi
    if ((_ASH_CALLER_PIPEFAIL)); then set -o pipefail; else set +o pipefail; fi
    if ((_ASH_CALLER_XTRACE)); then set -x; else set +x; fi
    if ((_ASH_CALLER_NOGLOB)); then set -f; else set +f; fi
    if ((_ASH_CALLER_ALLEXPORT)); then set -a; else set +a; fi
    if ((_ASH_CALLER_FUNCTRACE)); then set -T; else set +T; fi
    if ((_ASH_CALLER_ERRTRACE)); then set -E; else set +E; fi
}

ash_install_traps() {
    local mode="$1"

    trap '_ash_exit_trap' EXIT

    if [[ "$mode" == "sourced" ]]; then
        # functrace (`set -T`) is deliberately NOT enabled for sourced mode.
        # With it, every command inside the handler, every command substitution
        # and every background subshell re-enters the trap; that is issue #6.
        # Top-level user commands are still captured, which is what an
        # interactive shell actually needs. Full function/subshell coverage is
        # the job of the auditd layer, not the DEBUG trap.
        #
        # If the caller already enabled functrace for its own reasons, do not
        # install the DEBUG trap at all: restoring `-T` would make the handler
        # re-enter itself. Monitoring is disabled for that session instead of
        # hanging or killing the caller's shell.
        if [[ $- == *T* ]]; then
            _ash_note "WARN" "functrace is enabled in the caller; ASH DEBUG monitoring is disabled for this session"
        else
            trap '_ash_debug_trap' DEBUG
        fi
    fi

    if [[ "$mode" == "direct" ]]; then
        trap '_ash_err_trap' ERR
        trap '_ash_int_trap' INT
        trap '_ash_term_trap' TERM
    fi
}

_ash_exit_trap() {
    ASH_DEBUG_DEPTH=1
    trap - DEBUG 2>/dev/null || true
    cleanup_ash 2>/dev/null || true
    _ash_run_prev_trap EXIT || true
}

_ash_err_trap() {
    agent_log "ERROR" "Command failed at line ${LINENO:-?}: ${BASH_COMMAND:-unknown}"
}

_ash_int_trap() {
    agent_log "WARN" "Received SIGINT"
    cleanup_ash 2>/dev/null || true
    exit 0
}

_ash_term_trap() {
    agent_log "WARN" "Received SIGTERM"
    cleanup_ash 2>/dev/null || true
    exit 0
}

# ─── Sourced-Shell Wrapper ───────────────────────────────────────────────────
# Contract: a sourced profile hook must never terminate the caller, never
# leave errexit/nounset/pipefail enabled on a failure path, and never return
# a non-zero status. `main` keeps its non-zero status only for direct
# execution, where the process owns the shell.
ash_source_init() {
    local rc=0

    ash_capture_caller_state

    # Do not let this file's strict-mode settings leak into the caller. main()
    # performs explicit checks on every step that can fail. functrace/errtrace
    # are deliberately left as the caller had them; enabling functrace makes
    # the DEBUG trap re-enter itself (issue #6).
    set +e +u +o pipefail

    if ! main "$@"; then
        rc=1
    fi

    if ((rc != 0)); then
        ASH_INIT_FAILED=1
        ASH_DISABLED=true
        export ASH_DISABLED
        _ash_note "ERROR" "ASH initialization failed; monitoring is disabled for this session"
        ash_restore_caller_options false
        _ash_restore_previous_traps
        if [[ -n "${_ASH_PREV_BASH_ENV:-}" ]]; then
            export BASH_ENV="$_ASH_PREV_BASH_ENV"
        else
            unset BASH_ENV 2>/dev/null || true
        fi
        return 0
    fi

    ash_restore_caller_options true

    # Only replace BASH_ENV when it was unset or already points at ASH.
    # Clobbering another tool's BASH_ENV would silently break it.
    if [[ -z "${_ASH_PREV_BASH_ENV:-}" || "${_ASH_PREV_BASH_ENV}" == "${BASH_SOURCE[0]}" ]]; then
        export BASH_ENV="${BASH_SOURCE[0]}"
    else
        _ash_note "WARN" "BASH_ENV already set to $_ASH_PREV_BASH_ENV; not replacing it"
    fi

    export ASH_INITIALIZED="true"

    # Install the DEBUG/EXIT traps only after all setup is complete, and keep
    # the depth guard on while doing it so the wrapper's own `trap`/`export`
    # commands are not logged as user commands. The final `return 0` is
    # skipped by the handler's built-in-command prefix check.
    ASH_DEBUG_DEPTH=1
    ash_install_traps "sourced"
    if [[ $- == *i* ]]; then
        # Do not duplicate the hook if this file is sourced twice in one
        # shell (e.g. by both profile.d and bash.bashrc).
        case ";${PROMPT_COMMAND:-};" in
            *";ash_prompt_command;"*) ;;
            *) PROMPT_COMMAND="ash_prompt_command${PROMPT_COMMAND:+; ${PROMPT_COMMAND}}" ;;
        esac
    fi
    ASH_DEBUG_DEPTH=0
    return 0
}

# ─── Main Initialization ─────────���──────────────────────────────────────────
main() {
    local mode="${ASH_AGENT_MODE:-direct}"

    # Validate configuration. The sourced-shell wrapper turns a non-zero
    # return into "monitoring disabled for this session" and returns 0 to the
    # caller; direct execution lets the non-zero status exit the process.
    validate_config || return 1

    ash_prepare_log_files || {
        _ash_note "ERROR" "Cannot create ${ASH_EVENTS_FILE} or ${ASH_AGENT_LOG}"
        return 1
    }

    # Initialize subsystems. A broken hash chain is fatal: without it the
    # local log is no longer tamper-evident, so do not pretend to monitor.
    load_redaction_rules
    hash_chain_init || {
        _ash_note "ERROR" "Cannot initialise hash chain at ${ASH_HASH_FILE}"
        return 1
    }

    local spool_ok=0
    if spool_init; then
        spool_ok=1
    else
        _ash_note "WARN" "Kafka spool unavailable at ${ASH_SPOOL_DIR}; local logging continues"
    fi

    recover_state || true
    save_state

    # Start background monitors.
    start_file_watcher
    start_container_monitor
    start_auditd_monitor
    if [[ $spool_ok -eq 1 ]]; then
        spool_flush_timer
    fi

    # Emit session start. If this fails, local logging is broken; do not
    # install the DEBUG trap and pretend to monitor.
    if ! emit_session_start; then
        _ash_note "ERROR" "Cannot write session_start to ${ASH_EVENTS_FILE}"
        return 1
    fi
    ASH_SESSION_STARTED=1

    # Start the systemd liveness heartbeat (no-op outside systemd).
    start_watchdog

    # Set up traps last: every step above must succeed before the caller's
    # shell gets a DEBUG trap or PROMPT_COMMAND hook. Sourced mode installs
    # its traps in ash_source_init() after the caller's options are restored;
    # installing them here would log the wrapper's own setup commands.
    if [[ "$mode" == "direct" ]]; then
        ash_install_traps "$mode"
        export BASH_ENV="${BASH_SOURCE[0]}"
    fi

    agent_log "INFO" "ASH agent v${ASH_VERSION} started on $(hostname) (session: ${ASH_SESSION_ID}, mode: ${mode}, log: ${ASH_LOG_DIR})"
    return 0
}

# Run if sourced or executed.
#
# --functions-only: honored by src/agent/shells/zsh-integration.sh (and any
# other non-bash shell integration), which only wants the portable helper
# functions defined above (redact_sensitive_data, emit_event, hash chain,
# spool, ...) without bash-only side effects — the DEBUG trap,
# PROMPT_COMMAND, BASH_ENV propagation into child processes, or the
# background watchers, all of which the zsh integration sets up itself via
# preexec/precmd.
if [[ "${1:-}" == "--functions-only" ]]; then
    ASH_AGENT_MODE="functions"
    # Resolve writable locations so emit_event() works from a non-bash shell
    # whose configured paths are root-owned. Failures leave the paths as-is;
    # emit_event() reports the write failure rather than aborting the shell.
    ash_resolve_temp_dir || true
    ash_resolve_log_dir || true
    ash_resolve_spool_dir || true
    ash_resolve_paths
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
        exit 0
    fi
    return 0
elif [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Executed directly (e.g. systemd's ExecStart=/usr/local/bin/ash-agent)
    # rather than sourced: this is our own process, so a main() failure may
    # exit it. Strict mode is scoped to this process.
    ASH_AGENT_MODE="direct"
    set -euo pipefail
    set -E
    main "$@"
    exit $?
elif [[ "${ASH_INITIALIZED:-}" == "true" ]]; then
    # A child bash sourced this file through BASH_ENV after the parent agent
    # already initialized. Define the helper functions, but do not install a
    # second DEBUG trap, start watchers, or re-run main().
    ASH_AGENT_MODE="child"
    return 0
else
    # Sourced into someone else's shell (interactive login, or a child bash
    # process via BASH_ENV). The wrapper guarantees a zero return status and
    # restores the caller's options/traps on failure.
    ASH_AGENT_MODE="sourced"
    export ASH_INITIALIZED="true"
    ash_source_init "$@"
fi
