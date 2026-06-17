#!/usr/bin/env bats
# Unit tests for sensitive data redaction engine

setup() {
    export ASH_LOG_DIR="/tmp/ash_test_$$"
    export ASH_TEMP_DIR="/tmp/ash_test_tmp_$$"
    export ASH_SPOOL_DIR="/tmp/ash_test_spool_$$"
    export ASH_CONFIG_DIR="/tmp/ash_test_conf_$$"
    mkdir -p "$ASH_LOG_DIR" "$ASH_TEMP_DIR" "$ASH_SPOOL_DIR" "$ASH_CONFIG_DIR"
    mkdir -p "$ASH_SPOOL_DIR/pending" "$ASH_SPOOL_DIR/sent"

    # Source only the functions we need
    source "${BATS_TEST_DIRNAME}/../../src/agent/ash-agent.sh" 2>/dev/null || true
    load_redaction_rules
}

teardown() {
    rm -rf "/tmp/ash_test_$$" "/tmp/ash_test_tmp_$$" "/tmp/ash_test_spool_$$" "/tmp/ash_test_conf_$$"
}

@test "redact --password=VALUE" {
    result=$(redact_sensitive_data 'mysql --password=secret123 -u root')
    [[ "$result" != *"secret123"* ]]
    [[ "$result" == *"REDACTED"* ]]
}

@test "redact -p flag with space" {
    result=$(redact_sensitive_data 'mysql -p mysecret -u root')
    [[ "$result" != *"mysecret"* ]]
}

@test "redact Bearer token" {
    result=$(redact_sensitive_data 'curl -H "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyIn0.abc123" http://api.example.com')
    [[ "$result" != *"eyJhbGciOiJIUzI1NiJ9"* ]]
}

@test "redact AWS access key" {
    result=$(redact_sensitive_data 'export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE')
    [[ "$result" != *"AKIAIOSFODNN7EXAMPLE"* ]]
    [[ "$result" == *"AKIA[REDACTED]"* ]]
}

@test "redact private key header" {
    result=$(redact_sensitive_data 'cat -----BEGIN RSA PRIVATE KEY-----')
    [[ "$result" == *"REDACTED"* ]]
}

@test "redact JWT token" {
    result=$(redact_sensitive_data 'echo eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyIn0.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk')
    [[ "$result" == *"JWT_REDACTED"* ]]
}

@test "preserve non-sensitive commands" {
    result=$(redact_sensitive_data 'ls -la /var/log')
    [[ "$result" == "ls -la /var/log" ]]
}

@test "preserve paths and normal arguments" {
    result=$(redact_sensitive_data 'cp /home/user/file.txt /tmp/backup/')
    [[ "$result" == "cp /home/user/file.txt /tmp/backup/" ]]
}

@test "redact api_key parameter" {
    result=$(redact_sensitive_data 'curl http://api.example.com?api_key=sk_live_abcdef123456')
    [[ "$result" != *"sk_live_abcdef123456"* ]]
}
