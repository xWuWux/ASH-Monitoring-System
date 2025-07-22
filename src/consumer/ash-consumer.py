#!/usr/bin/env python3
"""
ASH Kafka Consumer - Centralized Log Processing
Processes shell command logs from multiple servers via Kafka
"""

import json
import logging
import os
import signal
import sys
from datetime import datetime
from pathlib import Path
from typing import Dict, Any

from kafka import KafkaConsumer
import psycopg2
from psycopg2.extras import RealDictCursor

class ASHConsumer:
    def __init__(self, config_path: str = "/etc/ash/consumer.conf"):
        self.config = self.load_config(config_path)
        self.setup_logging()
        self.running = True
        
        # Initialize storage
        self.log_dir = Path(self.config.get('log_dir', '/var/log/ash'))
        self.log_dir.mkdir(parents=True, exist_ok=True)
        
        # Setup database if enabled
        self.db_conn = None
        if self.config.get('database_enabled', False):
            self.setup_database()
        
        # Setup Kafka consumer
        self.setup_kafka_consumer()
        
        # Signal handlers
        signal.signal(signal.SIGTERM, self.signal_handler)
        signal.signal(signal.SIGINT, self.signal_handler)
    
    # [REST OF THE ORIGINAL ash-consumer.py CONTENT FROM YOUR DOCUMENT]
    # [CONTINUE WITH THE FULL SCRIPT AS PROVIDED IN YOUR INITIAL REQUEST]
