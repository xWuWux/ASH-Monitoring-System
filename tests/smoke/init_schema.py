#!/usr/bin/env python3
"""Create the ASH database schema for the API smoke test."""

import importlib.util
import logging
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONSUMER_PATH = ROOT / "src" / "consumer" / "ash-consumer.py"


def main() -> int:
    database_url = os.environ.get("ASH_DATABASE_URL")
    if not database_url:
        print("ASH_DATABASE_URL is required", file=sys.stderr)
        return 2

    spec = importlib.util.spec_from_file_location("ash_consumer_smoke", CONSUMER_PATH)
    if spec is None or spec.loader is None:
        print(f"cannot load {CONSUMER_PATH}", file=sys.stderr)
        return 2
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    consumer = object.__new__(module.ASHConsumer)
    consumer.config = {"database_url": database_url}
    consumer.logger = logging.getLogger("ash-smoke-schema")
    consumer._setup_database()

    if consumer.db_conn is None:
        print("could not create the ASH schema", file=sys.stderr)
        return 1

    consumer.db_conn.close()
    print("ASH schema ready")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
