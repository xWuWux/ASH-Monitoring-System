# ASH Code Review — 2026-09-14

**Reviewed:** commit `293c253` (v2.2.0, "ASH 1.5")
**Scope:** full read of every source file, config, test, CI workflow,
Dockerfile, and systemd unit, plus live execution where it mattered — an
isolated bash sandbox for the shell agent, a fresh Python venv with the
actual pinned dependencies, and a disposable local Postgres container for
the consumer. Several of the findings below were only found by running
the code, not by reading it; each is marked accordingly.

**Standard reviewed against:** an architecture/security/code-quality
checklist covering CQRS, infrastructure-as-code/GitOps, idempotent
pipelines with dead-letter queues, dynamic ABAC, append-only/WORM audit
logs, layered (OSI-style) diagnostics, JPL-style code-generation
constraints (bounded loops, small function scope, validated inputs,
minimal-dereference pointers), and a CI/CD + WAF + network-isolation
pre-commit checklist. ASH is a Linux shell-command audit/monitoring
system (bash agent → Kafka → Postgres consumer → REST API), not a
healthcare/FHIR-OMOP platform, so the findings below translate those
principles to what's actually here rather than force-fitting the
literal domain terms. The two documents referenced in that checklist
(`Roadmap_Platform_Build_20251119.xlsx`, `Process Outline.docx`) were not
available for this review; the repo carries its own equivalents —
`Ash architecture roadmap.odt` and `Ash architecture requirements..odt`,
with a tracked `FL-01`…`FL-27` fix list — which were used instead (see
§4).

**Outcome of this review:** 2 pull requests with fixes verified by
direct execution, and 10 issues for items that need a maintainer
decision rather than a unilateral patch. All are linked inline below.

---

## Executive Summary

The core reliability engineering here is genuinely solid — atomic
`flock`-protected writes, a durable local spool queue with retry,
crash recovery, structured JSON events, session tracking, a real BATS
test suite, a working CI pipeline. `docs/PROJECT_REPORT.md` and
`docs/REMAINING_GAPS.md` are also unusually candid for a project's own
self-assessment; several gaps documented there (Kafka TLS, no
`.deb`/`.rpm` packages, no chaos testing, no `THREAT_MODEL.md`) are
accurate and don't need to be re-litigated here.

What this review adds is a layer underneath the acknowledged gaps:
**several features documented and marked "✅ Implemented" against the
project's own roadmap don't actually do what the roadmap item asked for
once exercised** — a JWT-issuing endpoint with no real authentication
behind it, a tamper-evident hash chain that a non-root process can't
actually append to, a Kafka consumer whose "guaranteed delivery" can
silently lose events, a "file change tracking" feature whose database
table has never had a row inserted into it, and a DEBUG-trap reentrancy
bug that made the agent hang when actually sourced. None of these show
up from reading the code casually — most surfaced only when the code
was run and its own test suite's CI logs were checked past the green
checkmark.

---

## 1. Architecture & Infrastructure

### CQRS
There's a reasonable approximate split — the consumer (`ash-consumer.py`)
owns writes, the API (`api_server.py`) is read-only — but it's not a
true CQRS implementation: no separate read-optimized projection, no
event-sourcing/replay capability, and the same relational schema serves
both sides. That's a reasonable choice for this system's scale and not
flagged as a defect, but worth naming plainly rather than crediting it
as CQRS proper.

### Infrastructure as Code / GitOps
Docker Compose + systemd units exist and are version-controlled, which
covers the basics. There's no Terraform/Pulumi/CloudFormation, no
Kubernetes manifests despite `k8s-audit` being a first-class event
source in the schema, and no automated drift detection — `install.sh`
is imperative (mutates a live host) rather than declarative/idempotent
infrastructure. Given the project's own scope (single-tool Linux
monitoring, not a multi-cloud platform), this is proportionate; flagging
only because the standard explicitly calls for AWS network
topology/Kubernetes config as code, which doesn't exist here yet.

