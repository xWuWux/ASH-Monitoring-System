# ASH v2.2 — Remaining Gaps & Future Work

This document lists features, edge cases, and architectural concerns that were **identified in the requirements/roadmap** but are **not yet fully implemented** in this release. They represent work for future iterations.

---

## 1. Gaps That Require External Infrastructure

These cannot be implemented in code alone — they need operational deployment decisions.

| Gap | Description | Effort | Blocked By |
|-----|-------------|--------|------------|
| **Kafka TLS** | Transport encryption between agents and brokers | 4h | Kafka infra + cert management |
| **OpenSearch/Elasticsearch** | Full-text indexed search with aggregations | 16h | Cluster deployment decision |
| **eBPF monitoring** | Kernel-level tracing beyond auditd | 20h | Kernel version ≥5.8, BCC/libbpf tooling |
| **Kubernetes audit log integration** | K8s API server audit webhook | 8h | K8s cluster access + RBAC |
| **Hardware security module** | HSM-backed log signing | 12h | Hardware procurement |
| **Remote syslog forwarding** | rsyslog/syslog-ng integration for compliance | 4h | Syslog infrastructure |

---

## 2. Features Partially Implemented (Needs Hardening)

| Feature | Current State | What's Missing |
|---------|---------------|----------------|
| **auditd integration** | Reads audit.log, normalizes events | No automatic rule deployment on install; no ausearch wrapper |
| **Docker monitoring** | Streams docker events | No `docker exec` content capture; no image hash verification |
| **Multi-shell support** | Zsh and Fish integrations exist | Not tested on all versions; no Dash/POSIX sh support |
| **RBAC/JWT auth** | Basic role system in API | No user management UI; no token refresh; no LDAP/OIDC federation |
| **Alerting webhooks** | Slack format implemented | No Discord-native format; no email integration; no PagerDuty |
| **Retention/archival** | Daily archive + delete in consumer | No S3/GCS offload; no configurable per-host retention |

---

## 3. Edge Cases Not Yet Addressed

From the error analysis (27 identified issues), the following remain **partially or unresolved**:

### 3.1 Background Process Monitoring (FL-4.2)
- **Problem**: Commands with `&` create background processes invisible to DEBUG trap
- **Current state**: auditd catches the execve, but bash-level `&` is not explicitly intercepted
- **Needed**: Process accounting (`accton`) integration or explicit job control hook
- **Impact**: ~15% of commands on active servers are backgrounded

### 3.2 Multiple DEBUG Trap Replacement (FL-1.3)
- **Problem**: If another tool sets `trap ... DEBUG`, ASH is silently disabled
- **Current state**: No stack-based trap management implemented
- **Workaround**: `/etc/profile.d/ash.sh` loads last, so it wins on session start
- **Needed**: Periodic watchdog that verifies the trap is still active

### 3.3 Non-Interactive Shell Coverage (FL-1.1)
- **Problem**: Scripts run via `cron`, `at`, `systemd`, or `ssh host "cmd"` don't source profile
- **Current state**: auditd covers execve, but no bash-level context (cwd, variables)
- **Needed**: `BASH_ENV` export + PAM session hook for SSH
- **Impact**: Significant — many automated actions go through non-interactive shells

### 3.4 Output Capture for Complex Pipelines
- **Problem**: `cmd1 | cmd2 | cmd3` — only the last command's output is capturable
- **Current state**: Only captures what DEBUG trap sees (the full pipeline string)
- **Needed**: `script(1)` or `tee`-based session recording (like Asciinema)
- **Trade-off**: Heavy I/O cost vs. complete forensic record

### 3.5 Binary/Compiled Program Monitoring
- **Problem**: ASH only monitors shell commands, not direct syscalls from binaries
- **Current state**: auditd catches execve but not internal behavior
- **Needed**: eBPF probes on open/write/connect syscalls
- **Impact**: Critical for detecting compiled malware

---

## 4. Performance Benchmarks Not Yet Established

The roadmap calls for (NFR-02):

| Metric | Target | Status |
|--------|--------|--------|
| Agent CPU overhead | <5% | **Not measured** |
| Agent memory usage | <50MB | **Not measured** |
| Event latency (local) | <100ms | **Not measured** |
| Event latency (Kafka) | <1s | **Not measured** |
| Throughput | >1000 events/s | **Not measured** |

