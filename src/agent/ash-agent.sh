#!/bin/bash
# ASH (Again SHell) Monitoring Agent v2.2
# Production-grade shell activity monitoring with structured events,
# tamper-evident logging, crash recovery, and multi-layer monitoring.

set -euo pipefail
set -T  # functrace — inherit DEBUG/ERR traps into functions and subshells
set -E  # errtrace — inherit ERR trap into functions and subshells

readonly ASH_VERSION="2.2.0"

# ─── Configuration ───────────────────────────────────────────────────────────
ASH_CONFIG_DIR="${ASH_CONFIG_DIR:-/etc/ash}"
ASH_LOG_DIR="${ASH_LOG_DIR:-/var/log/ash}"
ASH_TEMP_DIR="${ASH_TEMP_DIR:-/tmp/ash}"
ASH_SPOOL_DIR="${ASH_SPOOL_DIR:-/var/spool/ash}"
ASH_HASH_FILE="${ASH_LOG_DIR}/.hash_chain"
ASH_STATE_FILE="${ASH_TEMP_DIR}/agent_state.json"
ASH_AGENT_LOG="${ASH_LOG_DIR}/agent.log"
ASH_EVENTS_FILE="${ASH_LOG_DIR}/events.jsonl"
ASH_REDACTION_CONFIG="${ASH_CONFIG_DIR}/redaction_rules.conf"

KAFKA_ENABLED="${KAFKA_ENABLED:-false}"
KAFKA_BROKER="${KAFKA_BROKER:-localhost:9092}"
KAFKA_TOPIC="${KAFKA_TOPIC:-ash-logs}"

INOTIFY_ENABLED="${INOTIFY_ENABLED:-true}"
AUDITD_ENABLED="${AUDITD_ENABLED:-false}"
DOCKER_MONITOR_ENABLED="${DOCKER_MONITOR_ENABLED:-false}"

MAX_COMMANDS_PER_SECOND="${MAX_COMMANDS_PER_SECOND:-50}"
MAX_OUTPUT_SIZE="${MAX_OUTPUT_SIZE:-1048576}"
ASH_SPOOL_MAX_SIZE="${ASH_SPOOL_MAX_SIZE:-1073741824}"

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

# ─── Load Configuration ───────���──────────────────────────────────────────────
[[ -f "${ASH_CONFIG_DIR}/ash.conf" ]] && source "${ASH_CONFIG_DIR}/ash.conf"

# ─── Agent Self-Logging ──────────────────────────────────────────────────────
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
    echo "$log_entry" >> "${ASH_AGENT_LOG}" 2>/dev/null || true
}

# ─── Configuration Validation ────────────────────────────────────────────────
validate_config() {
    local errors=0

    for dir_var in ASH_LOG_DIR ASH_TEMP_DIR ASH_SPOOL_DIR; do
        local dir_path="${!dir_var}"
        if [[ ! -d "$dir_path" ]]; then
            mkdir -p "$dir_path" 2>/dev/null || {
                echo "ERROR: Cannot create $dir_var=$dir_path" >&2
                ((errors++))
            }
        fi
        if [[ ! -w "$dir_path" ]]; then
            echo "ERROR: $dir_var=$dir_path is not writable" >&2
            ((errors++))
        fi
    done

    if [[ "${KAFKA_ENABLED}" == "true" ]]; then
        if [[ -z "${KAFKA_BROKER:-}" ]]; then
            echo "ERROR: KAFKA_ENABLED=true but KAFKA_BROKER is empty" >&2
            ((errors++))
        fi
        if [[ -z "${KAFKA_TOPIC:-}" ]]; then
            echo "ERROR: KAFKA_ENABLED=true but KAFKA_TOPIC is empty" >&2
            ((errors++))
        fi
    fi

    if [[ "${MAX_COMMANDS_PER_SECOND}" -lt 1 ]] 2>/dev/null; then
        echo "ERROR: MAX_COMMANDS_PER_SECOND must be >= 1" >&2
        ((errors++))
    fi

    if [[ "${MAX_OUTPUT_SIZE}" -lt 1024 ]] 2>/dev/null; then
        echo "ERROR: MAX_OUTPUT_SIZE must be >= 1024" >&2
        ((errors++))
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
    local temp_file="${ASH_TEMP_DIR}/write.$$.tmp"

    printf '%s\n' "$content" > "$temp_file" 2>/dev/null || return 1

    (
        flock -x 200
        cat "$temp_file" >> "$target_file"
        rm -f "$temp_file"
    ) 200>"${target_file}.lock" 2>/dev/null

    if [[ $? -ne 0 ]]; then
        printf '%s\n' "$content" >> "$target_file" 2>/dev/null || return 1
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
        done < "${ASH_REDACTION_CONFIG}"
    fi
}

