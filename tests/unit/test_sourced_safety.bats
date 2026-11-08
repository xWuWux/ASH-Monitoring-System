#!/usr/bin/env bats
# Regression tests for the sourced-shell contract (issue #5).
#
# ash-agent.sh is sourced directly into a user's login shell by
# /etc/profile.d/ash.sh. On any failure path it must:
#   * return status 0 to the caller;
#   * restore the caller's errexit/nounset/pipefail options;
#   * not leave ASH's DEBUG/EXIT traps installed;
#   * not set BASH_ENV.
# On success it may install a DEBUG trap and PROMPT_COMMAND, but it must not
# enable errexit/nounset/pipefail in the caller.

setup() {
    export AGENT="${BATS_TEST_DIRNAME}/../../src/agent/ash-agent.sh"
    export TMPROOT="$BATS_TEST_TMPDIR"
    export ASH_CONFIG_DIR="$TMPROOT/conf"
    mkdir -p "$ASH_CONFIG_DIR"
    cat >"$ASH_CONFIG_DIR/ash.conf" <<'CONF'
INOTIFY_ENABLED=false
KAFKA_ENABLED=false
AUDITD_ENABLED=false
DOCKER_MONITOR_ENABLED=false
CONF
    mkdir -p "$TMPROOT/log" "$TMPROOT/tmp" "$TMPROOT/spool"
}

teardown() {
    rm -rf "$TMPROOT"
}

# Run a bash script that sources the agent. The script is the first argument;
# the agent path is "$1" inside it.
run_sourced() {
    local script="$1"
    run env \
        ASH_LOG_DIR="${ASH_LOG_DIR_OVERRIDE:-$TMPROOT/log}" \
        ASH_TEMP_DIR="${ASH_TEMP_DIR_OVERRIDE:-$TMPROOT/tmp}" \
        ASH_SPOOL_DIR="${ASH_SPOOL_DIR_OVERRIDE:-$TMPROOT/spool}" \
        ASH_CONFIG_DIR="$ASH_CONFIG_DIR" \
        ASH_STRICT_PERMISSIONS="${ASH_STRICT_PERMISSIONS_OVERRIDE:-false}" \
        ASH_ALLOW_HOME_FALLBACK="${ASH_ALLOW_HOME_FALLBACK_OVERRIDE:-true}" \
        INOTIFY_ENABLED=false KAFKA_ENABLED=false \
        AUDITD_ENABLED=false DOCKER_MONITOR_ENABLED=false \
        timeout 15s bash --noprofile --norc -c "$script" _ "$AGENT"
}

@test "failed init returns 0 and never kills an errexit caller" {
    local blocker="$TMPROOT/not-a-directory"
    : >"$blocker"
    export ASH_LOG_DIR_OVERRIDE="$blocker/log"
    export ASH_SPOOL_DIR_OVERRIDE="$blocker/spool"
    export ASH_STRICT_PERMISSIONS_OVERRIDE=true
    export ASH_ALLOW_HOME_FALLBACK_OVERRIDE=false

    run_sourced '
        set -e
        source "$1"
        rc=$?
        [[ $rc -eq 0 ]] || { echo "source returned $rc"; exit 1; }
        [[ "${ASH_DISABLED:-}" == "true" ]] || { echo "not disabled"; exit 1; }
        false || true
        echo SURVIVED
    '

    [[ $status -eq 0 ]]
    [[ "$output" == *"SURVIVED"* ]]
    [[ "$output" == *"ASH_DISABLED"* || "$output" == *"SURVIVED"* ]]
}

@test "successful source restores the caller's options" {
    run_sourced '
        before_e=0; [[ $- == *e* ]] && before_e=1
        before_u=0; [[ $- == *u* ]] && before_u=1
        before_p=0; [[ -o pipefail ]] && before_p=1

        source "$1"
        [[ $? -eq 0 ]] || { echo "source failed"; exit 1; }

        after_e=0; [[ $- == *e* ]] && after_e=1
        after_u=0; [[ $- == *u* ]] && after_u=1
        after_p=0; [[ -o pipefail ]] && after_p=1

        [[ $before_e -eq $after_e ]] || { echo "errexit changed"; exit 1; }
        [[ $before_u -eq $after_u ]] || { echo "nounset changed"; exit 1; }
        [[ $before_p -eq $after_p ]] || { echo "pipefail changed"; exit 1; }

        false
        echo SURVIVED
    '

    [[ $status -eq 0 ]]
    [[ "$output" == *"SURVIVED"* ]]
}

@test "successful source does not enable errexit for a caller that had it off" {
    run_sourced '
        set +e +u +o pipefail
        source "$1"
        [[ $? -eq 0 ]]
        false
        echo SURVIVED
    '

    [[ $status -eq 0 ]]
    [[ "$output" == *"SURVIVED"* ]]
}

@test "--functions-only changes no options and installs no traps" {
    run_sourced '
        before_flags="$-"
        before_exit="$(trap -p EXIT)"
        before_debug="$(trap -p DEBUG)"

        source "$1" --functions-only

        [[ "$before_flags" == "$-" ]] || { echo "flags changed"; exit 1; }
        [[ "$before_exit" == "$(trap -p EXIT)" ]] || { echo "EXIT trap changed"; exit 1; }
        [[ "$before_debug" == "$(trap -p DEBUG)" ]] || { echo "DEBUG trap changed"; exit 1; }
        [[ -z "${ASH_INITIALIZED:-}" ]] || { echo "main ran"; exit 1; }
        echo FUNCTIONS_ONLY_OK
    '

    [[ $status -eq 0 ]]
    [[ "$output" == *"FUNCTIONS_ONLY_OK"* ]]
}

@test "a pre-existing EXIT trap is still run after ASH cleanup" {
    run_sourced '
        trap "echo PREV_EXIT_RAN" EXIT
        source "$1"
        echo BODY_RAN
    '

    [[ $status -eq 0 ]]
    [[ "$output" == *"BODY_RAN"* ]]
    [[ "$output" == *"PREV_EXIT_RAN"* ]]
}

@test "failed init does not leave BASH_ENV pointing at the agent" {
    local blocker="$TMPROOT/not-a-directory"
    : >"$blocker"
    export ASH_LOG_DIR_OVERRIDE="$blocker/log"
    export ASH_SPOOL_DIR_OVERRIDE="$blocker/spool"
    export ASH_STRICT_PERMISSIONS_OVERRIDE=true
    export ASH_ALLOW_HOME_FALLBACK_OVERRIDE=false

    run_sourced '
        unset BASH_ENV
        source "$1"
        [[ $? -eq 0 ]]
        [[ -z "${BASH_ENV:-}" ]] || { echo "BASH_ENV=$BASH_ENV"; exit 1; }
        echo BASH_ENV_CLEAN
    '

    [[ $status -eq 0 ]]
    [[ "$output" == *"BASH_ENV_CLEAN"* ]]
}
