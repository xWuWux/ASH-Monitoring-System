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

Three semantic changes were approved after the audit and are implemented here:

1. **Offset commits wait for PostgreSQL.** A failed database write keeps the
   batch in memory, does not commit the Kafka offset, and makes the stall
   visible through `ash_consumer_database_available` and Kafka lag.
2. **Strict validation with per-row fallback.** UUIDs, timestamps, event
   types/sources, field types, and column-width limits are checked before a
   batch reaches PostgreSQL. Malformed payloads are dead-lettered from the raw
   bytes; if a batch still fails, rows are retried individually and only the
   rejected row goes to the DLQ.
3. **Exact raw event text is stored.** `command_logs.raw_event_text` holds the
   exact signed line Kafka delivered. The API still performs link-only
   integrity verification in this PR (approved deferral), but the stored text
   is sufficient to recompute `sha256(prev_hash || event_json)` later; the
   Kafka E2E already does so.

The overall model after these changes is **defensible and substantially
safer**:

- The agent is deliberately fail-open. That is the right default for a tool
  that must not break an operator's shell, but it is only acceptable if lost
  or delayed events are *visible*. Most agent failures are still suppressed
  with `|| true` / `2>/dev/null` and are not counted anywhere; that remains a
  gap (see rows 4–12 below).
- The pipeline is at-least-once, and the consumer now advances offsets only
  after the PostgreSQL transaction and the local JSONL append both succeed.
  A database outage no longer creates a permanent gap in the API's data; it
  stalls the consumer, which is the intended backpressure.
