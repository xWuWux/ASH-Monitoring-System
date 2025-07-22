
---

### Source Files
**File: `src/agent/ash-agent.sh`**
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

# [REST OF THE ORIGINAL ash-agent.sh CONTENT FROM YOUR DOCUMENT]
# [CONTINUE WITH THE FULL SCRIPT AS PROVIDED IN YOUR INITIAL REQUEST]
