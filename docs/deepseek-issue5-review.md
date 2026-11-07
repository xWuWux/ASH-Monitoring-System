# ASH Review: permission model, issue #5, and sourced-shell safety

## Task 1 — Permission model

**Verdict:** issue #5’s choice set is a false dilemma. A single host-wide audit log cannot be both directly writable by every user and tamper-evident. Sticky directories and `umask 007` protect names, not contents; a group member can still `O_TRUNC` or rewrite the log. POSIX ACLs grant `rwx`, not append-only. Per-user logs let each owner delete their own evidence. The safe model is **mediated append**: users submit events; one privileged writer owns the log and hash chain.

### Recommended layout

| Path | Owner:group | Mode | Purpose |
|---|---|---|---|
| `/var/log/ash/audit` | `ash-append:ash` | `0750` | host-wide log dir; group `ash` read/traverse |
| `/var/log/ash/audit/events.jsonl` | `ash-append:ash` | `0640` | single authoritative log |
| `/var/log/ash/audit/.hash_chain` | `ash-append:ash` | `0600` | chain state |
| `/var/log/ash/audit/.hash_chain.lock` | `ash-append:ash` | `0600` | pre-created lock |
| `/var/spool/ash/incoming` | `root:root` | `1733` | submit drop: create-only, no list/read |
| `/var/spool/ash/state` | `ash-append:ash` | `0700` | daemon state/quota |
| `/run/ash/append.sock` | `root:root` | `0666` | local submit socket; `SO_PEERCRED` checked |
| `${ASH_TEMP_DIR}` | user | `0700` | per-session `mktemp -d` |

Create a dedicated system user/group `ash-append` (or reuse `ash` only if you accept that the consumer can tamper). `ash-appendd` runs as `ash-append` with `CapabilityBoundingSet=CAP_DAC_READ_SEARCH`, `NoNewPrivileges=true`, and `ReadWritePaths=/var/log/ash/audit /var/spool/ash`. It is the **only** process that opens `events.jsonl` or `.hash_chain`. Users never get write access to either.

Agent flow: `ash_submit_event` sends JSON over `/run/ash/append.sock`; the daemon validates size/JSON, overwrites `user`/`uid` from `SO_PEERCRED`, rate-limits per uid, appends under `flock`, and returns the signed line (or an error). If the socket is down, `ash_submit_spool` writes `incoming/${EUID}.${BASHPID}.${RANDOM}.json` with `umask 077`; `drain_incoming` consumes it. Kafka spooling must use the daemon-returned signed event; the agent must not sign independently.

### New names

Variables (all overridable in `ash.conf`): `ASH_APPEND_MODE` (string enum `socket|spool`, default `socket`), `ASH_APPEND_SOCKET` (string, `/run/ash/append.sock`), `ASH_INGEST_DIR` (string, `/var/spool/ash/incoming`), `ASH_APPEND_TIMEOUT` (integer seconds, `2`), `ASH_APPEND_MAX_BYTES` (integer, `65536`), `ASH_APPEND_RATE` (integer events/sec/uid, `50`), `ASH_EVENTS_MAX_BYTES` (integer, `1073741824`), `ASH_EVENTS_KEEP` (integer, `5`), `ASH_ALLOW_NFS_LOG` (boolean, `false`), `ASH_TEMP_DIR` (default `mktemp -d "${TMPDIR:-/tmp}/ash.XXXXXXXX"`, not `/tmp/ash`), `ASH_PROPAGATE_BASH_ENV` (boolean, `false`).

Functions: agent `ash_submit_event(event_json, target=ASH_EVENTS_FILE) -> int`; `ash_submit_spool(event_json) -> int`; `ash_validate_permissions() -> int` (sets `ASH_PERM_ERROR`); `ash_cleanup_session() -> void`. Daemon (`src/agent/ash-appendd.py`): `peer_uid(conn) -> int`; `append_event(event: dict, peer_uid: int) -> dict`; `drain_incoming(dir: Path) -> int`; `rotate_log(path: Path, max_bytes: int, keep: int) -> int`; `rate_limit(uid: int, now: float) -> bool`.

Files that must change: `scripts/install.sh` (user/group, dirs, pre-created files, logrotate, profile `|| true`), `src/agent/ash-agent.sh` (variables, `emit_event`, remove direct `hash_chain_append`/`safe_log_write` from user path, `validate_config`, dispatch), `src/agent/shells/fish-integration.fish` (currently `echo $event >> /var/log/ash/events.jsonl`), `deployments/systemd/ash-agent.service` (its `chmod 750 /var/spool/ash` contradicts install.sh’s 700; add `/run/ash` and incoming), new `deployments/systemd/ash-appendd.service`/`.socket`, new `src/agent/ash-appendd.py`, `config/ash.conf.example`, `src/common/schema/event-v1.json` (add `submitter_uid`/`ingest_uid`), `docs/ARCHITECTURE.md`, `docs/OBSERVABILITY.md`, `tests/unit/test_permissions.bats`, `tests/integration/test_appendd.bats`, CI non-root job.