redact_sensitive_data() {
    local input="$1"
    local output="${input}"

    for i in "${!REDACTION_PATTERNS[@]}"; do
        # sed's `s/pattern/replacement/` uses '/' as the delimiter. Patterns
        # matching URLs (e.g. `scheme://user:pass@host`) contain literal '/'
        # characters that would otherwise be misread as extra delimiters,
        # silently corrupting the substitution (and — via the `|| echo
        # "$output"` fallback below — silently skipping redaction entirely
        # instead of failing loudly). Escape '/' in both pattern and
        # replacement before building the sed command.
        local pat="${REDACTION_PATTERNS[$i]//\//\\/}"
        local rep="${REDACTION_REPLACEMENTS[$i]//\//\\/}"
        output=$(echo "$output" | sed -E "s/${pat}/${rep}/gI" 2>/dev/null || echo "$output")
    done
    echo "$output"
}

# ─── Hash-Chained Append-Only Logs ─────────────────────────────��────────────
hash_chain_init() {
    if [[ ! -f "${ASH_HASH_FILE}" ]]; then
        echo "0000000000000000000000000000000000000000000000000000000000000000" > "${ASH_HASH_FILE}"
        chmod 400 "${ASH_HASH_FILE}" 2>/dev/null || true
    fi
}

hash_chain_append() {
    local event_json="$1"
    local prev_hash
    prev_hash=$(tail -1 "${ASH_HASH_FILE}" 2>/dev/null || echo "0000000000000000000000000000000000000000000000000000000000000000")
    local combined="${prev_hash}${event_json}"
    local current_hash
    current_hash=$(printf '%s' "$combined" | sha256sum | cut -d' ' -f1)

    # Add hash fields to event JSON
    local signed_event
    if command -v jq >/dev/null 2>&1; then
        signed_event=$(echo "$event_json" | jq -c --arg ph "$prev_hash" --arg eh "$current_hash" '. + {prev_hash: $ph, event_hash: $eh}')
    else
        signed_event="${event_json%\}},\"prev_hash\":\"${prev_hash}\",\"event_hash\":\"${current_hash}\"}"
    fi

    echo "$current_hash" >> "${ASH_HASH_FILE}"
    echo "$signed_event"
}

verify_hash_chain() {
    local log_file="${1:-${ASH_EVENTS_FILE}}"
    local prev_hash="0000000000000000000000000000000000000000000000000000000000000000"
    local line_num=0
    local errors=0

    while IFS= read -r line; do
        ((line_num++))
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
            ((errors++))
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
            ((errors++))
        fi
        prev_hash="$stored_hash"
    done < "$log_file"

    if [[ $errors -eq 0 ]]; then
        echo "PASS: All $line_num entries verified successfully"
    else
        echo "FAIL: $errors integrity errors found in $line_num entries"
    fi
    return $errors
}

# ─── Local Spool Queue ───────────────────────────────────────────────────────
spool_init() {
    mkdir -p "${ASH_SPOOL_DIR}/pending" "${ASH_SPOOL_DIR}/sent"
    chmod 700 "${ASH_SPOOL_DIR}"
}

spool_write() {
    local event_json="$1"
    local spool_file="${ASH_SPOOL_DIR}/pending/$(date +%s%N)_$$"
    printf '%s\n' "$event_json" > "$spool_file" 2>/dev/null || return 1

    # Enforce max spool size
    local spool_size
    spool_size=$(du -sb "${ASH_SPOOL_DIR}/pending" 2>/dev/null | cut -f1)
    if [[ ${spool_size:-0} -gt ${ASH_SPOOL_MAX_SIZE} ]]; then
        ls -t "${ASH_SPOOL_DIR}/pending/" | tail -n +100 | \
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
            ((sent++))
        else
            ((failed++))
            break
        fi
    done

    # Clean sent files older than 1 hour
    find "${ASH_SPOOL_DIR}/sent/" -type f -mmin +60 -delete 2>/dev/null || true
    return $failed
}

