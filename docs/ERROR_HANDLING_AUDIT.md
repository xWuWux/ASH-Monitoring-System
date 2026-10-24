# ASH Error-Handling and Architecture Audit

Date: 2026-10-24
Scope: agent → Kafka → consumer → PostgreSQL → API, plus deployment and CI.
Method: read every stage, run the real Kafka end-to-end path locally against
a real broker and PostgreSQL, and add regression tests for every behavior
changed here.

## Verdict

**No — the project did not have correct error handling at every stage.** The
audit found one defect that prevented the consumer from starting at all, two
paths that could silently drop audit data, several shell exit-status bugs, and
a database-outage path that returned HTML instead of a JSON error. Those are
fixed in this PR and covered by tests.

The overall model is **defensible but not optimal**:

- The agent is deliberately fail-open. That is the right default for a tool
  that must not break an operator's shell, but it is only acceptable if lost
  or delayed events are *visible*. Today most agent failures are suppressed
  with `|| true` / `2>/dev/null` and are not counted anywhere.
- The pipeline is at-least-once and the consumer commits Kafka offsets only
  after a flush. That part is sound.
- The weak link is the consumer's contract with PostgreSQL: a failed database
  write is logged, treated as a successful flush, and the offset is committed.
  The local JSONL file remains as a fallback, but the API reads only
  PostgreSQL, so “the event is on disk somewhere” is not the same as “the
  monitoring system recorded it.”
- The API's integrity check verifies chain *links* only. It cannot recompute a
  hash because `raw_event` is JSONB, which does not preserve the exact bytes
  that were signed. For a tamper-evident system, that is a real limitation,
  not a cosmetic one.

## Stage-by-stage findings