### Failure modes

- **ENOSPC:** daemon returns a typed error; agent spools; per-uid quota (`ASH_INGEST_MAX_BYTES`) prevents one user filling the host; never silently truncate the audit tail. Rotate only under daemon control; never `copytruncate`.
- **NFS:** `flock` may return `ENOLCK`; `chattr +a` unsupported; root-squash breaks ownership. Detect with `stat -f -c %T`; `ASH_ALLOW_NFS_LOG=false` fails closed to local spool. Do not fall back to unlocked append.
- **Missing group:** `getent group ash-append` at install; `groupadd -r`; fail install, do not degrade to world-write.
- **UID namespace:** `SO_PEERCRED` uid is namespace-local; stamp both `uid` and `/proc/$pid/status` `NSpid`/user-ns identity; never trust `$USER` (already spoofable in `emit_event`).
- **`sudo -i`:** target shell re-sources profile; daemon stamps real uid; root events allowed. `sudo -E` can carry `BASH_ENV`/`ASH_INITIALIZED`; strip inherited `ASH_*` or require `env_reset`.
- **BASH_ENV recursion:** current code exports `BASH_ENV` and sets `ASH_INITIALIZED=true` *before* `main` (lines 1195–1196); every child bash still executes the file-scope `set -euo pipefail` and traps. Export only after successful init, and have the child branch define functions only.
- **Symlink/TOCTOU:** pre-create lock/log files; daemon uses `O_NOFOLLOW`, `O_APPEND`, `fstat` owner checks; agent uses `mktemp -d`.

### Rollback

Ship `ASH_APPEND_MODE=direct` for one release, root-only. Upgrade order: install `ash-appendd` and layout first, then agent; old agents keep working until the log becomes non-group-writable. Rollback: stop `ash-appendd`, set `ASH_APPEND_MODE=spool` (events accumulate, no loss), then reinstall the prior agent; if direct write is required, document a one-time `chown root:ash /var/log/ash/audit; chmod 2750 ...; chmod 660 events.jsonl`. Never delete `events.jsonl`; keep the daemon able to drain the old spool. `install.sh --upgrade` must be idempotent and must not `rm -rf` the audit dir.

## Task 2 — Critique of issue #5, `CODE_REVIEW.md`, `REMAINING_GAPS.md`

1. **“every non-root non-ash user fails validate_config’s writability check”** is understated and mis-scoped. `/tmp/ash` is created by root with `chmod 700` and **no `chown`** (`install.sh:109–117`), so even the `ash` user fails `ASH_TEMP_DIR`; `ash` also fails `/var/spool/ash`? No—spool is `ash:ash`, but temp is not. The issue names two dirs and omits spool and the log/hash files, which are not pre-created at all; the first writer’s ownership and umask decide them. Rewrite as a table: path, owner:group, mode, required operation, which uid passes, which fails.

2. **“world-writable (tamperable) vs per-user subdirs”** is a false dichotomy and has no threat model. Group-writable is equally tamperable by every group member; per-user logs are deletable by their owner; the real options include append-only filesystem attributes, a privileged append helper, a socket daemon, or per-user spool plus privileged merge. State the adversary (local user, group member, root), asset (past events vs new events), and property (no rewrite, no forge, no delete) before comparing.

3. **“The consumer currently reads a single per-host ASH_EVENTS_FILE /var/log/ash/events.jsonl”** is false in this repo. `ash-consumer.py:399` sets `log_dir`; it writes `ash-history-{hostname}.jsonl` at `:1304`, plus `dead_letter.jsonl` and `alerts.jsonl`; it never opens `events.jsonl`. A per-user-log merge is therefore a **new local ingestion pipeline with checkpointing**, not a permission tweak. Rewrite the premise and add that work to the estimate.

4. **“main() now returns instead of exits”** is insufficient. `ash-agent.sh` still enables `set -euo pipefail` at file scope (line 17) and installs `trap cleanup_ash EXIT` plus ERR/SIGINT/SIGTERM traps (lines 1119–1122) before dispatch. On **successful** init there is no restore (lines 1216–1219 restore only on failure), so the user’s interactive shell gets `-e`; the first `false`/`grep` failure exits it. Worse, the SIGINT trap is `cleanup_ash; exit 0` (line 1121), so Ctrl-C can still `exit` the user’s shell. Rewrite: “`main` no longer calls `exit` on validation failure, but sourcing still mutates options and traps on every path.”

