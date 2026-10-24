#!/usr/bin/env bats
# Argument-contract tests for the real Kafka E2E script.
#
# The full script needs a broker and PostgreSQL (see tests/integration), but
# its environment validation happens before any network access, so it can be
# tested without either service.

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../integration/kafka-e2e.sh"
    DATABASE_URL="postgresql://ash:test@localhost:5432/ash_logs"
}

@test "kafka-e2e requires ASH_DATABASE_URL" {
    run env -u ASH_DATABASE_URL bash "$SCRIPT"
    [[ $status -ne 0 ]]
    [[ "$output" == *"ASH_DATABASE_URL"* ]]
}

@test "kafka-e2e rejects a non-numeric timeout" {
    run env ASH_DATABASE_URL="$DATABASE_URL" ASH_E2E_TIMEOUT=soon \
        bash "$SCRIPT"
    [[ $status -eq 2 ]]
    [[ "$output" == *"TIMEOUT"* ]]
}

@test "kafka-e2e rejects a zero timeout" {
    run env ASH_DATABASE_URL="$DATABASE_URL" ASH_E2E_TIMEOUT=0 \
        bash "$SCRIPT"
    [[ $status -eq 2 ]]
    [[ "$output" == *"at least 1 second"* ]]
}

@test "kafka-e2e rejects an out-of-range metrics port" {
    run env ASH_DATABASE_URL="$DATABASE_URL" ASH_E2E_METRICS_PORT=70000 \
        bash "$SCRIPT"
    [[ $status -eq 2 ]]
    [[ "$output" == *"between 1 and 65535"* ]]
}