| # | Stage | Failure mode | Current behavior | Risk | Verdict / recommendation |
|---|-------|--------------|------------------|------|--------------------------|
| 1 | Agent config | Non-numeric `MAX_COMMANDS_PER_SECOND` / `MAX_OUTPUT_SIZE` | `[[ abc -lt 1 ]]` exits 2; the old `2>/dev/null` turned that into “valid” | Bad values reach arithmetic later | **Fixed**; digits are required and tested |
| 2 | Agent event build | `tty` not available | `tty` printed “not a tty” and then `|| echo unknown` appended a second line | Garbage values in every non-interactive event | **Fixed**; fallback assignment + test |
| 3 | Agent event return | `((EVENTS_LOGGED++))` on the first event | Post-increment returns the old value 0 → status 1, after the event was written | Callers see failure; `set -e` callers abort; the Kafka E2E refused to flush | **Fixed**; assignment + test |
| 4 | Agent redaction | `sed` fails at runtime | `redact_sensitive_data` falls back to `echo "$input"` — the **unredacted** command | Secret leak into events/logs | **Open — policy decision.** Fail closed with a placeholder rather than emit raw input |
| 5 | Agent hash append | Hash-file append fails (disk full/permissions) | Return status is ignored; the event can still be written with a hash that was never appended | Broken chain, silent integrity loss | **Open — policy decision.** Fail the event rather than write an unsigned link, or count and alert |
| 6 | Agent local log | Atomic append fails | `safe_log_write` fallback was masked by `rm` returning success | Event silently lost | **Fixed**; `cat ... \|\| exit 1` + test |
| 7 | Agent spool | `spool_write` fails | Return value ignored by `emit_event`; event remains only in the local JSONL | Kafka path silently absent | **Open.** Log/count spool failures; keep local log as source of truth |
| 8 | Agent Kafka send | Broker down / producer hangs | 3 retries, `KAFKA_SEND_TIMEOUT`, then fail-open; stderr discarded | Events spool for later (good), but no visibility | Acceptable fail-open; add a failure counter and a single warning |
| 9 | Agent lifecycle | SIGTERM/SIGINT | Signal trap calls `cleanup_ash`, then `exit` triggers the EXIT trap → cleanup twice; duplicate `session_end` | Duplicate audit events | **Open — small fix.** Guard cleanup with a flag |
| 10 | Agent `--functions-only` | Sourced by shell integrations | Top-level `set -euo pipefail`, `set -T`, and EXIT/ERR/SIGTERM traps are installed before the flag is honored | Clobbers the caller's options/traps | **Open.** Install traps/options only in the normal path |
| 11 | Agent recovery | Stale PID files | Kills any numeric PID found in `${ASH_TEMP_DIR}/*.pid` | PID reuse can kill an unrelated process | **Open.** Validate PID > 1 and the process cmdline before killing |
| 12 | Agent watchers | `inotifywait`/auditd/docker loops die | Background loops have no supervision | File/container coverage silently stops | **Open.** Restart with backoff and expose a heartbeat metric |
| 13 | Consumer startup | Logging configured before `log_dir` existed | `AttributeError: 'ASHConsumer' object has no attribute 'log_dir'` on every real start | **Consumer could never start** | **Fixed (critical)**; ordering + constructor test |
| 14 | Consumer config | Malformed JSON | Exception propagates out of `__init__`; non-zero exit | Restart loop with a traceback | Acceptable, but log a clear message and fail fast |
| 15 | Consumer Kafka setup | Broker absent | `KafkaConsumer(...)` does not connect; “Kafka consumer initialized” is logged immediately | Health signal is misleading; first poll is the real test | **Open.** Poll/`partitions_for_topic` with retries before declaring ready |
| 16 | Consumer deserialization | Poison message (invalid JSON) | `json.loads` raises inside the consumer iterator; `run()` catches and exits | Restart at the same offset → poison-pill loop | **Open — needs decision.** Catch per-message, DLQ the raw payload, skip the offset |
| 17 | Consumer validation | Only field presence is checked | A valid-looking event with a non-UUID `session_id` or bad timestamp reaches PostgreSQL and fails the whole batch | Poison event blocks/aborts DB writes for the batch | **Open — needs decision.** Validate UUID/timestamp/event-type/length, DLQ invalid values |
| 18 | Consumer DLQ | DLQ write fails | Logs the failure and continues | Invalid event is dropped without a trace | Acceptable; count it and alert |
| 19 | Consumer dedup | Process restart / cache eviction | In-memory set only; duplicates are re-processed | Duplicate JSONL rows; DB `ON CONFLICT` prevents duplicate rows | Acceptable given at-least-once; file duplicates are expected |
| 20 | Consumer local write | Disk full | Batch is re-added to memory and retried; offset is not committed | Correct durability, but unbounded memory growth | Acceptable short-term; add backpressure/metrics |
| 21 | Consumer DB write | PostgreSQL down / query error | `_write_database_batch` logs/rolls back and **returns success**; `_flush_batch` sets `_commit_pending` | Offset advances, DB is missing events forever; API/search is incomplete | **Open — primary decision.** Do not commit the offset until the DB commit succeeds, or persist a replayable outbox |
| 22 | Consumer DB retry | One bad event in a batch | Whole `execute_values` batch fails; no per-event isolation | One bad UUID/timestamp poisons every event in the batch | **Open.** Validate first; optionally fall back to per-event inserts and DLQ only the bad row |
| 23 | Consumer main loop | Unexpected exception | `run()` catches, logs, exits **0** | `Restart=always` masks it, but Kubernetes/on-failure supervisors do not; operators see a clean exit | **Open.** Exit non-zero on fatal loop failure |
| 24 | Consumer retention | `VACUUM` after `DELETE` | `VACUUM` ran inside a transaction and failed every time | Table bloat; cleanup logged as successful | **Fixed**; autocommit around VACUUM + unit test |
| 25 | Consumer retention | Archive/delete cutoffs | Archive re-reads and appends the same old rows each day; `datetime.now()` is local time | Duplicate archive growth; timezone skew | **Open.** Record archive watermarks; use naive UTC |
| 26 | Consumer metrics | Metrics port fails | Logs a warning and continues | Docker health check hits the metrics port; an unhealthy process can look healthy | **Open.** Fail startup or expose a real health endpoint |
| 27 | API startup | Missing secrets/env | Refuses to start with a clear `RuntimeError` | Good | Acceptable |
| 28 | API auth | Credential comparison | `hmac.compare_digest`; JWT with expiry | Good | Acceptable; add revocation/refresh only if needed |
| 29 | API input | Invalid int/UUID/timestamp | Returns JSON 400 before SQL | Good | Acceptable; cap free-text filter lengths |
| 30 | API database | Connection lost mid-request | Previously Flask's HTML 500 | JSON clients break; retryable outage looks like a bug | **Fixed**; JSON 503 for `OperationalError`, JSON 500 for other DB errors + test |
| 31 | API integrity | Verification order | Ordered by `log_timestamp`; a late event with an earlier timestamp produced a false FAIL | False alarms and false confidence | **Fixed**; `ORDER BY id` + contract test |
| 32 | API integrity | Content tampering | Only `prev_hash` links are checked; `raw_event` JSONB cannot reproduce the signed bytes | An attacker with DB write access can rewrite content and recompute links; verification still says PASS | **Open — needs decision.** Store the exact raw line (`TEXT`) and recompute the hash |
| 33 | API performance | One PostgreSQL connection per request | New TCP/auth/backend per API call; p95 is sensitive to DB latency | Throughput ceiling, connection storms | **Open.** Add a per-worker connection pool |
| 34 | API rate limit | In-memory limiter under 4 gunicorn workers | Effective limit is roughly 4× configured | Brute-force budget is larger than documented | Documented limitation; use Redis if exact |
| 35 | Deployment | Consumer liveness | Docker health check only proves the metrics HTTP port is open | Kafka/DB stalled but container “healthy” | **Open.** Health should reflect consumer lag/last successful flush |
| 36 | CI | Real integration | New `kafka-e2e` job uses real Kafka/Zookeeper/PostgreSQL, the real agent producer, and the real consumer | The startup bug above was invisible to mocked tests and is now caught | **Added**; kept blocking in `ci-success` |

