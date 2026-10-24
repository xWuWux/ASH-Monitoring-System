# ASH Architecture

## System Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                    MONITORED SERVERS                              │
│                                                                  │
│  ┌─────────────┐  ┌─────────────┐  ┌────��────────────────────┐ │
│  │ Bash/Zsh/   │  │   auditd    │  │   inotify / Docker      │ │
│  │ Fish Shell  │  │  (kernel)   │  │   events                │ │
│  └──────┬──────┘  └──────┬──────┘  └────────────┬────────────┘ │
│         │                 │                      │              │
│         ▼                 ▼                      ▼              │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                   ASH AGENT (ash-agent.sh)                │   │
│  │                                                           │   │
│  │  • Structured JSON events (schema v1.0)                   │   │
│  │  • Sensitive data redaction                               │   │
│  │  • Hash-chained tamper-evident logging                    │   │
│  │  • Rate limiting + output truncation                      │   │
│  │  • Session tracking (UUID per login)                      │   │
│  │  • Crash recovery + state persistence                     │   │
│  └────────────────────────┬──────────────────────────────────┘   │
│                           ��                                      │
│                           ▼                                      │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │              LOCAL SPOOL QUEUE (/var/spool/ash)           │   │
│  │                                                           │   │
│  │  • Write-ahead log style persistence                      │   │
│  │  • Retry timer (30s flush cycle)                          │   │
│  │  • Size-bounded (1GB default)                             │   │
│  │  • Guaranteed delivery with backpressure                  │   │
│  └────────────────────────┬──────────────────────────────────┘   │
│                           │                                      │
└───────────────────────────┼──────────────────────────────────────┘
                            │
                            ▼
              ┌─────────────────────────┐
              │     Apache Kafka        │
              │  (topic: ash-logs)      │
              └────────────┬────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────────┐
│                    CENTRAL SERVER                                 │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │             ASH CONSUMER (ash-consumer.py)                │   │
│  │                                                           │   │
│  │  • Batch processing (configurable size + timeout)         │   │
│  │  • Event deduplication (UUID-based)                       │   │
│  │  • Schema validation                                      │   │
│  │  • Retry logic with exponential backoff                   │   │
│  │  • JSON logs + event correlation (event_id/session_id)    │   │
│  │  • Metrics, liveness, readiness (:9090)                   │   │
│  │  • Retention management (archive + delete)                │   │
│  └───────┬─────────────────┬──────────────────┬─────────────┘   │
│          │                 │                  │                  │
│          ▼                 ▼                  ▼                  │
│  ┌──────────────┐  ┌──────────────┐  ┌────��─────────────────┐  │
│  │  PostgreSQL  │  │  JSONL Files │  │   Alert Engine        │  │
│  │  (indexed)   │  │  (per-host)  │  │   (MITRE ATT&CK)     │  │
│  └──────┬───────┘  └──────────────┘  └──────────┬───────────┘  │
│         │                                        │              │
│         ▼                                        ▼              │
│  ┌──────────────┐                        ┌──────────────────┐   │
│  │   REST API   │                        │  Slack/Discord   │   │
│  │   (:8080)    │                        │  Webhooks        │   │
│  └──────────────┘                        └──────────────────┘   │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

## Data Flow

1. **Shell command executed** → DEBUG trap fires in bash
2. **Event constructed** → Structured JSON with UUID, session, user context
3. **Redaction applied** → Passwords, keys, tokens stripped
4. **Hash chain signed** → SHA-256 chain linking to previous event
5. **Local log written** → Atomic flock-protected append to `events.jsonl`
6. **Spool queued** → Written to `/var/spool/ash/pending/` for Kafka delivery
7. **Kafka produced** → Reliable delivery with ack=1 and retry
8. **Consumer receives** → Validates, deduplicates, batches
9. **Storage written** → PostgreSQL (indexed) + JSONL files (archive)
10. **Alerts evaluated** → Pattern matching against threat rules
11. **Webhook fired** → Slack/Discord notification on match

## Monitoring Layers

| Layer | Technology | Coverage | Bypass Difficulty |
|-------|-----------|----------|-------------------|
| 1. Shell | DEBUG trap (bash), preexec (zsh/fish) | Interactive commands | Easy (unset trap) |
| 2. Kernel | auditd execve rules | ALL process execution | Hard (requires root) |
| 3. Filesystem | inotify watches | File modifications | Medium (inotify limits) |
| 4. Container | Docker event stream | Container lifecycle | Medium |

## Observability

The consumer and API emit one JSON object per application log record to
stdout; the consumer also writes a bounded rotating file. Event-related
consumer lines carry `event_id`/`session_id`, and API responses carry
`X-Request-ID`.

Health is split into liveness and readiness. Consumer readiness requires a
successful storage path (PostgreSQL when enabled, local JSONL always) and no
flush left pending. API readiness requires a PostgreSQL connection. Docker
probes readiness; the consumer's systemd unit uses `Type=notify` and a
watchdog. The consumer's Kafka lag gauge is explicitly position-based, not
committed-offset lag, so alerts should also use the last-successful-flush
timestamp.

Agent logs stay local and append-only; agent events reach the central server
through Kafka. See `docs/OBSERVABILITY.md` for the schema, metrics,
environment-variable domains, and security rules. Distributed tracing and the
monitoring stack are later PRs.

## Event Schema (v1.0)

Every event conforms to `src/common/schema/event-v1.json`. Key fields:

- `event_id` — UUID, globally unique
- `schema_version` — "1.0" for forward compatibility
- `timestamp` — ISO 8601 with milliseconds
- `hostname` — Source system
- `source` — Which layer generated it (bash-debug, auditd, inotify, etc.)
- `event_type` — What happened (command_start, file_modify, session_end, etc.)
- `session_id` — Correlates all events within one login session
- `prev_hash` / `event_hash` — Tamper-evident chain

## Security Model

- **Redaction**: Credentials never reach disk or network
- **Integrity**: SHA-256 hash chain detects log tampering
- **Immutability**: `chattr +a` on log files (optional)
- **Transport**: Kafka TLS (configurable)
- **Access**: JWT + RBAC on API (admin/analyst/readonly)
- **Isolation**: Agent runs as root (necessary for auditd); consumer/API run as `ash` user
