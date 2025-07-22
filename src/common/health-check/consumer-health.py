#!/usr/bin/env python3
"""
ASH Consumer Health Check
"""

import json
import psutil
from kafka import KafkaConsumer
from kafka.errors import NoBrokersAvailable

def check_consumer_health():
    health = {
        "status": "healthy",
        "checks": {
            "process_running": False,
            "kafka_connection": False,
            "disk_usage": {"percent": 0, "status": "ok"}
        }
    }
    
    # Check if consumer process is running
    for proc in psutil.process_iter(['cmdline']):
        if 'ash-consumer.py' in ' '.join(proc.info['cmdline']):
            health['checks']['process_running'] = True
            break
    
    # Check Kafka connectivity
    try:
        consumer = KafkaConsumer(bootstrap_servers=['localhost:9092'])
        consumer.close()
        health['checks']['kafka_connection'] = True
    except NoBrokersAvailable:
        health['status'] = "unhealthy"
    
    # Check disk space
    disk_usage = psutil.disk_usage('/')
    health['checks']['disk_usage']['percent'] = disk_usage.percent
    if disk_usage.percent > 90:
        health['checks']['disk_usage']['status'] = "critical"
        health['status'] = "unhealthy"
    elif disk_usage.percent > 80:
        health['checks']['disk_usage']['status'] = "warning"
        health['status'] = "degraded"
    
    return health

if __name__ == "__main__":
    health = check_consumer_health()
    print(json.dumps(health, indent=2))
    exit(0 if health['status'] == 'healthy' else 1)