- The API's integrity check still verifies chain *links* only. `raw_event`
  JSONB cannot reproduce the signed bytes, but `raw_event_text` now can; the
  API-side recomputation is the remaining follow-up, not a missing input.

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
| 16 | Consumer deserialization | Poison message (invalid JSON) | Raw bytes are kept and parsed in `_decode_message`; invalid UTF-8/JSON/oversized payloads are dead-lettered with the raw text and the loop continues | A poison message no longer crashes the iterator | **Fixed**; per-message DLQ + consume-loop test |
| 17 | Consumer validation | Only field presence is checked | `_validate_event` checks UUIDs, ISO-8601 timestamps, allow-listed sources/event types, field types, and column widths; the specific reason is recorded in the DLQ | Invalid events cannot poison a database batch | **Fixed**; validation tests |
| 18 | Consumer DLQ | DLQ write fails | `_append_dead_letter_record` logs and returns `False`; `process_message()`/`run()` still continue, so a later flush can commit past an event that was neither inserted nor dead-lettered | Silent loss if the DLQ is unwritable | **Open — policy decision.** Fail the consume loop (non-zero exit, uncommitted offset) instead of advancing past an unrecorded event |
| 19 | Consumer dedup | Process restart / cache eviction | In-memory set only; duplicates are re-processed | Duplicate JSONL rows; DB `ON CONFLICT` prevents duplicate rows | Acceptable given at-least-once; file duplicates are expected |
| 20 | Consumer local write | Disk full | Batch is re-added to memory and retried; offset is not committed | Correct durability, but unbounded memory growth | Acceptable short-term; add backpressure/metrics |
| 21 | Consumer DB write | PostgreSQL down / query error | `_write_database_batch` raises `DatabaseWriteError`; `_flush_batch` keeps the batch, writes no local JSONL, and does not set `_commit_pending`; `ash_consumer_database_available` and Kafka lag expose the stall | Offset no longer advances past data the API cannot see | **Fixed**; degradation tests |
| 22 | Consumer DB retry | One bad event in a batch | A failed batch is retried row by row; only the row PostgreSQL still rejects is DLQ'd (`db_row_error`) | One bad row no longer discards the rest of the batch | **Fixed**; per-row fallback test |
| 23 | Consumer main loop | Unexpected exception | `run()` logs and re-raises; the offset is not committed | On-failure supervisors restart it; the failure is visible | **Fixed**; consume-loop test |
| 24 | Consumer retention | `VACUUM` after `DELETE` | `VACUUM` ran inside a transaction and failed every time | Table bloat; cleanup logged as successful | **Fixed**; autocommit around VACUUM + unit test |
| 25 | Consumer retention | Archive/delete cutoffs | Archive re-reads and appends the same old rows each day; `datetime.now()` is local time | Duplicate archive growth; timezone skew | **Open.** Record archive watermarks; use naive UTC |
| 26 | Consumer metrics | Metrics port fails | Logs an error and continues processing; the listener cannot bind | Docker now probes `/health/ready`, so a missing listener is unhealthy instead of "port open, process wedged" | **Fixed.** Combined metrics/health listener; bind failure is visible and data processing is not aborted |
| 27 | API startup | Missing secrets/env | Refuses to start with a clear `RuntimeError` | Good | Acceptable |
| 28 | API auth | Credential comparison | `hmac.compare_digest`; JWT with expiry | Good | Acceptable; add revocation/refresh only if needed |
| 29 | API input | Invalid int/UUID/timestamp | Returns JSON 400 before SQL | Good | Acceptable; cap free-text filter lengths |
| 30 | API database | Connection lost mid-request | Previously Flask's HTML 500 | JSON clients break; retryable outage looks like a bug | **Fixed**; JSON 503 for `OperationalError`, JSON 500 for other DB errors + test |
| 31 | API integrity | Verification order | Ordered by `log_timestamp`; a late event with an earlier timestamp produced a false FAIL | False alarms and false confidence | **Fixed**; `ORDER BY id` + contract test |
| 32 | API integrity | Content tampering | Only `prev_hash` links are checked; `raw_event` JSONB cannot reproduce the signed bytes. `command_logs.raw_event_text` now stores the exact signed line, and the Kafka E2E recomputes the hash from it | An attacker with DB write access can still rewrite content and recompute links; API verification still says PASS until it recomputes from `raw_event_text` | **Partially fixed — approved deferral.** Raw text is stored (done); recompute `sha256(prev_hash || event_json)` in the API next |
| 33 | API performance | One PostgreSQL connection per request | New TCP/auth/backend per API call; p95 is sensitive to DB latency | Throughput ceiling, connection storms | **Open.** Add a per-worker connection pool |
| 34 | API rate limit | In-memory limiter under 4 gunicorn workers | Effective limit is roughly 4× configured | Brute-force budget is larger than documented | Documented limitation; use Redis if exact |
| 35 | Deployment | Consumer liveness | Docker and systemd previously had no readiness signal; only the metrics port was probed | Kafka/DB stalled but container “healthy” | **Fixed.** `/health/live` vs `/health/ready` (DB + pending flush); Docker probes readiness; consumer sends systemd `READY=1`/`WATCHDOG=1`; Kafka E2E asserts readiness, metrics, and JSON logs |
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
| Malformed Kafka payloads are DLQ'd instead of crashing the iterator | `tests/unit/python/test_consumer_unit.py::test_run_dead_letters_poison_payloads_and_keeps_consuming` |
| Validation rejects bad UUIDs/timestamps/types/sources/lengths | `tests/unit/python/test_consumer_unit.py::test_validation_*` |
| A failed batch is retried per row and only the bad row is DLQ'd | `tests/unit/python/test_consumer_unit.py::test_failed_batch_retries_rows_and_dlqs_only_the_bad_row` |
| The exact raw Kafka line reaches `raw_event_text` | `tests/unit/python/test_consumer_unit.py::test_database_batch_stores_the_exact_raw_text` |
| A DB outage keeps the batch and blocks the Kafka offset commit | `tests/degradation/python/test_consumer_degradation.py::test_flush_blocks_commit_when_the_database_stays_down` |
| DB availability is exposed as a gauge | `tests/unit/python/test_consumer_unit.py::test_database_outage_marks_the_gauge_unavailable` |
| Fatal loop errors exit non-zero | `tests/unit/python/test_consumer_unit.py::test_run_raises_on_a_fatal_loop_error` |
| The flush timer cannot commit past an in-flight message | `tests/unit/python/test_consumer_unit.py::test_flush_timer_flushes_under_the_processing_lock` |
| Real agent → Kafka → consumer → PostgreSQL path, including raw-text hash recomputation | `tests/integration/kafka-e2e.sh`, CI job `kafka-e2e` |

