#!/bin/bash
# ASH Agent Installation Script

set -euo pipefail

# Create ash user if not exists
if ! id -u ash >/dev/null 2>&1; then
    useradd -r -s /bin/false ash
fi

# Create directories
mkdir -p /etc/ash /var/log/ash /usr/local/bin
chown ash:ash /var/log/ash

# Install scripts
cp ash-agent.sh /usr/local/bin/
chmod 755 /usr/local/bin/ash-agent.sh

# Install configuration
if [ ! -f /etc/ash/ash.conf ]; then
    cp ../../common/config/ash.conf.example /etc/ash/ash.conf
    chmod 640 /etc/ash/ash.conf
fi

# Install systemd service
if [ -d /etc/systemd/system ]; then
    cp ../../../deployments/systemd/ash-agent.service /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable ash-agent
    echo "ASH agent installed as systemd service"
fi

echo "ASH Agent installed successfully"
echo "Start with: systemctl start ash-agent"
echo "View logs: tail -f /var/log/ash/ash-$(hostname).log"