spool_flush_timer() {
    while true; do
        sleep 30
        spool_flush 2>/dev/null || true
    done &
    echo $! > "${ASH_TEMP_DIR}/spool_flush.pid"
}

send_to_kafka_raw() {
    local message="$1"
    local max_retries=3
    local retry=0

    while [[ $retry -lt $max_retries ]]; do
        if printf '%s\n' "$message" | kafka-console-producer.sh \
            --broker-list "${KAFKA_BROKER}" \
            --topic "${KAFKA_TOPIC}" \
            --request-required-acks 1 \
            2>/dev/null; then
            return 0
        fi
        ((retry++))
        sleep $((retry * 2))
    done
    return 1
}

# ─── Structured Event Emission ───��───────────────────────────────────────────
emit_event() {
    local event_type="$1"
    shift
    local extra_fields="${1:-}"

    local event_id timestamp hostname user uid session_id pid ppid tty cwd
    event_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "$$-$(date +%s%N)")
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
    hostname=$(hostname)
    user="${USER:-unknown}"
    uid="${EUID:-$(id -u)}"
    session_id="${ASH_SESSION_ID:-unknown}"
    pid="$$"
    ppid="${PPID:-1}"
    tty=$(tty 2>/dev/null || echo "unknown")
    cwd="${PWD}"

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
                ssh_connection: $ssh
            }')

        # Merge extra fields if provided
        if [[ -n "$extra_fields" ]]; then
            event=$(echo "$event" | jq -c --argjson extra "$extra_fields" '. + $extra')
        fi
    else
        event="{\"event_id\":\"$event_id\",\"schema_version\":\"1.0\",\"timestamp\":\"$timestamp\",\"hostname\":\"$hostname\",\"source\":\"bash-debug\",\"event_type\":\"$event_type\",\"user\":\"$user\",\"uid\":$uid,\"session_id\":\"$session_id\",\"pid\":$pid,\"ppid\":$ppid,\"tty\":\"$tty\",\"cwd\":\"$cwd\",\"ssh_connection\":\"$ASH_SSH_CONNECTION\"}"

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

    # Hash chain signing
    local signed_event
    signed_event=$(hash_chain_append "$event")

    # Write to local events log
    safe_log_write "$signed_event"

    # Forward to Kafka spool
    if [[ "${KAFKA_ENABLED}" == "true" ]]; then
        spool_write "$signed_event"
    fi

    ((EVENTS_LOGGED++))
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
    local duration=$(( $(date +%s) - ${ASH_START_TIME} ))
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
    spool_flush 2>/dev/null || true
}

# ─── Rate Limiting ────────────��──────────────────────────────────────────────
rate_limit_check() {
    local current_second
    current_second=$(date +%s)

    if [[ $current_second -eq $LAST_SECOND ]]; then
        ((COMMAND_COUNTER++))
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

        local snapshot="${ASH_TEMP_DIR}/pre_$(basename "${file_path}").$$_$(date +%s%N)"
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
            '{command: $cmd, file_path: $fp, diff_content: $dc, source: "bash-diff"}')
    else
        local escaped_diff
        escaped_diff=$(echo "$diff_content" | head -c 1024 | tr '\n' ' ' | sed 's/"/\\"/g')
        extra="{\"command\":\"$command\",\"file_path\":\"$file_path\",\"diff_content\":\"$escaped_diff\",\"source\":\"bash-diff\"}"
    fi
    emit_event "$event_type" "$extra"
}

ASH_PENDING_SNAPSHOTS=()

