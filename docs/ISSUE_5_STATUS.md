# Issue #5 — Work-In-Progress Status, Design, and Review

**Status:** WIP / draft, not mergeable yet.
**Branch:** `fix/issue-5-permissions-sourced-shell`
**Base:** `main` at clone time (`d3b6629`).
**Scope:** fix the login-shell-death symptom and make an explicit permission-model
decision for non-root users. Installer/systemd/fish integration updates and the
full test matrix are **not** finished in this branch.

---

## 1. What is implemented in this branch

`src/agent/ash-agent.sh` was substantially reworked:

1. **No file-scope strict mode when sourced.** `set -euo pipefail`,
   `set -T`, and `set -E` are no longer applied at file scope. Direct
   execution (`BASH_SOURCE[0] == $0`) sets them only for its own process.
2. **Sourced-shell contract.** `ash_source_init()`:
   * captures the caller's `errexit`, `nounset`, `pipefail`, `functrace`,
     `errtrace`, `xtrace`, `noglob`, and `allexport` flags;
   * captures the caller's existing `EXIT`, `DEBUG`, `ERR`, `INT`, `TERM`
     traps and `BASH_ENV`;
   * never returns non-zero to the caller;
   * restores the caller's options on success **and** failure;
   * restores the caller's traps and `BASH_ENV` on failure;
   * sets `ASH_DISABLED=true` on failure and logs a diagnostic.
3. **Trap chaining.** `_ash_run_prev_trap()` uses the traps captured before
   ASH installed its own handlers. The previous implementation re-read
   `trap -p SIG` inside the handler, which returned ASH's own handler and
   recursed (the EXIT handler re-entered on exit; the DEBUG handler
   re-entered on every command).
4. **DEBUG-trap reentrancy fixed for sourced mode.** `set -T` (functrace) is
   no longer enabled in the caller. The DEBUG trap therefore fires for
   top-level commands only, not for every command inside ASH's own handler
   or every command substitution. This is the direct fix for the hang in
   issue #6. Full function/subshell coverage remains the job of the auditd
   layer, not the DEBUG trap.
5. **Stale-command duplicate suppression.** The EXIT trap's first command
   fires the DEBUG trap with the last command's stale `BASH_COMMAND`, which
   produced a duplicate `command_start` for the final command of every
   session. A 250 ms identical-command window suppresses that duplicate.
6. **Permission resolution.**
   * `ASH_TEMP_DIR` now defaults to empty and is created per session with
     `mktemp -d "${TMPDIR:-/tmp}/ash.${EUID}.XXXXXXXX"`, mode 0700.
   * If `ASH_LOG_DIR` is not writable, the agent falls back to
     `${ASH_USER_LOG_ROOT}/${EUID}` (default `/var/log/ash/users/$UID`),
     created mode 0700 and rejected if owned by another uid or group/world
     writable.
   * If that fails, it falls back to `$XDG_STATE_HOME/ash/log` (or
     `$HOME/.local/state/ash/log`).
   * `ASH_SPOOL_DIR` follows the same per-user/home fallback.
   * `ASH_STRICT_PERMISSIONS=true` disables fallback (intended for the root
     systemd agent; a broken host fails loudly).
   * `ASH_ALLOW_HOME_FALLBACK=false` disables the last-resort home fallback.
7. **File modes.** `events.jsonl` and `agent.log` are pre-created with 0640
   for the root shared log and 0600 for per-user logs. Temporary event files
   and spool files are chmod 600.
8. **Concurrent-session recovery.** `recover_state()` no longer disables a
   new session just because another session's PID is alive. Concurrent
   terminals are normal. It only reaps watchers when the previous shell is
   gone.
9. **Safer cleanup.** `cleanup_ash()` removes the DEBUG trap before doing
   work, avoids recursive DEBUG events, only removes a temp directory ASH
   created, and never deletes the contents of an operator-supplied shared
   temp directory.
10. **No synchronous Kafka flush on session end.** A broker outage no longer
    makes closing a terminal wait through retry backoff. Pending spool files
    survive for the next session/timer.
