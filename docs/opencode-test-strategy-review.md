# ASH Test Strategy Review

## Verdict

One real gap: sustained API load against the composed stack. ASH already has a PR-blocking API smoke + p95 gate, Kafka E2E, and degradation tests. `ephemeral-deploy-benchmarks` starts the stack but times the Bash pipeline, not HTTP. DAST is low ROI for a JSON/JWT API with no UI; Chaos Mesh does not fit Compose; mutation is premature; a11y is N/A.

## 1. What exists vs. what is missing

| Area | Evidence | Reality |
|---|---|---|
| API smoke + load, every PR | `.github/workflows/ci.yml:333-378` runs `tests/smoke/smoke-api.sh`; it starts gunicorn (`smoke-api.sh:75-85`), gets a JWT (`:114-139`), queries events (`:141-157`), then runs `load_api.py` (`:159-162`). `load_api.py` defaults to 50 requests/50 threads, p95 < 500 ms (`:11-14,49-52,76-81`). | Tiny: no avg/error-rate/5xx/sustained load; `urllib` opens a new connection per request. |
| API contract, every PR | `ci.yml:414-447`; 25 tests cover every endpoint, filters, pagination, invalid input, RBAC (`tests/contract/test_api_contract.py`; `tests/README.md:17`). | Strong gate. |
| Kafka E2E, every PR | `ci.yml:450-542`; `tests/integration/kafka-e2e.sh` agent -> broker -> consumer -> PostgreSQL, hash recomputation. | Happy path only; no failure injection. |
| Degradation, every PR | `ci.yml:302-331`; Kafka outage with fake producer and spool drain (`tests/degradation/test_kafka_outage.bats:57-127`); consumer DB outage mocked (`tests/degradation/python/test_consumer_degradation.py:81-127`); API 503 mocked (`tests/degradation/python/test_api_degradation.py:6-26`). | Deterministic, but not real-service reconnect. |
| Ephemeral deploy, main/manual only | `ci.yml:674-724`; compose up, health wait, `curl /health` (`:709-710`), `benchmark.sh 1000` (`:712-713`). | `benchmark.sh` measures hash-chain + redaction (`:1-11,35-58`), not the API. Never sends authenticated API load. |
| Security | Bandit, Semgrep, pip-audit, OSV-Scanner, detect-secrets (`ci.yml:151-215`); CodeQL (`.github/workflows/codeql.yml`); `tests/README.md:57-63`. | SAST/SCA only; no DAST. |
| Coverage | Report-only (`ci.yml:288-298`). | No threshold, no mutation. |
| Scheduling | Triggers are push/PR/dispatch only (`ci.yml:3-8`). | No nightly tests; CodeQL weekly only (`codeql.yml:8-9`). |
| Frontend | No `package.json`, HTML, or SPA files. `docs/REMAINING_GAPS.md:112-128` says no frontend; `docs/PROJECT_REPORT.md:117,202`. Grafana is optional third-party UI (`deployments/docker/docker-compose.yml:260-290`). | No UI; a11y N/A. |

Genuinely missing:

1. Sustained authenticated API load with seed data, error-rate/5xx, avg/p95, artifact, trend.
2. Real-service failure/reconnect: Kafka stop/start, consumer rebalance, PostgreSQL stop/start. Tests fake the producer or monkeypatch `get_db`.
3. DAST (limited value; below).
4. Mutation testing (premature).
5. Accessibility: N/A until a UI exists.

## 2. Tool assessment

### k6 vs. the existing `load_api.py`

k6 is better for sustained load: VUs, keep-alive, thresholds, nonzero exit, JSON summary. A 2-core runner, 4 synchronous gunicorn workers (`deployments/docker/Dockerfile.api:22`), one PostgreSQL (`docker-compose.yml:45-60`), one Kafka (`:23-43`). Hundreds-to-thousands of VUs measure runner/DB queueing, not ASH capacity. Use 10-50 VUs in CI; thousands need distributed k6/pre-prod.

HTTP 502/504 are impossible to check here: there is no reverse proxy, the API publishes 8080 directly (`docker-compose.yml:119-120`), and database failure returns 503 (`src/consumer/api_server.py:376-387`). Gate on 5xx/503 and network errors. Add 502/504 only if an ingress is introduced.

