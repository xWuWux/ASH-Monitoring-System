# ASH (Again SHell) Monitoring System
## Complete Documentation & Deployment Guide

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Core Components](#core-components)
4. [Installation Methods](#installation-methods)
5. [Configuration](#configuration)
6. [Deployment Options](#deployment-options)
7. [Security Considerations](#security-considerations)
8. [Monitoring & Maintenance](#monitoring--maintenance)
9. [Troubleshooting](#troubleshooting)

---

## Overview

ASH (Again SHell) is a comprehensive shell monitoring system that captures every command executed in bash environments, tracks file modifications, and provides centralized logging across distributed systems. It combines multiple monitoring techniques to ensure complete visibility into system activity.

### Key Features

- **Complete Command Tracking**: Captures all bash commands with timestamps, output, and exit codes
- **File Change Detection**: Monitors file modifications using multiple methods (diff, inotify, background watchers)
- **Distributed Architecture**: Centralized logging from multiple servers using Kafka message queuing
- **Real-time Monitoring**: Event-driven file system monitoring with inotify
- **Flexible Deployment**: Systemd service, container, or package installation options

---

## Architecture

### Local Mode
```
bash shell → DEBUG trap → log_command() → file tracking → local log
```

### Distributed Mode
```
[Producer Servers] → [Kafka Message Queue] → [ASH Consumer] → [Centralized Storage]
```

### Components Overview

| Component | Purpose | Technology |
|-----------|---------|------------|
| **ASH Agent** | Command & file monitoring | Bash scripting, inotify |
| **Message Queue** | Reliable log transport | Apache Kafka |
| **Log Consumer** | Centralized log processing | Python, Flask |
| **Storage** | Log persistence | Files, PostgreSQL, Elasticsearch |

---

## Core Components

### 1. ASH Agent (ash-agent.sh)

The main monitoring script that runs on each target system.

```bash
#!/bin/bash
# ASH Agent - Complete Shell Monitoring System
# Version: 2.0

set -euo pipefail

# Configuration
ASH_CONFIG_DIR="${ASH_CONFIG_DIR:-/etc/ash}"
ASH_LOG_DIR="${ASH_LOG_DIR:-/var/log/ash}"
ASH_TEMP_DIR="${ASH_TEMP_DIR:-/tmp/ash}"
ASH_LOG_FILE="${ASH_LOG_DIR}/ash-$(hostname).log"

# Kafka configuration
KAFKA_ENABLED="${KAFKA_ENABLED:-false}"
KAFKA_BROKER="${KAFKA_BROKER:-localhost:9092}"
KAFKA_TOPIC="${KAFKA_TOPIC:-ash-logs}"

# Watched files for critical monitoring
WATCHED_FILES=(
    "/etc/passwd"
    "/etc/shadow"
    "/etc/ssh/sshd_config"
    "/etc/sudoers"
)

# Initialize directories
init_ash_environment() {
    mkdir -p "${ASH_CONFIG_DIR}" "${ASH_LOG_DIR}" "${ASH_TEMP_DIR}"
    chmod 700 "${ASH_TEMP_DIR}"
    
    # Create log file with proper permissions
    touch "${ASH_LOG_FILE}"
    chmod 640 "${ASH_LOG_FILE}"
    
    # Load configuration if exists
    [ -f "${ASH_CONFIG_DIR}/ash.conf" ] && source "${ASH_CONFIG_DIR}/ash.conf"
}

# Main command logging function
log_command() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local cmd="${BASH_COMMAND}"
    local server_ip=$(hostname -I | awk '{print $1}')
    local exit_code=0
    
    # Skip logging ASH's own commands
    [[ "${cmd}" =~ ^(log_command|track_file_changes|init_ash) ]] && return 0
    
    # Execute command and capture output
    local cmd_output
    cmd_output=$(eval "${cmd}" 2>&1) || exit_code=$?
    
    # Create log entry
    local log_entry="${timestamp} [${exit_code}] ${cmd}"
    local full_log="${log_entry}\nOUTPUT:\n${cmd_output}\n---"
    
    # Write to local log
    echo -e "${full_log}" >> "${ASH_LOG_FILE}"
    
    # Send to Kafka if enabled
    if [[ "${KAFKA_ENABLED}" == "true" ]]; then
        send_to_kafka "${server_ip}" "${cmd}" "${cmd_output}" "${exit_code}"
    fi
    
    # Track file changes
    track_file_changes "${cmd}"
}

# File change tracking function
track_file_changes() {
    local cmd="$1"
    local potential_files=()
    
    # Extract files from various command patterns
    extract_target_files "${cmd}" potential_files
    
    # Process each detected file
    for file_path in "${potential_files[@]}"; do
        [[ ! -f "${file_path}" ]] && continue
        [[ "${file_path}" == "${ASH_TEMP_DIR}"* ]] && continue
        
        local temp_file="${ASH_TEMP_DIR}/$(basename "${file_path}").before"
        
        # Create backup before command execution
        cp "${file_path}" "${temp_file}" 2>/dev/null || continue
        
        # Wait briefly for command completion
        sleep 0.5
        
        # Compare and log changes
        if [[ -f "${file_path}" ]]; then
            if ! diff -q "${temp_file}" "${file_path}" >/dev/null 2>&1; then
                log_file_change "${file_path}" "${temp_file}"
            fi
        else
            log_file_deletion "${file_path}" "${cmd}"
        fi
        
        # Cleanup
        rm -f "${temp_file}"
    done
}

# Extract target files from command patterns
extract_target_files() {
    local cmd="$1"
    local -n files_ref=$2
    
    # Text editors
    if [[ "${cmd}" =~ (vim|vi|nano|emacs|gedit|ed) ]]; then
        files_ref+=($(echo "${cmd}" | awk '{for(i=2;i<=NF;i++) if($i !~ /^-/) print $i}'))
    fi
    
    # Redirections
    if [[ "${cmd}" =~ (>|>>|2>|&>) ]]; then
        files_ref+=($(echo "${cmd}" | grep -oP '(?<=[>]{1,2}\s*)[^\s;|&]+'))
    fi
    
    # In-place editing
    if [[ "${cmd}" =~ (sed|perl).*\ -i ]]; then
        files_ref+=($(echo "${cmd}" | awk '{print $NF}'))
    fi
    
    # File manipulation commands
    if [[ "${cmd}" =~ ^(touch|cp|mv|rsync|dd|tee|truncate) ]]; then
        files_ref+=($(echo "${cmd}" | awk '{print $NF}'))
    fi
}

# Log file changes with diff
log_file_change() {
    local file_path="$1"
    local temp_file="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    {
        echo "${timestamp} FILE MODIFIED: ${file_path}"
        diff "${temp_file}" "${file_path}" 2>/dev/null || true
        echo "---"
    } >> "${ASH_LOG_FILE}"
}

# Log file deletion
log_file_deletion() {
    local file_path="$1"
    local cmd="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    echo "${timestamp} FILE DELETED: ${file_path} (by: ${cmd})" >> "${ASH_LOG_FILE}"
}

# Send logs to Kafka
send_to_kafka() {
    local server_ip="$1"
    local command="$2"
    local output="$3"
    local exit_code="$4"
    
    local json_payload=$(cat <<EOF
{
    "server_ip": "${server_ip}",
    "command": "${command}",
    "output": "${output}",
    "exit_code": ${exit_code},
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
)
    
    echo "${json_payload}" | kafka-console-producer.sh \
        --broker-list "${KAFKA_BROKER}" \
        --topic "${KAFKA_TOPIC}" 2>/dev/null || true
}

# Background file watcher using inotify
start_file_watcher() {
    local watched_files_str=$(printf "%s " "${WATCHED_FILES[@]}")
    
    inotifywait -m -e modify,create,delete,move ${watched_files_str} \
        --format '%w%f %e %T' --timefmt '%Y-%m-%d %H:%M:%S' 2>/dev/null | \
    while read file event timestamp; do
        echo "${timestamp} INOTIFY EVENT (${event}): ${file}" >> "${ASH_LOG_FILE}"
    done &
    
    echo $! > "${ASH_TEMP_DIR}/inotify.pid"
}

# Background diff monitoring for critical files
start_diff_monitor() {
    for file in "${WATCHED_FILES[@]}"; do
        [[ -f "${file}" ]] || continue
        
        (
            local snapshot="${ASH_TEMP_DIR}/$(basename "${file}").monitor"
            cp "${file}" "${snapshot}" 2>/dev/null || continue
            
            while true; do
                sleep 30
                [[ -f "${file}" ]] || continue
                
                if ! diff -q "${file}" "${snapshot}" >/dev/null 2>&1; then
                    log_file_change "${file}" "${snapshot}"
                    cp "${file}" "${snapshot}" 2>/dev/null || true
                fi
            done
        ) &
        
        echo $! >> "${ASH_TEMP_DIR}/monitor.pids"
    done
}

# Cleanup function
cleanup_ash() {
    # Kill background processes
    if [[ -f "${ASH_TEMP_DIR}/inotify.pid" ]]; then
        kill $(cat "${ASH_TEMP_DIR}/inotify.pid") 2>/dev/null || true
    fi
    
    if [[ -f "${ASH_TEMP_DIR}/monitor.pids" ]]; then
        while read pid; do
            kill "${pid}" 2>/dev/null || true
        done < "${ASH_TEMP_DIR}/monitor.pids"
    fi
    
    # Cleanup temp files
    rm -rf "${ASH_TEMP_DIR}"/*
}

# Signal handlers
trap cleanup_ash EXIT
trap cleanup_ash SIGTERM
trap cleanup_ash SIGINT

# Main initialization
main() {
    init_ash_environment
    
    # Start background monitors
    command -v inotifywait >/dev/null && start_file_watcher
    start_diff_monitor
    
    # Activate command trap
    trap 'log_command' DEBUG
    
    echo "ASH Agent started on $(hostname) at $(date)"
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

**Code Explanation:**

- **Environment Setup**: Creates necessary directories and loads configuration
- **Command Logging**: Captures every bash command with output and exit codes
- **File Tracking**: Monitors file changes through multiple methods
- **Kafka Integration**: Sends logs to message queue for distributed deployment
- **Background Monitoring**: Runs inotify and diff monitors for critical files
- **Signal Handling**: Proper cleanup on termination

### 2. Kafka Consumer (ash-consumer.py)

Centralized log processing service for distributed deployments.

```python
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
    
    def load_config(self, config_path: str) -> Dict[str, Any]:
        """Load configuration from file or use defaults"""
        default_config = {
            'kafka_brokers': ['localhost:9092'],
            'kafka_topic': 'ash-logs',
            'kafka_group_id': 'ash-consumer-group',
            'log_dir': '/var/log/ash',
            'database_enabled': False,
            'database_url': 'postgresql://ash:password@localhost/ash_logs',
            'log_level': 'INFO'
        }
        
        if os.path.exists(config_path):
            with open(config_path, 'r') as f:
                config = json.load(f)
                default_config.update(config)
        
        return default_config
    
    def setup_logging(self):
        """Configure logging"""
        log_level = getattr(logging, self.config['log_level'])
        logging.basicConfig(
            level=log_level,
            format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
            handlers=[
                logging.FileHandler('/var/log/ash/consumer.log'),
                logging.StreamHandler()
            ]
        )
        self.logger = logging.getLogger('ash-consumer')
    
    def setup_database(self):
        """Initialize PostgreSQL database connection"""
        try:
            self.db_conn = psycopg2.connect(self.config['database_url'])
            self.create_tables()
            self.logger.info("Database connection established")
        except Exception as e:
            self.logger.error(f"Database setup failed: {e}")
            self.db_conn = None
    
    def create_tables(self):
        """Create necessary database tables"""
        with self.db_conn.cursor() as cursor:
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS command_logs (
                    id SERIAL PRIMARY KEY,
                    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    server_ip VARCHAR(50) NOT NULL,
                    hostname VARCHAR(100),
                    command TEXT NOT NULL,
                    output TEXT,
                    exit_code INTEGER,
                    log_timestamp TIMESTAMP,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    INDEX(server_ip, log_timestamp),
                    INDEX(hostname, log_timestamp)
                );
                
                CREATE TABLE IF NOT EXISTS file_changes (
                    id SERIAL PRIMARY KEY,
                    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    server_ip VARCHAR(50) NOT NULL,
                    file_path TEXT NOT NULL,
                    change_type VARCHAR(20),
                    diff_content TEXT,
                    command TEXT,
                    INDEX(server_ip, timestamp),
                    INDEX(file_path, timestamp)
                );
            """)
            self.db_conn.commit()
    
    def setup_kafka_consumer(self):
        """Initialize Kafka consumer"""
        try:
            self.consumer = KafkaConsumer(
                self.config['kafka_topic'],
                bootstrap_servers=self.config['kafka_brokers'],
                group_id=self.config['kafka_group_id'],
                value_deserializer=lambda x: json.loads(x.decode('utf-8')),
                auto_offset_reset='latest',
                enable_auto_commit=True
            )
            self.logger.info("Kafka consumer initialized")
        except Exception as e:
            self.logger.error(f"Kafka setup failed: {e}")
            sys.exit(1)
    
    def process_log_message(self, log_data: Dict[str, Any]):
        """Process incoming log message"""
        try:
            # Extract message data
            server_ip = log_data.get('server_ip', 'unknown')
            hostname = log_data.get('hostname', server_ip)
            command = log_data.get('command', '')
            output = log_data.get('output', '')
            exit_code = log_data.get('exit_code', 0)
            log_timestamp = log_data.get('timestamp')
            
            # Parse timestamp
            if log_timestamp:
                timestamp = datetime.fromisoformat(log_timestamp.replace('Z', '+00:00'))
            else:
                timestamp = datetime.now()
            
            # Write to file
            self.write_file_log(server_ip, timestamp, command, output, exit_code)
            
            # Write to database if enabled
            if self.db_conn:
                self.write_database_log(server_ip, hostname, command, output, 
                                      exit_code, timestamp)
            
            self.logger.debug(f"Processed log from {server_ip}: {command[:50]}...")
            
        except Exception as e:
            self.logger.error(f"Error processing log message: {e}")
    
    def write_file_log(self, server_ip: str, timestamp: datetime, 
                      command: str, output: str, exit_code: int):
        """Write log to file"""
        log_file = self.log_dir / f"ash-history-{server_ip}.log"
        
        log_entry = (
            f"{timestamp.strftime('%Y-%m-%d %H:%M:%S')} [{exit_code}] {command}\n"
            f"OUTPUT:\n{output}\n"
            f"---\n"
        )
        
        with open(log_file, 'a', encoding='utf-8') as f:
            f.write(log_entry)
    
    def write_database_log(self, server_ip: str, hostname: str, command: str,
                          output: str, exit_code: int, timestamp: datetime):
        """Write log to database"""
        try:
            with self.db_conn.cursor() as cursor:
                cursor.execute("""
                    INSERT INTO command_logs 
                    (server_ip, hostname, command, output, exit_code, log_timestamp)
                    VALUES (%s, %s, %s, %s, %s, %s)
                """, (server_ip, hostname, command, output, exit_code, timestamp))
                self.db_conn.commit()
        except Exception as e:
            self.logger.error(f"Database write error: {e}")
            self.db_conn.rollback()
    
    def run(self):
        """Main consumer loop"""
        self.logger.info("ASH Consumer started")
        
        try:
            for message in self.consumer:
                if not self.running:
                    break
                
                self.process_log_message(message.value)
                
        except KeyboardInterrupt:
            self.logger.info("Consumer interrupted")
        except Exception as e:
            self.logger.error(f"Consumer error: {e}")
        finally:
            self.cleanup()
    
    def signal_handler(self, signum, frame):
        """Handle shutdown signals"""
        self.logger.info(f"Received signal {signum}, shutting down...")
        self.running = False
    
    def cleanup(self):
        """Cleanup resources"""
        if hasattr(self, 'consumer'):
            self.consumer.close()
        
        if self.db_conn:
            self.db_conn.close()
        
        self.logger.info("ASH Consumer stopped")

if __name__ == "__main__":
    consumer = ASHConsumer()
    consumer.run()
```

**Code Explanation:**

- **Configuration Management**: Loads settings from JSON config file
- **Kafka Integration**: Consumes messages from Kafka topic with proper error handling
- **Dual Storage**: Writes logs to both files and PostgreSQL database
- **Signal Handling**: Graceful shutdown on SIGTERM/SIGINT
- **Error Recovery**: Robust error handling with logging

---

## Installation Methods

### Method 1: Systemd Service

#### 1. Create systemd service files

```bash
# /etc/systemd/system/ash-agent.service
[Unit]
Description=ASH Shell Monitoring Agent
After=network.target
Wants=network.target

[Service]
Type=forking
User=ash
Group=ash
Environment=ASH_CONFIG_DIR=/etc/ash
Environment=ASH_LOG_DIR=/var/log/ash
ExecStartPre=/bin/mkdir -p /var/log/ash /tmp/ash
ExecStartPre=/bin/chown ash:ash /var/log/ash /tmp/ash
ExecStart=/usr/local/bin/ash-agent.sh
ExecStop=/bin/kill -TERM $MAINPID
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```bash
# /etc/systemd/system/ash-consumer.service
[Unit]
Description=ASH Kafka Consumer
After=network.target kafka.service
Wants=network.target
Requires=kafka.service

[Service]
Type=simple
User=ash
Group=ash
Environment=PYTHONPATH=/usr/local/lib/python3/dist-packages
ExecStart=/usr/local/bin/ash-consumer.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

#### 2. Installation script

```bash
#!/bin/bash
# install-ash-systemd.sh

set -euo pipefail

# Create ash user
useradd -r -s /bin/false ash || true

# Create directories
mkdir -p /etc/ash /var/log/ash /usr/local/bin
chown ash:ash /var/log/ash

# Install scripts
cp ash-agent.sh /usr/local/bin/
cp ash-consumer.py /usr/local/bin/
chmod +x /usr/local/bin/ash-agent.sh /usr/local/bin/ash-consumer.py

# Install systemd services
cp ash-agent.service /etc/systemd/system/
cp ash-consumer.service /etc/systemd/system/

# Reload systemd and enable services
systemctl daemon-reload
systemctl enable ash-agent
systemctl enable ash-consumer

echo "ASH installed as systemd service"
echo "Start with: systemctl start ash-agent"
```

### Method 2: Docker Container

#### 1. ASH Agent Dockerfile

```dockerfile
# Dockerfile.ash-agent
FROM ubuntu:22.04

# Install dependencies
RUN apt-get update && apt-get install -y \
    bash \
    inotify-tools \
    diffutils \
    curl \
    kafka-clients \
    && rm -rf /var/lib/apt/lists/*

# Create ash user
RUN useradd -r -u 1000 ash

# Create directories
RUN mkdir -p /etc/ash /var/log/ash /tmp/ash
RUN chown -R ash:ash /var/log/ash /tmp/ash

# Copy scripts
COPY ash-agent.sh /usr/local/bin/
COPY ash.conf /etc/ash/
RUN chmod +x /usr/local/bin/ash-agent.sh

# Switch to ash user
USER ash

# Start ash agent
CMD ["/usr/local/bin/ash-agent.sh"]
```

#### 2. ASH Consumer Dockerfile

```dockerfile
# Dockerfile.ash-consumer
FROM python:3.11-slim

# Install dependencies
RUN pip install kafka-python psycopg2-binary

# Create ash user
RUN useradd -r -u 1000 ash

# Create directories
RUN mkdir -p /etc/ash /var/log/ash
RUN chown -R ash:ash /var/log/ash

# Copy application
COPY ash-consumer.py /usr/local/bin/
COPY consumer.conf /etc/ash/
RUN chmod +x /usr/local/bin/ash-consumer.py

# Switch to ash user
USER ash

# Start consumer
CMD ["/usr/local/bin/ash-consumer.py"]
```

#### 3. Docker Compose

```yaml
# docker-compose.yml
version: '3.8'

services:
  zookeeper:
    image: confluentinc/cp-zookeeper:latest
    environment:
      ZOOKEEPER_CLIENT_PORT: 2181
      ZOOKEEPER_TICK_TIME: 2000

  kafka:
    image: confluentinc/cp-kafka:latest
    depends_on:
      - zookeeper
    ports:
      - "9092:9092"
    environment:
      KAFKA_BROKER_ID: 1
      KAFKA_ZOOKEEPER_CONNECT: zookeeper:2181
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://localhost:9092
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1

  postgres:
    image: postgres:15
    environment:
      POSTGRES_DB: ash_logs
      POSTGRES_USER: ash
      POSTGRES_PASSWORD: secure_password
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"

  ash-consumer:
    build:
      context: .
      dockerfile: Dockerfile.ash-consumer
    depends_on:
      - kafka
      - postgres
    volumes:
      - ./logs:/var/log/ash
      - ./config/consumer.conf:/etc/ash/consumer.conf
    restart: unless-stopped

  ash-agent:
    build:
      context: .
      dockerfile: Dockerfile.ash-agent
    volumes:
      - ./logs:/var/log/ash
      - ./config/ash.conf:/etc/ash/ash.conf
      - /var/run/docker.sock:/var/run/docker.sock
    privileged: true
    restart: unless-stopped

volumes:
  postgres_data:
```

### Method 3: Debian Package

#### 1. Package structure

```
ash-monitor_2.0-1/
├── DEBIAN/
│   ├── control
│   ├── postinst
│   ├── prerm
│   └── postrm
├── etc/
│   ├── ash/
│   │   ├── ash.conf
│   │   └── consumer.conf
│   └── systemd/system/
│       ├── ash-agent.service
│       └── ash-consumer.service
├── usr/
│   ├── local/bin/
│   │   ├── ash-agent.sh
│   │   └── ash-consumer.py
│   └── share/doc/ash-monitor/
│       ├── README.md
│       └── examples/
└── var/log/ash/
```

#### 2. Control file

```
# DEBIAN/control
Package: ash-monitor
Version: 2.0-1
Section: admin
Priority: optional
Architecture: all
Depends: bash (>= 4.0), inotify-tools, python3, python3-kafka, python3-psycopg2
Maintainer: Your Name <your.email@domain.com>
Description: ASH (Again SHell) Monitoring System
 Comprehensive shell command and file change monitoring system
 with distributed logging capabilities using Kafka message queuing.
```

#### 3. Post-installation script

```bash
#!/bin/bash
# DEBIAN/postinst

set -e

case "$1" in
    configure)
        # Create ash user
        if ! getent passwd ash > /dev/null; then
            useradd -r -s /bin/false ash
        fi
        
        # Set permissions
        chown -R ash:ash /var/log/ash /etc/ash
        chmod 750 /var/log/ash
        chmod 640 /etc/ash/*.conf
        
        # Reload systemd
        systemctl daemon-reload
        
        # Enable services
        systemctl enable ash-agent
        systemctl enable ash-consumer
        
        echo "ASH Monitor installed successfully"
        echo "Configure /etc/ash/ash.conf and start with: systemctl start ash-agent"
        ;;
esac

exit 0
```

#### 4. Build script

```bash
#!/bin/bash
# build-deb.sh

set -euo pipefail

PACKAGE_NAME="ash-monitor"
VERSION="2.0-1"
BUILD_DIR="build"

# Create build directory
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}/${PACKAGE_NAME}_${VERSION}"

# Copy package structure
cp -r debian-package/* "${BUILD_DIR}/${PACKAGE_NAME}_${VERSION}/"

# Copy source files
cp ash-agent.sh "${BUILD_DIR}/${PACKAGE_NAME}_${VERSION}/usr/local/bin/"
cp ash-consumer.py "${BUILD_DIR}/${PACKAGE_NAME}_${VERSION}/usr/local/bin/"

# Set permissions
chmod +x "${BUILD_DIR}/${PACKAGE_NAME}_${VERSION}/usr/local/bin/"*
chmod +x "${BUILD_DIR}/${PACKAGE_NAME}_${VERSION}/DEBIAN/"*

# Build package
cd "${BUILD_DIR}"
dpkg-deb --build "${PACKAGE_NAME}_${VERSION}"

echo "Package built: ${BUILD_DIR}/${PACKAGE_NAME}_${VERSION}.deb"
```

---

## Configuration

### ASH Agent Configuration (/etc/ash/ash.conf)

```bash
# ASH Agent Configuration

# Basic settings
ASH_LOG_DIR="/var/log/ash"
ASH_TEMP_DIR="/tmp/ash"

# Kafka settings (for distributed mode)
KAFKA_ENABLED=true
KAFKA_BROKER="kafka.example.com:9092"
KAFKA_TOPIC="ash-logs"

# File monitoring
WATCHED_FILES=(
    "/etc/passwd"
    "/etc/shadow"
    "/etc/ssh/sshd_config"
    "/etc/sudoers"
    "/etc/hosts"
    "/root/.ssh/authorized_keys"
)

# Monitoring intervals (seconds)
DIFF_MONITOR_INTERVAL=30
INOTIFY_ENABLED=true

# Log rotation
MAX_LOG_SIZE="100M"
LOG_RETENTION_DAYS=30

# Security
FILTER_PASSWORDS=true
EXCLUDE_COMMANDS=(
    "^ssh "
    "^mysql.*-p"
    "^sudo.*passwd"
)
```

### Consumer Configuration (/etc/ash/consumer.conf)

```json
{
    "kafka_brokers": ["kafka1.example.com:9092", "kafka2.example.com:9092"],
    "kafka_topic": "ash-logs",
    "kafka_group_id": "ash-consumer-group",
    "log_dir": "/var/log/ash",
    "database_enabled": true,
    "database_url": "postgresql://ash:secure_password@postgres.example.com/ash_logs",
    "log_level": "INFO",
    "batch_size": 100,
    "flush_interval": 5,
    "retention_days": 90
}
```

---

## Deployment Options

### Single Server Deployment

```bash
# Install and start ASH agent only
sudo dpkg -i ash-monitor_2.0-1.deb
sudo systemctl start ash-agent
sudo systemctl status ash-agent
```

### Distributed Deployment

#### Central Logging Server

```bash
# Install full package
sudo dpkg -i ash-monitor_2.0-1.deb

# Configure Kafka and PostgreSQL
sudo systemctl start kafka
sudo systemctl start postgresql

# Create Kafka topic
kafka-topics.sh --create --topic ash-logs \
    --bootstrap-server localhost:9092 \
    --partitions 6 --replication-factor 1

# Start consumer
sudo systemctl start ash-consumer
```

#### Client Servers

```bash
# Install agent only
sudo dpkg -i ash-monitor_2.0-1.deb

# Configure for central logging
sudo tee /etc/ash/ash.conf << EOF
KAFKA_ENABLED=true
KAFKA_BROKER="central.example.com:9092"
EOF

# Start agent
sudo systemctl start ash-agent
```

### Container Deployment

```bash
# Deploy full stack
docker-compose up -d

# Deploy agent only on monitored servers
docker run -d --name ash-agent \
    --privileged \
    -v /var/log/ash:/var/log/ash \
    -v /etc/ash:/etc/ash \
    ash-monitor:ash-agent
```

### Kubernetes Deployment

```yaml
# ash-agent-daemonset.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ash-agent
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: ash-agent
  template:
    metadata:
      labels:
        app: ash-agent
    spec:
      serviceAccountName: ash-agent
      hostPID: true
      hostNetwork: true
      containers:
      - name: ash-agent
        image: ash-monitor:ash-agent
        securityContext:
          privileged: true
        env:
        - name: KAFKA_BROKER
          value: "kafka.monitoring.svc.cluster.local:9092"
        - name: KAFKA_ENABLED
          value: "true"
        volumeMounts:
        - name: ash-logs
          mountPath: /var/log/ash
        - name: ash-config
          mountPath: /etc/ash
        - name: host-root
          mountPath: /host
          readOnly: true
      volumes:
      - name: ash-logs
        hostPath:
          path: /var/log/ash
      - name: ash-config
        configMap:
          name: ash-config
      - name: host-root
        hostPath:
          path: /
```

---

## Security Considerations

### Authentication and Encryption

#### TLS Configuration for Kafka

```bash
# Generate certificates
openssl req -new -x509 -keyout kafka-server-key.pem \
    -out kafka-server-cert.pem -days 365 -nodes

# Configure Kafka with TLS
cat >> /etc/kafka/server.properties << EOF
listeners=SSL://0.0.0.0:9093
ssl.keystore.location=/etc/kafka/ssl/kafka.server.keystore.jks
ssl.keystore.password=kafka-secret
ssl.key.password=kafka-secret
ssl.truststore.location=/etc/kafka/ssl/kafka.server.truststore.jks
ssl.truststore.password=kafka-secret
security.inter.broker.protocol=SSL
EOF
```

#### API Authentication

```python
# Enhanced consumer with JWT authentication
import jwt
from functools import wraps

class SecureASHConsumer(ASHConsumer):
    def __init__(self, config_path: str = "/etc/ash/consumer.conf"):
        super().__init__(config_path)
        self.jwt_secret = self.config.get('jwt_secret', 'default-secret')
        self.setup_api_server()
    
    def verify_token(self, f):
        @wraps(f)
        def decorated_function(*args, **kwargs):
            token = request.headers.get('Authorization')
            if not token:
                return {'error': 'No token provided'}, 401
            
            try:
                token = token.split(' ')[1]  # Remove 'Bearer '
                jwt.decode(token, self.jwt_secret, algorithms=['HS256'])
                return f(*args, **kwargs)
            except jwt.InvalidTokenError:
                return {'error': 'Invalid token'}, 401
        
        return decorated_function
    
    @verify_token
    def query_logs(self):
        """Protected endpoint for log queries"""
        pass
```

### Access Control

#### RBAC Configuration

```bash
# Create ASH service accounts with minimal permissions
sudo useradd -r -s /bin/false ash-agent
sudo useradd -r -s /bin/false ash-consumer

# Set file permissions
sudo chown ash-agent:ash-agent /var/log/ash
sudo chmod 750 /var/log/ash
sudo chmod 640 /etc/ash/*.conf

# SELinux policy (if enabled)
sudo setsebool -P domain_can_mmap_files 1
sudo semanage fcontext -a -t admin_home_t "/var/log/ash(/.*)?"
sudo restorecon -R /var/log/ash
```

#### Network Security

```bash
# Firewall rules for Kafka
sudo ufw allow from 10.0.0.0/8 to any port 9092
sudo ufw allow from 172.16.0.0/12 to any port 9092
sudo ufw deny 9092

# iptables rules
sudo iptables -A INPUT -p tcp --dport 9092 -s 10.0.0.0/8 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 9092 -j DROP
```

### Data Protection

#### Log Sanitization

```bash
# Enhanced log_command function with password filtering
log_command() {
    local cmd="${BASH_COMMAND}"
    
    # Filter sensitive commands
    for pattern in "${EXCLUDE_COMMANDS[@]}"; do
        if [[ "${cmd}" =~ ${pattern} ]]; then
            cmd="[FILTERED] ${cmd%% *}"
            break
        fi
    done
    
    # Remove password patterns
    if [[ "${FILTER_PASSWORDS}" == "true" ]]; then
        cmd=$(echo "${cmd}" | sed -E 's/(password|passwd|pwd)=[^[:space:]]*/\1=[REDACTED]/gi')
        cmd=$(echo "${cmd}" | sed -E 's/-p[[:space:]]*[^[:space:]]*/\ -p [REDACTED]/gi')
    fi
    
    # Continue with filtered command
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "${timestamp} [0] ${cmd}" >> "${ASH_LOG_FILE}"
}
```

#### Encryption at Rest

```bash
# Encrypt log files using LUKS
sudo cryptsetup luksFormat /dev/sdb1
sudo cryptsetup luksOpen /dev/sdb1 ash-logs
sudo mkfs.ext4 /dev/mapper/ash-logs
sudo mount /dev/mapper/ash-logs /var/log/ash

# Add to /etc/fstab
echo "/dev/mapper/ash-logs /var/log/ash ext4 defaults 0 2" >> /etc/fstab

# Configure automatic unlock
echo "ash-logs /dev/sdb1 /etc/luks/ash-key luks" >> /etc/crypttab
```

---

## Monitoring & Maintenance

### Health Checks

#### Agent Health Check Script

```bash
#!/bin/bash
# ash-health-check.sh

check_ash_agent() {
    local status=0
    
    # Check if agent is running
    if ! pgrep -f "ash-agent.sh" > /dev/null; then
        echo "ERROR: ASH agent not running"
        status=1
    fi
    
    # Check log file size
    local log_size=$(stat -c%s "${ASH_LOG_FILE}" 2>/dev/null || echo 0)
    if [[ ${log_size} -eq 0 ]]; then
        echo "WARNING: ASH log file is empty"
        status=1
    fi
    
    # Check disk space
    local disk_usage=$(df /var/log/ash | tail -1 | awk '{print $5}' | sed 's/%//')
    if [[ ${disk_usage} -gt 90 ]]; then
        echo "ERROR: Disk usage high: ${disk_usage}%"
        status=1
    fi
    
    # Check Kafka connectivity (if enabled)
    if [[ "${KAFKA_ENABLED}" == "true" ]]; then
        if ! kafka-broker-api-versions.sh --bootstrap-server "${KAFKA_BROKER}" > /dev/null 2>&1; then
            echo "ERROR: Cannot connect to Kafka broker"
            status=1
        fi
    fi
    
    if [[ ${status} -eq 0 ]]; then
        echo "OK: ASH agent healthy"
    fi
    
    return ${status}
}

check_ash_agent
```

#### Consumer Health Check

```python
#!/usr/bin/env python3
# ash-consumer-health.py

import json
import psutil
import requests
from kafka import KafkaConsumer
from kafka.errors import NoBrokersAvailable

def check_consumer_health():
    """Check ASH consumer health"""
    health_status = {
        'status': 'healthy',
        'checks': {}
    }
    
    # Check if consumer process is running
    consumer_running = any('ash-consumer.py' in p.cmdline() for p in psutil.process_iter(['cmdline']))
    health_status['checks']['process_running'] = consumer_running
    
    # Check Kafka connectivity
    try:
        consumer = KafkaConsumer(bootstrap_servers=['localhost:9092'])
        health_status['checks']['kafka_connection'] = True
        consumer.close()
    except NoBrokersAvailable:
        health_status['checks']['kafka_connection'] = False
        health_status['status'] = 'unhealthy'
    
    # Check database connectivity
    try:
        import psycopg2
        conn = psycopg2.connect("postgresql://ash:password@localhost/ash_logs")
        conn.close()
        health_status['checks']['database_connection'] = True
    except Exception:
        health_status['checks']['database_connection'] = False
        health_status['status'] = 'degraded'
    
    # Check disk space
    disk_usage = psutil.disk_usage('/var/log/ash')
    disk_percent = (disk_usage.used / disk_usage.total) * 100
    health_status['checks']['disk_usage'] = {
        'percent': disk_percent,
        'healthy': disk_percent < 90
    }
    
    if disk_percent > 90:
        health_status['status'] = 'unhealthy'
    
    return health_status

if __name__ == "__main__":
    health = check_consumer_health()
    print(json.dumps(health, indent=2))
    exit(0 if health['status'] == 'healthy' else 1)
```

### Log Rotation

#### Logrotate Configuration

```bash
# /etc/logrotate.d/ash
/var/log/ash/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 640 ash ash
    postrotate
        /bin/systemctl reload ash-agent > /dev/null 2>&1 || true
    endscript
}

/var/log/ash/consumer.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 640 ash ash
    postrotate
        /bin/systemctl reload ash-consumer > /dev/null 2>&1 || true
    endscript
}
```

### Performance Monitoring

#### Metrics Collection

```python
#!/usr/bin/env python3
# ash-metrics.py

import time
import json
import psutil
from kafka import KafkaConsumer
from kafka.structs import TopicPartition

class ASHMetrics:
    def __init__(self):
        self.consumer = KafkaConsumer(
            bootstrap_servers=['localhost:9092'],
            group_id='metrics-collector'
        )
    
    def collect_kafka_metrics(self):
        """Collect Kafka topic metrics"""
        topic = 'ash-logs'
        partitions = self.consumer.partitions_for_topic(topic)
        
        metrics = {
            'topic': topic,
            'partitions': len(partitions) if partitions else 0,
            'lag': 0,
            'throughput': 0
        }
        
        # Calculate consumer lag
        if partitions:
            topic_partitions = [TopicPartition(topic, p) for p in partitions]
            end_offsets = self.consumer.end_offsets(topic_partitions)
            committed = self.consumer.committed(*topic_partitions)
            
            total_lag = sum(end_offsets[tp] - (committed.get(tp) or 0) 
                           for tp in topic_partitions)
            metrics['lag'] = total_lag
        
        return metrics
    
    def collect_system_metrics(self):
        """Collect system performance metrics"""
        return {
            'cpu_percent': psutil.cpu_percent(interval=1),
            'memory': {
                'total': psutil.virtual_memory().total,
                'used': psutil.virtual_memory().used,
                'percent': psutil.virtual_memory().percent
            },
            'disk': {
                'total': psutil.disk_usage('/var/log/ash').total,
                'used': psutil.disk_usage('/var/log/ash').used,
                'percent': (psutil.disk_usage('/var/log/ash').used / 
                           psutil.disk_usage('/var/log/ash').total) * 100
            }
        }
    
    def collect_all_metrics(self):
        """Collect all metrics"""
        return {
            'timestamp': time.time(),
            'kafka': self.collect_kafka_metrics(),
            'system': self.collect_system_metrics()
        }

if __name__ == "__main__":
    metrics_collector = ASHMetrics()
    metrics = metrics_collector.collect_all_metrics()
    print(json.dumps(metrics, indent=2))
```

---

## Troubleshooting

### Common Issues

#### 1. Agent Not Logging Commands

**Symptoms**: No entries in log files, empty output
**Diagnosis**:
```bash
# Check if DEBUG trap is active
trap -p DEBUG

# Check process permissions
ps aux | grep ash-agent
ls -la /var/log/ash/

# Test manually
bash -x /usr/local/bin/ash-agent.sh
```

**Solutions**:
- Ensure user has write permissions to log directory
- Check if another trap is overriding DEBUG
- Verify bash version supports trap DEBUG

#### 2. Kafka Connection Issues

**Symptoms**: Consumer unable to connect, producer timeouts
**Diagnosis**:
```bash
# Test Kafka connectivity
kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic ash-logs

# Check Kafka logs
journalctl -u kafka -f

# Verify network connectivity
telnet kafka-broker 9092
```

**Solutions**:
- Check firewall rules
- Verify Kafka broker configuration
- Ensure topic exists and has correct permissions

#### 3. High Disk Usage

**Symptoms**: Logs consuming excessive disk space
**Diagnosis**:
```bash
# Check log file sizes
du -sh /var/log/ash/*

# Check for rotation issues
ls -la /var/log/ash/*.gz

# Monitor real-time growth
watch "du -sh /var/log/ash/"
```

**Solutions**:
- Configure more aggressive log rotation
- Implement log compression
- Add log retention policies

#### 4. Performance Issues

**Symptoms**: High CPU usage, slow command execution
**Diagnosis**:
```bash
# Profile ASH agent
strace -p $(pgrep ash-agent)

# Check resource usage
top -p $(pgrep ash-agent)

# Monitor file system activity
iotop
```

**Solutions**:
- Reduce diff monitoring frequency
- Exclude high-frequency directories
- Optimize file watching patterns

### Debug Mode

#### Enable Detailed Logging

```bash
# Add to ash-agent.sh
set -x  # Enable bash debug mode

# Enhanced logging function
debug_log() {
    local message="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "${timestamp} DEBUG: ${message}" >> "${ASH_LOG_DIR}/debug.log"
}

# Use throughout script
debug_log "Starting file monitoring for: ${file_path}"
```

#### Kafka Debug Consumer

```python
#!/usr/bin/env python3
# debug-consumer.py

import json
from kafka import KafkaConsumer

consumer = KafkaConsumer(
    'ash-logs',
    bootstrap_servers=['localhost:9092'],
    value_deserializer=lambda x: json.loads(x.decode('utf-8')),
    auto_offset_reset='earliest'  # Read from beginning
)

print("Debug consumer started...")
for message in consumer:
    log_data = message.value
    print(f"Received: {log_data.get('server_ip')} - {log_data.get('command')}")
```

### Recovery Procedures

#### Database Recovery

```sql
-- Backup current database
pg_dump ash_logs > ash_logs_backup.sql

-- Recreate tables if corrupted
DROP TABLE IF EXISTS command_logs, file_changes;

-- Restore from backup
psql ash_logs < ash_logs_backup.sql

-- Verify data integrity
SELECT COUNT(*) FROM command_logs;
SELECT COUNT(*) FROM file_changes;
```

#### Log File Recovery

```bash
#!/bin/bash
# recover-logs.sh

# Recover from corrupted log files
for log_file in /var/log/ash/*.log; do
    if [[ -f "${log_file}" ]]; then
        # Create backup
        cp "${log_file}" "${log_file}.backup"
        
        # Remove null bytes and control characters
        tr -d '\000' < "${log_file}.backup" > "${log_file}.clean"
        
        # Validate structure
        if grep -q "^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}" "${log_file}.clean"; then
            mv "${log_file}.clean" "${log_file}"
            echo "Recovered: ${log_file}"
        else
            echo "Recovery failed: ${log_file}"
        fi
    fi
done
```

---

## Advanced Features

### Custom Plugins

#### Plugin Architecture

```bash
# Plugin interface
ash_plugin_interface() {
    local event_type="$1"
    local data="$2"
    
    # Load all plugins
    for plugin in /etc/ash/plugins/*.sh; do
        [[ -f "${plugin}" ]] && source "${plugin}"
        
        # Call plugin function if exists
        local plugin_name=$(basename "${plugin}" .sh)
        local function_name="ash_plugin_${plugin_name}_${event_type}"
        
        if declare -F "${function_name}" > /dev/null; then
            "${function_name}" "${data}"
        fi
    done
}

# Example security plugin
ash_plugin_security_command() {
    local command="$1"
    
    # Check for suspicious commands
    local suspicious_patterns=(
        "wget.*\.sh"
        "curl.*|.*sh"
        "nc.*-l.*-p"
        "python.*-m.*http.server"
    )
    
    for pattern in "${suspicious_patterns[@]}"; do
        if [[ "${command}" =~ ${pattern} ]]; then
            alert_security_team "Suspicious command detected: ${command}"
            break
        fi
    done
}
```

### Real-time Alerting

#### Webhook Integration

```python
#!/usr/bin/env python3
# ash-alerting.py

import json
import requests
from kafka import KafkaConsumer

class ASHAlerting:
    def __init__(self):
        self.webhook_url = "https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
        self.alert_rules = [
            {
                'name': 'Suspicious Commands',
                'pattern': r'(wget|curl).*\.(sh|py),
                'severity': 'high'
            },
            {
                'name': 'Password Changes',
                'pattern': r'passwd\s+\w+',
                'severity': 'medium'
            },
            {
                'name': 'SSH Key Modifications',
                'file_pattern': r'authorized_keys,
                'severity': 'high'
            }
        ]
    
    def send_alert(self, alert_data):
        """Send alert to Slack"""
        message = {
            "text": f"🚨 ASH Alert: {alert_data['rule_name']}",
            "attachments": [
                {
                    "color": "danger" if alert_data['severity'] == 'high' else "warning",
                    "fields": [
                        {"title": "Server", "value": alert_data['server_ip'], "short": True},
                        {"title": "Command", "value": alert_data['command'], "short": False},
                        {"title": "Time", "value": alert_data['timestamp'], "short": True}
                    ]
                }
            ]
        }
        
        requests.post(self.webhook_url, json=message)
    
    def process_log_message(self, log_data):
        """Check log message against alert rules"""
        import re
        
        command = log_data.get('command', '')
        
        for rule in self.alert_rules:
            if 'pattern' in rule and re.search(rule['pattern'], command):
                alert_data = {
                    'rule_name': rule['name'],
                    'severity': rule['severity'],
                    'server_ip': log_data.get('server_ip'),
                    'command': command,
                    'timestamp': log_data.get('timestamp')
                }
                self.send_alert(alert_data)

# Usage in consumer
alerting = ASHAlerting()

for message in consumer:
    log_data = message.value
    alerting.process_log_message(log_data)
```

### Analytics Dashboard

#### Grafana Dashboard JSON

```json
{
  "dashboard": {
    "title": "ASH Monitoring Dashboard",
    "panels": [
      {
        "title": "Commands per Hour",
        "type": "graph",
        "targets": [
          {
            "expr": "rate(ash_commands_total[1h])",
            "legendFormat": "{{server_ip}}"
          }
        ]
      },
      {
        "title": "Top Commands",
        "type": "table",
        "targets": [
          {
            "expr": "topk(10, count by (command) (ash_commands_total))"
          }
        ]
      },
      {
        "title": "File Changes",
        "type": "stat",
        "targets": [
          {
            "expr": "increase(ash_file_changes_total[24h])"
          }
        ]
      }
    ]
  }
}
```

---

## Conclusion

The ASH (Again SHell) monitoring system provides comprehensive visibility into shell activity across distributed environments. With multiple deployment options (systemd, Docker, Debian package), robust security features, and scalable architecture using Kafka, ASH can be adapted to various organizational needs.

Key benefits:
- **Complete Visibility**: Tracks all shell commands and file modifications
- **Scalable Architecture**: Supports thousands of monitored servers
- **Flexible Deployment**: Multiple installation and deployment options
- **Security Focused**: Built-in filtering, encryption, and access controls
- **Extensible**: Plugin architecture for custom functionality

For production deployments, ensure proper security configuration, regular monitoring of system health, and appropriate log retention policies.