11. **Arithmetic under `set -e` fixed.** `((x++))` patterns that return
    status 1 on the first increment were replaced with assignments in the
    spool, retry, and rate-limit paths.
12. **`--functions-only` is side-effect free** with respect to shell options
    and traps. It resolves writable paths so non-bash integrations can emit
    events, but does not install traps or start `main()`.

New/changed variables (type, default, interaction):

| Variable | Type | Default | Notes |
|---|---|---|---|
| `ASH_TEMP_DIR` | string path | `""` (auto) | Per-session `mktemp -d`; explicit value preserved if writable. |
| `ASH_USER_LOG_ROOT` | string path | `/var/log/ash/users` | Sticky parent for per-uid log dirs. |
| `ASH_USER_SPOOL_ROOT` | string path | `/var/spool/ash/users` | Sticky parent for per-uid spool dirs. |
| `ASH_STRICT_PERMISSIONS` | bool | `false` | If true, unwritable configured dirs are fatal. |
| `ASH_ALLOW_HOME_FALLBACK` | bool | `true` | Allows `$XDG_STATE_HOME/ash` last resort. |
| `ASH_AGENT_MODE` | enum | auto | `direct`, `sourced`, `functions`, `child`. |
| `ASH_DEBUG_DEPTH` | int | `0` | Reentrancy guard for `log_command`. |
| `ASH_TEMP_DIR_IS_SESSION` | 0/1 | `0` | Cleanup may remove the temp dir only when 1. |
| `ASH_SESSION_STARTED` | 0/1 | `0` | Prevents `session_end` without `session_start`. |
| `ASH_CLEANUP_DONE` | 0/1 | `0` | Idempotent cleanup. |
| `ASH_LAST_LOGGED_COMMAND` | string | `""` | Duplicate suppression. |
| `ASH_LAST_LOGGED_US` | int µs | `""` | Duplicate suppression window. |
| `_ASH_PREV_TRAP_*` | string | captured | Caller traps for chaining/restoration. |
| `_ASH_PREV_BASH_ENV` | string | captured | Restored on failure. |

New functions (args, return, interaction):

| Function | Args | Returns | Interaction |
|---|---|---|---|
| `_ash_dir_writable` | path | 0/1 | Directory existence + w/x check. |
| `_ash_ensure_private_dir` | path | 0/1 | Creates 0700; rejects foreign owner or group/world write. |
| `_ash_resolve_dir` | var name, desired, fallback, strict | 0/1 | Sets variable via `printf -v`. |
| `ash_resolve_temp_dir` | none | 0/1 | Sets `ASH_TEMP_DIR`, `ASH_TEMP_DIR_IS_SESSION`. |
| `ash_resolve_log_dir` | none | 0/1 | Sets `ASH_LOG_DIR` (configured → per-uid → home). |
| `ash_resolve_spool_dir` | none | 0/1 | Sets `ASH_SPOOL_DIR` similarly. |
| `ash_resolve_paths` | none | void | Fills `ASH_EVENTS_FILE`, `ASH_HASH_FILE`, `ASH_AGENT_LOG`, `ASH_STATE_FILE`. |
| `ash_prepare_log_files` | none | 0/1 | Creates event/agent logs with 0640/0600. |
| `ash_capture_caller_state` | none | void | Captures options and traps. |
| `ash_restore_caller_options` | none | void | Restores captured `set` flags. |
| `_ash_restore_previous_traps` | none | void | Restores caller traps on failure. |
| `ash_source_init` | agent args | always 0 | Sourced wrapper; sets `ASH_DISABLED` on failure. |
| `_ash_prev_trap_cmd` | signal | command string | Used only during capture. |
| `_ash_run_prev_trap` | signal | 0 | Runs captured previous trap. |
| `ash_install_traps` | `direct`/`sourced` | void | Installs chained traps. |
| `_ash_debug_trap` | none | 0 | DEBUG handler. |
| `_ash_exit_trap` | none | 0 | Cleanup + previous EXIT. |
| `_ash_int_trap` / `_ash_term_trap` | none | exits | Direct mode only. |
| `_ash_err_trap` | none | 0 | Direct mode only. |

