#!/bin/bash
# ASH Monitoring System — Complete Installer v2.2
set -euo pipefail

VERSION="2.2.0"
INSTALL_DIR="/usr/local"
CONFIG_DIR="/etc/ash"
LOG_DIR="/var/log/ash"
SPOOL_DIR="/var/spool/ash"
TEMP_DIR="/tmp/ash"
SYSTEMD_DIR="/etc/systemd/system"
SHARE_DIR="/usr/local/share/ash"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
header(){ echo -e "\n${BLUE}━━━ $* ━━━${NC}"; }

check_root() {
    [[ $EUID -eq 0 ]] || error "This script must be run as root (use sudo)"
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        warn "Cannot detect OS — proceeding anyway"
        return
    fi
    source /etc/os-release
    info "Detected: $PRETTY_NAME"
}

check_dependencies() {
    local missing_required=()
    local missing_optional=()

    for cmd in bash coreutils; do
        command -v "$cmd" >/dev/null 2>&1 || missing_required+=("$cmd")
    done

    # Check for flock (part of util-linux)
    command -v flock >/dev/null 2>&1 || missing_required+=("util-linux (flock)")

    for cmd in jq inotifywait; do
        command -v "$cmd" >/dev/null 2>&1 || missing_optional+=("$cmd")
    done

    if [[ ${#missing_required[@]} -gt 0 ]]; then
        error "Missing required: ${missing_required[*]}"
    fi

    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        warn "Missing optional (recommended): ${missing_optional[*]}"
    fi
}

detect_package_manager() {
    if command -v apt-get >/dev/null; then echo "apt"
    elif command -v dnf >/dev/null; then echo "dnf"
    elif command -v yum >/dev/null; then echo "yum"
    elif command -v pacman >/dev/null; then echo "pacman"
    else echo "unknown"; fi
}

install_dependencies() {
    local pkg_mgr
    pkg_mgr=$(detect_package_manager)
    info "Installing dependencies via $pkg_mgr..."

    case "$pkg_mgr" in
        apt)
            apt-get update -qq
            apt-get install -y -qq jq inotify-tools uuid-runtime python3 python3-pip 2>/dev/null || true
            ;;
        dnf|yum)
            "$pkg_mgr" install -y jq inotify-tools util-linux python3 python3-pip 2>/dev/null || true
            ;;
        pacman)
            pacman -S --noconfirm jq inotify-tools python python-pip 2>/dev/null || true
            ;;
        *)
            warn "Unknown package manager — install jq, inotify-tools, python3 manually"
            ;;
    esac
}

create_user() {
    if ! getent passwd ash >/dev/null 2>&1; then
        useradd -r -s /bin/false -d /var/lib/ash -m ash
        info "Created system user: ash"
    else
        info "User 'ash' already exists"
    fi
}

create_directories() {
    mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$SPOOL_DIR" "$TEMP_DIR" \
             "$SPOOL_DIR/pending" "$SPOOL_DIR/sent" \
             "$SHARE_DIR/shells" "/var/archive/ash"

    chown root:ash "$LOG_DIR"
    chmod 750 "$LOG_DIR"
    chown ash:ash "$SPOOL_DIR" "$SPOOL_DIR/pending" "$SPOOL_DIR/sent"
    chmod 700 "$SPOOL_DIR"
    chmod 700 "$TEMP_DIR"
    chown ash:ash "/var/archive/ash"

    info "Directories created"
}

install_agent() {
    install -m 755 src/agent/ash-agent.sh "$INSTALL_DIR/bin/ash-agent"

    # Shell integrations
    install -m 644 src/agent/shells/zsh-integration.sh "$SHARE_DIR/shells/"
    install -m 644 src/agent/shells/fish-integration.fish "$SHARE_DIR/shells/"

    # auditd rules
    if [[ -d /etc/audit/rules.d ]]; then
        install -m 640 src/agent/auditd/ash.rules /etc/audit/rules.d/ash.rules
        info "auditd rules installed"
    fi

    info "Agent installed: $INSTALL_DIR/bin/ash-agent"
}

install_consumer() {
    # Install Python consumer
    install -m 755 src/consumer/ash-consumer.py "$INSTALL_DIR/bin/ash-consumer"
    install -m 755 src/consumer/api_server.py "$INSTALL_DIR/lib/ash/" 2>/dev/null || {
        mkdir -p "$INSTALL_DIR/lib/ash"
        install -m 755 src/consumer/api_server.py "$INSTALL_DIR/lib/ash/"
    }
    install -m 644 src/consumer/ash_alerting.py "$INSTALL_DIR/lib/ash/"

    # Python dependencies
    if command -v pip3 >/dev/null 2>&1; then
        pip3 install -q -r src/consumer/requirements.txt 2>/dev/null || \
            warn "pip install failed — install Python dependencies manually"
    fi

    info "Consumer installed: $INSTALL_DIR/bin/ash-consumer"
}

