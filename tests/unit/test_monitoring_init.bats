#!/usr/bin/env bats
# Fail-closed and rendering tests for scripts/monitoring-init.sh.
#
# Validation failures happen before the root check, so most tests run as the
# CI user. The full render/ownership test uses passwordless sudo when the
# suite is not already root, because the rendered files are deliberately owned
# by the container UIDs (65534/472/10001).

setup() {
    INIT="${BATS_TEST_DIRNAME}/../../scripts/monitoring-init.sh"
    export ASH_METRICS_ENABLED=true
    export ASH_METRICS_TOKEN=abcdef0123456789abcdef
    export ASH_ALERTMANAGER_WEBHOOK_URL=https://example.invalid/ash
    unset ASH_GRAFANA_ADMIN_PASSWORD ASH_MONITORING_RUNTIME_DIR ASH_MONITORING_DATA_DIR

    CAN_ROOT=false
    if [[ $EUID -eq 0 ]] || sudo -n true 2>/dev/null; then
        CAN_ROOT=true
    fi
}

teardown() {
    if [[ "$CAN_ROOT" == "true" && $EUID -ne 0 ]]; then
        sudo -n rm -rf "$BATS_TEST_TMPDIR" 2>/dev/null || true
    fi
}

# run_as_root COMMAND... -> run directly as root or through passwordless sudo.
run_as_root() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    else
        sudo -n "$@"
    fi
}

@test "monitoring-init --help works without root" {
    run bash "$INIT" --help
    [[ $status -eq 0 ]]
    [[ "$output" == *"monitoring-init.sh"* ]]
    [[ "$output" == *"--runtime-dir"* ]]
}

@test "monitoring-init rejects an unknown argument" {
    run bash "$INIT" --not-a-real-option
    [[ $status -ne 0 ]]
    [[ "$output" == *"unknown argument"* ]]
}

@test "monitoring-init refuses to render without an alert webhook" {
    run env -u ASH_ALERTMANAGER_WEBHOOK_URL \
        ASH_METRICS_ENABLED=true ASH_METRICS_TOKEN="$ASH_METRICS_TOKEN" \
        bash "$INIT" \
        --runtime-dir "$BATS_TEST_TMPDIR/runtime" \
        --data-dir "$BATS_TEST_TMPDIR/data"
    [[ $status -ne 0 ]]
    [[ "$output" == *"ASH_ALERTMANAGER_WEBHOOK_URL is required"* ]]
    [[ ! -e "$BATS_TEST_TMPDIR/runtime" ]]
    [[ ! -e "$BATS_TEST_TMPDIR/data" ]]
}

@test "monitoring-init refuses disabled API metrics" {
    run env ASH_METRICS_ENABLED=false ASH_METRICS_TOKEN="$ASH_METRICS_TOKEN" \
        bash "$INIT" \
        --runtime-dir "$BATS_TEST_TMPDIR/runtime" \
        --data-dir "$BATS_TEST_TMPDIR/data"
    [[ $status -ne 0 ]]
    [[ "$output" == *"ASH_METRICS_ENABLED must be true"* ]]
}

@test "monitoring-init refuses a short metrics token" {
    run env ASH_METRICS_TOKEN=short \
        bash "$INIT" \
        --runtime-dir "$BATS_TEST_TMPDIR/runtime" \
        --data-dir "$BATS_TEST_TMPDIR/data"
    [[ $status -ne 0 ]]
    [[ "$output" == *"ASH_METRICS_TOKEN must be at least 16 characters"* ]]
}

@test "monitoring-init refuses a metrics token with header-breaking characters" {
    run env ASH_METRICS_TOKEN='abcdefgh ijklmnop' \
        bash "$INIT" \
        --runtime-dir "$BATS_TEST_TMPDIR/runtime" \
        --data-dir "$BATS_TEST_TMPDIR/data"
    [[ $status -ne 0 ]]
    [[ "$output" == *"ASH_METRICS_TOKEN must contain only"* ]]
}

@test "monitoring-init refuses webhook userinfo" {
    run env ASH_ALERTMANAGER_WEBHOOK_URL=https://user:pass@example.invalid/ash \
        bash "$INIT" \
        --runtime-dir "$BATS_TEST_TMPDIR/runtime" \
        --data-dir "$BATS_TEST_TMPDIR/data"
    [[ $status -ne 0 ]]
    [[ "$output" == *"must not contain userinfo"* ]]
}