# ─── Main Command Logging ────��───────────────────────────────────────────────
log_command() {
    # Skip ASH's own internal commands
    [[ "${BASH_COMMAND}" =~ ^(log_command|safe_log_write|emit_event|hash_chain|spool_|agent_log|rate_limit|redact_|check_pending|track_file) ]] && return 0
    [[ "${BASH_COMMAND}" == ":" ]] && return 0

    # Rate limiting
    if ! rate_limit_check; then
        if [[ $((COMMAND_COUNTER % 100)) -eq 0 ]]; then
            agent_log "WARN" "Rate limited: $COMMAND_COUNTER commands/sec"
        fi
        return 0
    fi

    local cmd
    cmd=$(redact_sensitive_data "${BASH_COMMAND}")

    local start_time
    start_time=$(date +%s%N 2>/dev/null || echo "0")

    # Track potential file changes
    track_file_changes "${BASH_COMMAND}"

    # Build extra fields
    local extra
    if command -v jq >/dev/null 2>&1; then
        extra=$(jq -n -c \
            --arg cmd "$cmd" \
            --argjson sub "${BASH_SUBSHELL:-0}" \
            --argjson lineno "${BASH_LINENO[0]:-0}" \
            '{command: $cmd, bash_subshell: $sub, lineno: $lineno}')
    else
        extra="{\"command\":\"$cmd\",\"bash_subshell\":${BASH_SUBSHELL:-0},\"lineno\":${BASH_LINENO[0]:-0}}"
    fi

    emit_event "command_start" "$extra"

    # Privilege escalation detection
    if [[ "${BASH_COMMAND}" =~ ^(sudo|su|doas)[[:space:]] ]]; then
        local priv_extra
        if command -v jq >/dev/null 2>&1; then
            priv_extra=$(jq -n -c --arg cmd "$cmd" '{command: $cmd, risk_flag: "privilege_escalation"}')
        else
            priv_extra="{\"command\":\"$cmd\",\"risk_flag\":\"privilege_escalation\"}"
        fi
        emit_event "privilege_escalation" "$priv_extra"
    fi

    # Systemd watchdog kick
    systemd-notify WATCHDOG=1 2>/dev/null || true
}

# ─── PROMPT_COMMAND Integration ──────────────────────────────────────────────
ash_prompt_command() {
    local last_exit=$?

    # Check for file changes from last command
    check_pending_file_changes "${BASH_COMMAND:-unknown}"

    # Emit command_end for last command if exit code is non-zero
    if [[ $last_exit -ne 0 ]]; then
        local extra
        if command -v jq >/dev/null 2>&1; then
            extra=$(jq -n -c --argjson ec "$last_exit" '{exit_code: $ec, status: "failed"}')
        else
            extra="{\"exit_code\":$last_exit,\"status\":\"failed\"}"
        fi
        emit_event "command_end" "$extra"
    fi
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
        --format '%T|%e|%w%f' --timefmt '%Y-%m-%dT%H:%M:%SZ' 2>/dev/null | \
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
    done &

    echo $! > "${ASH_TEMP_DIR}/inotify.pid"
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
    done &

    echo $! > "${ASH_TEMP_DIR}/docker_events.pid"
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
                ash_passwd|ash_shadow|ash_sshd|ash_root_ssh) event_type="file_modify" ;;
                ash_sudoers*) event_type="file_modify" ;;
                ash_crontab|ash_cron_d|ash_systemd) event_type="file_modify" ;;
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
    done &

    echo $! > "${ASH_TEMP_DIR}/auditd_tail.pid"
    agent_log "INFO" "auditd monitor started"
}

# ─── Crash Recovery ──��───────────────────────────────────────────────────────
save_state() {
    local state_json
    if command -v jq >/dev/null 2>&1; then
        state_json=$(jq -n -c \
            --argjson pid "$$" \
            --argjson ppid "${PPID:-1}" \
            --arg sid "${ASH_SESSION_ID:-unknown}" \
            --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --argjson events "${EVENTS_LOGGED:-0}" \
            '{pid: $pid, ppid: $ppid, session_id: $sid, started_at: $started, events_logged: $events}')
    else
        state_json="{\"pid\":$$,\"ppid\":${PPID:-1},\"session_id\":\"${ASH_SESSION_ID}\",\"events_logged\":${EVENTS_LOGGED:-0}}"
    fi
    echo "$state_json" > "${ASH_STATE_FILE}" 2>/dev/null || true
}

