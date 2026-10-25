#!/usr/bin/env bats
# Unit tests for the agent's systemd watchdog heartbeat.
#
# The old implementation only kicked the watchdog from log_command(), so an
# idle host was restarted by systemd. These tests use a fake
# systemd-notify so they do not need a live systemd PID 1.

setup() {
    export ASH_LOG_DIR="$BATS_TEST_TMPDIR/log"
    export ASH_TEMP_DIR="$BATS_TEST_TMPDIR/tmp"
    export ASH_SPOOL_DIR="$BATS_TEST_TMPDIR/spool"
    export ASH_CONFIG_DIR="$BATS_TEST_TMPDIR/conf"
    export ASH_HASH_FILE="$ASH_LOG_DIR/.hash_chain"
    export ASH_EVENTS_FILE="$ASH_LOG_DIR/events.jsonl"
    export ASH_AGENT_LOG="$ASH_LOG_DIR/agent.log"
    export ASH_WATCHDOG_INTERVAL=1
    mkdir -p "$ASH_LOG_DIR" "$ASH_TEMP_DIR" "$ASH_CONFIG_DIR"
    mkdir -p "$ASH_SPOOL_DIR/pending" "$ASH_SPOOL_DIR/sent"

    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/systemd-notify" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_NOTIFY_LOG"
SH
    chmod +x "$BATS_TEST_TMPDIR/bin/systemd-notify"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    export FAKE_NOTIFY_LOG="$BATS_TEST_TMPDIR/notify.log"

    source "${BATS_TEST_DIRNAME}/../../src/agent/ash-agent.sh" --functions-only 2>/dev/null || true
    trap - DEBUG RETURN ERR EXIT 2>/dev/null || true
    set +e
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
}

@test "watchdog_kick is a no-op outside systemd" {
    unset NOTIFY_SOCKET

    watchdog_kick

    [[ ! -s "$FAKE_NOTIFY_LOG" ]]
}

@test "watchdog_kick sends WATCHDOG=1 through systemd-notify" {
    export NOTIFY_SOCKET="$BATS_TEST_TMPDIR/notify.sock"

    watchdog_kick

    grep -Fq "WATCHDOG=1" "$FAKE_NOTIFY_LOG"
}

@test "start_watchdog sends READY and periodic WATCHDOG notifications" {
    export NOTIFY_SOCKET="$BATS_TEST_TMPDIR/notify.sock"

    start_watchdog
    sleep 1.2
    kill "$(cat "$ASH_TEMP_DIR/watchdog.pid")" 2>/dev/null || true

    grep -Fq -- "--ready" "$FAKE_NOTIFY_LOG"
    grep -Fq "WATCHDOG=1" "$FAKE_NOTIFY_LOG"
}
