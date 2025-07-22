#!/bin/bash
# ASH Consumer Installation Script

set -euo pipefail

# Create directories
mkdir -p /etc/ash /var/log/ash
chown ash:ash /var/log/ash

# Install Python dependencies
pip3 install kafka-python psycopg2-binary

# Install scripts
cp ash-consumer.py /usr/local/bin/
chmod 755 /usr/local/bin/ash-consumer.py

# Install configuration
if [ ! -f /etc/ash/consumer.conf ]; then
    cp ../../common/config/consumer.conf.example /etc/ash/consumer.conf
    chmod 640 /etc/ash/consumer.conf
fi

# Install systemd service
if [ -d /etc/systemd/system ]; then
    cp ../../../deployments/systemd/ash-consumer.service /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable ash-consumer
    echo "ASH consumer installed as systemd service"
fi

echo "ASH Consumer installed successfully"
echo "Start with: systemctl start ash-consumer"
echo "View logs: journalctl -u ash-consumer -f"
