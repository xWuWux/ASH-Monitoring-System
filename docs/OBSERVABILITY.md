# ASH Observability

This document covers the observability foundation delivered in PR 1
(structured logs, request/event correlation, health signals, and Prometheus
metrics) and distributed tracing delivered in PR 2. The Grafana/Tempo/Loki
monitoring stack is delivered in PR 3 and is not required for the behavior
below.

## Design rules

1. **Application logs are JSON on stdout.** systemd/journald and Docker
   capture stdout; the consumer additionally writes a bounded JSON file for
   existing file-based deployments. Gunicorn's own process-lifecycle
   messages still use Gunicorn's format unless its `logconfig_dict` is
   overridden; ASH's request/access and error logs are JSON.
2. **The consumer and API log centrally; the agent does not.** Agent events
   stay in the local append-only `events.jsonl` / `agent.log`. Centralizing
   per-command agent lines would duplicate the Kafka event stream and increase
   the blast radius of a compromised agent.
3. **Never log a credential.** Webhook URLs are reduced to scheme + host.
   Query strings, request headers, request bodies, JWTs, database URLs, and
   command text are not included in service logs.
4. **Health must answer a real question.** Liveness means "the process is
   alive"; readiness means "the consumer/API can durably serve traffic right
   now." A listening metrics port is not a health signal.
5. **Metrics may be imperfect, but they must say so.** The Kafka lag gauge is
   position-based, not committed-offset lag; its help text and this document
   say that explicitly.
6. **Tracing never changes the data path.** Span creation, attachment, export,
   and shutdown are best-effort. A tracing failure is logged and swallowed;
   it can never drop, duplicate, or delay an event or an HTTP response.
7. **No per-host OpenTelemetry runtime.** The agent emits portable W3C IDs and
   the consumer reconstructs the agent span. Only the consumer and API run an
   OTel SDK, and only when tracing or log export is explicitly enabled.
8. **Central log export is opt-in and best-effort.** stdout remains
   authoritative; a broken OTLP log exporter cannot fail or delay a request or
   event, and it never removes the local line.

## Log schema

Every consumer/API application log record is one JSON object:

```json
{"timestamp":"2026-10-24T19:00:00.123Z","severity":"INFO","component":"ash-api","logger":"ash-api","message":"request completed","pid":123,"request_id":"9f0c...","method":"GET","path":"/api/v1/events","route":"/api/v1/events","status_code":200,"duration_ms":12.4,"remote_addr":"10.0.0.5"}
```

| Field | Domain | Notes |
|-------|--------|-------|
| `timestamp` | ISO-8601 UTC with milliseconds, `Z` suffix | Generated per record |
| `severity` | `DEBUG`, `INFO`, `WARNING`, `ERROR`, `CRITICAL` | Python logging level |
| `component` | `ash-consumer`, `ash-api`, `ash-alerting` | Derived from logger name |
| `logger` | logger name | For example `ash-consumer` |
| `message` | string | Static message; no secrets by construction |
| `pid` | positive integer | Worker/process ID |
| `request_id` | 1-128 chars from `[A-Za-z0-9._:-]` | API only; inbound `X-Request-ID` or generated UUID |
| `event_id` | UUID string | Consumer processing/DLQ messages |
| `session_id` | UUID string | Consumer processing/DLQ messages |
| `method` | HTTP method | API access logs |
| `path` | URL path only, no query string | API access logs |
| `route` | Flask rule or `unmatched` | Bounded metric/log label |
| `status_code` | HTTP status integer | API access logs |
| `duration_ms` | non-negative number | API request duration |
| `remote_addr` | IP string or null | API peer address; not trusted for auth |
| `batch_size` | non-negative integer | Consumer flush failures |
| `channel` | short string | For example `kafka`, `observability` |
| `webhook_index` | zero-based integer | Alert delivery; position in the configured webhook list. Never the URL, host, or path, because those contain the credential. |
| `message` / `exception` | string | Redacted centrally: URL userinfo and `password=`/`token:` assignments become `[redacted]` |
| `error_type` | exception class or reason code | Safe replacement for exception text |
| `exception` | stack trace string | Only where the exception text is safe to retain (consumer flush/handler errors) |
| `trace_id` | 32 lowercase hex chars, not all zero | Active span's trace ID, or the explicitly logged event trace ID |
| `span_id` | 16 lowercase hex chars, not all zero | Active span's ID, or the explicitly logged event span ID |