@test "monitoring-init refuses a non-http webhook" {
    run env ASH_ALERTMANAGER_WEBHOOK_URL=ftp://example.invalid/ash \
        bash "$INIT" \
        --runtime-dir "$BATS_TEST_TMPDIR/runtime" \
        --data-dir "$BATS_TEST_TMPDIR/data"
    [[ $status -ne 0 ]]
    [[ "$output" == *"must be an absolute http(s) URL"* ]]
}

@test "monitoring-init refuses YAML-breaking characters in the webhook" {
    run env ASH_ALERTMANAGER_WEBHOOK_URL='https://example.invalid/a"b' \
        bash "$INIT" \
        --runtime-dir "$BATS_TEST_TMPDIR/runtime" \
        --data-dir "$BATS_TEST_TMPDIR/data"
    [[ $status -ne 0 ]]
    [[ "$output" == *"must not contain quotes or backslashes"* ]]
}

@test "monitoring-init refuses relative runtime and data directories" {
    run env ASH_MONITORING_RUNTIME_DIR=relative/runtime \
        bash "$INIT" \
        --runtime-dir relative/runtime \
        --data-dir "$BATS_TEST_TMPDIR/data"
    [[ $status -ne 0 ]]
    [[ "$output" == *"ASH_MONITORING_RUNTIME_DIR must be an absolute path"* ]]

    run env ASH_MONITORING_DATA_DIR=relative/data \
        bash "$INIT" \
        --runtime-dir "$BATS_TEST_TMPDIR/runtime" \
        --data-dir relative/data
    [[ $status -ne 0 ]]
    [[ "$output" == *"ASH_MONITORING_DATA_DIR must be an absolute path"* ]]
}

@test "monitoring-init refuses / as a state directory" {
    run bash "$INIT" \
        --runtime-dir / \
        --data-dir "$BATS_TEST_TMPDIR/data"
    [[ $status -ne 0 ]]
    [[ "$output" == *"must not be /"* ]]
}

@test "monitoring-init parses the env file as data, never sources it" {
    local canary="$BATS_TEST_TMPDIR/sourced"
    cat >"$BATS_TEST_TMPDIR/init.env" <<EOF
ASH_METRICS_ENABLED=true
ASH_METRICS_TOKEN=abcdef0123456789
ASH_ALERTMANAGER_WEBHOOK_URL=\$(touch $canary)
EOF

    run env -u ASH_METRICS_ENABLED -u ASH_METRICS_TOKEN -u ASH_ALERTMANAGER_WEBHOOK_URL \
        bash "$INIT" \
        --env-file "$BATS_TEST_TMPDIR/init.env" \
        --runtime-dir "$BATS_TEST_TMPDIR/runtime" \
        --data-dir "$BATS_TEST_TMPDIR/data"
    [[ $status -ne 0 ]]
    [[ ! -e "$canary" ]]
    [[ "$output" == *"must be an absolute http(s) URL"* ]]
}

@test "monitoring-init keeps exported values over the env file" {
    cat >"$BATS_TEST_TMPDIR/init.env" <<'EOF'
ASH_METRICS_ENABLED=true
ASH_METRICS_TOKEN=abcdef0123456789
ASH_ALERTMANAGER_WEBHOOK_URL=https://example.invalid/from-file
EOF

    run env ASH_ALERTMANAGER_WEBHOOK_URL=ftp://invalid \
        bash "$INIT" \
        --env-file "$BATS_TEST_TMPDIR/init.env" \
        --runtime-dir "$BATS_TEST_TMPDIR/runtime" \
        --data-dir "$BATS_TEST_TMPDIR/data"
    [[ $status -ne 0 ]]
    [[ "$output" == *"must be an absolute http(s) URL"* ]]
}

