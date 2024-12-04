#!/bin/bash

# Configure logging
readonly LOG_FILE="/var/log/daemon-manager.log"
readonly PID_DIR="/var/run"

# Create necessary directories
mkdir -p "${PID_DIR}" "${LOG_FILE%/*}"
touch "${LOG_FILE}"

exec 1> >(tee -a "${LOG_FILE}")
exec 2> >(tee -a "${LOG_FILE}" >&2)

# Timestamp function for logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Global variable to track if we should continue running
KEEP_RUNNING=true
SHUTDOWN_IN_PROGRESS=false

# Store main process PID
echo $$ > "${PID_DIR}/daemon-manager.pid"

# Function to stop all daemons gracefully
stop_daemons() {
    if [[ "${SHUTDOWN_IN_PROGRESS}" == "true" ]]; then
        return
    fi
    SHUTDOWN_IN_PROGRESS=true

    log "Stopping all daemons..."
    local -a pids=()

    # Read all PID files
    for name in "${!daemons[@]}"; do
        local pid_file="${PID_DIR}/${name}.pid"
        if [[ -f "${pid_file}" ]]; then
            local pid
            pid=$(<"${pid_file}")
            if is_process_running "${pid}"; then
                pids+=("${pid}")
                # Send SIGTERM to each process
                log "Sending SIGTERM to ${name} (PID: ${pid})"
                kill -TERM "${pid}" 2>/dev/null || true
            fi
            rm -f "${pid_file}"
        fi
    done

    # Wait for processes to stop gracefully (up to 30 seconds)
    local timeout=30
    while ((timeout > 0)) && ((${#pids[@]} > 0)); do
        sleep 1
        local -a remaining_pids=()
        for pid in "${pids[@]}"; do
            if is_process_running "${pid}"; then
                remaining_pids+=("${pid}")
            fi
        done
        if ((${#remaining_pids[@]} == 0)); then
            break
        fi
        pids=("${remaining_pids[@]}")
        ((timeout--))
    done

    # Force kill any remaining processes
    if ((${#pids[@]} > 0)); then
        log "Force killing remaining processes..."
        for pid in "${pids[@]}"; do
            if is_process_running "${pid}"; then
                log "Sending SIGKILL to PID: ${pid}"
                kill -KILL "${pid}" 2>/dev/null || true
            fi
        done
    fi

    rm -f "${PID_DIR}/daemon-manager.pid"
    log "All daemons stopped"
    exit 0
}

# Signal handler function
handle_signal() {
    local signal=$1
    log "Received signal: ${signal}"
    KEEP_RUNNING=false
    stop_daemons
}

# Function to check if a process is running
is_process_running() {
    local pid=$1
    [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null
}

# Function to start a daemon process
start_daemon() {
    local name=$1
    local command=$2
    local pid_file="${PID_DIR}/${name}.pid"

    log "Starting ${name}..."
    if [[ -f "${pid_file}" ]]; then
        local old_pid
        old_pid=$(<"${pid_file}")
        if is_process_running "${old_pid}"; then
            log "${name} is already running with PID ${old_pid}"
            return
        else
            rm -f "${pid_file}"
        fi
    fi

    # Start the process and store its PID
    eval "${command}" &
    local pid=$!
    echo "${pid}" > "${pid_file}"
    log "${name} started with PID ${pid}"
}

# Function to check and restart dead processes
check_and_restart() {
    local name=$1
    local command=$2
    local pid_file="${PID_DIR}/${name}.pid"

    if [[ -f "${pid_file}" ]]; then
        local pid
        pid=$(<"${pid_file}")
        if ! is_process_running "${pid}"; then
            log "WARNING: ${name} (PID ${pid}) died, restarting..."
            rm -f "${pid_file}"
            if [[ "$name" == "xray" ]]; then
                rm -f /app/sockets/*
            fi
            start_daemon "${name}" "${command}"
        fi
    else
        log "WARNING: ${name} not running, starting..."
        start_daemon "${name}" "${command}"
    fi
}

# Register signal handlers
trap 'handle_signal SIGTERM' SIGTERM
trap 'handle_signal SIGINT' SIGINT
trap 'handle_signal SIGHUP' SIGHUP

# Initialize system variables
readonly APP_NAME="${FLY_APP_NAME:-}"
if [[ -z "${APP_NAME}" ]]; then
    log "ERROR: FLY_APP_NAME is not set"
    exit 1
fi

# Get app IP and UDP bind address with timeout
APP_IP=$(timeout 5 dig +short "${APP_NAME}.fly.dev" 127.0.0.1 || echo "")
if [[ -z "${APP_IP}" ]]; then
    log "WARNING: Could not resolve ${APP_NAME}.fly.dev"
fi

UDP_BIND_ADDR=$(grep -m1 'fly-global-services' /etc/hosts | awk '{print $1}' || echo "")
if [[ -z "${UDP_BIND_ADDR}" ]]; then
    log "WARNING: Could not find fly-global-services in /etc/hosts"
fi

# Ensure required variables are set
declare -a REQUIRED_VARS=("UUID" "ParameterSSENCYPT" "sshPubKey" "hosts" "cloudflareIP")
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        log "ERROR: ${var} is not set"
        exit 1
    fi
done

# Create necessary directories with proper permissions
mkdir -p /root/.ssh
chmod 700 /root/.ssh

# Configure NGINX
if [[ ! -f "/app/config/nginx.conf.var" ]]; then
    log "ERROR: NGINX template file not found"
    exit 1
fi

# shellcheck disable=SC2154
sed -e "s|\$cloudflareIP|${cloudflareIP}|g" \
    "/app/config/nginx.conf.var" > "/app/config/nginx.conf" || {
        log "ERROR: Failed to configure NGINX"
        exit 1
    }

# Configure xray
log "Configuring xray..."
if [[ ! -f "/app/config/xray.json.var" ]]; then
    log "ERROR: xray template file not found"
    exit 1
fi

# shellcheck disable=SC2154
sed -e "s|\$UUID|${UUID}|g" \
    -e "s|\$ParameterSSENCYPT|${ParameterSSENCYPT}|g" \
    -e "s|\$appName|${APP_NAME}|g" \
    -e "s|\$appIP|${APP_IP}|g" \
    -e "s|\$udpBindAddr|${UDP_BIND_ADDR}|g" \
    "/app/config/xray.json.var" > "/app/config/xray.json" || {
        log "ERROR: Failed to configure xray"
        exit 1
    }

# Configure SSH with proper permissions
log "Configuring SSH..."
# shellcheck disable=SC2154
echo "${sshPubKey}" > /root/.ssh/authorized_keys
chmod 600 "/root/.ssh/authorized_keys"

# Define daemon processes
declare -A daemons=(
    ["sshd"]="/usr/sbin/sshd -D -e"
    ["tor"]="tor -f /app/config/torrc"
    ["xray"]="/app/xray/xray -config /app/config/xray.json"
    ["nginx"]="nginx -c /app/config/nginx.conf"
    ["frps"]="/app/frps -c /app/config/frps.toml"
)

# Check if required daemon binaries exist
for name in "${!daemons[@]}"; do
    cmd=${daemons[${name}]%% *}  # Extract command without arguments
    if ! command -v "${cmd}" &> /dev/null; then
        log "ERROR: ${cmd} not found"
        exit 1
    fi
done

# Start all daemons
for name in "${!daemons[@]}"; do
    start_daemon "${name}" "${daemons[${name}]}"
done

# Monitor and restart dead processes while handling signals
log "Starting daemon monitoring..."
while "${KEEP_RUNNING}"; do
    for name in "${!daemons[@]}"; do
        if [[ "${KEEP_RUNNING}" != "true" ]]; then
            break
        fi
        check_and_restart "${name}" "${daemons[${name}]}"
    done

    # Sleep in small intervals to be more responsive to signals
    for ((i=0; i<30 && "${KEEP_RUNNING}" == "true"; i++)); do
        sleep 1
    done
done

# If we get here, initiate graceful shutdown
stop_daemons
