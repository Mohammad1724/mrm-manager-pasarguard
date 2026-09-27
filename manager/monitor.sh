#!/bin/bash
# MRM Manager monitor.sh — Monitor & Alerts
# Telegram alerts for: panel down, CPU high, disk full, RAM high (cron-driven).

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export HOME="${HOME:-/root}"

# ─── Shared libraries ────────────────────────────────────────────────────────
MRM_DIR="${MRM_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)}"
[ -r "$MRM_DIR/utils.sh" ] || MRM_DIR="/opt/mrm-manager"
# shellcheck source=/dev/null
if [ -f "$MRM_DIR/utils.sh" ]; then source "$MRM_DIR/utils.sh"; fi
# shellcheck source=/dev/null
if ! declare -f ui_header >/dev/null 2>&1 && [ -f "$MRM_DIR/ui.sh" ]; then source "$MRM_DIR/ui.sh"; fi

BACKUP_DIR="/root/mrm-backups"
TG_CONFIG="/root/.mrm_telegram"
MONITOR_CONFIG="/opt/mrm-manager/monitor.conf"
MONITOR_LOG="/var/log/mrm-monitor.log"
MONITOR_STATE="/tmp/mrm-monitor-state"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

init_monitor_logging() {
    mkdir -p "$(dirname "$MONITOR_LOG")" 2>/dev/null
    touch "$MONITOR_LOG" 2>/dev/null
    chmod 600 "$MONITOR_LOG" 2>/dev/null || true
}

log_monitor() {
    local LEVEL=$1
    local MESSAGE=$2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$LEVEL] $MESSAGE" >> "$MONITOR_LOG"
    # Rotate log if >5MB
    if [ -f "$MONITOR_LOG" ] && [ "$(stat -c%s "$MONITOR_LOG" 2>/dev/null || echo 0)" -gt 5242880 ]; then
        mv "$MONITOR_LOG" "$MONITOR_LOG.1" 2>/dev/null
        touch "$MONITOR_LOG"
    fi
}

