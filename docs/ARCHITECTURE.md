
## Architecture

### Local Mode
```
bash shell → DEBUG trap → log_command() → file tracking → local log
```

### Distributed Mode
```
[Producer Servers] → [Kafka Message Queue] → [ASH Consumer] → [Centralized Storage]
```

### Components Overview

| Component | Purpose | Technology |
|-----------|---------|------------|
| **ASH Agent** | Command & file monitoring | Bash scripting, inotify |
| **Message Queue** | Reliable log transport | Apache Kafka |
| **Log Consumer** | Centralized log processing | Python, Flask |
| **Storage** | Log persistence | Files, PostgreSQL, Elasticsearch |

---