## Decisions needed before changing semantics

These were the open semantic questions. The first three were answered and
implemented in this PR; the remaining ones still need a decision.

1. **Should a PostgreSQL write failure block Kafka offset commits?**
   - **Approved and implemented:** yes. `_write_database_batch` raises
     `DatabaseWriteError`; `_flush_batch` keeps the batch in memory, does not
     write the local JSONL, and does not set `_commit_pending`. The offset is
     therefore not committed. `ash_consumer_database_available` and
     `ash_consumer_kafka_lag` make the stall visible. PostgreSQL is the API's
     source of truth.
2. **How strict should event validation be?**
   - **Approved and implemented:** strict, plus per-row fallback. UUID
     `event_id`/`session_id`, ISO-8601 `timestamp`, allow-listed `source` and
     `event_type`, scalar types, and column-width caps are checked first.
     Invalid events go to the DLQ with a specific reason. If PostgreSQL still
     rejects a batch, rows are retried individually and only the rejected row
     is dead-lettered (`db_row_error`).
3. **Do we need exact-byte integrity verification via the API?**
   - **Approved and partially implemented:** store `raw_event_text TEXT` now;
     defer API-side recomputation. The consumer stores the exact signed line,
     and `tests/integration/kafka-e2e.sh` already recomputes
     `sha256(prev_hash || event_json)` from it. The API continues to verify
     chain links only in this PR.

Secondary questions:

4. Should the agent fail closed on redaction failure (never emit raw input)?
   Recommended: yes, with a visible placeholder and a counter.
5. Should `--functions-only` leave the caller's shell options/traps untouched?
   Recommended: yes; this is a library mode and must have no side effects.
6. Is an API connection pool acceptable operational complexity, or should the
   API stay connection-per-request? Recommended: pool per worker.

## New variables and functions

The observability PR adds the production variables below. Their full
definitions, precedence rules, and security notes are in
`docs/OBSERVABILITY.md`; the consumer/API tables there are authoritative.