## What this PR fixes (and the tests that lock it in)

| Fix | Test |
|-----|------|
| Consumer sets/creates `log_dir` before configuring logging | `tests/unit/python/test_consumer_unit.py::test_constructor_creates_log_dir_before_configuring_logging` |
| First `emit_event` returns success; `set -e` callers are not aborted | `tests/unit/test_events.bats::emit_event returns success for the first event` |
| `tty` fallback is a single clean value | `tests/unit/test_events.bats::emit_event records a clean tty fallback without a terminal` |
| `safe_log_write` reports failure instead of losing the event behind `rm` | `tests/unit/test_events.bats::safe_log_write reports failure when the target is not writable` |
| `verify_hash_chain` cannot wrap 256/512 errors to exit 0 | `tests/unit/test_events.bats::verify_hash_chain fails when the error count is a multiple of 256` |
| Concurrent spool writers use `BASHPID`, not `$$` | `tests/unit/test_spool.bats::concurrent spool writes from one parent do not overwrite each other` |
| Non-numeric config values are rejected | `tests/unit/test_config_validation.bats::validate_config rejects a non-numeric ...` |
| Retention VACUUM runs outside a transaction and restores autocommit | `tests/unit/python/test_consumer_unit.py::test_retention_vacuums_with_autocommit_and_restores_it` |
| API DB outage returns JSON 503, not HTML | `tests/degradation/python/test_api_degradation.py::test_database_outage_on_an_endpoint_returns_json_503` |
| Integrity verification uses chain/insert order, not wall-clock order | `tests/contract/test_api_contract.py::test_integrity_verify_uses_insert_order_not_timestamps` |
| Real agent → Kafka → consumer → PostgreSQL path | `tests/integration/kafka-e2e.sh`, CI job `kafka-e2e` |

## Decisions needed before changing semantics

These are deliberately **not** changed here because the existing tests encode
the current behavior and the right answer depends on the deployment contract.

