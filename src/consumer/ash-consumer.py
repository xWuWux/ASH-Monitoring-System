#!/usr/bin/env python3
"""
ASH Kafka Consumer v2.2 — Centralized Log Processing
Production-grade consumer with batch processing, deduplication,
retry logic, structured event validation, and Prometheus metrics.
"""

import gzip
import json
import logging
import os
import signal
import sys
import time
import threading
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Dict, List, Optional

import psycopg2
from psycopg2.extras import RealDictCursor, execute_values
from kafka import KafkaConsumer
from kafka.errors import NoBrokersAvailable, KafkaError
from prometheus_client import Counter, Histogram, Gauge, start_http_server


# ─── Prometheus Metrics ──────────────────────────────────────────────────────
EVENTS_RECEIVED = Counter(
    'ash_consumer_events_received_total',
    'Total events received from Kafka',
    ['source', 'event_type']
)
EVENTS_PROCESSED = Counter(
    'ash_consumer_events_processed_total',
    'Total events successfully processed'
)
EVENTS_FAILED = Counter(
    'ash_consumer_events_failed_total',
    'Total events that failed processing',
    ['reason']
)
EVENTS_DEDUPLICATED = Counter(
    'ash_consumer_events_deduplicated_total',
    'Total duplicate events skipped'
)
BATCH_FLUSH_LATENCY = Histogram(
    'ash_consumer_batch_flush_seconds',
    'Batch flush latency',
    buckets=[0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]
)
DB_WRITE_LATENCY = Histogram(
    'ash_consumer_db_write_seconds',
    'Database write latency',
    buckets=[0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]
)
KAFKA_LAG = Gauge(
    'ash_consumer_kafka_lag',
    'Kafka consumer lag (estimated)'
)
BATCH_SIZE_GAUGE = Gauge(
    'ash_consumer_batch_buffer_size',
    'Current batch buffer size'
)


# ─── Event Schema Validation ─────────────────────────────────────────────────
REQUIRED_FIELDS = ['event_id', 'timestamp', 'hostname', 'source', 'event_type']
VALID_SOURCES = [
    'bash-debug', 'bash-session', 'bash-diff', 'auditd',
    'inotify', 'fanotify', 'docker-events', 'k8s-audit',
    'process-accounting'
]
VALID_EVENT_TYPES = [
    'command_start', 'command_end', 'file_modify', 'file_create',
    'file_delete', 'file_move', 'file_attrib', 'session_start',
    'session_end', 'privilege_escalation', 'alert',
    'container_start', 'container_stop', 'container_exec',
    'container_die', 'container_create', 'container_destroy'
]