| Name | Domain / values | Default | Purpose |
|------|-----------------|---------|---------|
| `ASH_KAFKA_BROKERS` | comma-separated `host:port` list, at least one | JSON/default | Docker/Compose Kafka bootstrap servers |
| `ASH_KAFKA_TOPIC` | non-empty topic string | JSON/default | Consumer topic |
| `ASH_KAFKA_GROUP_ID` | non-empty group string | JSON/default | Consumer group |
| `ASH_DATABASE_URL` | non-empty PostgreSQL URL | JSON/default | Database connection |
| `ASH_DATABASE_ENABLED` | `1/true/yes/on` or `0/false/no/off` | JSON/default | Whether PostgreSQL is authoritative |
| `ASH_ALERTING_ENABLED` | boolean domain above | JSON/default | Enable alert engine |
| `ASH_LOG_DIR` | non-empty writable path | `/var/log/ash` | JSON file log directory (consumer); optional API per-worker file |
| `ASH_LOG_LEVEL` | `DEBUG`, `INFO`, `WARNING`, `ERROR`, `CRITICAL` | `INFO` | Consumer/API root log level |
| `ASH_LOG_MAX_BYTES` | integer ≥ 0 | `10485760` | Rotation threshold; 0 disables |
| `ASH_LOG_BACKUP_COUNT` | integer ≥ 0 | `5` | Retained rotated files |
| `ASH_METRICS_HOST` | hostname or IP | `127.0.0.1` | Consumer health/metrics bind address |
| `ASH_METRICS_PORT` | integer 1-65535 | `9090` | Consumer health/metrics port |
| `ASH_BATCH_SIZE` | integer ≥ 1 | `100` | Events per batch |
| `ASH_BATCH_TIMEOUT` | finite number ≥ 0.001 | `5.0` | Partial-batch timeout seconds |
| `ASH_ALERT_LOG` | writable file path; unset/empty uses default | `/var/log/ash/alerts.jsonl` | Alert JSONL destination when no explicit path is passed |
| `ASH_METRICS_ENABLED` | `1/true/yes/on` or unset/false | `false` | API `/metrics` served instead of 404 |
| `ASH_METRICS_TOKEN` | non-empty secret; empty fails closed | empty | Bearer token for API `/metrics` |
| `PROMETHEUS_MULTIPROC_DIR` | writable directory path | unset / image default | Aggregate API metrics across gunicorn workers |
| `ASH_WATCHDOG_INTERVAL` | integer seconds ≥ 1 | `10` | Agent systemd watchdog heartbeat interval |
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
| `raw_event_text` (DB column) | `TEXT`, nullable | `NULL` for rows written before this migration | Exact signed line received from Kafka, used for future hash recomputation |
| `DatabaseWriteError` (consumer) | exception | — | Raised when a batch is not durable in PostgreSQL; prevents the offset commit |
| `_validate_event(event)` (consumer) | returns `(bool, reason)`; reasons: `not_an_object`, `missing_field`, `invalid_uuid`, `invalid_timestamp`, `invalid_event_type`, `invalid_source`, `invalid_type`, `field_too_long` | — | Validation boundary before batching |
| `_decode_message(value)` (consumer) | returns `(raw_text?, event?, error?)`; errors: `invalid_utf8`, `unsupported_payload`, `raw_too_long`, `invalid_json`, `not_an_object` | — | Keeps exact bytes and turns poison payloads into DLQ entries |
| `_write_database_batch(events, raw_texts)` (consumer) | raises `DatabaseWriteError` when not durable | — | Transactional batch insert with reconnect retries |
| `_write_database_rows_individually(events, raw_texts)` (consumer) | `bool` | — | Per-row fallback that DLQs only rejected rows |
| `_insert_database_rows(cursor, events, raw_texts)` (consumer) | cursor + parallel lists | — | Shared command/file/session insert path |
| `_append_dead_letter_record(record)` (consumer) | `bool` | — | Shared DLQ JSONL append; reports failure |
| `_write_dead_letter_raw(raw_text, reason)` (consumer) | `bool` | — | DLQ for payloads that are not valid JSON objects |
| `_update_lag()` (consumer) | none; updates lag/assignment gauges | — | Publishes Kafka position lag and assignment; explicitly not committed-offset lag |
| `_apply_environment(config)` (consumer) | mutates a config dict; raises `ValueError` on invalid values | — | Applies and validates `ASH_*` overrides |
| `_env_bool`, `_env_int`, `_env_float`, `_env_string` (consumer) | see `docs/OBSERVABILITY.md` domains | — | Typed environment parsing with fail-fast errors |
| `_ensure_shared_module_path(lib_dir)` (consumer) | absolute directory path; missing paths are ignored | `/usr/local/lib/ash` | Lets the installed `bin/ash-consumer` import shared modules from `lib/ash`; no-op in source/container layouts |
| `_is_ready()` (consumer) | `bool`; requires running, no pending flush error, and DB available when enabled | — | Single readiness decision used by the gauge and endpoint |
| `_refresh_readiness()` (consumer) | updates `ash_consumer_ready` | — | Keeps the gauge aligned with `/health/ready` |
| `health_liveness()` (consumer) | returns `(HTTPStatus, dict)`; 200 while running, 503 while stopping | — | Process-only liveness |
| `health_readiness()` (consumer) | returns `(HTTPStatus, dict)`; 200 only when running, flush has no pending error, and DB (if enabled) is available | — | Secret-free readiness body |
| `_ObservabilityHandler` (consumer) | `GET` on `/metrics`, `/health/live`, `/health/ready`, `/health`; other paths 404 | — | One listener for metrics and health; request lines are not logged |
| `_start_observability_server()` (consumer) | host/IP + TCP port from config | — | Serves `/metrics`, `/health/live`, `/health/ready`, `/health` |
| `_start_watchdog()` (consumer) | no-op without `NOTIFY_SOCKET`; sends every 10s | — | systemd liveness without tying it to Kafka traffic |
| `utc_timestamp()` (observability) | no input; ISO-8601 UTC string with milliseconds and `Z` | — | Consistent timestamps for JSON logs and alert records |
| `new_request_id()` (observability) | no input; 36-character lowercase UUID | — | Request ID when the client did not send a safe one |
| `configure_logging(component, level, log_dir, ...)` (observability) | component string; level allow-list; directory or `None`; max bytes/backups ≥ 0 | — | JSON stdout plus optional bounded rotating file; idempotent |
| `JsonFormatter(component)` (observability) | LogRecord -> one JSON object using the allow-list | — | Stable schema; no arbitrary record attributes |
| `log_extra(**values)` (observability) | keys from `LOG_EXTRA_FIELDS` only; unknown keys dropped | — | Prevents reserved/arbitrary logging keys and unstable fields |
| `redact_text(value)` (observability) | any value -> string with URL userinfo and `password=`/`token:`-style assignments replaced by `[redacted]` | — | Safety net for exception text; host/port/path remain |
| `sanitize_request_id(value)` (observability) | 1-128 chars from `[A-Za-z0-9._:-]` or `None` | — | Prevents header/log injection |
| `sd_notify(message)` (observability) | `READY=1`, `WATCHDOG=1`, `STOPPING=1`, etc.; no-op without `NOTIFY_SOCKET` | — | Minimal systemd notification client |
| `_start_request_observation()` (API) | inbound `X-Request-ID` sanitized or replaced; starts timer and in-flight gauge | — | Correlation and bounded request measurements |
| `_finish_request_observation(error)` (API) | decrements the in-flight gauge once | — | Prevents gauge drift on errors |
| `_log_request(response)` (API) | Flask response; logs bounded route/method/status/duration and `X-Request-ID` | — | Access log without query string, headers, or body |
| `_database_available()` (API) | `bool`; opens and closes one PostgreSQL connection | — | Shared readiness decision; failure text is not logged or returned |
| `health_live()`, `health_ready()` (API) | GET; 200/503 as described in `docs/OBSERVABILITY.md` | — | Split liveness from DB readiness |
| `_metrics_enabled()`, `_metrics_token()`, `_metrics_authorized()` (API) | enabled: `1/true/yes/on` or unset/false; token: non-empty secret; auth: exact `Bearer <token>` | disabled/empty | Fail-closed gate for `/metrics` |
| `metrics()` (API) | GET; 404 disabled, 401 unauthenticated, 200 with bearer token | — | Opt-in Prometheus endpoint |
| `on_starting`, `child_exit` (gunicorn) | no-op without `PROMETHEUS_MULTIPROC_DIR` | — | Clear stale mmaps and mark dead workers |
| `configure_tracing(component)` (tracing) | `ASH_TRACING_ENABLED` boolean; `ASH_OTLP_ENDPOINT` absolute http(s) URL with host and no userinfo; ratio in `[0,1]` | disabled | Opt-in OTLP/HTTP tracing; invalid config fails startup instead of silently dropping spans |
| `Tracing.start_agent_span(event)` (tracing) | decoded event mapping; optional valid `trace_id`/`span_id`/`parent_span_id` | new trace | Reconstructs the exact agent span; malformed context never rejects the event |
| `Tracing.start_span`, `start_root_span`, `start_server_span` (tracing) | stable name; optional parent/kind/attributes/links | no-op span | Best-effort span creation; SDK failures are logged by type and swallowed |
| `Tracing.links_for_events(events)` (tracing) | iterable of event mappings | `[]` | Links a batch-root span to each valid event trace |
| `trace_context_strings(event)`, `trace_columns(event)` (tracing) | any mapping; W3C IDs validated and normalized | `None` / all-`None` columns | Invalid context is ignored and stored as `NULL` |
| `SpanHandle.record_exception(error)` (tracing) | any exception | no-op | Records only `exception.type` and ERROR status, never message/traceback |
| `_ForcedIdGenerator` (tracing) | thread-local 128-bit trace / 64-bit span IDs | random non-zero | Emits the agent's exact IDs once; reports forced IDs as non-random |
| `shutdown_tracing()`, `Tracing.shutdown()` (tracing) | no input; idempotent | no-op when disabled | Flush queued spans; failures are logged and swallowed |
| `configure_log_export(component)` (log export) | `ASH_LOG_OTLP_ENABLED` boolean; `ASH_OTLP_LOGS_ENDPOINT` absolute http(s) URL with host and no userinfo | disabled | Opt-in OTLP/HTTP log export; invalid config fails startup instead of silently dropping logs |
| `LogExport.force_flush()`, `LogExport.shutdown()` (log export) | no input; idempotent | no-op when disabled | Flush queued records; failures are logged by type and swallowed |
| `_register_telemetry_shutdown()` (API) | no input; registers log-export then tracing `atexit` handlers | — | Flushes queued telemetry on normal gunicorn worker exit (log export last) |
| `watchdog_kick()`, `start_watchdog()` (agent) | no-op without `NOTIFY_SOCKET`; interval ≥ 1s | — | Heartbeat independent of command traffic |
| `DB_AVAILABLE` (metric) | gauge, `0` or `1` | `1` after a successful write | Consumer database health signal |
| `API_DATABASE_AVAILABLE` (metric) | gauge, `0` or `1`, `multiprocess_mode=max` | `0` until a readiness check succeeds | API database health signal |
| `_processing_lock` (consumer) | `threading.Lock` | — | Serializes message processing/commit against the flush timer |
| `batch_raw_texts` (consumer) | list parallel to `batch_buffer`; `str` or `None` | `[]` | Raw text retained with buffered events |
| `MAX_TEXT_LENGTH` (consumer) | `1_048_576` | — | Maximum `TEXT` field length accepted |
| `MAX_RAW_EVENT_LENGTH` (consumer) | `2_097_152` | — | Maximum raw Kafka payload length accepted |
| `MAX_FIELD_LENGTHS` (consumer) | field name → maximum length | — | Pre-check against varchar column widths |
| `INTEGER_FIELDS` (consumer) | `("uid", "pid", "ppid", "exit_code")` | — | Integer type check |
| `VALID_SOURCES`, `VALID_EVENT_TYPES` (consumer) | string allow-lists | — | Source/event-type validation |