install_configs() {
    for conf in config/*.example; do
        local target="$CONFIG_DIR/$(basename "$conf" .example)"
        if [[ ! -f "$target" ]]; then
            install -m 640 -o root -g ash "$conf" "$target"
        else
            warn "Config exists, not overwriting: $target"
        fi
    done
    info "Configuration installed to $CONFIG_DIR"
}

install_services() {
    install -m 644 deployments/systemd/*.service "$SYSTEMD_DIR/"
    systemctl daemon-reload
    info "Systemd services installed"
}

generate_api_secrets() {
    # ash-api.service reads this via EnvironmentFile=. Generating a random
    # secret/password per install (instead of shipping the fixed
    # "change-me-in-production" / "admin"/"admin" defaults baked into
    # api_server.py) closes a straightforward JWT-forgery / default-
    # credential path for anyone who deploys without manually overriding
    # them.
    local secrets_file="$CONFIG_DIR/api.env"
    if [[ -f "$secrets_file" ]]; then
        info "API secrets already present, not regenerating: $secrets_file"
        return
    fi

    local jwt_secret admin_pass
    jwt_secret=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
    admin_pass=$(openssl rand -base64 24 2>/dev/null || head -c 24 /dev/urandom | base64)

    cat > "$secrets_file" << EOF
# Auto-generated by install.sh — do not commit.
# Rotating: delete this file and restart ash-api (existing JWTs signed
# with the old secret are invalidated immediately).
ASH_JWT_SECRET=${jwt_secret}
ASH_ADMIN_USER=admin
ASH_ADMIN_PASS=${admin_pass}
EOF
    chmod 600 "$secrets_file"
    chown root:root "$secrets_file"

    warn "Generated ASH API admin credentials (shown once — save them now):"
    warn "  Username: admin"
    warn "  Password: ${admin_pass}"
    warn "  Also stored in $secrets_file (root-only, mode 600)"
}

configure_shell_integration() {
    cat > /etc/profile.d/ash.sh << 'PROFILE'
# ASH (Again SHell) Monitoring Integration
if [[ -f /usr/local/bin/ash-agent ]] && [[ "${ASH_DISABLED:-}" != "true" ]]; then
    source /usr/local/bin/ash-agent
fi
PROFILE

    # Also add to /etc/bash.bashrc for non-login shells
    if ! grep -q 'ash-agent\|profile.d/ash.sh' /etc/bash.bashrc 2>/dev/null; then
        echo '[[ -f /etc/profile.d/ash.sh ]] && source /etc/profile.d/ash.sh' >> /etc/bash.bashrc
    fi

    info "Shell integration configured (/etc/profile.d/ash.sh)"
}

show_summary() {
    cat << SUMMARY

${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
${GREEN}  ASH Monitoring System v${VERSION} — Installation Complete${NC}
${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}

  Agent:     $INSTALL_DIR/bin/ash-agent
  Consumer:  $INSTALL_DIR/bin/ash-consumer
  API:       $INSTALL_DIR/lib/ash/api_server.py
  Config:    $CONFIG_DIR/
  Logs:      $LOG_DIR/
  Spool:     $SPOOL_DIR/

  ${BLUE}Next steps:${NC}
  1. Edit $CONFIG_DIR/ash.conf (set KAFKA_BROKER if using distributed mode)
  2. systemctl start ash-agent        (start monitoring)
  3. systemctl start ash-consumer     (start log processing, requires Kafka+PostgreSQL)
  4. systemctl start ash-api          (start REST API)

  ${BLUE}Quick test (local mode):${NC}
  source /usr/local/bin/ash-agent
  ls /tmp
  cat $LOG_DIR/events.jsonl | jq .

  ${BLUE}Disable for a session:${NC}
  export ASH_DISABLED=true

  ${BLUE}Uninstall:${NC}
  $0 --uninstall

${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
SUMMARY
}

do_install() {
    header "Checking environment"
    check_root
    check_os
    check_dependencies

    header "Installing dependencies"
    install_dependencies

    header "Creating user and directories"
    create_user
    create_directories

    header "Installing components"
    install_agent
    install_consumer
    install_configs
    install_services
    generate_api_secrets

    header "Configuring shell integration"
    configure_shell_integration

    show_summary
}

do_uninstall() {
    check_root
    header "Uninstalling ASH"

    systemctl stop ash-agent ash-consumer ash-api 2>/dev/null || true
    systemctl disable ash-agent ash-consumer ash-api 2>/dev/null || true

    rm -f "$SYSTEMD_DIR/ash-agent.service" "$SYSTEMD_DIR/ash-consumer.service" "$SYSTEMD_DIR/ash-api.service"
    rm -f "$INSTALL_DIR/bin/ash-agent" "$INSTALL_DIR/bin/ash-consumer"
    rm -rf "$INSTALL_DIR/lib/ash"
    rm -rf "$SHARE_DIR"
    rm -f /etc/profile.d/ash.sh
    rm -f /etc/audit/rules.d/ash.rules 2>/dev/null || true

    # Remove shell integration line from bash.bashrc
    sed -i '/ash-agent\|profile.d\/ash.sh/d' /etc/bash.bashrc 2>/dev/null || true

    rm -rf "$CONFIG_DIR" "$SPOOL_DIR" "$TEMP_DIR"
    systemctl daemon-reload

    warn "Log directory preserved: $LOG_DIR"
    warn "Archive preserved: /var/archive/ash"
    info "ASH uninstalled successfully"
}

do_upgrade() {
    check_root
    header "Upgrading ASH to v${VERSION}"

    # Backup config
    local backup_dir="${CONFIG_DIR}/backup_$(date +%Y%m%d_%H%M%S)"
    cp -r "$CONFIG_DIR" "$backup_dir"
    info "Config backed up to $backup_dir"

    # Stop services
    systemctl stop ash-agent ash-consumer ash-api 2>/dev/null || true

    # Reinstall binaries (configs preserved)
    install_agent
    install_consumer
    install_services

    # Restart
    systemctl start ash-agent 2>/dev/null || true
    systemctl start ash-consumer 2>/dev/null || true

    info "Upgrade complete. Restart services to apply."
}

# ─── Main ─────────────────────────────────────────────────────────────────────
case "${1:-install}" in
    install|--install)   do_install ;;
    uninstall|--uninstall) do_uninstall ;;
    upgrade|--upgrade)   do_upgrade ;;
    *)
        echo "Usage: $0 {install|uninstall|upgrade}"
        exit 1
        ;;
esac
