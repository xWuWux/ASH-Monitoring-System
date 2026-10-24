# Tests

The suites are split by intent so CI can run the fast, blocking checks on
every push and pull request.

| Suite | What it covers |
| --- | --- |
| `tests/unit/*.bats` | Redaction, config validation, hash chain, event emission, spool queue |
| `tests/regression/*.bats` | Shell constructs that previously broke the DEBUG trap |
| `tests/shell/*.bats` | Bash/zsh/fish syntax, shell integration hooks, installer entry points |
| `tests/degradation/*.bats` | Kafka outage, missing `jq`/`inotifywait`, spool failures, crash recovery |
| `tests/smoke/*.bats` | End-to-end agent event pipeline (redaction → hash chain → spool) |
| `tests/security/*.bats` | Secret-egress checks: events, agent log, spool, Kafka, file diffs |
| `tests/unit/python/` | Consumer processing/batching and API auth/health |
| `tests/degradation/python/` | Database/Kafka startup failures, DLQ writes, degraded API health |
| `tests/security/python/` | API responses never echo credentials, tokens, or DB URLs |
| `tests/contract/` | API response contract against real PostgreSQL: every endpoint, filters, pagination, invalid input, RBAC |
| `tests/smoke/smoke-api.sh` | Real gunicorn API + PostgreSQL: health, auth, search, RBAC rejection, load check |
| `tests/integration/kafka-e2e.sh` | Real Kafka + Zookeeper + PostgreSQL: agent producer → broker → Python consumer → DB row, with raw-text storage and hash-recomputation assertions |
| `tests/performance/load_api.py` | 50 concurrent `GET /api/v1/events` requests, p95 < 500ms |
| `tests/performance/benchmark.sh` | Report-only hash-chain + redaction throughput |

## Running locally

```bash
# BATS (install bats-core first)
bats tests/unit/*.bats
bats tests/regression/*.bats
bats tests/shell/*.bats
bats tests/degradation/*.bats
bats tests/smoke/*.bats
bats tests/security/*.bats

# Python
pip install -r src/consumer/requirements.txt pytest pytest-cov
pytest tests/unit/python tests/degradation/python tests/security/python -v

# API contract tests (needs a reachable PostgreSQL)
ASH_DATABASE_URL='postgresql://ash:password@localhost:5432/ash_logs' \
ASH_ADMIN_USER='admin' ASH_ADMIN_PASS='local-test-password' \
    pytest tests/contract -v

# API smoke test + 50-request load check (needs a reachable PostgreSQL)
export ASH_DATABASE_URL='postgresql://ash:password@localhost:5432/ash_logs'
export ASH_JWT_SECRET='local-test-secret'
export ASH_ADMIN_USER='admin'
export ASH_ADMIN_PASS='local-test-password'
bash tests/smoke/smoke-api.sh

# Kafka end-to-end test (needs a reachable broker and PostgreSQL, plus the
# Kafka CLI on PATH; the CI job provisions all three)
export ASH_DATABASE_URL='postgresql://ash:password@localhost:5432/ash_logs'
export ASH_KAFKA_BROKER='127.0.0.1:9092'
bash tests/integration/kafka-e2e.sh
```

## Security scanning

`ci.yml` runs Bandit, Semgrep, `pip-audit`, OSV-Scanner, and `detect-secrets`.
CodeQL runs from `.github/workflows/codeql.yml` for Python and GitHub Actions.
`tests/security/` is the regression gate that proves secrets are redacted
before they reach the event log, agent log, spool, Kafka, file-change diffs, or
API responses.