`trace_id`/`span_id` appear automatically while a span is current. When a
record explicitly sets them (for example an agent event log line), the
explicit values win, so the log can identify the agent span even while the
consumer's processing span is active.

### Correlation

* **API:** every response carries `X-Request-ID`. The same value is in the
  access log. Unsafe or oversized inbound values are replaced with a UUID.
* **Consumer:** every event-related log line carries `event_id` and, when
  present, `session_id`. The Kafka payload's `event_id` is the stable join key
  to the database, JSONL files, DLQ, and the synthetic agent span.
* **Agent → consumer:** the agent's `events.jsonl` line contains `event_id`;
  the consumer logs that ID when an event is rejected or duplicated. It also
  contains the W3C trace context used to reconstruct the trace (below).

## Log destinations and rotation

| Component | stdout | File | Bounds |
|-----------|--------|------|--------|
| Consumer | JSON | `${log_dir}/consumer.log` by default | `log_max_bytes` (default 10 MiB) × `log_backup_count` (default 5) |
| API | JSON | none by default; `api-<pid>.log` when `ASH_LOG_DIR` is set | Same rotation settings; one file per gunicorn worker because sharing a rotating file across processes is unsafe |
| Alerts | none | `${log_dir}/alerts.jsonl` | Append-only data stream; rotate externally like the agent event log, never truncate in place |
| Agent | none | `${ASH_LOG_DIR}/agent.log` and `events.jsonl` | Append-only by design; use external logrotate for `agent.log` only. **Never** `copytruncate` `events.jsonl` or the hash chain. |
| Docker | JSON where emitted | Docker `json-file` | Compose caps every service at 10 MiB × 3 files |
| systemd | JSON | journald | Use `SystemMaxUse=`/`SystemMaxFileSize=` in `journald.conf` |

The consumer's file rotation is a standard `RotatingFileHandler`; it is not
used on the agent's hash-chained event log. Truncating that chain would break
the integrity proof.

### Optional OTLP log export

The consumer and API can additionally export application logs over OTLP/HTTP
to the collector in the monitoring stack. This is **off by default** and is
independent of tracing: operators can centralize logs without spans, or spans
without logs.

