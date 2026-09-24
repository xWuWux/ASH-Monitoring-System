#!/usr/bin/env python3
"""
ASH Alerting Engine — Rule-based threat detection with MITRE ATT&CK mapping.
Supports webhook (Slack/Discord), email, and custom integrations.
"""

import json
import logging
import os
import re
from datetime import datetime
from typing import Any, Dict, List, Optional

import requests

logger = logging.getLogger("ash-alerting")


class AlertRule:
    """A single alert rule with pattern matching and cooldown."""

    def __init__(
        self,
        name: str,
        pattern: str,
        severity: str,
        description: str,
        actions: List[str],
        mitre_id: Optional[str] = None,
        mitre_tactic: Optional[str] = None,
        cooldown_seconds: int = 300,
    ):
        self.name = name
        self.pattern = re.compile(pattern, re.IGNORECASE)
        self.severity = severity
        self.description = description
        self.actions = actions
        self.mitre_id = mitre_id
        self.mitre_tactic = mitre_tactic
        self.cooldown_seconds = cooldown_seconds
        self.last_triggered: Optional[datetime] = None
        self.trigger_count: int = 0

    def matches(self, event: Dict[str, Any]) -> bool:
        command = event.get("command", "")
        if not command:
            return False

        if self.last_triggered:
            elapsed = (datetime.now() - self.last_triggered).total_seconds()
            if elapsed < self.cooldown_seconds:
                return False

        return bool(self.pattern.search(command))