### Pipeline resilience — idempotency keys & Dead-Letter Queues
This is where the gap between "documented" and "actual" was largest.
Findings, fixed in **[PR #3](https://github.com/xWuWux/ASH-Monitoring-System/pull/3)**:

- `enable_auto_commit=True` on the Kafka consumer committed offsets on a
  fixed timer, decoupled from whether events had actually been flushed
  to file/DB — a crash in that window silently lost events, directly
  contradicting the "~99% Kafka failure resilience" claim in
  `docs/PROJECT_REPORT.md`. Fixed: commit only after a durable flush
  succeeds.
- **No Dead-Letter Queue existed at all** — the explicit requirement in
  this review's standard. Events failing schema validation were logged
  at `WARNING` and discarded with no trace. Added a file-based DLQ.
- Idempotency *was* correctly implemented at the DB layer
  (`ON CONFLICT (event_id) DO NOTHING`) — that part held up under a real
  re-submission test (see PR #3's testing notes).
- `kafka-python>=2.0.2` with no upper bound resolves to a version today
  that **can't even be imported** by this codebase (found by installing
  the actual pinned requirements into a venv) — pinned to `<3.0.0`.

---

## 2. Security

### Attribute-Based Access Control
What exists is role-based (`admin`/`analyst`/`readonly`), not
attribute-based — no runtime evaluation of user/resource/operation
context, which is what the standard specifically asks for. More
pressingly, the RBAC that does exist doesn't hold up:

- **[Issue #4 — Critical, open]**: `/api/v1/auth/token` issues a valid,
  signed `readonly` JWT to anyone supplying *any* non-empty username —
  password is never checked on that branch, and there's no real user
  store behind it. Full read access (session replay, search, host
  list) to anyone who can reach the API.
- Fixed in **[PR #2](https://github.com/xWuWux/ASH-Monitoring-System/pull/2)**:
  the JWT secret and admin credentials previously defaulted to literal,
  source-visible values (`change-me-in-production`, `admin`/`admin`) —
  including hardcoded directly in the shipped `ash-api.service` unit
  file — meaning an unconfigured deployment let anyone forge an admin
  token directly. `install.sh` now generates real per-install secrets.

Moving to true dynamic ABAC (attributes like host sensitivity, time of
day, data classification) is a larger design change tracked implicitly
by issue #4 rather than specified in detail here.

### Read-only / append-only (WORM) logs
- The per-host hash chain is a reasonable design, but two bugs
  undermine it in practice (**[Issue #7 — High, open]**, found by
  actually sourcing the agent): `hash_chain_init()`'s own `chmod 400`
  makes the file unwritable to its own non-root owner for every
  subsequent append (confirmed live — the very first event after
  initialization fails with `Permission denied`), and the
  read-then-append in `hash_chain_append()` has no locking, so
  concurrent sessions on one host (the normal case) can produce a chain
  `verify_hash_chain()` reports as tampered when nothing was tampered
  with.
- **[Issue #8 — High, open]**: the actual system of record for the API
  (PostgreSQL) is not WORM at all — the retention job hard-`DELETE`s
  rows on a schedule, nothing enforces immutability at the DB layer, and
  the hash chain isn't verified at ingestion time.
- `chattr +a` (true filesystem-level append-only) is explicitly
  documented as *optional*, not default.

### Network isolation & WAF
- **[Issue #9 — High, open]**: `docker-compose.yml` publishes Kafka
  (`PLAINTEXT`, no auth) and Postgres directly to the host's network
  interfaces, not just the compose-internal network the app services
  already use to reach them.
- No WAF layer anywhere — the Flask API has no request-filtering
  middleware, no rate limiting on the login endpoint, and (per issue #4)
  weak-to-nonexistent authentication in front of it. The standard's
  explicit "every request checked before it reaches the service" isn't
  met.
- Fixed in PR #2: `ash-agent.service` had `NoNewPrivileges=false` sitting
  directly under a `# Security hardening` comment (flipped to `true`),
  and an unused `CAP_SYS_PTRACE` grant (dropped — nothing in the agent
  uses ptrace).

### Sensitive-data redaction
Fixed in PR #2, all reproduced live before and after the fix:
- File-change events (`file_modify`/`file_delete`) carried the *raw,
  unredacted* triggering command, and `diff_content` — the literal file
  diff — was never redacted at all. `echo "API_KEY=..." >> file` leaked
  the key verbatim into the event, even though the identical string as a
  plain command would have been redacted.
- The redaction engine silently no-op'd on any pattern containing a
  literal `/` (a `sed` delimiter collision) — found while adding a
  credentials-in-URL pattern, which completely failed to redact until
  fixed.
- Added coverage for PKCS8 private keys (previously only the
  `RSA|DSA|EC|OPENSSH`-prefixed header was matched), HTTP Basic auth
  headers, and credentials embedded in URLs.
- **[Issue #11 — Medium, open]**: the auditd fallback layer — pitched as
  the bypass-proof kernel-level layer — never actually parses command
  arguments, only the executable path, so it captures far less than
  advertised, and whatever does get captured there bypasses ASH's own
  redaction entirely.

### A bug found only by running the code: DEBUG trap reentrancy
**[Issue #6 — Critical, open]**. `log_command()`'s reentrancy guard only
excludes commands starting with ASH's own function names — not the
~15 external commands (`date`, `jq`, `hostname`, `sha256sum`, `flock`...)
those functions call internally. With `set -T` propagating the trap into
subshells, each of those independently re-triggers full event emission
again — unbounded recursive self-triggering, not a fixed chain.
Confirmed by sourcing the agent for real: it produced a permission-denied
loop and then hung until forcibly killed. **Independently reconfirmed in
this repo's own CI**: `test_hash_chain.bats` and `test_redaction.bats` —
which source the full agent directly, against a warning a sibling test
file already follows (see below) — time out at the 90-second CI limit on
every run, currently invisible because bats failures are wrapped as
non-blocking (see [issue #13](https://github.com/xWuWux/ASH-Monitoring-System/issues/13#issuecomment-5666658647)).

### install.sh permission model
**[Issue #5 — Critical, open]**. `/tmp/ash` ends up root-owned mode 700;
`/var/log/ash` ends up `root:ash` mode 750 (group has no write bit).
Combined with `validate_config || exit 1` running inside a script
sourced directly into the user's interactive shell via
`/etc/profile.d/ash.sh`, this kills the login shell of every non-root,
non-`ash` user on a stock install — verified live, including the
specific bash semantics involved (a sourced script's own `set -e` can
retroactively apply to its own `return` status as observed by the
caller, which took two rounds of live testing to characterize
correctly — see the issue for the empirical detail).

---

## 3. Code Quality / Code-Generation Constraints

The JPL-style constraints in the standard (bounded loops, no
recursion, ~60-line functions, two assertions per function, single-level
pointer dereference, no function pointers, dynamic-memory prohibition)
are written for C/embedded systems; this codebase is bash + Python, so
they're evaluated by intent rather than literally:

- **Control flow**: no `goto`, no genuine recursion in the reviewed
  code. Loop bounds: `spool_flush_timer()`'s `while true; do sleep 30;
  ...; done &` and the consumer's `while self.running:` timer threads
  are intentionally unbounded (daemon loops) — appropriate for their
  purpose, not a violation.
- **Function length**: most functions are well under ~60 lines.
  `ash-consumer.py`'s `_write_database_batch()` and
  `ash-agent.sh`'s `main()` and `start_auditd_monitor()` run longer,
  though not egregiously.
- **Assertions**: essentially none of the "closest equivalent" —
  `bash -u` / explicit `set -u` guards, Python type hints — are backed
  by actual runtime assertions inside function bodies. Not flagged as a
  standalone issue; folded into the specific correctness bugs above
  where it mattered (e.g., unchecked return values from `jq`/`sed`
  falling back silently instead of asserting).
- **Validation of inputs and return values**: this is where real bugs
  lived — `redact_sensitive_data()`'s `sed` failures were swallowed by
  `|| echo "$output"` with no distinction between "no match" and "the
  command itself broke" (§2, fixed in PR #2); several API endpoints
  (`limit`/`offset`/`hours` query params) call `int()` with no
  try/except, returning a bare 500 on malformed input rather than a
  validated 400.
- **Compiler warnings / static analysis**: `shellcheck -S error` and
  `flake8`/`bandit` run in CI (see §5 on their actual blocking status).
  This review additionally ran `bash -n` on every changed shell script
  and `flake8`/`bandit` with the exact flags CI uses against the changed
  Python, all clean — see PR testing notes.
- **[Issue #12 — Medium, open]**: `src/common/schema/event-v1.json` — the
  "canonical" schema — is never loaded or enforced by any code path;
  `command_end`/`duration_ms` are effectively dead for the success path
  (a `local start_time` is computed in `log_command()` and never used
  again).

---

## 4. Roadmap Compliance

Cross-checked against the repo's own `FL-01`…`FL-27` fix list
(extracted from `Ash architecture roadmap.odt`) and
`docs/PROJECT_REPORT.md`'s completion table. Several items marked
**✅ Implemented** don't fully meet the acceptance criteria their own
roadmap entry describes, once exercised:

| Roadmap item | Marked | This review found |
|---|---|---|
| FL-06 — Hash-chained append-only logs | ✅ Implemented | Breaks for any non-root append (chmod 400 self-lockout) and races under concurrent sessions — issue #7 |
| FL-16 — Idempotent consumer processing | ✅ Implemented | `enable_auto_commit=True` could silently lose events; no DLQ existed at all — fixed in PR #3 |
| FL-18 — RBAC + authentication | ✅ Implemented | Self-service `readonly` token issuance with no real credential check — issue #4 |
| FL-09 — auditd kernel fallback | ✅ Implemented | Never parses command arguments, only the executable path — issue #11 |
| FL-25 — Container/Docker awareness | ✅ Implemented | Functional, but `docker-compose.yml`'s own Kafka/Postgres are exposed with no network isolation — issue #9 |
| FL-03 — Structured JSON event schema | ✅ Implemented | Schema file exists but is never loaded/enforced by any validator — issue #12 |

This isn't a criticism of the roadmap process itself — the roadmap's own
problem statements were accurate, and most of the *first-order* fix (a
hash chain exists, a DLQ concept was scoped, RBAC scaffolding exists) was
genuinely built. The gap is between "the feature exists" and "the
feature does what its own problem statement said it needed to do" —
which is exactly the kind of thing that only shows up under actual
execution, not a design review.

---

## 5. CI/CD & Pre-Commit Checklist

**[Issue #13 — Medium, open]**, with concrete evidence added after
this review's own PRs ran through CI:

- Every `bats` invocation in CI is wrapped so a failure or timeout
  becomes a non-blocking `::warning::` rather than a failed job.
  Checked what that's currently hiding, on both of this review's PRs:
  **2 real assertion failures** in `test_config_validation.bats`, and
  **both `test_hash_chain.bats` and `test_redaction.bats` time out at
  the 90-second CI limit** — on every run, currently invisible because
  the `unit-tests` job still reports green. See the linked run logs on
  issue #13 and #6.
- `detect-secrets scan`'s result is discarded (`|| true`).
- `security-scan` (the job that actually runs `bandit -ll` without
  suppression) is not a dependency of `build-package`, so a real finding
  there wouldn't block packaging.
- Two of four bats files source `ash-agent.sh` directly into the live
  BATS process, against a safety warning a sibling test file in the same
  suite already documents and follows.

**Net effect**: the CI pipeline exists and runs six jobs per the
roadmap's FL-23, but as currently configured it cannot fail on the two
things most likely to matter (a real bats regression, a detected
secret) — worth treating "make CI blocking again" as a priority
follow-up given how directly it undercuts this standard's explicit
"catch regressions early" and "zero warnings" requirements.

---

## Summary of Actions Taken

### Pull requests (verified by direct execution — see each PR's testing notes)
- **[PR #2 — security](https://github.com/xWuWux/ASH-Monitoring-System/pull/2)**: redaction leaks (file-diff secret leakage, delimiter-collision no-op, coverage gaps), a silent `emit_event` field-loss bug affecting every event when `jq` is absent, and shipped default secrets (JWT secret, admin credentials, systemd hardening).
- **[PR #3 — reliability](https://github.com/xWuWux/ASH-Monitoring-System/pull/3)**: Kafka data-loss window, missing DLQ, dead `file_changes` table, dead `risk_score`, and a broken `kafka-python` dependency pin.

### Issues filed (need a maintainer decision, not a unilateral patch)
| # | Severity | Title |
|---|---|---|
| [#4](https://github.com/xWuWux/ASH-Monitoring-System/issues/4) | Critical | `/api/v1/auth/token` issues valid tokens to anyone |
| [#5](https://github.com/xWuWux/ASH-Monitoring-System/issues/5) | Critical | Default install.sh permissions can kill non-root users' login shells |
| [#6](https://github.com/xWuWux/ASH-Monitoring-System/issues/6) | Critical | DEBUG trap reentrancy — confirmed hanging in CI |
| [#7](https://github.com/xWuWux/ASH-Monitoring-System/issues/7) | High | Hash chain race + chmod-400 self-lockout |
| [#8](https://github.com/xWuWux/ASH-Monitoring-System/issues/8) | High | Central Postgres store isn't WORM |
| [#9](https://github.com/xWuWux/ASH-Monitoring-System/issues/9) | High | Kafka/Postgres exposed on host network, no TLS/SASL |
| [#10](https://github.com/xWuWux/ASH-Monitoring-System/issues/10) | High | Alert cooldown is global across the whole fleet |
| [#11](https://github.com/xWuWux/ASH-Monitoring-System/issues/11) | Medium | auditd never captures command arguments |
| [#12](https://github.com/xWuWux/ASH-Monitoring-System/issues/12) | Medium | Event schema decorative; command_end/duration_ms dead |
| [#13](https://github.com/xWuWux/ASH-Monitoring-System/issues/13) | Medium | CI non-blocking — confirmed hiding real failures |
