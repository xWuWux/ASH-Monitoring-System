#!/bin/zsh
# ASH Zsh Integration — Source this from ~/.zshrc
# source /usr/local/share/ash/shells/zsh-integration.sh

ASH_AGENT_PATH="${ASH_AGENT_PATH:-/usr/local/bin/ash-agent}"

if [[ ! -f "$ASH_AGENT_PATH" ]]; then
    return 0
fi

# Load core functions from ash-agent (portable parts)
source "$ASH_AGENT_PATH" --functions-only 2>/dev/null || true

# Zsh uses preexec/precmd hooks instead of DEBUG trap
autoload -Uz add-zsh-hook

_ash_preexec() {
    local cmd="$1"
    ASH_LAST_COMMAND="$cmd"
    ASH_COMMAND_START=$(date +%s%N 2>/dev/null || date +%s)

    local redacted
    redacted=$(redact_sensitive_data "$cmd" 2>/dev/null || echo "$cmd")

    local extra
    if command -v jq >/dev/null 2>&1; then
        extra=$(jq -n -c --arg cmd "$redacted" '{command: $cmd}')
    else
        extra="{\"command\":\"$redacted\"}"
    fi
    emit_event "command_start" "$extra" 2>/dev/null || true
}

_ash_precmd() {
    local last_exit=$?

    if [[ -n "${ASH_LAST_COMMAND:-}" ]]; then
        local extra
        if command -v jq >/dev/null 2>&1; then
            extra=$(jq -n -c --argjson ec "$last_exit" '{exit_code: $ec}')
        else
            extra="{\"exit_code\":$last_exit}"
        fi
        emit_event "command_end" "$extra" 2>/dev/null || true
        unset ASH_LAST_COMMAND
    fi
}

add-zsh-hook preexec _ash_preexec
add-zsh-hook precmd _ash_precmd