recover_state() {
    [[ ! -f "${ASH_STATE_FILE}" ]] && return 0

    local prev_pid
    if command -v jq >/dev/null 2>&1; then
        prev_pid=$(jq -r '.pid' "${ASH_STATE_FILE}" 2>/dev/null || echo "")
    else
        prev_pid=$(grep -oP '"pid":\K\d+' "${ASH_STATE_FILE}" 2>/dev/null || echo "")
    fi

    # Check if previous instance is still running
    if [[ -n "$prev_pid" ]] && kill -0 "$prev_pid" 2>/dev/null; then
        agent_log "ERROR" "Previous ASH agent (PID $prev_pid) still running"
        return 1
    fi

    agent_log "INFO" "Recovering from previous state (prev PID: $prev_pid)"

    # Kill orphaned background processes
    for pid_file in "${ASH_TEMP_DIR}"/*.pid; do
        [[ -f "$pid_file" ]] || continue
        local orphan_pid
        orphan_pid=$(cat "$pid_file")
        kill "$orphan_pid" 2>/dev/null || true
        rm -f "$pid_file"
    done

    # Flush pending spool
    spool_flush 2>/dev/null || true

    rm -f "${ASH_STATE_FILE}"
}

# ─── Prometheus Metrics ──────────────────────────────────────────────────────
write_prometheus_metrics() {
    local metrics_file="${ASH_TEMP_DIR}/ash_metrics.prom"
    cat > "$metrics_file" << EOF
# HELP ash_agent_events_total Total events logged by ASH agent
# TYPE ash_agent_events_total counter
ash_agent_events_total ${EVENTS_LOGGED:-0}
# HELP ash_agent_spool_pending Pending events in spool queue
# TYPE ash_agent_spool_pending gauge
ash_agent_spool_pending $(ls "${ASH_SPOOL_DIR}/pending/" 2>/dev/null | wc -l)
# HELP ash_agent_uptime_seconds Agent uptime in seconds
# TYPE ash_agent_uptime_seconds gauge
ash_agent_uptime_seconds $(($(date +%s) - ASH_START_TIME))
# HELP ash_agent_info Agent version and metadata
# TYPE ash_agent_info gauge
ash_agent_info{version="${ASH_VERSION}",hostname="$(hostname)"} 1
EOF
}

# ─── Cleanup ─────────────────────────────────────────────────────────────────
cleanup_ash() {
    emit_session_end 2>/dev/null || true

    # Kill background processes
    for pid_file in "${ASH_TEMP_DIR}"/*.pid; do
        [[ -f "$pid_file" ]] || continue
        kill "$(cat "$pid_file")" 2>/dev/null || true
    done

    rm -rf "${ASH_TEMP_DIR}"/* 2>/dev/null || true
    agent_log "INFO" "ASH agent stopped"
}

# ─── Signal Handlers ─────────────────────────────────────────────────────────
trap cleanup_ash EXIT
trap 'agent_log "WARN" "Received SIGTERM"; cleanup_ash; exit 0' SIGTERM
trap 'agent_log "WARN" "Received SIGINT"; cleanup_ash; exit 0' SIGINT
trap 'agent_log "ERROR" "Command failed at line $LINENO: $BASH_COMMAND"' ERR

# ─── Main Initialization ─────────���──────────────────────────────────────────
main() {
    # Validate configuration
    validate_config || exit 1

    # Initialize subsystems
    load_redaction_rules
    hash_chain_init
    spool_init
    recover_state || exit 1

    # Save current state
    save_state

    # Start background monitors
    start_file_watcher
    start_container_monitor
    start_auditd_monitor
    spool_flush_timer

    # Emit session start
    emit_session_start

    # Set up command trapping
    trap 'log_command' DEBUG

    # Integrate with PROMPT_COMMAND
    if [[ -z "${PROMPT_COMMAND:-}" ]]; then
        PROMPT_COMMAND="ash_prompt_command"
    else
        PROMPT_COMMAND="ash_prompt_command; ${PROMPT_COMMAND}"
    fi

    agent_log "INFO" "ASH agent v${ASH_VERSION} started on $(hostname) (session: ${ASH_SESSION_ID})"
}

# Run if sourced or executed.
#
# --functions-only: honored by src/agent/shells/zsh-integration.sh (and any
# other non-bash shell integration), which only wants the portable helper
# functions defined above (redact_sensitive_data, emit_event, hash chain,
# spool, ...) without bash-only side effects — the DEBUG trap,
# PROMPT_COMMAND, BASH_ENV propagation into child processes, or the
# background watchers, all of which the zsh integration sets up itself via
# preexec/precmd. Previously this flag was accepted by the caller but never
# implemented here, so sourcing from zsh silently ran the full bash-only
# main() anyway.
if [[ "${1:-}" == "--functions-only" ]]; then
    :
elif [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    export BASH_ENV="${BASH_SOURCE[0]}"
    main "$@"
elif [[ "${ASH_INITIALIZED:-}" != "true" ]]; then
    export ASH_INITIALIZED="true"
    export BASH_ENV="${BASH_SOURCE[0]}"
    main "$@"
fi