---

## 2. What is **not** finished (do not merge)

* `scripts/install.sh` still creates `/tmp/ash` mode 700 and `/var/log/ash`
  root:ash 0750. It must:
  * create `/var/log/ash/users` and `/var/spool/ash/users` as `root:root`
    mode `1733`;
  * make `/var/log/ash` and `/var/spool/ash` traversable by other users
    (e.g. `0751`) if per-user dirs live underneath;
  * pre-create per-uid dirs for existing human users;
  * pre-create `events.jsonl` (0640 root:ash) and `.hash_chain`;
  * not `rm -rf` audit logs on uninstall/upgrade;
  * fix the `do_upgrade` recursive `cp -r "$CONFIG_DIR" "$CONFIG_DIR/backup"`
    bug;
  * add `|| true` and an `ASH_DISABLED` guard to the profile hook.
* `deployments/systemd/ash-agent.service` still does
  `mkdir -p /tmp/ash; chmod 700 /tmp/ash` and `chmod 750 /var/log/ash
  /var/spool/ash`. It must match the installer and set
  `ASH_STRICT_PERMISSIONS=true` for the root agent.
* `src/agent/shells/fish-integration.fish` still writes directly to
  `/var/log/ash/events.jsonl`, without hash chain or redaction, and emits
  `source: "fish-hook"` which is not in the consumer's `VALID_SOURCES`
  (it will be DLQ'd). It must use a writable per-user path or call a shared
  emitter.
* `config/ash.conf.example` still documents `ASH_TEMP_DIR="/tmp/ash"`.
* Docs (`ARCHITECTURE.md`, `REMAINING_GAPS.md`, `CODE_REVIEW.md`) need
  updating. `CODE_REVIEW.md` contains stale claims at HEAD (see §4).
* Tests added: `tests/unit/test_sourced_safety.bats` and two new
  config-validation cases. **Not yet added:** installer permission tests,
  non-root `setpriv` integration test, fish/zsh tests, full CI run.
* The branch has not been through `shellcheck`/`shfmt`/full bats/CI.

---

## 3. Design decision and rationale

The issue's choice set (world-writable shared log vs per-user subdirs vs
"something else") is a false dilemma. A single host-wide audit log cannot be
both writable by every local user and tamper-evident: group/world write
permission lets any writer truncate or rewrite it, and POSIX ACLs grant
`rwx`, not append-only. Sticky directories protect names, not contents.

The chosen default is a **layered, fail-safe layout**:

1. root / the `ash` service account keeps the shared host log
   `/var/log/ash/events.jsonl`;
2. every other user gets a private `/var/log/ash/users/$UID` directory
   (mode 0700) and a private spool `/var/spool/ash/users/$UID`;
3. if the system directories are unavailable, a home-directory fallback
   keeps monitoring alive locally;
4. if no safe location exists, monitoring is disabled for that session
   without touching the caller's shell.

This preserves cross-user isolation, works for every local user without
group membership, keeps Kafka/PostgreSQL as the central cross-host record,
and does not require a new privileged daemon. The trade-off is that the
local `events.jsonl` is split per user when the host log is not writable;
root must collect `users/*/events.jsonl` for local forensics, and the
per-user hash chain is not a MAC (a writer can forge a consistent suffix).
That limitation is inherent to running the agent as the audited user; the
central store or auditd is the authoritative record.

**Long-term best practice:** a privileged append daemon (`ash-appendd`)
owning the canonical log and hash chain, with users submitting over a Unix
socket or a create-only spool. DeepSeek's review recommends this; it is the
right eventual architecture but is too large/risky for this WIP branch.

---

## 4. Harsh review of issue #5 and the repo docs

1. **Issue #5 under-scopes the failure.** It says `/tmp/ash` is root-owned
   mode 700 and `/var/log/ash` root:ash 750. It omits that `/tmp/ash` is
   never chowned, so even the `ash` service account fails `ASH_TEMP_DIR`;
   it also omits the spool, hash-chain, and event files, whose ownership and
   modes are decided by the first writer's umask. Rewrite as a table:
   path, owner:group, mode, required operation, which uid passes/fails.
