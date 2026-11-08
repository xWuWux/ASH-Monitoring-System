-- Benchmark seed data for the k6 API load test.
--
-- TEST ONLY. This truncates the ASH tables. Never run it against a real
-- deployment. It is executed against the disposable Compose PostgreSQL
-- volume created by .github/workflows/ci.yml.
--
-- 500,000 command_logs rows across 20 hosts and 30 days (~16.7k in the last
-- 24 hours), 20,000 sessions, and 50,000 file_changes rows. The volume is deliberately large enough that
-- GET /api/v1/events must execute its list + COUNT(*), /hosts must
-- aggregate the last 24 hours, and /stats/timeline and /stats/top-commands
-- must group the last 24 hours. The ILIKE search path is not exercised
-- because the load request has no command filter.

TRUNCATE TABLE alerts, command_logs, file_changes, sessions RESTART IDENTITY;

INSERT INTO sessions (
    session_id,
    hostname,
    username,
    start_time,
    end_time,
    ssh_connection,
    tty,
    shell,
    event_count
)
SELECT
    md5(i::text)::uuid,
    'bench-host-' || (i % 20),
    'bench-user',
    now() - (random() * interval '30 days'),
    now(),
    '10.0.0.1 52341 10.0.0.2 22',
    '/dev/pts/0',
    'bash',
    25
FROM generate_series(1, 20000) AS g(i);

INSERT INTO command_logs (
    event_id,
    schema_version,
    timestamp,
    hostname,
    source,
    event_type,
    username,
    uid,
    session_id,
    pid,
    ppid,
    tty,
    command,
    cwd,
    ssh_connection,
    risk_score,
    trace_id,
    span_id,
    log_timestamp
)
SELECT
    gen_random_uuid(),
    '1.0',
    ts,
    'bench-host-' || (i % 20),
    'bash-debug',
    'command_start',
    'bench-user',
    1000,
    md5(((i % 20000) + 1)::text)::uuid,
    1000 + i,
    999,
    '/dev/pts/0',
    'bench-command-' || (i % 5000),
    '/home/bench',
    '10.0.0.1 52341 10.0.0.2 22',
    i % 100,
    md5(i::text),
    substr(md5((i + 1)::text), 1, 16),
    ts
FROM (
    SELECT i, now() - (random() * interval '30 days') AS ts
    FROM generate_series(1, 500000) AS g(i)
) AS seeded;

INSERT INTO file_changes (
    event_id,
    timestamp,
    hostname,
    username,
    session_id,
    file_path,
    change_type,
    diff_content,
    command,
    source
)
SELECT
    gen_random_uuid(),
    now() - (random() * interval '30 days'),
    'bench-host-' || (i % 20),
    'bench-user',
    md5(((i % 20000) + 1)::text)::uuid,
    '/tmp/bench-' || (i % 1000),
    'modify',
    '--- a/bench\n+++ b/bench\n@@ -1 +1 @@\n-old\n+new',
    'bench-command-' || (i % 5000),
    'bash-diff'
FROM generate_series(1, 50000) AS g(i);

ANALYZE command_logs;
ANALYZE sessions;
ANALYZE file_changes;
