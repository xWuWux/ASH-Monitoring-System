#!/usr/bin/env bats
# Shell-level tests: syntax checks for every shipped script, plus checks that
# the non-bash integrations load without starting the bash-only agent main().

setup() {
    export REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
    export ASH_AGENT="$REPO_ROOT/src/agent/ash-agent.sh"
    export ZSH_INTEGRATION="$REPO_ROOT/src/agent/shells/zsh-integration.sh"
    export FISH_INTEGRATION="$REPO_ROOT/src/agent/shells/fish-integration.fish"
    export INSTALL_SCRIPT="$REPO_ROOT/scripts/install.sh"
    export ASH_LOG_DIR="$BATS_TEST_TMPDIR/log"
    export ASH_TEMP_DIR="$BATS_TEST_TMPDIR/tmp"
    export ASH_SPOOL_DIR="$BATS_TEST_TMPDIR/spool"
    export ASH_CONFIG_DIR="$BATS_TEST_TMPDIR/conf"
    mkdir -p "$ASH_LOG_DIR" "$ASH_TEMP_DIR" "$ASH_CONFIG_DIR"
    mkdir -p "$ASH_SPOOL_DIR/pending" "$ASH_SPOOL_DIR/sent"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
}

@test "every bash script passes bash -n" {
    status=0
    while IFS= read -r -d '' script; do
        [[ "$script" == *"zsh-integration.sh" ]] && continue
        bash -n "$script" || status=1
    done < <(find "$REPO_ROOT/src" "$REPO_ROOT/scripts" "$REPO_ROOT/tests" \
        -type f -name "*.sh" -print0)
    [[ $status -eq 0 ]]
}

@test "zsh integration passes zsh -n" {
    command -v zsh >/dev/null 2>&1 || skip "zsh is not installed"
    run zsh -n "$ZSH_INTEGRATION"
    [[ $status -eq 0 ]]
}

@test "fish integration passes fish -n" {
    command -v fish >/dev/null 2>&1 || skip "fish is not installed"
    run fish -n "$FISH_INTEGRATION"
    [[ $status -eq 0 ]]
}

@test "fish integration defines its preexec and postexec hooks" {
    command -v fish >/dev/null 2>&1 || skip "fish is not installed"
    run fish -c "source '$FISH_INTEGRATION'; functions -q ash_preexec; and functions -q ash_postexec"
    [[ $status -eq 0 ]]
}

@test "zsh integration loads and registers its hooks" {
    command -v zsh >/dev/null 2>&1 || skip "zsh is not installed"
    run env ASH_AGENT_PATH="$ASH_AGENT" ASH_LOG_DIR="$ASH_LOG_DIR" \
        ASH_TEMP_DIR="$ASH_TEMP_DIR" ASH_SPOOL_DIR="$ASH_SPOOL_DIR" \
        zsh -f -c "source '$ZSH_INTEGRATION'; whence -w _ash_preexec; whence -w _ash_precmd"
    [[ $status -eq 0 ]]
    [[ "$output" == *"_ash_preexec: function"* ]]
    [[ "$output" == *"_ash_precmd: function"* ]]
}

@test "--functions-only defines the public helpers without starting main" {
    run env ASH_LOG_DIR="$ASH_LOG_DIR" ASH_TEMP_DIR="$ASH_TEMP_DIR" \
        ASH_SPOOL_DIR="$ASH_SPOOL_DIR" ASH_CONFIG_DIR="$ASH_CONFIG_DIR" \
        KAFKA_ENABLED=false INOTIFY_ENABLED=false \
        /bin/bash --noprofile --norc -c '
            source "$1" --functions-only
            trap - DEBUG RETURN ERR EXIT 2>/dev/null || true
            for fn in redact_sensitive_data hash_chain_init hash_chain_append \
                verify_hash_chain spool_init spool_write spool_flush emit_event; do
                declare -F "$fn" >/dev/null || { echo "missing: $fn"; exit 1; }
            done
            [[ -z "${ASH_INITIALIZED:-}" ]] || { echo "main ran"; exit 1; }
            [[ ! -f "$ASH_TEMP_DIR/spool_flush.pid" ]] || { echo "timer started"; exit 1; }
            echo "functions-only-ok"
        ' _ "$ASH_AGENT"
    [[ $status -eq 0 ]]
    [[ "$output" == *"functions-only-ok"* ]]
}

@test "installer prints usage and exits non-zero for an unknown action" {
    run bash "$INSTALL_SCRIPT" definitely-not-an-action
    [[ $status -eq 1 ]]
    [[ "$output" == *"Usage:"* ]]
}

@test "installer keeps its documented entry points" {
    run grep -q '^case "${1:-install}" in' "$INSTALL_SCRIPT"
    [[ $status -eq 0 ]]
    run grep -q 'uninstall | --uninstall' "$INSTALL_SCRIPT"
    [[ $status -eq 0 ]]
    run grep -q 'upgrade | --upgrade' "$INSTALL_SCRIPT"
    [[ $status -eq 0 ]]
}