2. **The "world-writable vs per-user" framing has no threat model.** State
   the adversary (local user, group member, root), the asset (past events
   vs new events), and the property (no rewrite, no forge, no delete)
   before comparing options.
3. **"ASH_EVENTS_FILE is a single shared per-host file today" is false for
   the consumer.** `src/consumer/ash-consumer.py` consumes Kafka and writes
   `ash-history-{hostname}.jsonl`, `dead_letter.jsonl`, and `alerts.jsonl`;
   it never opens `/var/log/ash/events.jsonl`. A per-user-log merge is not a
   permission tweak; it is a new local ingestion pipeline with checkpoints.
   Correct the premise or add that work to the estimate.
4. **The "return 1 instead of exit" mitigation is not sufficient by itself.**
   `ash-agent.sh` used to enable `set -euo pipefail` and install traps at
   file scope. On a *successful* source there was no restore, so the user's
   interactive shell kept errexit; the first unrelated failing command could
   exit it. The SIGINT trap also called `exit 0`, which could exit the
   caller's shell. The branch fixes these, but the issue text overstates the
   sufficiency of the earlier mitigation.
5. **The hash chain is not authenticated.** `CODE_REVIEW.md` calls it
   "tamper-evident"; it detects truncation and naive edits, but any writer
   who can append can read the last hash and forge a consistent suffix.
   Rewrite: "append-only chain detects truncation and naive modification; it
   is not a MAC."
6. **`CODE_REVIEW.md` is stale at HEAD.** It says `/tmp/ash` is root-owned
   700 and `chmod 400` locks the hash chain; HEAD uses `chmod 600`. It says
   bats failures are non-blocking; `ci.yml` runs `timeout 90s bats` without
   `|| true` and the job is blocking. It says `detect-secrets` is discarded;
   the workflow compares the baseline and exits 1. It says `security-scan` is
   not a dependency of `build-package`; the job graph shows it is. It says
   `kafka-python>=2.0.2` is pinned `<3.0.0`; requirements are
   `>=3.0.0,<4.0.0`. Add `Reviewed at: <sha>` and a "still true at HEAD"
   column.
7. **`REMAINING_GAPS.md` §8 is self-contradictory.** The heading says
   "Chaos Testing Not Implemented", then says degradation tests run on every
   CI build, then lists what is still missing. Rewrite as "Chaos testing:
   N automated, M outstanding" with a test-to-scenario table.
8. **`REMAINING_GAPS.md` §2 says auditd has no automatic rule deployment.**
   `install.sh` installs `/etc/audit/rules.d/ash.rules`; what is missing is
   `augenrules --load` / `auditctl -R` and verification. Rewrite to "rules
   file installed; not loaded or verified."
9. **`REMAINING_GAPS.md` §4 says "Next step: Create
   tests/performance/benchmark.sh".** The file exists and CI runs it; the
   real gap is recorded results and thresholds.
10. **`REMAINING_GAPS.md` §10 marketing contradicts its own gaps.**
    "File change tracking: Yes", "Tamper-evident chain: Yes",
    "Kernel-level fallback: Yes" while the review documents a dead
    `file_changes` table, chain bugs, and auditd capturing only `exe`.
    Delete "only" and add an "advertised / partial / verified" column.
11. **Structure.** `CODE_REVIEW.md` opens with a 15-line cross-domain
    standard (FHIR, WAF, JPL C constraints) and then says it is
    force-fitting. The executive summary, §2, and the issue table repeat the
    same findings. Split into `BLOCKERS.md`, `ROADMAP.md`, `BENCHMARKS.md`;
    each row: ID, evidence link, owner, target release, acceptance test.

**Priority changes:** (1) finish the sourced-shell contract (done in this
branch); (2) implement a permission model with real cross-user isolation
(per-user now; privileged append later); (3) make installer/systemd the
single source of truth for modes and add non-root tests; (4) re-verify and
version-stamp the review docs, deleting false CI claims; (5) correct the
data-path premise or add local `events.jsonl` ingestion.