1. **Should a PostgreSQL write failure block Kafka offset commits?**
   - Option A (recommended): yes. Retry with backoff; do not commit; expose
     consumer lag. PostgreSQL is the API's source of truth.
   - Option B: keep file-only fallback, but add a replay tool and mark the
     consumer degraded. This is simpler operationally but requires a real
     replay path that does not exist today.
   - Option C: per-event DLQ for DB failures, then commit. This avoids
     blocking but makes the DB incomplete until replay.
2. **How strict should event validation be?**
   - Recommended: UUID `event_id`/`session_id`, ISO-8601 timestamp, allow-listed
     `event_type`, and length caps. Invalid events go to the DLQ and never
     reach a database batch.
3. **Do we need exact-byte integrity verification via the API?**
   - Recommended: add `raw_event_text TEXT` (the exact signed line) and verify
     `sha256(prev_hash || raw_event_text)`. Keep `raw_event` JSONB for queries.
     Link-only verification is not tamper-evident against DB writes.

Secondary questions:

4. Should the agent fail closed on redaction failure (never emit raw input)?
   Recommended: yes, with a visible placeholder and a counter.
5. Should `--functions-only` leave the caller's shell options/traps untouched?
   Recommended: yes; this is a library mode and must have no side effects.
6. Is an API connection pool acceptable operational complexity, or should the
   API stay connection-per-request? Recommended: pool per worker.

## New variables and functions

No production environment variables were added.

| Name | Domain / values | Default | Purpose |
|------|-----------------|---------|---------|
| `ASH_KAFKA_BROKER` (E2E) | `host:port` | `127.0.0.1:9092` | Broker used by the E2E test |
| `ASH_KAFKA_TOPIC` (E2E) | Kafka topic string | `ash-e2e-<epoch>-<pid>` | Unique topic per run |
| `ASH_KAFKA_GROUP` (E2E) | Kafka group string | `ash-e2e-group-<epoch>-<pid>` | Unique group per run |
| `ASH_E2E_TIMEOUT` (E2E) | integer seconds, ≥ 0 | `90` | Per-stage wait budget |
| `ASH_E2E_METRICS_PORT` (E2E) | TCP port, integer | `19090` | Consumer metrics port |
| `ASH_DATABASE_URL` (E2E) | PostgreSQL URL | required | Schema setup and row verification |
| `cleanup()` (E2E) | script-local function | — | Kill consumer, dump diagnostics on failure, delete the test row |
| `wait_for_log()` (E2E) | `pattern: string` | — | Wait for a consumer log line or fail/timeout |
| `database_unavailable()` (API) | Flask error handler for `psycopg2.OperationalError` | — | JSON 503 without leaking connection details |
| `database_error()` (API) | Flask error handler for `psycopg2.Error` | — | JSON 500 for non-connectivity DB errors |

## Simpler, safer target architecture

1. **One source of truth for the pipeline: PostgreSQL.** Keep the agent's
   local JSONL as the host-side forensic copy, but make the consumer's offset
   commit conditional on the database transaction. On DB failure, pause and
   retry instead of advancing past data that the API will never see.
2. **One validation boundary.** Validate once, at the consumer edge, with the
   same JSON schema the agent claims to emit. Invalid events go to the DLQ;
   valid events cannot poison a batch.
3. **One integrity representation.** Store the exact raw line alongside the
   JSONB copy, and verify the hash over the raw line. Link-only checks are a
   consistency check, not tamper evidence.
4. **Visible fail-open.** The agent should never break a shell, but every
   dropped event, failed spool write, and failed Kafka send should increment a
   counter and be visible in metrics/logs. Silence is the problem, not
   fail-open itself.
5. **Keep the real E2E.** The startup bug found here is exactly the class of
   defect that unit tests with `object.__new__` cannot catch. The Kafka job
   should stay blocking.

The current architecture can be made correct without a rewrite. The largest
complexity is the ambiguous dual-write (file + DB) and the missing validation
boundary; both can be simplified by making the contract explicit rather than
adding more retries.