* stdout (and the consumer's bounded file) remains authoritative and is always
  kept. A failed export never removes or delays the local line.
* `ASH_LOG_OTLP_ENABLED` is the strict boolean flag; enabling it requires a
  full `ASH_OTLP_LOGS_ENDPOINT` (http/https, host, no userinfo).
* The OTel batch processor is asynchronous. Shutdown flushes with the
  exporter's 5-second timeout; `SIGKILL`/worker timeouts lose queued records.
* OTLP records use `service.name` as the resource and carry the same
  allow-listed fields as JSON logs (`component`, `logger`, `pid`, request/event
  correlation, and trace IDs). Exception records include only
  `exception.type`, never the message or traceback.
* `trace_id`/`span_id` come from the explicit record fields when both are
  valid, otherwise from the active span. That is what makes a Loki line
  clickable through to its Tempo trace.
* No Alloy/Promtail, Docker-socket log tailing, or file tailing is used. The
  agent still does not ship logs.

## Health endpoints

### Consumer (`metrics_host:metrics_port`, default `127.0.0.1:9090`)

| Endpoint | HTTP 200 when | HTTP 503 when |
|----------|---------------|---------------|
| `/health/live` | Process is running and not stopping | Shutdown has started |
| `/health/ready` | Running, the last flush did not leave data pending, and PostgreSQL is available (or disabled) | A flush failed and its batch is still pending, or the database gauge is 0 |
| `/health` | Alias for `/health/ready` | Same as readiness |

The readiness body is stable and secret-free:

```json
{"status":"ready","checks":{"consumer":"running","database":"connected","flush":"ok"},"last_message_at":"...","last_flush_success_at":"...","uptime_seconds":42.1}
```

A consumer that never receives a message is still ready. A consumer holding an
undurable batch is not. Docker's healthcheck uses `/health/ready`; systemd
uses `Type=notify` plus `WatchdogSec=60`, with a heartbeat every 10 seconds.

### API (`/health/*` on the API port)

| Endpoint | Meaning |
|----------|---------|
| `/health/live` | The API process can answer HTTP; never checks PostgreSQL |
| `/health/ready` | A PostgreSQL connection can be opened; `503` with `{"status":"degraded","checks":{"database":"disconnected"}}` otherwise |
| `/health` | Legacy body `{"status":"healthy","database":"connected"}` / `{"status":"degraded","database":"disconnected"}`; same decision as readiness |

Docker uses readiness for container health. The consumer systemd unit uses
`Type=notify` plus a watchdog; the API unit exposes the same endpoints for an
external checker or load balancer. Liveness is for restart decisions only.

## Distributed tracing

Tracing is **disabled by default**. When enabled, the consumer and API export
OTLP/HTTP spans to `ASH_OTLP_ENDPOINT`; the agent never runs an OTel SDK.

### Trace model

| Producer | Span | Parent | Notes |
|----------|------|--------|-------|
| Agent | `ash.agent.<event_type>` | `parent_span_id` when present | The consumer creates this span with the agent's **exact** `trace_id`/`span_id`; it is not a new span with a copied attribute |
| Consumer | `ash.consumer.process_event` | Reconstructed agent span | One per Kafka event |
| Consumer | `ash.consumer.flush_batch` | none (root) | A batch can contain many traces, so it links to each event span instead of inventing a parent |
| Consumer | `ash.db.insert_events` | `ash.consumer.flush_batch` | Child of the batch root; only when PostgreSQL is enabled |
| API | `ash.api.request` | Inbound W3C `traceparent` when valid | Server span; no outbound HTTP calls are traced yet |

The agent generates one trace per command. `command_start` is the root; the
matching `command_end`, `privilege_escalation`, and file-change events reuse
that trace and are parented to the command span. Session and non-bash events
are separate roots. The IDs are optional in the event schema: a malformed or
missing context starts a new consumer-side trace rather than dead-lettering
the event.

Sampling is deterministic per trace ID (`ASH_TRACING_SAMPLE_RATIO`). This is
why a `command_end` child is never exported when its `command_start` root was
dropped at a partial ratio. An inbound API `traceparent` marked sampled still
wins over a local ratio of `0`, so an upstream trace is not silently severed.
Batch-root links report the same ratio-derived decision as the reconstructed
agent span, so a tail sampler or span-metrics connector is never told that a
dropped trace was sampled.

### Storage and retrieval

`command_logs` stores the validated `trace_id`, `span_id`, and
`parent_span_id` (all nullable, with `idx_cmd_logs_trace`). Invalid values are
stored as `NULL`; event processing still succeeds. `GET /api/v1/events`
returns those columns, and `GET /api/v1/events/<event_id>` returns them as
part of the full row.

### Safety boundaries

* Attributes contain event metadata only (`event_id`, `event_type`, `source`,
  `hostname`, `session_id`, user, exit code, risk score, HTTP method/route),
  never command text, output, headers, query strings, JWTs, or database URLs.
* Exception recording stores only `exception.type` and an ERROR status, never
  `str(error)` or traceback text.
* `ASH_OTLP_ENDPOINT` rejects userinfo so a credential cannot be placed in
  configuration or logs. Use HTTPS for a collector on another host; plain
  HTTP is intended for a loopback/sidecar collector.
* Enabling tracing without an endpoint, or with an invalid ratio/URL, fails
  startup instead of silently dropping spans.
* SDK creation, span attachment, export, and shutdown failures are logged by
  type and swallowed. A broken exporter cannot fail a flush or an API request.
* The API flushes queued spans from an `atexit` handler on normal gunicorn
  worker exit. `SIGKILL`/worker timeouts lose queued spans; that is accepted
  best-effort behavior, not a data-loss path for events.

## Metrics

### Consumer

Served at `/metrics` on the same listener as health.

| Metric | Type | Meaning |
|--------|------|---------|
| `ash_consumer_events_received_total{source,event_type}` | counter | Valid events received from Kafka |
| `ash_consumer_events_processed_total` | counter | Events durably written |
| `ash_consumer_events_failed_total{reason}` | counter | Processing/flush failures |
| `ash_consumer_events_deduplicated_total` | counter | Duplicate events skipped |
| `ash_consumer_events_dead_lettered_total{reason}` | counter | Events sent to the DLQ |
| `ash_consumer_batch_flush_seconds` | histogram | Flush latency |
| `ash_consumer_db_write_seconds` | histogram | PostgreSQL write latency |
| `ash_consumer_kafka_lag` | gauge | Estimated records behind the **last fetched position**, not committed-offset lag |
| `ash_consumer_kafka_assigned_partitions` | gauge | Partitions currently assigned |
| `ash_consumer_last_message_timestamp_seconds` | gauge | Unix time of the last Kafka message |
| `ash_consumer_last_flush_success_timestamp_seconds` | gauge | Unix time of the last durable flush |
| `ash_consumer_flush_failures_total` | counter | Flushes that left a batch pending |
| `ash_consumer_batch_buffer_size` | gauge | Events currently buffered |
| `ash_consumer_database_available` | gauge | 1 after a successful DB write, 0 while failing |
| `ash_consumer_ready` | gauge | 1 when readiness would return 200 |

A DB stall can leave `ash_consumer_kafka_lag` temporarily low because the
consumer has already fetched the records it cannot write. Alert on
`last_flush_success_timestamp_seconds` becoming stale and on
`ash_consumer_ready == 0`, not on lag alone.

### API

Disabled by default; returns `404` unless `ASH_METRICS_ENABLED=true`. When
enabled, **both** `ASH_METRICS_ENABLED=true` and a non-empty
`ASH_METRICS_TOKEN` are required; requests must send
`Authorization: Bearer <token>`. With no token, every request returns `401`
(fail closed). The API port is commonly published, so this endpoint must not
be exposed unauthenticated.

| Metric | Type | Meaning |
|--------|------|---------|
| `ash_api_requests_total{method,route,status}` | counter | Requests by bounded route rule |
| `ash_api_request_duration_seconds{method,route}` | histogram | Request duration |
| `ash_api_inflight_requests` | gauge | Requests currently being handled |
| `ash_api_database_available` | gauge | 1 when the last readiness check opened PostgreSQL; aggregated as the maximum across workers |

Under gunicorn, `PROMETHEUS_MULTIPROC_DIR` enables mmap aggregation across
workers. `src/consumer/gunicorn.conf.py` clears stale files at master start
and calls `mark_process_dead()` when a worker exits.

### Installed layout

`scripts/install.sh` places the executable at `/usr/local/bin/ash-consumer`
and the shared modules (`ash_observability.py`, `ash_tracing.py`,
`ash_log_export.py`, `ash_alerting.py`, `api_server.py`,
`gunicorn.conf.py`) in `/usr/local/lib/ash`. The consumer adds that directory to `sys.path` before
importing its siblings, and the systemd unit also sets
`PYTHONPATH=/usr/local/lib/ash:...`; running from a source checkout or the
container, where the files are siblings, needs neither.

## Environment variables

All variables are optional unless marked. Precedence is environment >
JSON config file > built-in default. Invalid values fail startup with a
message naming the variable; empty values are rejected where an empty value
would silently point at the wrong broker, URL, or directory.

### Consumer

| Variable | Domain | Default | Effect |
|----------|--------|---------|--------|
| `ASH_KAFKA_BROKERS` | Comma-separated `host:port` list, at least one | `localhost:9092` | Kafka bootstrap servers |
| `ASH_KAFKA_TOPIC` | Non-empty topic string | `ash-logs` | Consumed topic |
| `ASH_KAFKA_GROUP_ID` | Non-empty group string | `ash-consumer-group` | Consumer group |
| `ASH_DATABASE_URL` | Non-empty PostgreSQL URL | `postgresql://ash:password@localhost/ash_logs` | Database connection |
| `ASH_DATABASE_ENABLED` | `1/true/yes/on` or `0/false/no/off` | `false` | Whether PostgreSQL is authoritative |
| `ASH_ALERTING_ENABLED` | Same boolean domain | `false` | Enable the alert engine |
| `ASH_LOG_DIR` | Non-empty writable directory path | `/var/log/ash` | JSON file log directory |
| `ASH_LOG_LEVEL` | `DEBUG`, `INFO`, `WARNING`, `ERROR`, `CRITICAL` | `INFO` | Root log level |
| `ASH_LOG_MAX_BYTES` | Integer ≥ 0; 0 disables rotation | `10485760` | Per-file rotation threshold |
| `ASH_LOG_BACKUP_COUNT` | Integer ≥ 0 | `5` | Retained rotated files |
| `ASH_METRICS_HOST` | Hostname or IP address | `127.0.0.1` | Health/metrics bind address |
| `ASH_METRICS_PORT` | Integer 1-65535 | `9090` | Health/metrics TCP port |
| `ASH_BATCH_SIZE` | Integer ≥ 1 | `100` | Events per flush |
| `ASH_BATCH_TIMEOUT` | Finite number ≥ 0.001 | `5.0` | Seconds before a partial batch flushes |
| `ASH_ALERT_LOG` | Writable file path; unset or empty uses the default | `/var/log/ash/alerts.jsonl` | Alert JSONL destination when the consumer does not pass an explicit path |
| `ASH_TRACING_ENABLED` | `1/true/yes/on` or `0/false/no/off`; unset = disabled | `false` | Enables OTLP span export; any other value fails startup |
| `ASH_OTLP_ENDPOINT` | Absolute `http`/`https` URL with a host, no userinfo | empty | OTLP/HTTP traces URL; required when tracing is enabled |
| `ASH_TRACING_SAMPLE_RATIO` | Finite number in `[0.0, 1.0]` | `1.0` | Trace-ID-ratio sampling; a sampled API parent still wins |
| `ASH_LOG_OTLP_ENABLED` | `1/true/yes/on` or `0/false/no/off`; unset = disabled | `false` | Exports application logs over OTLP/HTTP; independent of tracing |
| `ASH_OTLP_LOGS_ENDPOINT` | Absolute `http`/`https` URL with a host, no userinfo | empty | OTLP/HTTP logs URL; required when log export is enabled |

The JSON config keys `log_name`, `log_max_bytes`, `log_backup_count`,
`metrics_host`, and `metrics_port` mirror these settings; see
`config/consumer.conf.example`.

### API

| Variable | Domain | Default | Effect |
|----------|--------|---------|--------|
| `ASH_LOG_LEVEL` | Same levels as above | `INFO` | Root log level; an invalid value fails startup |
| `ASH_LOG_DIR` | Non-empty writable directory path or unset | unset | Enables per-worker `api-<pid>.log`; stdout is always JSON |
| `ASH_METRICS_ENABLED` | `1/true/yes/on` or `0/false/no/off`; unset = false | `false` | Serves `/metrics` instead of 404; any other value fails startup |
| `ASH_METRICS_TOKEN` | Non-empty secret or empty | empty | Bearer token required by `/metrics`; empty fails closed |
| `ASH_TRACING_ENABLED` | `1/true/yes/on` or `0/false/no/off`; unset = disabled | `false` | Enables OTLP span export; any other value fails startup |
| `ASH_OTLP_ENDPOINT` | Absolute `http`/`https` URL with a host, no userinfo | empty | OTLP/HTTP traces URL; required when tracing is enabled |
| `ASH_TRACING_SAMPLE_RATIO` | Finite number in `[0.0, 1.0]` | `1.0` | Trace-ID-ratio sampling for new traces; a sampled inbound `traceparent` wins |
| `ASH_LOG_OTLP_ENABLED` | `1/true/yes/on` or `0/false/no/off`; unset = disabled | `false` | Exports application logs over OTLP/HTTP; independent of tracing |
| `ASH_OTLP_LOGS_ENDPOINT` | Absolute `http`/`https` URL with a host, no userinfo | empty | OTLP/HTTP logs URL; required when log export is enabled |
| `PROMETHEUS_MULTIPROC_DIR` | Writable directory path | unset in single-process mode; `/tmp/ash-prometheus` in the image | Aggregates metrics across gunicorn workers |

### Agent and deployment

| Variable | Domain | Default | Effect |
|----------|--------|---------|--------|
| `ASH_WATCHDOG_INTERVAL` | Integer seconds ≥ 1 | `10` | Interval between `WATCHDOG=1` notifications; keep below `WatchdogSec=30` |

## Security notes

* Webhook URLs are logged as `scheme://host[:port]` only. Delivery failures
  log the exception class, not `str(exception)` (which embeds the URL).
* Trace attributes never include command text, output, headers, query strings,
  or credentials. Exception events carry only the exception type. The OTLP
  endpoint is validated and cannot contain URL userinfo.
* The agent emits trace IDs but does not send telemetry directly; only the
  consumer/API export spans, and only when tracing is enabled.
* API access logs include the path but never the query string, headers, or
  body. Search terms and JWTs therefore do not reach central logs.
* API `/metrics` is disabled by default and fails closed when enabled without
  a token. The consumer metrics/health port is not published by the Docker
  Compose file; it is reachable only on the internal network.
* Health bodies never include database URLs, exception text, broker lists, or
  environment values.
* `X-Request-ID` accepts only 1-128 safe characters; invalid values are
  replaced, preventing header/log injection.
* The API speaks plain HTTP in this repository. Put it behind a
  TLS-terminating proxy before publishing it; the JWT and the `/metrics`
  bearer token are only as protected as the transport. Keep `/metrics` on
  the internal network even when the token is enabled.

## Verification

```bash
# Consumer (after it starts)
curl -fsS http://127.0.0.1:9090/health/live
curl -fsS http://127.0.0.1:9090/health/ready
curl -fsS http://127.0.0.1:9090/metrics | grep '^ash_consumer_'

# API
curl -fsS http://127.0.0.1:8080/health/live
curl -fsS http://127.0.0.1:8080/health/ready
curl -fsS -H "Authorization: Bearer $ASH_METRICS_TOKEN" \
  http://127.0.0.1:8080/metrics | grep '^ash_api_'

# Structured logs (one JSON object per line)
tail -n 1 /var/log/ash/consumer.log | jq .

# Trace the exact agent span for an event (PostgreSQL)
psql "$ASH_DATABASE_URL" -c \
  "SELECT event_id, trace_id, span_id, parent_span_id
     FROM command_logs ORDER BY log_timestamp DESC LIMIT 5;"
```

With tracing enabled, search the collector/Tempo for the returned
`trace_id`; the span with `span_id` equal to the row's `span_id` is the
reconstructed agent span, and `ash.consumer.process_event` is its child.

The blocking `kafka-e2e` CI job waits for `/health/ready`, checks the
consumer metrics, and parses every consumer log line as JSON.