---

## 5. Known bugs / limitations in this WIP

* The duplicate-suppression window (250 ms) can suppress two genuinely
  distinct identical commands issued back-to-back in a non-interactive
  script. Interactive shells are separated by `PROMPT_COMMAND`; this is a
  trade-off, not a final design.
* Sourced mode logs only top-level commands because `functrace` is off.
  Function/subshell coverage is delegated to auditd. Document this clearly.
* `BASH_ENV` is not replaced when the caller already has one pointing at
  another tool; child bash processes are then not monitored. This is safer
  than clobbering it, but the gap should be documented.
* `recover_state()` only tracks the most recent previous session via the
  shared state file; older crashed sessions' watchers can remain orphaned.
* `ASH_STATE_FILE` is now in `ASH_LOG_DIR` (not temp), so concurrent
  sessions share it. The live-PID check avoids disabling concurrent
  sessions, but the last writer wins.
* `ash_prepare_log_files` may chmod an operator-managed file only when the
  current euid owns it; otherwise it leaves it alone and may later fail.
* `emit_event` now returns 0 even when the local write fails (it logs). This
  keeps the DEBUG trap from aborting the caller, but monitoring can silently
  degrade if the log becomes unwritable after startup.
* The fish integration is still broken for non-root and invalid-source
  events.
* Installer/systemd are not updated; a stock install still produces the
  old root-owned layout. The agent's fallback makes non-root sessions work,
  but `/var/log/ash/users` may not exist/traverse.
* No CI run, no `shellcheck`/`shfmt` full pass, no non-root integration test.

---

## 6. Next steps (ordered)

1. Update `scripts/install.sh`:
   * `create_directories`: `0751` on `/var/log/ash` and `/var/spool/ash`;
     `1733` on `users` dirs; pre-create per-uid dirs; pre-create
     `events.jsonl` 0640 root:ash and `.hash_chain` 0600.
   * `configure_shell_integration`: `source ... || true`, `ASH_DISABLED`
     guard, interactive-only guard.
   * `do_uninstall`: preserve `/var/log/ash`, remove only ASH-created
     per-user dirs if empty; fix `do_upgrade` backup path.
2. Update `deployments/systemd/ash-agent.service`: match dirs/modes,
   remove `/tmp/ash`, add `ASH_STRICT_PERMISSIONS=true`, `ReadWritePaths`.
3. Update `config/ash.conf.example` (`ASH_TEMP_DIR=""`, document new vars).
4. Fix fish integration (writable path, valid source, redaction/hash chain
   or route through the bash emitter).
5. Add tests:
   * `tests/unit/test_permissions.bats` (fallback, foreign-owner rejection,
     strict mode, modes);
   * non-root `setpriv --reuid=nobody` integration test;
   * installer mode assertions (container/root job);
   * fish/zsh path tests.
6. Run `shellcheck -S error`, `shfmt -d -i 4 -ci`, all bats, and CI.
7. Update docs and replace stale `CODE_REVIEW.md` claims.
8. Consider the privileged `ash-appendd` design for a follow-up release.

---

## 7. DeepSeek V4.1 review (verbatim, for future reference)

The full DeepSeek V4.1 report produced during this session is stored in the
branch as `docs/deepseek-issue5-review.md`. It recommends a privileged
append daemon, a socket protocol, `SO_PEERCRED` attribution, per-uid
rate limits, rotation, and a non-root integration test. It also lists the
same doc-staleness findings as §4. Treat it as a design input, not as
already-implemented code.

---

## 8. How to resume

```bash
git fetch origin
git checkout fix/issue-5-permissions-sourced-shell
cd /home/wojtek/Projects/ASH/repo
bash -n src/agent/ash-agent.sh
bats tests/unit/test_sourced_safety.bats
bats tests/unit/test_config_validation.bats
```

Read this file first, then §6. Do not merge until installer/systemd are
updated and the full CI matrix is green.
