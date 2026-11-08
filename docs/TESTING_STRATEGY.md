# Test Expansion Strategy (Load, Resilience, Mutation)

This document records the decisions for the test-expansion work requested
after the security/contract/Kafka-E2E foundation. It is deliberately explicit
about what is implemented, what is deferred, and what still needs a decision.

## Scope decisions

| Layer | Decision | Where |
|---|---|---|
| Load/performance | Implement k6 against the Compose stack; hard per-endpoint gates | `tests/performance/k6/`, `ci.yml` ephemeral job |
| DAST | **Deferred.** JSON/JWT API, no UI, no OpenAPI spec; low ROI until compliance requires it | This document |
| Resilience | Implement PostgreSQL stop/start and API→PostgreSQL Toxiproxy latency; no Chaos Mesh | `tests/resilience/`, `.github/workflows/nightly.yml` |
| Accessibility | **N/A.** No frontend exists; Grafana is vendor UI | This document |
| Mutation | Implement mutmut 3.8.1 over `src/consumer`, pure unit tests only, nightly, 120-minute cap | `setup.cfg`, `.github/workflows/nightly.yml` |

## 1. k6 load test

- **Tool:** k6 v0.54.0, pinned binary plus SHA-256 in `ci.yml`. The existing
  `tests/performance/load_api.py` stays as the small every-PR regression
  guard; it is not replaced.
- **Endpoints (per-endpoint gates):**
  - `/api/v1/events?limit=50`
  - `/api/v1/hosts`
  - `/api/v1/stats/timeline?hours=24`
  - `/api/v1/stats/top-commands?hours=24&limit=20`
  - `/api/v1/sessions?limit=50`
- **Load:** 20 constant VUs for 60 seconds; each VU cycles through all
  endpoints with 100 ms think time.
- **Hard gates:** average `< 200 ms`, p95 `< 500 ms`, failed requests
  `< 1%`, checks `> 99%` per endpoint. k6 exits non-zero on failure.
- **Seed:** `tests/performance/k6/seed.sql` inserts 500,000 `command_logs`
  rows (20 hosts, 24 hours), 20,000 `sessions`, and 50,000 `file_changes`.
  The seed **truncates** the tables and is test-only.
- **CI trigger:** existing `ephemeral-deploy-benchmarks` job, which runs on
  push to `main` and manual dispatch. It is not in the required-to-merge
  chain, so PR time is unaffected.
- **Why not every PR:** stack build + 500k seed + 60s load adds roughly
  2–4 minutes and is noisy on a shared runner. PRs keep the Python p95
  check.

### Known risk

The 24-hour aggregate endpoints are the likely bottleneck, not the events
list: `/api/v1/hosts` (`COUNT(DISTINCT session_id)`), `/api/v1/stats/timeline`
and `/api/v1/stats/top-commands` group 500k rows. The k6 events request has no
`command` filter, so the `ILIKE` path is not exercised by this load test. With
500k rows the hard `avg < 200 ms` gate may fail on a 2-core GitHub runner even
after the seed correlates `session_id` with the 20k seeded sessions. If it
fails, do not silently relax the threshold: capture the measured p50/p95, add
the missing time/aggregate index or rewrite the query, and re-baseline. The
gate is intentionally strict because it is the requested SLO; the first main
run is the calibration run.

There is no reverse proxy in Compose, so 502/504 cannot be produced. The
failure gate covers 5xx/503, timeouts, and non-JSON responses.

## 2. Resilience

- **What is implemented:** `tests/resilience/postgres-outage.sh` plus
  `deployments/docker/docker-compose.resilience.yml` and
  `deployments/docker/toxiproxy.json`.
  - Toxiproxy proxies the API's PostgreSQL connection only; the consumer
    keeps its direct connection.
  - The script injects 200 ms ± 50 ms latency, asserts the API still returns
    200 and that latency increased, removes the toxic, then stops PostgreSQL
    and asserts `/health/ready` and `/api/v1/events` return 503. It starts
    PostgreSQL again and asserts 200 without an API restart.
- **What is not implemented:** real DB failover (Compose has one PostgreSQL,
  no replica), Kafka outage/reconnect in this script, Chaos Mesh (requires
  Kubernetes), and Toxiproxy on the consumer→Kafka link. The script name and
  docs scope this to PostgreSQL; Kafka reconnect remains a separate gap.
- **CI:** `.github/workflows/nightly.yml` at 03:00 UTC plus manual dispatch.

## 3. Mutation testing

- **Tool:** mutmut 3.8.1.
- **Configuration:** `setup.cfg` `[mutmut]`:
  - `source_paths = src/consumer`
  - `pytest_add_cli_args_test_selection = tests/unit/python`
  - `pytest_add_cli_args = -x -q`
  - `mutate_only_covered_lines = true`
- **Why only unit tests:** integration/contract/degradation/Kafka tests need
  PostgreSQL or Kafka; running them once per mutant is impractical. The unit
  suite mocks those services.
- **Runtime:** nightly job, `timeout 7200 mutmut run` (120-minute cap),
  artifacts uploaded. The job is **report-only** (`continue-on-error`) until
  a mutation-score threshold is agreed; the first runs are for baseline and
  triage. `mutmut run` exits 0 even with surviving mutants, so a green job
  without a parsed score is not a quality signal.
- **Known risk:** mutmut 3.x may not support every Python 3.12 feature used
  by the consumer; if the first run fails during collection, pin the last
  working mutmut version and document it.

## 4. DAST — deferred

ZAP/Nuclei would mostly re-test authentication/RBAC, which the contract
tests already cover. There is no OpenAPI spec, no browser UI, and no
server-rendered HTML, so spidering/XSS have little surface. SQL injection is
already mitigated by parameterized queries; the only dynamic interval value
is parsed as an integer. If compliance later requires DAST, run a
report-only ZAP baseline monthly, or Nuclei with a curated template set,
against a staging deployment with an ingress.

## 5. Accessibility — N/A

No frontend exists. `docs/REMAINING_GAPS.md` explicitly says the UI is
future work. When a UI is built, add Playwright + axe-core for WCAG checks
and Lighthouse CI for performance/accessibility budgets.

## 6. Follow-ups

1. Run the k6 job once on `main` and record the baseline in
   `docs/PROJECT_REPORT.md`; if the gate fails, fix the query/index rather
   than weakening it.
2. Add Kafka outage/reconnect to the nightly resilience script if the
   consumer's reconnect behavior is in scope.
3. Add a mutation-score threshold after 2–3 nightly baselines.
4. Add a UI accessibility job only when a frontend exists.
5. Add an ingress/proxy if 502/504 coverage is required.