@test "monitoring-init uses the last value in the env file" {
    cat >"$BATS_TEST_TMPDIR/init.env" <<'EOF'
ASH_METRICS_ENABLED=true
ASH_METRICS_TOKEN=short
ASH_ALERTMANAGER_WEBHOOK_URL=ftp://invalid
ASH_ALERTMANAGER_WEBHOOK_URL=https://example.invalid/last
EOF

    run env -u ASH_METRICS_ENABLED -u ASH_METRICS_TOKEN -u ASH_ALERTMANAGER_WEBHOOK_URL \
        bash "$INIT" \
        --env-file "$BATS_TEST_TMPDIR/init.env" \
        --runtime-dir "$BATS_TEST_TMPDIR/runtime" \
        --data-dir "$BATS_TEST_TMPDIR/data"
    [[ $status -ne 0 ]]
    # The webhook error must not win: the last (valid) URL replaced the first.
    [[ "$output" == *"ASH_METRICS_TOKEN must be at least 16 characters"* ]]
}

@test "monitoring-init renders 0600 secrets and 0750 state directories" {
    [[ "$CAN_ROOT" == "true" ]] || skip "requires root or passwordless sudo"

    local runtime="$BATS_TEST_TMPDIR/runtime"
    local data="$BATS_TEST_TMPDIR/data"
    run_as_root env \
        ASH_METRICS_ENABLED=true \
        ASH_METRICS_TOKEN=abcdef0123456789abcdef \
        ASH_ALERTMANAGER_WEBHOOK_URL='https://example.invalid/ash?x=1&y=2' \
        ASH_GRAFANA_ADMIN_PASSWORD=test-password-1234 \
        bash "$INIT" --runtime-dir "$runtime" --data-dir "$data"
    [[ $status -eq 0 ]]

    [[ "$(run_as_root stat -c '%a' "$runtime")" == "711" ]]
    for file in alertmanager.yml api_metrics_token grafana_admin_password; do
        [[ "$(run_as_root stat -c '%a' "$runtime/$file")" == "600" ]]
    done
    [[ "$(run_as_root stat -c '%u' "$runtime/alertmanager.yml")" == "65534" ]]
    [[ "$(run_as_root stat -c '%u' "$runtime/api_metrics_token")" == "65534" ]]
    [[ "$(run_as_root stat -c '%u' "$runtime/grafana_admin_password")" == "472" ]]

    [[ "$(run_as_root stat -c '%a' "$data")" == "750" ]]
    [[ "$(run_as_root stat -c '%a' "$data/prometheus")" == "750" ]]
    [[ "$(run_as_root stat -c '%u' "$data/prometheus")" == "65534" ]]
    [[ "$(run_as_root stat -c '%u' "$data/loki")" == "10001" ]]
    [[ "$(run_as_root stat -c '%u' "$data/tempo")" == "10001" ]]
    [[ "$(run_as_root stat -c '%u' "$data/grafana")" == "472" ]]

    run_as_root grep -q 'https://example.invalid/ash?x=1&y=2' "$runtime/alertmanager.yml"
    run_as_root grep -q 'abcdef0123456789abcdef' "$runtime/api_metrics_token"
    run_as_root grep -q 'test-password-1234' "$runtime/grafana_admin_password"
}

@test "monitoring-init keeps an existing generated Grafana password" {
    [[ "$CAN_ROOT" == "true" ]] || skip "requires root or passwordless sudo"

    local runtime="$BATS_TEST_TMPDIR/runtime"
    local data="$BATS_TEST_TMPDIR/data"
    run_as_root env \
        ASH_METRICS_ENABLED=true \
        ASH_METRICS_TOKEN=abcdef0123456789abcdef \
        ASH_ALERTMANAGER_WEBHOOK_URL=https://example.invalid/ash \
        bash "$INIT" --runtime-dir "$runtime" --data-dir "$data"
    [[ $status -eq 0 ]]
    local first
    first="$(run_as_root cat "$runtime/grafana_admin_password")"

    run_as_root env -u ASH_GRAFANA_ADMIN_PASSWORD \
        ASH_METRICS_ENABLED=true \
        ASH_METRICS_TOKEN=abcdef0123456789abcdef \
        ASH_ALERTMANAGER_WEBHOOK_URL=https://example.invalid/ash \
        bash "$INIT" --runtime-dir "$runtime" --data-dir "$data"
    [[ $status -eq 0 ]]
    [[ "$(run_as_root cat "$runtime/grafana_admin_password")" == "$first" ]]
}