build_telegram_proxy_args() {
    local PROXY="$1"
    local PROXY_STR AUTH HOSTPORT
    if [[ "$PROXY" == socks5://* ]]; then
        PROXY_STR="${PROXY#socks5://}"
        if [[ "$PROXY_STR" == *"@"* ]]; then
            AUTH="${PROXY_STR%@*}"
            HOSTPORT="${PROXY_STR##*@}"
            printf '%s\n' "--socks5-hostname" "$HOSTPORT" "-U" "$AUTH"
        else
            printf '%s\n' "--socks5-hostname" "$PROXY_STR"
        fi
    elif [[ "$PROXY" == http://* || "$PROXY" == https://* ]]; then
        # FIX: http(s) proxies were silently ignored (same as MRM-074) — MRM-081
        printf '%s\n' "--proxy" "$PROXY"
    fi
}

send_telegram_alert() {
    local MESSAGE="$1"
    local TK CH PROXY RESULT
    local -a CURL_PROXY_ARGS=()
    if [ ! -f "$TG_CONFIG" ]; then return 1; fi
    # FIX: anchor keys so comments/similar keys can never shadow the real
    # values (same as MRM-072 in telegram.sh) — MRM-081
    TK=$(grep "^TG_TOKEN=" "$TG_CONFIG" 2>/dev/null | cut -d'=' -f2 | tr -d '"')
    CH=$(grep "^TG_CHAT=" "$TG_CONFIG" 2>/dev/null | cut -d'=' -f2 | tr -d '"')
    PROXY=$(grep "^TG_PROXY=" "$TG_CONFIG" 2>/dev/null | cut -d'=' -f2 | tr -d '"')
    mapfile -t CURL_PROXY_ARGS < <(build_telegram_proxy_args "$PROXY")
    if [ -z "$TK" ] || [ -z "$CH" ]; then return 1; fi

    RESULT=$(curl -4 -s -m 30 "${CURL_PROXY_ARGS[@]}" -X POST "https://api.telegram.org/bot$TK/sendMessage" \
        --data-urlencode "chat_id=$CH" \
        --data-urlencode "text=$MESSAGE" \
        --data-urlencode "parse_mode=Markdown" 2>&1)
    if ! echo "$RESULT" | grep -q '"ok":true'; then
        # FIX: Markdown parsing can fail on _ / * / [ in hostnames or process
        # output (Telegram 400 "can't parse entities") and the alert would be
        # lost — retry as plain text (MRM-082)
        RESULT=$(curl -4 -s -m 30 "${CURL_PROXY_ARGS[@]}" -X POST "https://api.telegram.org/bot$TK/sendMessage" \
            --data-urlencode "chat_id=$CH" \
            --data-urlencode "text=$MESSAGE" 2>&1)
    fi
    if echo "$RESULT" | grep -q '"ok":true'; then
        log_monitor "INFO" "Alert sent: $(echo "$MESSAGE" | head -1)"
        return 0
    else
        log_monitor "ERROR" "Failed to send alert: $RESULT"
        return 1
    fi
}

get_panel_status() {
    if [ -z "$PANEL_DIR" ]; then
        if declare -f detect_active_panel >/dev/null 2>&1; then detect_active_panel >/dev/null 2>&1; fi
    fi
    local COMPOSE_FILE
    if declare -f get_panel_compose_file >/dev/null 2>&1; then
        COMPOSE_FILE="$(get_panel_compose_file 2>/dev/null || true)"
    fi
    if [ -n "$COMPOSE_FILE" ]; then
        if docker compose -f "$COMPOSE_FILE" ps 2>/dev/null | grep -q "Up"; then
            echo "up"
        else
            echo "down"
        fi
    else
        # FIX: match the official pasarguard/panel image (MRM-080) — a loose
        # "grep -i pasarguard" counts pasarguard-node-1/exporter etc. as the
        # panel AND never fires the panel-down alert (same class as MRM-045)
        local PANEL_ID
        PANEL_ID="$(docker ps --format '{{.ID}}|{{.Image}}' 2>/dev/null | awk -F'|' '$2 ~ /^pasarguard\/panel(:|$)/ {print $1; exit}')"
        if [ -n "$PANEL_ID" ]; then
            echo "up"
        else
            echo "down"
        fi
    fi
}

get_disk_usage() {
    df / | awk 'NR==2{print $5}' | tr -d '%'
}

get_disk_free() {
    df -h / | awk 'NR==2{print $4}'
}

get_cpu_usage() {
    # Get CPU usage via top, fallback to loadavg
    local CPU
    CPU=$(top -bn1 2>/dev/null | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}' | cut -d'.' -f1)
    if [ -z "$CPU" ] || ! [[ "$CPU" =~ ^[0-9]+$ ]]; then
        # Fallback: use loadavg * 25 as rough estimate for 4-core
        local LOAD=$(cat /proc/loadavg 2>/dev/null | awk '{print $1}')
        CPU=$(awk "BEGIN {print int($LOAD*25)}" 2>/dev/null || echo 0)
    fi
    echo "${CPU:-0}"
}

get_ram_usage_percent() {
    free | awk 'NR==2{printf "%.0f", $3*100/$2 }'
}

get_ram_info() {
    free -h | awk 'NR==2{print $3"/"$2}'
}

should_alert() {
    local ALERT_TYPE="$1"
    # FIX: cooldown from monitor.conf (was hardcoded 3600) — MRM-079
    local COOLDOWN="${COOLDOWN_SECONDS:-3600}"
    local STATE_FILE="$MONITOR_STATE/$ALERT_TYPE"
    mkdir -p "$MONITOR_STATE"
    
    if [ -f "$STATE_FILE" ]; then
        local LAST=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
        local NOW=$(date +%s)
        local DIFF=$((NOW - LAST))
        if [ "$DIFF" -lt "$COOLDOWN" ]; then
            return 1  # Don't alert, cooldown
        fi
    fi
    # Update state
    date +%s > "$STATE_FILE"
    return 0
}

clear_alert_state() {
    local ALERT_TYPE="$1"
    rm -f "$MONITOR_STATE/$ALERT_TYPE" 2>/dev/null
}

# Which service this server is responsible for: panel | node | none.
# A node-only server must be judged by its node container, not by a panel
# that was never installed here (that used to raise a PANEL DOWN alert every run).
get_service_role() {
    if declare -f mrm_server_role >/dev/null 2>&1; then mrm_server_role; else echo panel; fi
}
get_node_status() {
    local COMPOSE_FILE=""
    if declare -f get_node_compose_file >/dev/null 2>&1; then
        COMPOSE_FILE="$(get_node_compose_file 2>/dev/null || true)"
    fi
    if [ -n "$COMPOSE_FILE" ]; then
        if docker compose -f "$COMPOSE_FILE" ps 2>/dev/null | grep -q "Up"; then echo "up"; else echo "down"; fi
    elif docker ps --format '{{.Image}}' 2>/dev/null | grep -qE '^pasarguard/node(:|$)'; then
        echo "up"
    else
        echo "down"
    fi
}
# Status of whichever service lives here (up | down | none)
get_service_status() {
    case "$(get_service_role)" in
        panel) get_panel_status ;;
        node)  get_node_status ;;
        *)     echo "none" ;;
    esac
}

check_and_alert() {
    local PANEL_STATUS DISK_USAGE CPU_USAGE RAM_PERCENT ROLE SERVICE_LABEL
    # FIX: monitor.conf used to be write-only — its values had NO effect.
    # Load it now so ENABLED / thresholds / cooldown actually apply (MRM-079)
    if [ -f "$MONITOR_CONFIG" ]; then
        # shellcheck source=/dev/null
        source "$MONITOR_CONFIG" 2>/dev/null
    fi
    if [ "${ENABLED:-true}" != "true" ]; then
        log_monitor "INFO" "Monitor disabled by config (ENABLED=false)"
        return 0
    fi
    local HOST=$(hostname)
    local IP=$(curl -4 -s --connect-timeout 5 icanhazip.com 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')

    ROLE=$(get_service_role)
    case "$ROLE" in
        panel) SERVICE_LABEL="Panel" ;;
        node)  SERVICE_LABEL="Node" ;;
        *)     SERVICE_LABEL="Service" ;;
    esac
    PANEL_STATUS=$(get_service_status)
    DISK_USAGE=$(get_disk_usage)
    CPU_USAGE=$(get_cpu_usage)
    RAM_PERCENT=$(get_ram_usage_percent)

    log_monitor "INFO" "Check - ${SERVICE_LABEL}:$PANEL_STATUS Disk:${DISK_USAGE}% CPU:${CPU_USAGE}% RAM:${RAM_PERCENT}%"

    # 1. Service down (the panel where it is installed, otherwise the node)
    if [ "${CHECK_PANEL_DOWN:-true}" = "true" ] && [ "$PANEL_STATUS" == "down" ]; then
        if should_alert "panel_down"; then
            local SVC_DIR SVC_COMPOSE
            if [ "$ROLE" = "node" ]; then SVC_DIR="$NODE_DIR"; SVC_COMPOSE="$(get_node_compose_file 2>/dev/null || true)"
            else SVC_DIR="$PANEL_DIR"; SVC_COMPOSE="$(get_panel_compose_file 2>/dev/null || true)"; fi
            local MSG="🚨 *MRM ALERT - ${SERVICE_LABEL^^} DOWN*