**Next step**: Create `tests/performance/benchmark.sh` that measures these under load.

---

## 5. Documentation Still Needed

| Document | Priority | Status |
|----------|----------|--------|
| `docs/THREAT_MODEL.md` | High | Not written |
| `docs/OPERATIONS_RUNBOOK.md` | Medium | Not written |
| `docs/UPGRADE_GUIDE.md` | Medium | Not written |
| `docs/SECURITY_HARDENING.md` | Medium | Not written |
| `docs/PERFORMANCE_TUNING.md` | Medium | Not written |
| `docs/COMPATIBILITY_MATRIX.md` | Medium | Not written |

---

## 6. Packaging Gaps

| Package Type | Status | Notes |
|-------------|--------|-------|
| `.deb` (Debian/Ubuntu) | **Not built** | `scripts/install.sh` covers the same scope manually |
| `.rpm` (RHEL/Fedora) | **Not built** | Need spec file |
| Homebrew formula | **Not applicable** | ASH is Linux-server focused |
| Container registry | **Not pushed** | Dockerfiles exist but no automated push to registry |
| Helm chart (K8s) | **Not written** | DaemonSet YAML exists in roadmap doc but not extracted |

---

## 7. UI/Dashboard

The roadmap (FL-20) calls for a web dashboard with:
- Live command stream (SSE)
- Search with filters
- Session replay
- Risk heatmap
- Alert feed

**Current state**: REST API exists (`api_server.py`) but **no frontend** is built.

**Options**:
1. Build with a lightweight framework (htmx + Jinja2 server-rendered)
2. Use Grafana dashboards with PostgreSQL data source
3. Build a React/Vue SPA (heaviest option)

**Recommendation**: Start with Grafana dashboards for v2.x, build custom UI for v3.0.

---

## 8. Chaos Testing Not Implemented

The roadmap calls for testing:
- Kafka broker failure mid-stream
- Disk fills up during logging
- Network partition between agent and consumer
- Consumer crash during batch write
- Filesystem corruption of spool directory
- OOM kill of agent process

**Current state**: Spool queue and retry logic handle most of these gracefully, but no automated chaos tests verify it.

---

## 9. Cross-Host Correlation (P1-11)

**Problem**: When an attacker SSHs from Host A → runs sudo on Host B → kubectl exec on Host C, ASH logs each hop independently.

**Needed**:
- Correlation engine that links events by SSH_CONNECTION source IP
- Session chain visualization
- Alert rule: "same user, 3+ hosts, within 5 minutes"

**Status**: Not implemented. Requires consumer-side join logic.

---

## 10. Competitive Feature Comparison

| Feature | ASH v2.2 | Atuin | McFly | HSTR | Bashhub |
|---------|----------|-------|-------|------|---------|
| Command history | Yes | Yes | Yes | Yes | Yes |
| Structured JSON events | **Yes** | No | No | No | Partial |
| File change tracking | **Yes** | No | No | No | No |
| Distributed multi-host | **Yes** | Sync | No | No | Cloud |
| Tamper-evident chain | **Yes** | No | No | No | No |
| Kernel-level fallback | **Yes** (auditd) | No | No | No | No |
| Session reconstruction | **Yes** | Partial | No | No | No |
| Alerting/SIEM | **Yes** | No | No | No | No |
| Fuzzy search UI | **No** | Yes | Yes | Yes | Web |
| SQLite local DB | No | Yes | Yes | No | No |
| Privacy/local-first | Configurable | Yes | Yes | Yes | No |

**ASH's unique positioning**: The only tool combining shell history + file diffs + distributed monitoring + forensic reconstruction + tamper evidence in one platform.

**Key gap vs. competitors**: No interactive TUI/fuzzy finder for local use. This is the biggest UX gap for developer adoption.

---

## Summary Priority for Next Release (v2.3)

1. **Performance benchmarks** — measure before optimizing
2. **Trap watchdog** — detect if another tool disables ASH
3. **Grafana dashboard templates** — immediate operational value
4. **`.deb` package build** — professional distribution
5. **BASH_ENV + PAM hook** — cover non-interactive shells
6. **Process accounting** — background process coverage