class ASHAlertEngine:
    """Alert engine that evaluates events against detection rules."""

    def __init__(self, config_path: str = "/etc/ash/alert_rules.json"):
        self.rules = self._load_rules(config_path)
        self.webhooks = self._load_webhooks(config_path)
        self.alert_log_path = "/var/log/ash/alerts.jsonl"

    def _load_rules(self, config_path: str) -> List[AlertRule]:
        default_rules = [
            AlertRule(
                name="Destructive File Operations",
                pattern=r"rm\s+(-rf?|-fr?)\s+(/|/etc|/var|/home|/root|/usr)",
                severity="critical",
                description="Potentially destructive rm command on critical directory",
                actions=["webhook", "log"],
                mitre_id="T1485",
                mitre_tactic="Impact",
            ),
            AlertRule(
                name="Reverse Shell Detection",
                pattern=r"(nc|ncat|netcat)\s.*(-l|-e|/dev/tcp|/dev/udp)|bash\s+-i\s+>&\s*/dev/tcp",
                severity="critical",
                description="Possible reverse shell detected",
                actions=["webhook", "log"],
                mitre_id="T1059.004",
                mitre_tactic="Execution",
            ),
            AlertRule(
                name="Download and Execute",
                pattern=r"(wget|curl)\s+[^\|]*\|\s*(sh|bash|python|perl)",
                severity="critical",
                description="Download and execute pattern — possible malware delivery",
                actions=["webhook", "log"],
                mitre_id="T1105",
                mitre_tactic="Command and Control",
            ),
            AlertRule(
                name="Credential File Access",
                pattern=r"(cat|less|more|head|tail|strings|xxd)\s+(/etc/shadow|/etc/passwd|.*\.pem|.*id_rsa)",
                severity="high",
                description="Reading sensitive credential or key files",
                actions=["webhook", "log"],
                mitre_id="T1552.001",
                mitre_tactic="Credential Access",
            ),
            AlertRule(
                name="Dangerous Permission Change",
                pattern=r"chmod\s+(777|666|000|[+]s|u\+s|4[0-9]{3})",
                severity="high",
                description="Dangerous permission modification (world-writable or SUID)",
                actions=["webhook", "log"],
                mitre_id="T1222.002",
                mitre_tactic="Defense Evasion",
            ),
            AlertRule(
                name="Privilege Escalation to Root",
                pattern=r"sudo\s+(su|bash|sh|zsh|fish)\s*$|sudo\s+su\s*-",
                severity="high",
                description="Privilege escalation to root shell",
                actions=["webhook", "log"],
                mitre_id="T1548.003",
                mitre_tactic="Privilege Escalation",
            ),
            AlertRule(
                name="SSH Key Manipulation",
                pattern=r"(cat|echo|tee|cp|mv|>>)\s.*authorized_keys",
                severity="high",
                description="SSH authorized_keys modification — possible persistence",
                actions=["webhook", "log"],
                mitre_id="T1098.004",
                mitre_tactic="Persistence",
            ),
            AlertRule(
                name="Cron Persistence",
                pattern=r"(crontab\s+-[elr]|echo\s.*>>\s*/etc/cron|/etc/cron\.d/)",
                severity="medium",
                description="Cron schedule modification — possible persistence",
                actions=["log"],
                mitre_id="T1053.003",
                mitre_tactic="Persistence",
            ),
            AlertRule(
                name="Monitoring Tool Disabled",
                pattern=r"(systemctl|service)\s+(stop|disable|mask)\s+(ash|auditd|rsyslog|syslog|fail2ban|apparmor|selinux)",
                severity="critical",
                description="Attempt to disable monitoring or security tool",
                actions=["webhook", "log"],
                mitre_id="T1562.001",
                mitre_tactic="Defense Evasion",
            ),
            AlertRule(
                name="Container Escape Attempt",
                pattern=r"(docker|kubectl)\s+(exec|run)\s+.*-(it|interactive)",
                severity="high",
                description="Interactive container session — possible lateral movement",
                actions=["webhook", "log"],
                mitre_id="T1610",
                mitre_tactic="Execution",
            ),
            AlertRule(
                name="History Tampering",
                pattern=r"(history\s+-c|unset\s+HISTFILE|export\s+HISTSIZE=0|>/.*\.bash_history|shred.*history)",
                severity="critical",
                description="Attempt to clear or tamper with command history",
                actions=["webhook", "log"],
                mitre_id="T1070.003",
                mitre_tactic="Defense Evasion",
            ),
            AlertRule(
                name="Kernel Module Loading",
                pattern=r"(insmod|modprobe|rmmod)\s+",
                severity="high",
                description="Kernel module manipulation",
                actions=["webhook", "log"],
                mitre_id="T1547.006",
                mitre_tactic="Persistence",
            ),
        ]

        # Load custom rules
        if os.path.exists(config_path):
            try:
                with open(config_path) as f:
                    custom = json.load(f)
                    for rule_def in custom.get("rules", []):
                        default_rules.append(
                            AlertRule(
                                name=rule_def["name"],
                                pattern=rule_def["pattern"],
                                severity=rule_def.get("severity", "medium"),
                                description=rule_def.get("description", ""),
                                actions=rule_def.get("actions", ["log"]),
                                mitre_id=rule_def.get("mitre", {}).get("technique"),
                                mitre_tactic=rule_def.get("mitre", {}).get("tactic"),
                                cooldown_seconds=rule_def.get("cooldown_seconds", 300),
                            )
                        )
            except Exception as e:
                logger.error(f"Error loading custom rules: {e}")

        return default_rules

    def _load_webhooks(self, config_path: str) -> List[str]:
        webhooks = []
        webhook_config = os.path.join(os.path.dirname(config_path), "webhooks.json")
        if os.path.exists(webhook_config):
            try:
                with open(webhook_config) as f:
                    data = json.load(f)
                    webhooks = data.get("webhook_urls", [])
            except Exception as e:
                logger.error(f"Error loading webhooks: {e}")
        return webhooks

    def check_event(self, event: Dict[str, Any]) -> List[AlertRule]:
        """Check an event against all rules, trigger actions for matches."""
        matched = []
        for rule in self.rules:
            if rule.matches(event):
                matched.append(rule)
                rule.last_triggered = datetime.now()
                rule.trigger_count += 1

                for action in rule.actions:
                    if action == "webhook":
                        self._send_webhook(rule, event)
                    elif action == "log":
                        self._log_alert(rule, event)

        return matched

    def _send_webhook(self, rule: AlertRule, event: Dict):
        """Send alert to configured webhook endpoints (Slack format)."""
        severity_colors = {
            "critical": "#FF0000",
            "high": "#FF6600",
            "medium": "#FFAA00",
            "low": "#00AAFF",
        }

        mitre_text = ""
        if rule.mitre_id:
            mitre_text = f" [{rule.mitre_id} - {rule.mitre_tactic}]"

        message = {
            "text": f"ASH Alert: {rule.name}{mitre_text}",
            "attachments": [
                {
                    "color": severity_colors.get(rule.severity, "#FFAA00"),
                    "fields": [
                        {
                            "title": "Severity",
                            "value": rule.severity.upper(),
                            "short": True,
                        },
                        {
                            "title": "Host",
                            "value": event.get("hostname", "unknown"),
                            "short": True,
                        },
                        {
                            "title": "User",
                            "value": event.get("user", "unknown"),
                            "short": True,
                        },
                        {
                            "title": "Time",
                            "value": event.get("timestamp", ""),
                            "short": True,
                        },
                        {
                            "title": "Command",
                            "value": f"`{event.get('command', '')[:200]}`",
                            "short": False,
                        },
                        {
                            "title": "Description",
                            "value": rule.description,
                            "short": False,
                        },
                    ],
                }
            ],
        }

        for webhook_url in self.webhooks:
            try:
                requests.post(webhook_url, json=message, timeout=5)
            except Exception as e:
                logger.error(f"Webhook delivery failed ({webhook_url}): {e}")

    def _log_alert(self, rule: AlertRule, event: Dict):
        """Write alert to structured log file."""
        alert_record = {
            "timestamp": datetime.utcnow().isoformat() + "Z",
            "rule_name": rule.name,
            "severity": rule.severity,
            "description": rule.description,
            "mitre_id": rule.mitre_id,
            "mitre_tactic": rule.mitre_tactic,
            "hostname": event.get("hostname", "unknown"),
            "user": event.get("user", "unknown"),
            "command": event.get("command", ""),
            "session_id": event.get("session_id", ""),
            "event_id": event.get("event_id", ""),
            "trigger_count": rule.trigger_count,
        }
        try:
            with open(self.alert_log_path, "a", encoding="utf-8") as f:
                f.write(json.dumps(alert_record) + "\n")
        except Exception as e:
            logger.error(f"Alert log write failed: {e}")