🖥 Host: $HOST
🌐 IP: $IP
📊 Status: ${SERVICE_LABEL} is DOWN!
⏰ Time: $(date '+%Y-%m-%d %H:%M:%S')
🔧 Action: Auto-restarting...

${SERVICE_LABEL} container is not running. MRM will try to restart."
            send_telegram_alert "$MSG"
            # Try auto-restart
            if [ -n "$SVC_DIR" ] && [ -d "$SVC_DIR" ] && [ -n "$SVC_COMPOSE" ]; then
                (cd "$SVC_DIR" && docker compose up -d) >/dev/null 2>&1
                log_monitor "INFO" "Attempted auto-restart of ${SERVICE_LABEL,,}"
                sleep 10
                if [ "$(get_service_status)" == "up" ]; then
                    send_telegram_alert "✅ *${SERVICE_LABEL^^} RECOVERED*
🖥 $HOST is UP again after auto-restart
⏰ $(date '+%Y-%m-%d %H:%M:%S')"
                    clear_alert_state "panel_down"
                fi
            fi
        fi
    else
        clear_alert_state "panel_down"
    fi

    # 2. Disk Full >85% warn, >90% critical (thresholds from monitor.conf)
    if [ "${CHECK_DISK:-true}" = "true" ] && [ "$DISK_USAGE" -ge "${DISK_THRESHOLD_CRITICAL:-90}" ] 2>/dev/null; then
        if should_alert "disk_critical"; then
            local FREE=$(get_disk_free)
            local MSG="🚨 *MRM ALERT - DISK CRITICAL*