An empty DB is unrealistically fast. `GET /api/v1/events` does a list query plus `COUNT(*)` (`api_server.py:565-579`); `command ILIKE '%...%'` (`:543-545`) cannot use the GIN index, and there is no standalone `log_timestamp` index (`ash-consumer.py:831-846`), so `ORDER BY ... LIMIT` sorts. Seed >=50k rows; this may expose a real missing index.

Auth: acquire one token in `setup()`. `POST /api/v1/auth/token` is rate-limited to 5/minute (`api_server.py:471`) and tokens last 24h by default (`:134`). Do not mint a token per VU.

Verdict: keep `load_api.py` for PR smoke; add k6 for deployment/nightly. Do not replace a working check with a new dependency.

### ZAP / Nuclei

No OpenAPI spec; ZAP's spider/baseline on JSON is passive noise. XSS is moot: JSON responses, no browser UI. SQLi is largely moot: queries are parameterized; the dynamic `INTERVAL '%s hours'` (`api_server.py:721,752`) only receives integers from `_int_arg` (`:399-418`). Real issues are auth/rate-limit/headers: only `X-Request-ID` is set (`:312`), `/metrics` is fail-closed (`:946-970`), and token/RBAC is already tested (`:443-466,470-513`). ZAP active scan: 3-5 days, flaky; Nuclei: 1-2 days, little yield. If compliance requires DAST, run ZAP baseline report-only monthly; otherwise defer. Stored XSS matters only when the planned UI renders command text.

### Chaos Mesh vs. Toxiproxy vs. existing BATS

Chaos Mesh requires Kubernetes. This repo is Docker Compose and has no Helm chart (`docs/REMAINING_GAPS.md:107-108`). N/A.

Toxiproxy can inject latency/partitions but needs a proxy container plus URL rewrites (`docker-compose.yml:73-74,122`). For a 10s Kafka outage, `docker compose stop kafka`/`start` is simpler and exercises the real client. But 10s is below the consumer's 30s session timeout (`ash-consumer.py:934-935`): it may reconnect the socket but not exercise session-expiry rebalance. Use >30-60s for that. DB failover is impossible with one PostgreSQL and no replica (`docker-compose.yml:45-60`); test outage/recovery only. Containers, not pods: use `docker compose stop/start/restart`.

Keep BATS fakes for PR speed. Add one nightly script: Kafka stop/start, assert consumer metrics/rows; PostgreSQL stop/start, assert API 503 then 200 and batch retention. Toxiproxy only if latency/jitter is required.

### mutmut vs. Cosmic Ray

Python is ~4.6k LOC (`api_server.py` 977, `ash-consumer.py` 1797, `ash_tracing.py` 833, etc.). mutmut fits better: simpler pytest integration/config than Cosmic Ray's init/exec/crunch. Both run the suite per mutant; 1k-2k mutants x seconds = hours; DB tests cannot run per mutant. Pilot pure modules (`ash_alerting.py` + `tests/unit/python/test_alerting.py`; API validators), nightly, non-blocking. Whole-repo only after the unit suite is <30s and coverage has a threshold. Defer.

### Accessibility

N/A. There is no UI; Grafana is vendor UI. When a UI is built (`docs/REMAINING_GAPS.md:114-128`), add axe-core + Playwright and Lighthouse for pages. JSON API responses have no accessibility surface.

## 3. k6 quick win: minimal PR plan

### Files

- New `tests/performance/k6/api-load.js`
- New `tests/performance/k6/seed.sql`
- Modify `.github/workflows/ci.yml`, job `ephemeral-deploy-benchmarks`
- Optional `tests/performance/k6/README.md`

### CI changes

Stack startup stays `docker compose up -d --build` (`ci.yml:687-689`); k6 runs on the host against published 8080. After the health wait (`ci.yml:691-707`):

1. Seed:
   `docker compose -f deployments/docker/docker-compose.yml exec -T -e PGPASSWORD="$ASH_DB_PASSWORD" postgres psql -U ash -d ash_logs -v ON_ERROR_STOP=1 < tests/performance/k6/seed.sql`
   Consumer creates schema at startup; health wait proves it. Seed 50k rows, 20 hosts, 24h spread.
2. Install pinned k6 tarball + SHA-256 (pattern: `ci.yml:38-40,514-527`); not apt.
3. `mkdir -p k6-results`; run with `ASH_API_BASE_URL=http://localhost:8080`, the existing admin credentials (`ci.yml:681-683`), `K6_VUS=20`, `K6_DURATION=60s`, and `--summary-export=k6-results/summary.json`.
4. Upload `k6-results/` with `if: always()`. Teardown is already `if: always()` (`:721-724`).
5. Rename the `benchmark.sh` step "agent pipeline benchmark"; it is not API perf.

