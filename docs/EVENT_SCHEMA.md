# ASH Event Schema Reference (v1.0)

## Overview

All ASH events are JSON objects written as newline-delimited JSON (JSONL). Every event MUST include the required fields. Optional fields are included when relevant to the event type.

## Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `event_id` | UUID string | Globally unique event identifier |
| `schema_version` | string | Always "1.0" for this version |
| `timestamp` | ISO 8601 | Event time with millisecond precision |
| `hostname` | string | FQDN or hostname of source system |
| `source` | enum | Monitoring layer that generated the event |
| `event_type` | enum | Classification of the event |

## Source Values

| Source | Description |
|--------|-------------|
| `bash-debug` | Bash shell DEBUG trap |
| `bash-session` | Session lifecycle events |
| `bash-diff` | File change detection via diff comparison |
| `auditd` | Linux audit subsystem (kernel-level) |
| `inotify` | Filesystem event notification |
| `docker-events` | Docker daemon event stream |
| `k8s-audit` | Kubernetes API audit webhook |
| `process-accounting` | Process accounting (acct/pacct) |

## Event Types

| Event Type | Description |
|-----------|-------------|
| `command_start` | Command execution began |
| `command_end` | Command execution completed (with exit code) |
| `file_modify` | File content was changed |
| `file_create` | New file created |
| `file_delete` | File removed |
| `file_move` | File renamed or moved |
| `file_attrib` | File permissions/ownership changed |
| `session_start` | New shell session opened |
| `session_end` | Shell session closed |
| `privilege_escalation` | sudo/su/doas detected |
| `alert` | Security alert triggered |
| `container_start` | Container started |
| `container_stop` | Container stopped |
| `container_exec` | Exec into container |

## Full Field Reference

```json
{
    "event_id": "550e8400-e29b-41d4-a716-446655440000",
    "schema_version": "1.0",
    "timestamp": "2025-01-15T14:30:00.123Z",
    "hostname": "web-prod-01.example.com",
    "source": "bash-debug",
    "event_type": "command_start",

    "user": "deploy",
    "uid": 1001,
    "euid": 0,
    "gid": 1001,
    "session_id": "a1b2c3d4-...",
    "pid": 12345,
    "ppid": 12340,
    "pgrp": 12345,
    "tty": "/dev/pts/0",

    "command": "systemctl restart nginx",
    "command_args": ["systemctl", "restart", "nginx"],
    "cwd": "/home/deploy",
    "shell": "/bin/bash",
    "bash_subshell": 0,
    "lineno": 1,

    "exit_code": 0,
    "signal": null,
    "duration_ms": 1523.4,
    "stdout": "● nginx.service - ...",
    "stderr": "",
    "output_truncated": false,

    "file_path": null,
    "file_path_previous": null,
    "diff_content": null,
    "inotify_event": null,

    "ssh_connection": "10.0.1.50 52341 10.0.1.100 22",
    "ssh_tty": "/dev/pts/0",

    "container_id": null,
    "container_name": null,
    "container_image": null,
    "docker_action": null,
    "k8s_namespace": null,
    "k8s_pod": null,

    "audit_key": null,

    "risk_score": 3,
    "risk_flags": ["service_restart"],

    "prev_hash": "a1b2c3d4e5f6...",
    "event_hash": "f6e5d4c3b2a1..."
}
```

## Integrity Fields

| Field | Description |
|-------|-------------|
| `prev_hash` | SHA-256 hash of the previous event in the chain |
| `event_hash` | SHA-256 of (`prev_hash` + current event without hash fields) |

To verify integrity, iterate events in order and recompute each hash. Any mismatch indicates tampering.

## Example Events

### Command Start
```json
{"event_id":"...","schema_version":"1.0","timestamp":"2025-01-15T14:30:00.123Z","hostname":"prod-01","source":"bash-debug","event_type":"command_start","user":"root","session_id":"...","pid":1234,"command":"apt update","cwd":"/root","prev_hash":"...","event_hash":"..."}
```

### File Modification
```json
{"event_id":"...","schema_version":"1.0","timestamp":"2025-01-15T14:30:05.456Z","hostname":"prod-01","source":"bash-diff","event_type":"file_modify","user":"root","session_id":"...","command":"sed -i 's/old/new/' /etc/config","file_path":"/etc/config","diff_content":"--- a\n+++ b\n@@ -1 +1 @@\n-old\n+new","prev_hash":"...","event_hash":"..."}
```

### Session End
```json
{"event_id":"...","schema_version":"1.0","timestamp":"2025-01-15T15:00:00.000Z","hostname":"prod-01","source":"bash-session","event_type":"session_end","user":"root","session_id":"...","session_start":"2025-01-15T14:00:00.000Z","duration_seconds":3600,"events_in_session":142,"prev_hash":"...","event_hash":"..."}
```