🖥 Host: $HOST
💾 Disk Usage: ${DISK_USAGE}% - CRITICAL!
💾 Free: $FREE
⏰ $(date '+%Y-%m-%d %H:%M:%S')
🔧 Action Required: Clean up!

Commands:
• docker system prune -af
• rm /root/mrm-backups/*.tar.gz old
• journalctl --vacuum-time=7d"
            send_telegram_alert "$MSG"
        fi
    elif [ "${CHECK_DISK:-true}" = "true" ] && [ "$DISK_USAGE" -ge "${DISK_THRESHOLD_WARN:-85}" ] 2>/dev/null; then
        if should_alert "disk_warn"; then
            local FREE=$(get_disk_free)
            local MSG="⚠️ *MRM ALERT - DISK HIGH*
🖥 Host: $HOST
💾 Disk Usage: ${DISK_USAGE}% (Free: $FREE)
⏰ $(date '+%Y-%m-%d %H:%M:%S')
ℹ️ Warning - Consider cleaning up soon."
            send_telegram_alert "$MSG"
        fi
    else
        clear_alert_state "disk_critical"
        clear_alert_state "disk_warn"
    fi

    # 3. CPU >90% (threshold from monitor.conf)
    if [ "${CHECK_CPU:-true}" = "true" ] && [ "$CPU_USAGE" -ge "${CPU_THRESHOLD:-90}" ] 2>/dev/null; then
        if should_alert "cpu_high"; then
            local LOAD=$(cat /proc/loadavg 2>/dev/null | awk '{print $1" "$2" "$3}')
            local TOP_PROC=$(ps aux --sort=-%cpu 2>/dev/null | head -n 6 | tail -n 5)
            local MSG="🔥 *MRM ALERT - CPU HIGH*
🖥 Host: $HOST
🔥 CPU Usage: ${CPU_USAGE}%
📊 Load: $LOAD
⏰ $(date '+%Y-%m-%d %H:%M:%S')

Top processes:
\`$TOP_PROC\`"
            send_telegram_alert "$MSG"
        fi
    else
        clear_alert_state "cpu_high"
    fi

    # 4. RAM >90% (threshold from monitor.conf)
    if [ "${CHECK_RAM:-true}" = "true" ] && [ "$RAM_PERCENT" -ge "${RAM_THRESHOLD:-90}" ] 2>/dev/null; then
        if should_alert "ram_high"; then
            local RAM_INFO=$(get_ram_info)
            local MSG="🧠 *MRM ALERT - RAM HIGH*
🖥 Host: $HOST
🧠 RAM Usage: ${RAM_PERCENT}% ($RAM_INFO)
⏰ $(date '+%Y-%m-%d %H:%M:%S')
ℹ️ Check for memory leaks or high traffic."
            send_telegram_alert "$MSG"
        fi
    else
        clear_alert_state "ram_high"
    fi
}

setup_monitor_config() {
    if [ ! -f "$MONITOR_CONFIG" ]; then
        cat > "$MONITOR_CONFIG" << EOF
# MRM Manager monitor.conf — thresholds and switches for monitor.sh
ENABLED=true
CHECK_PANEL_DOWN=true
CHECK_DISK=true
DISK_THRESHOLD_WARN=85
DISK_THRESHOLD_CRITICAL=90
CHECK_CPU=true
CPU_THRESHOLD=90
CHECK_RAM=true
RAM_THRESHOLD=90
COOLDOWN_SECONDS=3600
EOF
        chmod 600 "$MONITOR_CONFIG"
    fi
}

setup_cron() {
    local c CURRENT
    ui_header "Monitor Schedule" "Checks: panel / node down · CPU · disk · RAM"
    if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH check"; then
        CURRENT=$(crontab -l | grep "$SCRIPT_PATH" | awk '{print $1" "$2" "$3" "$4" "$5}')
        ui_kv_state "Schedule" ok "Active" "$CURRENT"
    else
        ui_kv_state "Schedule" off "Not scheduled"
    fi
    echo ""
    ui_menu_title "Check interval"
    ui_menu_item 1 "Every 2 minutes" "recommended"
    ui_menu_item 2 "Every 5 minutes"
    ui_menu_item 3 "Every 10 minutes"
    ui_menu_item 4 "Every 30 minutes"
    ui_menu_item 5 "Disable the monitor"
    ui_menu_back "Cancel"
    ui_select c
    local CRON_TIME=""
    case $c in
        1) CRON_TIME="*/2 * * * *" ;;
        2) CRON_TIME="*/5 * * * *" ;;
        3) CRON_TIME="*/10 * * * *" ;;
        4) CRON_TIME="*/30 * * * *" ;;
        5) CRON_TIME="" ;;
        0) return ;;
        *) ui_invalid; return ;;
    esac
    # Build the new crontab in a temp file — works even when no crontab
    # exists yet (crontab -l fails there and the old pipe version could
    # abort under set -e / pipefail before writing the new line).
    local TMP_CRON
    TMP_CRON="$(mktemp)"
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | grep -v "mrm-monitor" > "$TMP_CRON" || true
    if [ -n "$CRON_TIME" ]; then
        echo "$CRON_TIME /bin/bash $SCRIPT_PATH check >> $MONITOR_LOG 2>&1" >> "$TMP_CRON"
    fi
    if crontab "$TMP_CRON"; then
        rm -f "$TMP_CRON"
        if [ -n "$CRON_TIME" ]; then
            ui_success "Monitor enabled — cron: $CRON_TIME"
            log_monitor "INFO" "Monitor cron scheduled: $CRON_TIME"
            setup_monitor_config
        else
            ui_success "Monitor disabled"
            log_monitor "INFO" "Monitor cron disabled"
        fi
    else
        rm -f "$TMP_CRON"
        ui_error "Failed to install the crontab"
        log_monitor "ERROR" "Failed to install crontab"
    fi
    pause
}

