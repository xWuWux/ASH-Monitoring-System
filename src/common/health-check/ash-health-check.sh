#!/bin/bash
# ASH Agent Health Check Script

check_ash_agent() {
    # Check if agent is running
    if ! pgrep -f "ash-agent.sh" >/dev/null; then
        echo "ERROR: ASH agent not running"
        return 1
    fi
    
    # Check log file size
    local log_file="/var/log/ash/ash-$(hostname).log"
    if [ ! -s "$log_file" ]; then
        echo "WARNING: ASH log file is empty"
        return 1
    fi
    
    # Check Kafka connectivity if enabled
    if grep -q "KAFKA_ENABLED=true" /etc/ash/ash.conf; then
        local broker=$(grep "KAFKA_BROKER" /etc/ash/ash.conf | cut -d= -f2 | tr -d '"')
        if ! kafkacat -b "$broker" -L >/dev/null; then
            echo "ERROR: Cannot connect to Kafka broker"
            return 1
        fi
    fi
    
    echo "OK: ASH agent healthy"
    return 0
}

check_ash_agent
