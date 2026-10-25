#!/usr/bin/env python3
"""Lightweight API load check: concurrent GET /api/v1/events requests.

This is deliberately tiny -- it is a regression guard against accidentally
introducing an N+1 query or an unbounded scan in the hot search path, not a
capacity benchmark. The full benchmark suite still runs on main only.

Environment:
    ASH_API_BASE_URL   e.g. http://127.0.0.1:8080
    ASH_API_TOKEN      admin/analyst/readonly JWT
    ASH_LOAD_REQUESTS  total requests (default 50)
    ASH_LOAD_WORKERS   concurrent workers (default 50)
    ASH_LOAD_P95_MS    p95 threshold in milliseconds (default 500)
    ASH_LOAD_PATH      request path (default /api/v1/events?limit=50)
"""

import concurrent.futures
import json
import math
import os
import sys
import time
import urllib.request


def request_once(base_url, path, token):
    request = urllib.request.Request(
        f"{base_url}{path}",
        headers={"Authorization": f"Bearer {token}"},
    )
    started = time.perf_counter()
    with urllib.request.urlopen(request, timeout=10) as response:
        payload = response.read()
        if response.status != 200:
            raise RuntimeError(f"HTTP {response.status}: {payload[:200]!r}")
    elapsed_ms = (time.perf_counter() - started) * 1000
    json.loads(payload)
    return elapsed_ms


def percentile(sorted_values, fraction):
    index = max(0, math.ceil(fraction * len(sorted_values)) - 1)
    return sorted_values[index]


def main():
    base_url = os.environ["ASH_API_BASE_URL"].rstrip("/")
    token = os.environ["ASH_API_TOKEN"]
    path = os.environ.get("ASH_LOAD_PATH", "/api/v1/events?limit=50")
    total = int(os.environ.get("ASH_LOAD_REQUESTS", "50"))
    workers = int(os.environ.get("ASH_LOAD_WORKERS", "50"))
    threshold_ms = float(os.environ.get("ASH_LOAD_P95_MS", "500"))

    # Warm up the connection pool and PostgreSQL's plan cache so the first
    # request's TLS/connect cost is not counted as load.
    for _ in range(3):
        request_once(base_url, path, token)

    started = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        latencies = list(
            pool.map(lambda _i: request_once(base_url, path, token), range(total))
        )
    wall_ms = (time.perf_counter() - started) * 1000

    latencies.sort()
    p50 = percentile(latencies, 0.50)
    p95 = percentile(latencies, 0.95)
    p99 = percentile(latencies, 0.99)
    print(
        f"load: {total} requests / {workers} workers in {wall_ms:.0f}ms -- "
        f"p50 {p50:.0f}ms p95 {p95:.0f}ms p99 {p99:.0f}ms "
        f"max {latencies[-1]:.0f}ms (threshold p95 < {threshold_ms:.0f}ms)"
    )

    if p95 >= threshold_ms:
        print(
            f"FAIL: p95 {p95:.0f}ms exceeds {threshold_ms:.0f}ms",
            file=sys.stderr,
        )
        return 1
    print("load: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