test_alerts() {
    ui_header "Test Telegram Alert"
    if [ ! -f "$TG_CONFIG" ]; then
        ui_error "Telegram is not configured"
        ui_note "Set it up first: Backup & Restore › Telegram bot"
        pause
        return
    fi
    ui_task "Sending a test alert"
    local HOST=$(hostname)
    local DISK=$(get_disk_usage)
    local CPU=$(get_cpu_usage)
    local RAM=$(get_ram_usage_percent)
    local ROLE SVC_LABEL PANEL
    ROLE=$(get_service_role); PANEL=$(get_service_status)
    case "$ROLE" in panel) SVC_LABEL="Panel" ;; node) SVC_LABEL="Node" ;; *) SVC_LABEL="Service" ;; esac
    local MSG="🧪 *MRM Monitor Test*
🖥 Host: $HOST
📊 ${SVC_LABEL}: $PANEL
💾 Disk: ${DISK}%
🔥 CPU: ${CPU}%
🧠 RAM: ${RAM}%
⏰ $(date '+%Y-%m-%d %H:%M:%S')
✅ Alert system is working!
Version: $(get_mrm_version 2>/dev/null || echo unknown)
"
    if send_telegram_alert "$MSG"; then
        ui_task_done ok "delivered"
    else
        ui_task_done bad "check the Telegram configuration"
    fi
    pause
}

view_logs() {
    ui_header "Monitor Logs" "$MONITOR_LOG"
    if [ -f "$MONITOR_LOG" ]; then
        ui_note "Last 50 lines"
        echo ""
        tail -n 50 "$MONITOR_LOG" | sed "s/^/${UI_PAD}/"
    else
        ui_warning "No log file yet"
    fi
    pause
}