class ASHConsumer:
    """Production-grade ASH event consumer with resilience patterns."""

    def __init__(self, config_path: str = "/etc/ash/consumer.conf"):
        self.config = self._load_config(config_path)
        self._setup_logging()
        self.running = True

        # Deduplication
        self.seen_event_ids: set = set()
        self.max_seen_ids: int = self.config.get('max_dedup_cache', 100000)

        # Batch processing
        self.batch_buffer: List[Dict] = []
        self.batch_size: int = self.config.get('batch_size', 100)
        self.batch_timeout: float = self.config.get('batch_timeout', 5.0)
        self.last_flush: float = time.time()
        self.batch_lock = threading.Lock()

        # Storage
        self.log_dir = Path(self.config.get('log_dir', '/var/log/ash'))
        self.log_dir.mkdir(parents=True, exist_ok=True)

        # Database
        self.db_conn: Optional[psycopg2.extensions.connection] = None
        if self.config.get('database_enabled', False):
            self._setup_database()

        # Kafka
        self._setup_kafka_consumer()

        # Alerting
        self.alert_engine: Optional['ASHAlertEngine'] = None
        if self.config.get('alerting_enabled', False):
            from ash_alerting import ASHAlertEngine
            self.alert_engine = ASHAlertEngine(
                self.config.get('alert_rules_path', '/etc/ash/alert_rules.json')
            )

        # Retention
        self.retention_days: int = self.config.get('retention_days', 90)
        self.archive_days: int = self.config.get('archive_days', 30)
        self.archive_path = Path(self.config.get('archive_path', '/var/archive/ash'))

        # Metrics server
        metrics_port = self.config.get('metrics_port', 9090)
        try:
            start_http_server(metrics_port)
            self.logger.info(f"Prometheus metrics server on port {metrics_port}")
        except Exception as e:
            self.logger.warning(f"Could not start metrics server: {e}")

        # Signal handlers
        signal.signal(signal.SIGTERM, self._signal_handler)
        signal.signal(signal.SIGINT, self._signal_handler)

        # Start background flush timer
        self._start_flush_timer()

        # Start retention maintenance (daily)
        self._start_retention_timer()

    def _load_config(self, config_path: str) -> Dict[str, Any]:
        default_config = {
            'kafka_brokers': ['localhost:9092'],
            'kafka_topic': 'ash-logs',
            'kafka_group_id': 'ash-consumer-group',
            'log_dir': '/var/log/ash',
            'database_enabled': False,
            'database_url': 'postgresql://ash:password@localhost/ash_logs',
            'log_level': 'INFO',
            'batch_size': 100,
            'batch_timeout': 5.0,
            'retention_days': 90,
            'archive_days': 30,
            'archive_path': '/var/archive/ash',
            'metrics_port': 9090,
            'alerting_enabled': False,
            'alert_rules_path': '/etc/ash/alert_rules.json',
            'max_dedup_cache': 100000,
        }

        if os.path.exists(config_path):
            with open(config_path, 'r') as f:
                config = json.load(f)
                default_config.update(config)

        return default_config

    def _setup_logging(self):
        log_level = getattr(logging, self.config.get('log_level', 'INFO'))
        logging.basicConfig(
            level=log_level,
            format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
            handlers=[
                logging.FileHandler(
                    str(self.log_dir / 'consumer.log'),
                    encoding='utf-8'
                ),
                logging.StreamHandler()
            ]
        )
        self.logger = logging.getLogger('ash-consumer')

    def _setup_database(self):
        max_retries = 3
        for attempt in range(max_retries):
            try:
                self.db_conn = psycopg2.connect(self.config['database_url'])
                self.db_conn.autocommit = False
                self._create_tables()
                self.logger.info("Database connection established")
                return
            except Exception as e:
                self.logger.error(f"Database setup attempt {attempt+1} failed: {e}")
                time.sleep(2 ** attempt)

        self.logger.error("Database setup failed after all retries")
        self.db_conn = None

    def _create_tables(self):
        with self.db_conn.cursor() as cursor:
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS command_logs (
                    id SERIAL PRIMARY KEY,
                    event_id UUID UNIQUE NOT NULL,
                    schema_version VARCHAR(10) DEFAULT '1.0',
                    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    server_ip VARCHAR(50),
                    hostname VARCHAR(100) NOT NULL,
                    source VARCHAR(50) NOT NULL,
                    event_type VARCHAR(50) NOT NULL,
                    username VARCHAR(100),
                    uid INTEGER,
                    session_id UUID,
                    pid INTEGER,
                    ppid INTEGER,
                    tty VARCHAR(50),
                    command TEXT,
                    cwd TEXT,
                    exit_code INTEGER,
                    duration_ms REAL,
                    stdout TEXT,
                    stderr TEXT,
                    output_truncated BOOLEAN DEFAULT FALSE,
                    file_path TEXT,
                    diff_content TEXT,
                    ssh_connection VARCHAR(200),
                    container_id VARCHAR(100),
                    container_name VARCHAR(200),
                    risk_score INTEGER DEFAULT 0,
                    risk_flags TEXT[],
                    prev_hash VARCHAR(64),
                    event_hash VARCHAR(64),
                    raw_event JSONB,
                    log_timestamp TIMESTAMP,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                );

                CREATE INDEX IF NOT EXISTS idx_cmd_logs_hostname_time
                    ON command_logs (hostname, log_timestamp);
                CREATE INDEX IF NOT EXISTS idx_cmd_logs_session
                    ON command_logs (session_id, log_timestamp);
                CREATE INDEX IF NOT EXISTS idx_cmd_logs_user_time
                    ON command_logs (username, log_timestamp);
                CREATE INDEX IF NOT EXISTS idx_cmd_logs_event_type
                    ON command_logs (event_type, log_timestamp);
                CREATE INDEX IF NOT EXISTS idx_cmd_logs_source
                    ON command_logs (source);
                CREATE INDEX IF NOT EXISTS idx_cmd_logs_command_gin
                    ON command_logs USING gin (to_tsvector('english', coalesce(command, '')));
                CREATE INDEX IF NOT EXISTS idx_cmd_logs_event_id
                    ON command_logs (event_id);

                CREATE TABLE IF NOT EXISTS file_changes (
                    id SERIAL PRIMARY KEY,
                    event_id UUID UNIQUE NOT NULL,
                    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    hostname VARCHAR(100) NOT NULL,
                    username VARCHAR(100),
                    session_id UUID,
                    file_path TEXT NOT NULL,
                    change_type VARCHAR(30),
                    diff_content TEXT,
                    command TEXT,
                    source VARCHAR(50),
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                );

                CREATE INDEX IF NOT EXISTS idx_file_changes_host_time
                    ON file_changes (hostname, timestamp);
                CREATE INDEX IF NOT EXISTS idx_file_changes_path
                    ON file_changes (file_path, timestamp);
                CREATE INDEX IF NOT EXISTS idx_file_changes_session
                    ON file_changes (session_id);

                CREATE TABLE IF NOT EXISTS sessions (
                    id SERIAL PRIMARY KEY,
                    session_id UUID UNIQUE NOT NULL,
                    hostname VARCHAR(100) NOT NULL,
                    username VARCHAR(100),
                    start_time TIMESTAMP,
                    end_time TIMESTAMP,
                    ssh_connection VARCHAR(200),
                    tty VARCHAR(50),
                    shell VARCHAR(50),
                    event_count INTEGER DEFAULT 0,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                );

                CREATE INDEX IF NOT EXISTS idx_sessions_host
                    ON sessions (hostname, start_time);
                CREATE INDEX IF NOT EXISTS idx_sessions_user
                    ON sessions (username, start_time);

                CREATE TABLE IF NOT EXISTS alerts (
                    id SERIAL PRIMARY KEY,
                    event_id UUID REFERENCES command_logs(event_id),
                    rule_name VARCHAR(200) NOT NULL,
                    severity VARCHAR(20) NOT NULL,
                    description TEXT,
                    hostname VARCHAR(100),
                    username VARCHAR(100),
                    command TEXT,
                    triggered_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    acknowledged BOOLEAN DEFAULT FALSE,
                    acknowledged_by VARCHAR(100),
                    acknowledged_at TIMESTAMP
                );

                CREATE INDEX IF NOT EXISTS idx_alerts_severity
                    ON alerts (severity, triggered_at);
                CREATE INDEX IF NOT EXISTS idx_alerts_host
                    ON alerts (hostname, triggered_at);
            """)
            self.db_conn.commit()

    def _setup_kafka_consumer(self):
        max_retries = 5
        for attempt in range(max_retries):
            try:
                self.consumer = KafkaConsumer(
                    self.config['kafka_topic'],
                    bootstrap_servers=self.config['kafka_brokers'],
                    group_id=self.config['kafka_group_id'],
                    value_deserializer=lambda x: json.loads(x.decode('utf-8')),
                    auto_offset_reset='latest',
                    enable_auto_commit=True,
                    max_poll_interval_ms=300000,
                    session_timeout_ms=30000,
                    heartbeat_interval_ms=10000,
                )
                self.logger.info("Kafka consumer initialized")
                return
            except NoBrokersAvailable:
                self.logger.warning(f"Kafka not available, attempt {attempt+1}/{max_retries}")
                time.sleep(5 * (attempt + 1))
            except Exception as e:
                self.logger.error(f"Kafka setup error: {e}")
                time.sleep(5)

        self.logger.error("Kafka connection failed after all retries")
        sys.exit(1)

    def _validate_event(self, event: Dict[str, Any]) -> bool:
        for field in REQUIRED_FIELDS:
            if field not in event:
                EVENTS_FAILED.labels(reason='missing_field').inc()
                return False
        return True

    def _deduplicate(self, event_id: str) -> bool:
        if event_id in self.seen_event_ids:
            EVENTS_DEDUPLICATED.inc()
            return True
        self.seen_event_ids.add(event_id)
        if len(self.seen_event_ids) > self.max_seen_ids:
            # Evict oldest half
            ids_list = list(self.seen_event_ids)
            self.seen_event_ids = set(ids_list[self.max_seen_ids // 2:])
        return False

    def process_message(self, log_data: Dict[str, Any]):
        """Process a single incoming event with validation and deduplication."""
        try:
            if not self._validate_event(log_data):
                self.logger.warning(f"Invalid event schema: {log_data.get('event_id', 'unknown')}")
                return

            event_id = log_data.get('event_id', '')
            if self._deduplicate(event_id):
                self.logger.debug(f"Duplicate event skipped: {event_id}")
                return

            source = log_data.get('source', 'unknown')
            event_type = log_data.get('event_type', 'unknown')
            EVENTS_RECEIVED.labels(source=source, event_type=event_type).inc()

            # Alerting
            if self.alert_engine:
                self.alert_engine.check_event(log_data)

            # Add to batch buffer
            with self.batch_lock:
                self.batch_buffer.append(log_data)
                BATCH_SIZE_GAUGE.set(len(self.batch_buffer))

                if len(self.batch_buffer) >= self.batch_size:
                    self._flush_batch()

        except Exception as e:
            self.logger.error(f"Error processing message: {e}", exc_info=True)
            EVENTS_FAILED.labels(reason='processing_error').inc()

    def _flush_batch(self):
        """Flush the current batch to storage."""
        if not self.batch_buffer:
            return

        start_time = time.time()
        batch = self.batch_buffer[:]
        self.batch_buffer = []
        BATCH_SIZE_GAUGE.set(0)

        try:
            # Write to file
            self._write_file_batch(batch)

            # Write to database
            if self.db_conn:
                self._write_database_batch(batch)

            self.last_flush = time.time()
            EVENTS_PROCESSED.inc(len(batch))

        except Exception as e:
            self.logger.error(f"Batch flush failed: {e}")
            # Re-add failed batch for retry
            self.batch_buffer = batch + self.batch_buffer
            BATCH_SIZE_GAUGE.set(len(self.batch_buffer))
            EVENTS_FAILED.labels(reason='flush_error').inc()

        BATCH_FLUSH_LATENCY.observe(time.time() - start_time)

    def _write_file_batch(self, events: List[Dict]):
        """Write batch of events to JSONL files grouped by hostname."""
        files: Dict[str, list] = {}
        for event in events:
            hostname = event.get('hostname', 'unknown')
            if hostname not in files:
                files[hostname] = []
            files[hostname].append(event)

        for hostname, host_events in files.items():
            log_file = self.log_dir / f"ash-history-{hostname}.jsonl"
            with open(log_file, 'a', encoding='utf-8') as f:
                for event in host_events:
                    f.write(json.dumps(event, default=str) + '\n')

    def _write_database_batch(self, events: List[Dict]):
        """Write batch to PostgreSQL with retry logic."""
        max_retries = 3
        for attempt in range(max_retries):
            try:
                start_time = time.time()
                with self.db_conn.cursor() as cursor:
                    command_events = []
                    file_events = []
                    session_events = []

                    for e in events:
                        event_type = e.get('event_type', '')

                        if event_type in ('session_start', 'session_end'):
                            session_events.append(e)
                        elif event_type.startswith('file_'):
                            file_events.append(e)

                        # All events go to command_logs
                        command_events.append(e)

                    # Bulk insert command events
                    if command_events:
                        values = [
                            (
                                e.get('event_id'),
                                e.get('schema_version', '1.0'),
                                e.get('hostname', 'unknown'),
                                e.get('source', 'unknown'),
                                e.get('event_type', 'unknown'),
                                e.get('user', e.get('username', '')),
                                e.get('uid'),
                                e.get('session_id'),
                                e.get('pid'),
                                e.get('ppid'),
                                e.get('tty'),
                                e.get('command', ''),
                                e.get('cwd'),
                                e.get('exit_code'),
                                e.get('duration_ms'),
                                e.get('stdout', e.get('output', '')),
                                e.get('file_path'),
                                e.get('diff_content'),
                                e.get('ssh_connection'),
                                e.get('container_id'),
                                e.get('container_name'),
                                e.get('risk_score', 0),
                                e.get('prev_hash'),
                                e.get('event_hash'),
                                json.dumps(e, default=str),
                                e.get('timestamp'),
                            )
                            for e in command_events
                        ]
                        execute_values(
                            cursor,
                            """INSERT INTO command_logs
                            (event_id, schema_version, hostname, source, event_type,
                             username, uid, session_id, pid, ppid, tty, command, cwd,
                             exit_code, duration_ms, stdout, file_path, diff_content,
                             ssh_connection, container_id, container_name, risk_score,
                             prev_hash, event_hash, raw_event, log_timestamp)
                            VALUES %s
                            ON CONFLICT (event_id) DO NOTHING""",
                            values,
                            template="""(%s, %s, %s, %s, %s, %s, %s, %s::uuid, %s, %s,
                                         %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                                         %s, %s, %s, %s::jsonb, %s::timestamp)"""
                        )

                    # Handle sessions
                    for se in session_events:
                        if se.get('event_type') == 'session_start':
                            cursor.execute("""
                                INSERT INTO sessions
                                (session_id, hostname, username, start_time, ssh_connection, tty, shell)
                                VALUES (%s, %s, %s, %s, %s, %s, %s)
                                ON CONFLICT (session_id) DO NOTHING
                            """, (
                                se.get('session_id'),
                                se.get('hostname'),
                                se.get('user', se.get('username')),
                                se.get('timestamp'),
                                se.get('ssh_connection'),
                                se.get('tty'),
                                se.get('shell'),
                            ))
                        elif se.get('event_type') == 'session_end':
                            cursor.execute("""
                                UPDATE sessions
                                SET end_time = %s, event_count = %s
                                WHERE session_id = %s
                            """, (
                                se.get('timestamp'),
                                se.get('events_in_session', 0),
                                se.get('session_id'),
                            ))

                self.db_conn.commit()
                DB_WRITE_LATENCY.observe(time.time() - start_time)
                return

            except psycopg2.OperationalError as e:
                self.logger.warning(f"DB connection lost (attempt {attempt+1}): {e}")
                time.sleep(2 ** attempt)
                try:
                    self.db_conn = psycopg2.connect(self.config['database_url'])
                    self.db_conn.autocommit = False
                except Exception:
                    pass
            except Exception as e:
                self.logger.error(f"Database write error: {e}", exc_info=True)
                if self.db_conn:
                    self.db_conn.rollback()
                EVENTS_FAILED.labels(reason='db_write_error').inc()
                return

    def _start_flush_timer(self):
        """Periodic flush timer for batch timeout."""
        def flush_loop():
            while self.running:
                time.sleep(1.0)
                with self.batch_lock:
                    if self.batch_buffer and (time.time() - self.last_flush) >= self.batch_timeout:
                        self._flush_batch()

        thread = threading.Thread(target=flush_loop, daemon=True)
        thread.start()

    def _start_retention_timer(self):
        """Run retention maintenance daily."""
        def retention_loop():
            while self.running:
                time.sleep(86400)  # 24 hours
                try:
                    self._run_retention()
                except Exception as e:
                    self.logger.error(f"Retention maintenance failed: {e}")

        thread = threading.Thread(target=retention_loop, daemon=True)
        thread.start()

    def _run_retention(self):
        """Archive old records and delete expired ones."""
        if not self.db_conn:
            return

        self.logger.info("Running retention maintenance...")
        self.archive_path.mkdir(parents=True, exist_ok=True)

        # Archive records older than archive_days
        archive_cutoff = datetime.now() - timedelta(days=self.archive_days)
        with self.db_conn.cursor(cursor_factory=RealDictCursor) as cursor:
            cursor.execute(
                "SELECT * FROM command_logs WHERE log_timestamp < %s ORDER BY log_timestamp LIMIT 10000",
                (archive_cutoff,)
            )
            rows = cursor.fetchall()

            if rows:
                archive_file = self.archive_path / f"commands_{archive_cutoff.strftime('%Y%m%d')}.jsonl.gz"
                with gzip.open(archive_file, 'at', encoding='utf-8') as f:
                    for row in rows:
                        f.write(json.dumps(dict(row), default=str) + '\n')

                self.logger.info(f"Archived {len(rows)} records to {archive_file}")

        # Delete records older than retention_days
        retention_cutoff = datetime.now() - timedelta(days=self.retention_days)
        with self.db_conn.cursor() as cursor:
            cursor.execute("DELETE FROM command_logs WHERE log_timestamp < %s", (retention_cutoff,))
            deleted = cursor.rowcount
            cursor.execute("DELETE FROM file_changes WHERE timestamp < %s", (retention_cutoff,))
            self.db_conn.commit()

            if deleted > 0:
                self.logger.info(f"Deleted {deleted} expired records")
                cursor.execute("VACUUM ANALYZE command_logs")
                cursor.execute("VACUUM ANALYZE file_changes")

    def run(self):
        """Main consumer loop."""
        self.logger.info(f"ASH Consumer v2.2 started (topic: {self.config['kafka_topic']})")

        try:
            for message in self.consumer:
                if not self.running:
                    break
                self.process_message(message.value)

        except KeyboardInterrupt:
            self.logger.info("Consumer interrupted by user")
        except Exception as e:
            self.logger.error(f"Consumer loop error: {e}", exc_info=True)
        finally:
            self._cleanup()

    def _signal_handler(self, signum, frame):
        self.logger.info(f"Received signal {signum}, shutting down...")
        self.running = False

    def _cleanup(self):
        # Flush remaining batch
        with self.batch_lock:
            if self.batch_buffer:
                self._flush_batch()

        if hasattr(self, 'consumer'):
            self.consumer.close()
        if self.db_conn:
            self.db_conn.close()

        self.logger.info("ASH Consumer stopped")


if __name__ == "__main__":
    config_path = sys.argv[1] if len(sys.argv) > 1 else "/etc/ash/consumer.conf"
    consumer = ASHConsumer(config_path)
    consumer.run()
