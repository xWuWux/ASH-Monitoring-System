"""Shared fixtures for the Python consumer and API tests."""

import importlib.util
import logging
import os
import sys
import threading
import time
import uuid
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
CONSUMER_PATH = REPO_ROOT / "src" / "consumer" / "ash-consumer.py"
API_PATH = REPO_ROOT / "src" / "consumer" / "api_server.py"

# api_server.py refuses to import without these; tests use throwaway values.
os.environ.setdefault("ASH_JWT_SECRET", "test-only-jwt-secret-not-for-production")
os.environ.setdefault(
    "ASH_DATABASE_URL", "postgresql://ash:test@localhost:5432/ash_logs"
)
os.environ.setdefault("ASH_ADMIN_USER", "test-admin")
os.environ.setdefault("ASH_ADMIN_PASS", "test-password")


def _load_module(name: str, path: Path):
    """Load a dashed-filename module (ash-consumer.py) exactly once."""
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="session")
def consumer_module():
    return _load_module("ash_consumer", CONSUMER_PATH)


@pytest.fixture(scope="session")
def api_module():
    return _load_module("ash_api_server", API_PATH)


def _build_consumer(module, tmp_path: Path, **overrides):
    consumer = object.__new__(module.ASHConsumer)

    log_dir = tmp_path / "log"
    log_dir.mkdir(parents=True, exist_ok=True)

    consumer.config = {
        "database_enabled": False,
        "database_url": "postgresql://unused",
        "kafka_topic": "ash-logs-test",
        "batch_size": 100,
        "batch_timeout": 5.0,
        "max_dedup_cache": 100000,
        "retention_days": 90,
        "archive_days": 30,
        "archive_path": str(tmp_path / "archive"),
        "log_dir": str(log_dir),
    }
    consumer.config.update(overrides)
    consumer.logger = logging.getLogger(f"ash-consumer-test-{id(consumer)}")
    consumer.logger.addHandler(logging.NullHandler())
    consumer.logger.propagate = False
    consumer.running = True

    consumer.seen_event_ids = set()
    consumer.max_seen_ids = consumer.config["max_dedup_cache"]
    consumer.batch_buffer = []
    consumer.batch_raw_texts = []
    consumer.batch_size = consumer.config["batch_size"]
    consumer.batch_timeout = consumer.config["batch_timeout"]
    consumer.last_flush = time.time()
    consumer.batch_lock = threading.Lock()
    consumer._processing_lock = threading.Lock()
    consumer._commit_pending = threading.Event()

    consumer.log_dir = log_dir
    consumer.dlq_path = log_dir / "dead_letter.jsonl"
    consumer.db_conn = None
    consumer.alert_engine = None
    consumer.archive_path = Path(consumer.config["archive_path"])

    return consumer


@pytest.fixture
def consumer_factory(tmp_path, consumer_module):
    def factory(**overrides):
        return _build_consumer(consumer_module, tmp_path, **overrides)

    return factory


@pytest.fixture
def event_factory():
    def factory(**overrides):
        event = {
            "event_id": str(uuid.uuid4()),
            "schema_version": "1.0",
            "timestamp": "2026-01-01T00:00:00.000Z",
            "hostname": "smoke-host",
            "source": "bash-debug",
            "event_type": "command_start",
            "user": "tester",
            "uid": 1000,
            "session_id": str(uuid.uuid4()),
            "pid": 1234,
            "ppid": 1,
            "tty": "/dev/pts/0",
            "command": "echo hello",
            "cwd": "/tmp",
            "exit_code": 0,
            "prev_hash": "0" * 64,
            "event_hash": "1" * 64,
        }
        event.update(overrides)
        return event

    return factory


@pytest.fixture
def api_client(api_module):
    api_module.app.config["TESTING"] = True
    return api_module.app.test_client()