## Simpler, safer target architecture

1. **One source of truth for the pipeline: PostgreSQL (implemented).** The
   agent's local JSONL remains the host-side forensic copy, but the consumer's
   offset commit is now conditional on the database transaction. On DB
   failure, the batch is retained and the offset is not advanced.
2. **One validation boundary (implemented).** Validation runs once, at the
   consumer edge: UUIDs, timestamps, allow-listed sources/event types, scalar
   types, and length caps. Invalid events go to the DLQ; a batch that still
   fails is retried per row so valid events cannot be poisoned by one bad row.
3. **One integrity representation (input stored).** `raw_event_text` now keeps
   the exact signed line alongside the JSONB copy; the Kafka E2E verifies the
   hash from it. The API-side recomputation is the remaining follow-up;
   link-only checks are a consistency check, not tamper evidence.
4. **Visible fail-open (partially done).** `ash_consumer_database_available`
   and Kafka lag now expose DB stalls. The agent still does not break a shell,
   but its dropped events, failed spool writes, and failed Kafka sends are not
   all counted yet. Silence is the problem, not fail-open itself.
5. **Keep the real E2E (implemented).** The startup bug found here is exactly
   the class of defect that unit tests with `object.__new__` cannot catch. The
   Kafka job stays blocking in `ci-success`.

Items 1, 2, and 5 are implemented in this PR; item 3 has its data captured and
needs the API-side check next; item 4 remains the main open reliability gap.