### Script and thresholds

```js
import http from 'k6/http';
import { check, sleep } from 'k6';
const BASE = __ENV.ASH_API_BASE_URL;
export const options = {
  scenarios: { api: { executor: 'constant-vus', vus: Number(__ENV.K6_VUS || 20), duration: __ENV.K6_DURATION || '60s' } },
  thresholds: {
    'http_req_duration{scenario:api}': ['avg<200', 'p(95)<500', 'p(99)<1000'],
    'http_req_failed{scenario:api}': ['rate<0.01'],
    checks: ['rate>0.99'],
  },
};
export function setup() {
  const r = http.post(`${BASE}/api/v1/auth/token`, JSON.stringify({username: __ENV.ASH_ADMIN_USER, password: __ENV.ASH_ADMIN_PASS}), {headers: {'Content-Type': 'application/json'}});
  check(r, {token: x => x.status === 200});
  return {token: r.json('token')};
}
export default function (d) {
  const r = http.get(`${BASE}/api/v1/events?limit=50`, {headers: {Authorization: `Bearer ${d.token}`}, tags: {name: 'events'}, timeout: '10s'});
  check(r, {ok: x => x.status === 200, json: x => (x.headers['Content-Type'] || '').includes('application/json')});
  sleep(0.1);
}
```

`avg<200` is aggressive for a shared runner and full-table `COUNT(*)`. Baseline at 10 VUs first; if it fails at 20, lower VUs or gate p95 and report avg—do not silently relax. `http_req_failed` catches 5xx/503/network; 502/504 need a proxy. Setup is outside the `api` tag, so it does not pollute latency (verify). `timeout: '10s'` catches hangs.

Seed SQL:

```sql
INSERT INTO command_logs
  (event_id, hostname, source, event_type, username, command, log_timestamp, risk_score)
SELECT gen_random_uuid(), 'bench-host-' || (i % 20), 'bash-debug', 'command_start',
       'bench-user', 'bench-command-' || i, now() - (random() * interval '24 hours'), i % 100
FROM generate_series(1, 50000) AS g(i);
```

PostgreSQL 16 has `gen_random_uuid()` built in. Cleanup is the existing `docker compose down -v`.

### Runtime and PR speed

Adds ~80-120s (seed 5-10s, load 60s, install 5s); raise timeout 20 -> 25 min (`ci.yml:678`).

Job is not in `ci-success` (`ci.yml:649-666`) and runs only on main/manual (`:676`), so this adds zero PR time. For nightly, use a separate `.github/workflows/performance.yml` with `schedule`/`workflow_dispatch`; adding `schedule` to `ci.yml` runs every job. Keep `load_api.py` as the every-PR guard.

## 4. Decisions needed before implementation

- Frontend planned? If yes, a11y and stored-XSS scope change.
- Which endpoints define the SLO: `/events`, `/hosts`, `/stats/*`? Seed volume: 50k/500k/5M?
- Does "hundreds-thousands" mean VUs, RPS, or users? Which environment? A GitHub runner cannot.
- Is `avg<200ms` a hard gate at 20 VUs or report-only? p95 target?
- Is +2 min on main acceptable? Nightly? Who triages flakes?
- Pinned k6 binary or third-party action? Egress policy?
- Reuse existing CI ephemeral secrets (`ci.yml:680-683`) or add GitHub secrets for pre-prod?
- Keep or replace `load_api.py`? Keep it.
- DB failover in scope? Compose cannot do it; need HA PostgreSQL.
- DAST required for compliance? ZAP or Nuclei, report-only or blocking, who fixes?
- Mutation budget: pilot module or whole repo, minimum score, nightly runtime cap.
- Proxy/ingress planned? If not, drop 502/504.

## 5. Recommended order and effort

1. k6: 4-8h (script + CI + seed + baseline); 1-2 days if flaky. First.
2. Chaos script: 1-2 days (Kafka/PostgreSQL stop/start, assertions); no new tooling.
3. DAST: Nuclei 1-2 days; ZAP 3-5 days. Defer unless required.
4. Mutation pilot: 1-2 days setup/triage + nightly compute; whole repo 1-2 weeks. Defer.
5. Accessibility: zero now; 2-3 days when a UI exists.
