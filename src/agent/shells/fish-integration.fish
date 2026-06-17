# ASH Fish Shell Integration
# Add to ~/.config/fish/conf.d/ash.fish

set -gx ASH_AGENT_PATH /usr/local/bin/ash-agent

function ash_preexec --on-event fish_preexec
    set -g ASH_LAST_COMMAND (commandline -b)
    set -g ASH_CMD_START (date +%s)
end

function ash_postexec --on-event fish_postexec
    set -l last_status $status
    set -l cmd $ASH_LAST_COMMAND

    if test -z "$cmd"
        return
    end

    # Write event to ASH log
    set -l timestamp (date -u +"%Y-%m-%dT%H:%M:%SZ")
    set -l hostname (hostname)
    set -l event_id (cat /proc/sys/kernel/random/uuid 2>/dev/null; or echo (date +%s%N))

    set -l event "{\"event_id\":\"$event_id\",\"schema_version\":\"1.0\",\"timestamp\":\"$timestamp\",\"hostname\":\"$hostname\",\"source\":\"fish-hook\",\"event_type\":\"command_end\",\"user\":\"$USER\",\"session_id\":\"$ASH_SESSION_ID\",\"pid\":\"$fish_pid\",\"command\":\"$cmd\",\"exit_code\":$last_status}"

    echo $event >> /var/log/ash/events.jsonl 2>/dev/null
end

# Initialize session
if not set -q ASH_SESSION_ID
    set -gx ASH_SESSION_ID (cat /proc/sys/kernel/random/uuid 2>/dev/null; or echo (date +%s%N))
end
