# ASH (Again SHell) Monitoring System

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Comprehensive shell monitoring system capturing commands, outputs, and file changes.


## Quick Start
```bash
git clone https://github.com/xWuWux/ash-monitor.git
cd ash-monitor
sudo src/agent/install-agent.sh





## Overview

ASH (Again SHell) is a comprehensive shell monitoring system that captures every command executed in bash environments, tracks file modifications, and provides centralized logging across distributed systems. It combines multiple monitoring techniques to ensure complete visibility into system activity.

### Key Features

- **Complete Command Tracking**: Captures all bash commands with timestamps, output, and exit codes
- **File Change Detection**: Monitors file modifications using multiple methods (diff, inotify, background watchers)
- **Distributed Architecture**: Centralized logging from multiple servers using Kafka message queuing
- **Real-time Monitoring**: Event-driven file system monitoring with inotify
- **Flexible Deployment**: Systemd service, container, or package installation options

---

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
