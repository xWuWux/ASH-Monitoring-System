# Changelog

All notable changes to ASH are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Release notes are the contents of the matching version section. Keep the
`Unreleased` section current; a release moves those entries under a new
version heading instead of inventing notes after the fact.

## [Unreleased]

### Added

- _Nothing yet._

## [2.2.0] - 2026-11-04

### Added

- First semantic-version release of ASH.
- Bash agent with command capture, file-change monitoring, spooling, hash-chain
  integrity, and redaction of sensitive values.
- Kafka-to-PostgreSQL consumer with a read-only API, health endpoints, and
  structured JSON logs.
- Optional Prometheus, Grafana, Loki, and Alertmanager stack with fail-closed
  API metrics behind `ASH_METRICS_TOKEN`.
- W3C trace-context propagation and best-effort OTLP log export without
  requiring an OpenTelemetry runtime on monitored hosts.
- Shell, Python, integration, migration, Kafka end-to-end, contract,
  degradation, and log-leak test suites.
- Release metadata validation, a changelog, checksummed source archives, and a
  tag-driven GitHub Release workflow.

### Changed

- PostgreSQL is the authoritative durable store; the consumer commits offsets
  only after durable writes.
- CI is a staged pipeline with ShellCheck, shfmt, actionlint, yamllint,
  flake8, black, detect-secrets, OSV-Scanner, CodeQL, and BATS.

### Fixed

- Kafka consumer data-loss window and dead file-change/risk-score paths.
- Consumer no longer freezes when PostgreSQL becomes unresponsive.
- Agent hash-chain writes are serialized, and API input is validated.
- Unauthenticated read-only bypass on the token endpoint and unbounded login
  attempts are closed.

### Security

- Added a secrets baseline, dependency scanning, CodeQL, and a log-leak suite.
- Added rate limiting and removed hard-coded JWT defaults.
- Metrics endpoints are internal and require a token when enabled.

[Unreleased]: https://github.com/xWuWux/ASH-Monitoring-System/compare/v2.2.0...HEAD
[2.2.0]: https://github.com/xWuWux/ASH-Monitoring-System/releases/tag/v2.2.0