5. **“a tamper-evident hash chain that a non-root process can’t actually append to”** (`CODE_REVIEW.md` executive summary) overclaims. The chain has no secret/MAC; any writer can read the last hash and append a consistent forged chain. It detects accidental/naive edits, not a malicious writer. Rewrite: “append-only chain detects truncation and naive modification; it is not authenticated, and a writer who can append can forge a consistent suffix.”

6. **`CODE_REVIEW.md` §2 “install.sh permission model”** says “`/tmp/ash` ends up root-owned mode 700; `/var/log/ash` ends up `root:ash` mode 750 … this kills the login shell of every non-root, non-`ash` user … verified live.” This is stale: at HEAD, `chmod 600` replaced `chmod 400` (line 324 vs review’s §2), and the source path uses `return 1`, not `exit 1`. It is also overbroad: only bash login shells source `/etc/profile.d/ash.sh`; zsh/fish use different hooks, and dash cannot parse `[[`/`source`. Rewrite with a shell matrix and a “verified at commit” column.

7. **`CODE_REVIEW.md` §5 CI claims are false at HEAD.** “Every `bats` invocation in CI is wrapped so a failure or timeout becomes a non-blocking `::warning::`” — `ci.yml:242–261` runs `timeout 90s bats` with no `|| true`; the job is blocking. “`detect-secrets scan`’s result is discarded (`|| true`)” — lines 80–108 compare the baseline and `sys.exit(1)`. “`security-scan` … is not a dependency of `build-package`” — `security-compliance` → `integration-migration` → `build-package` (lines 548, 633). These are not nitpicks: the document’s central “CI is non-blocking” conclusion is wrong. Rewrite after re-running at HEAD, or mark the section historical.

8. **Stale dependency and test claims.** `CODE_REVIEW.md` says `kafka-python>=2.0.2 … pinned to <3.0.0`; current `requirements.txt` is `>=3.0.0,<4.0.0`. It says `test_config_validation.bats` has “2 real assertion failures”; at HEAD all 7 pass locally. It says `test_hash_chain.bats`/`test_redaction.bats` time out; current tests use `--functions-only`. Rewrite the whole document with `Reviewed at: <sha>`, a “still true at HEAD” column, and commands/results.

9. **`REMAINING_GAPS.md` §8 is self-contradictory:** heading “Chaos Testing Not Implemented,” then “`tests/degradation/` now covers Kafka outages … on every CI build,” then “Still not automated: disk-full, OOM-kill….” Rewrite as “Chaos testing: 7 automated, 4 outstanding,” with a test-to-scenario table.

10. **`REMAINING_GAPS.md` §2 says auditd has “No automatic rule deployment on install.”** `install.sh:131–133` installs `/etc/audit/rules.d/ash.rules`; what is missing is `augenrules --load`/`auditctl -R` and verification. Rewrite to “rules file installed; not loaded or verified.” Similarly §4 says “Next step: Create `tests/performance/benchmark.sh`,” but the file exists (2.8 KB) and `ci.yml:713` runs it; the real gap is recorded results and thresholds.

11. **`REMAINING_GAPS.md` §10 marketing contradicts its own gaps:** “File change tracking | **Yes**,” “Tamper-evident chain | **Yes**,” “Kernel-level fallback | **Yes** (auditd)” while `CODE_REVIEW.md` documents a dead `file_changes` table, chain bugs, and auditd capturing only `exe`. “The only tool combining … tamper evidence” is unsupported. Rewrite as “advertised / partial / verified” with citations, and delete “only.”

12. **Structural:** `CODE_REVIEW.md` opens with a 15-line cross-domain standard (FHIR, WAF, JPL C constraints) and then says it is force-fitting; the executive summary, §2, and the issue table repeat the same findings. `REMAINING_GAPS.md` mixes production blockers, unmeasured metrics, documentation wishlists, packaging, UI, and competitor marketing in one flat list, with no owner, severity, acceptance test, or target release. Split into `BLOCKERS.md`, `ROADMAP.md`, `BENCHMARKS.md`; each row: ID, evidence link, owner, target, acceptance test.

**Priority changes:** (1) stop sourcing from mutating the caller (see Task 3); (2) implement mediated append, not a group-writable audit log; (3) make install/systemd the single source of truth for modes, add non-root tests, rotation, and quota; (4) re-verify and version-stamp the review docs, deleting false CI claims; (5) correct the data-path premise or add local `events.jsonl` ingestion.