clear_states() {
    rm -rf "$MONITOR_STATE" 2>/dev/null
    ui_success "Alert states cleared — the next check sends alerts immediately"
    pause
}

show_monitor_config() {
    ui_header "Monitor Configuration" "$MONITOR_CONFIG"
    if [ -f "$MONITOR_CONFIG" ]; then
        grep -v '^#' "$MONITOR_CONFIG" | grep '=' | while IFS='=' read -r K V; do ui_kv "$K" "$V"; done
    else
        ui_warning "No configuration file yet"
    fi
    echo ""
    ui_section "Alert cooldown states"
    if [ -d "$MONITOR_STATE" ] && [ -n "$(ls -A "$MONITOR_STATE" 2>/dev/null)" ]; then
        ls -lh "$MONITOR_STATE" 2>/dev/null | tail -n +2 | sed "s/^/${UI_PAD}/"
    else
        ui_note "none (no recent alerts)"
    fi
    pause
}

monitor_menu() {
    local opt
    init_monitor_logging
    setup_monitor_config 2>/dev/null || true
    while true; do
        ui_header "Monitor & Alerts" "Telegram alerts for the panel or node, CPU, disk and RAM"
        local PANEL_STATUS DISK_USAGE DISK_FREE CPU_USAGE RAM_PERCENT ROLE
        ROLE=$(get_service_role)
        PANEL_STATUS=$(get_service_status)
        DISK_USAGE=$(get_disk_usage)
        DISK_FREE=$(get_disk_free)
        CPU_USAGE=$(get_cpu_usage)
        RAM_PERCENT=$(get_ram_usage_percent)

        case "$ROLE" in
            panel) if [ "$PANEL_STATUS" = "up" ]; then ui_kv_state "Panel" ok "Running"; else ui_kv_state "Panel" bad "Down"; fi ;;
            node)  if [ "$PANEL_STATUS" = "up" ]; then ui_kv_state "Node" ok "Running" "node-only server"; else ui_kv_state "Node" bad "Down" "node-only server"; fi ;;
            *)     ui_kv_state "Service" off "No panel or node on this server" "only CPU, disk and RAM are monitored" ;;
        esac
        ui_kv "Resources" "Disk ${DISK_USAGE}% (${DISK_FREE} free) · CPU ${CPU_USAGE}% · RAM ${RAM_PERCENT}%"
        if [ -f "$TG_CONFIG" ]; then
            ui_kv_state "Telegram" ok "Configured"
        else
            ui_kv_state "Telegram" off "Not configured" "Backup & Restore › Telegram bot"
        fi
        if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH check"; then
            ui_kv_state "Schedule" ok "Active" "$(crontab -l 2>/dev/null | grep "$SCRIPT_PATH check" | awk '{print $1}' | head -1)"
        else
            ui_kv_state "Schedule" off "Not scheduled"
        fi
        echo ""
        ui_menu_item 1 "Monitor schedule" "every 2/5/10/30 min"
        ui_menu_item 2 "Send a test alert"
        ui_menu_item 3 "Run a check now"
        ui_menu_item 4 "View monitor logs"
        ui_menu_item 5 "Clear alert states" "reset cooldown"
        ui_menu_item 6 "View configuration"
        ui_menu_back
        ui_select opt
        case $opt in
            1) setup_cron ;;
            2) test_alerts ;;
            3)
                ui_header "Manual Check"
                ui_task "Running all checks"
                check_and_alert
                ui_task_done ok "see the monitor log for details"
                log_monitor "INFO" "Manual check executed"
                pause
                ;;
            4) view_logs ;;
            5) clear_states ;;
            6) show_monitor_config ;;
            0) return ;;
            *) ui_invalid ;;
        esac
    done
}

# Entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "$1" in
        check)
            init_monitor_logging
            check_and_alert
            ;;
        test)
            init_monitor_logging
            test_alerts
            ;;
        menu|*)
            init_monitor_logging
            monitor_menu
            ;;
    esac
fi