## Task 3 — Is `return 1` instead of `exit` sufficient?

**No.** Three independent failures:

- **Success path:** `set -euo pipefail` (line 17), `set -T`/`-E` (18–19), and `trap cleanup_ash EXIT`/ERR/SIGINT/SIGTERM (1119–1122) remain in the caller. `main` succeeds → no restore. Verified in bash 5.3.9: after sourcing a successful mimic, `set -o` shows `errexit on`, `nounset on`, `pipefail on`; the next `false` kills an interactive shell.
- **Failure paths before dispatch:** a malformed `/etc/ash/ash.conf` (line 90), a `readonly ASH_VERSION` collision, or a failing `export BASH_ENV` aborts the sourced file under `-e` **before** the `if ! main` restore block, leaving options/traps installed.
- **`return 1` is still a nonzero status:** the profile wrapper `source /usr/local/bin/ash-agent` (`install.sh:236`) and `/etc/bash.bashrc` line (`:242`) have no `|| true`. Under caller `errexit`, the `source` in the `if` body/`&&` list trips errexit. The SIGINT trap can also `exit 0` the user shell.

**`eval "$_ASH_CALLER_SHELL_OPTS"` does not restore correctly.** It restores `set` options only; it does **not** restore `shopt` settings (`inherit_errexit`, `extglob`, `lastpipe`, `nullglob`), traps (ASH overwrites them), `PROMPT_COMMAND`, `BASH_ENV`, `ASH_INITIALIZED`, functions, or `readonly` variables. It also restores in the wrong order for a sourced helper: if the caller had `-e`, restoring it before `return 1` re-arms errexit and kills the caller.

**`_ASH_CALLER_SHELL_OPTS=$(set +o)` is not captured correctly for `errexit`.** Command substitution runs in a subshell that clears `-e` unless `shopt -s inherit_errexit`; verified: `set -e; x=$(set +o); grep errexit` prints `set +o errexit` (off). Thus the comment’s claim “if the caller already had errexit on … this restores that too” is false. `functrace`, `errtrace`, `nounset`, and `pipefail` are captured correctly. Also, `eval` of a shell variable is unnecessary attack surface; capture via redirection or an explicit flag.

**Correct contract:** a sourced profile hook must never return nonzero and must never mutate the caller’s options/traps on any path. Record failure in `ASH_INIT_FAILED=1`/`ASH_DISABLED=true`, log it, and `return 0`. Keep `main`’s nonzero status only for direct execution. Scope all traps inside the executed branch.

### Missing bats tests (`tests/unit/test_sourced_safety.bats`)

```bats
run_src() { run env ASH_LOG_DIR=/nonexistent/blocker/log ASH_TEMP_DIR="$BATS_TEST_TMPDIR/tmp" \
  ASH_SPOOL_DIR="$BATS_TEST_TMPDIR/spool" ASH_CONFIG_DIR="$BATS_TEST_TMPDIR/conf" \
  KAFKA_ENABLED=false INOTIFY_ENABLED=false bash --noprofile --norc -c "$1" _ "$AGENT"; }

@test "failed init never kills an errexit caller" {
  run_src 'set -e; source "$1"; echo SURVIVED'
  [[ $status -eq 0 && "$output" == *SURVIVED* ]]
}
@test "successful source leaves caller options and traps unchanged" {
  run_src 'before=$(set +o); source "$1"; after=$(set +o); [[ "$before" == "$after" ]]; ! trap -p EXIT | grep -q cleanup_ash; false || true; echo SURVIVED'
  [[ $status -eq 0 ]]
}
@test "caller errexit is restored with inherit_errexit" {
  run_src 'shopt -s inherit_errexit; set -e; source "$1"; echo SURVIVED'
  [[ $status -eq 0 && "$output" == *SURVIVED* ]]
}
@test "--functions-only changes no options and installs no traps" {
  run_src 'before=$(set +o); source "$1" --functions-only; [[ "$before" == "$(set +o)" ]]; [[ -z $(trap -p EXIT) ]]'
}
@test "failed init leaves BASH_ENV unset" {
  run_src 'unset BASH_ENV; source "$1"; [[ -z ${BASH_ENV:-} ]]'
}
```

Also add: malformed `ash.conf`; `recover_state` failure; SIGINT to a sourced shell must not exit; `spool_write` files must be `0600`; `stat` mode assertions for every installed path; and a non-root integration test using `setpriv --reuid=nobody` proving the log cannot be truncated while `ash_submit_event` succeeds.
