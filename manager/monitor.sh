#!/bin/bash

# ==========================================
# MRM MONITOR & ALERTS v1.0.0
# Telegram alerts for: Panel Down, CPU >90%, Disk Full, RAM High
# ==========================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export HOME="${HOME:-/root}"

if [ -f "/opt/mrm-manager/utils.sh" ]; then source /opt/mrm-manager/utils.sh; fi
if [ -f "/opt/mrm-manager/ui.sh" ]; then source /opt/mrm-manager/ui.sh; fi

BACKUP_DIR="/root/mrm-backups"
TG_CONFIG="/root/.mrm_telegram"
MONITOR_CONFIG="/opt/mrm-manager/monitor.conf"
MONITOR_LOG="/var/log/mrm-monitor.log"
MONITOR_STATE="/tmp/mrm-monitor-state"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

init_monitor_logging() {
    mkdir -p "$(dirname "$MONITOR_LOG")"
    touch "$MONITOR_LOG"
    chmod 600 "$MONITOR_LOG" 2>/dev/null || true
}

log_monitor() {
    local LEVEL=$1
    local MESSAGE=$2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$LEVEL] $MESSAGE" >> "$MONITOR_LOG"
    # Rotate log if >5MB
    if [ -f "$MONITOR_LOG" ] && [ $(stat -c%s "$MONITOR_LOG" 2>/dev/null || echo 0) -gt 5242880 ]; then
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

check_and_alert() {
    local PANEL_STATUS DISK_USAGE CPU_USAGE RAM_PERCENT
    local ALERTS=()
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

    PANEL_STATUS=$(get_panel_status)
    DISK_USAGE=$(get_disk_usage)
    CPU_USAGE=$(get_cpu_usage)
    RAM_PERCENT=$(get_ram_usage_percent)

    log_monitor "INFO" "Check - Panel:$PANEL_STATUS Disk:${DISK_USAGE}% CPU:${CPU_USAGE}% RAM:${RAM_PERCENT}%"

    # 1. Panel Down
    if [ "${CHECK_PANEL_DOWN:-true}" = "true" ] && [ "$PANEL_STATUS" == "down" ]; then
        if should_alert "panel_down"; then
            local MSG="🚨 *MRM ALERT - PANEL DOWN*
🖥 Host: $HOST
🌐 IP: $IP
📊 Status: Panel is DOWN!
⏰ Time: $(date '+%Y-%m-%d %H:%M:%S')
🔧 Action: Auto-restarting...

Panel container is not running. MRM will try to restart."
            send_telegram_alert "$MSG"
            # Try auto-restart
            if [ -n "$PANEL_DIR" ] && [ -d "$PANEL_DIR" ]; then
                local COMPOSE_FILE
                COMPOSE_FILE="$(get_panel_compose_file 2>/dev/null || true)"
                if [ -n "$COMPOSE_FILE" ]; then
                    (cd "$PANEL_DIR" && docker compose up -d) >/dev/null 2>&1
                    log_monitor "INFO" "Attempted auto-restart of panel"
                    sleep 10
                    if [ "$(get_panel_status)" == "up" ]; then
                        send_telegram_alert "✅ *PANEL RECOVERED*
🖥 $HOST is UP again after auto-restart
⏰ $(date '+%Y-%m-%d %H:%M:%S')"
                        clear_alert_state "panel_down"
                    fi
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
# MRM Monitor Config v1.0.0
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
    clear
    ui_header "MONITOR - TELEGRAM ALERTS v1.0.0"
    echo "Monitors: Panel Down, CPU>90%, Disk>85%, RAM>90%"
    echo ""
    echo "Current cron status:"
    if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH check"; then
        local CURRENT=$(crontab -l | grep "$SCRIPT_PATH")
        echo -e "${GREEN}Active:${NC} $CURRENT"
    else
        echo -e "${YELLOW}No monitor scheduled${NC}"
    fi
    echo ""
    echo "Select check interval:"
    echo "1) Every 2 minutes (Recommended)"
    echo "2) Every 5 minutes"
    echo "3) Every 10 minutes"
    echo "4) Every 30 minutes"
    echo "5) Disable monitor"
    echo "0) Cancel"
    echo ""
    read -p "Select: " c
    local CRON_TIME=""
    case $c in
        1) CRON_TIME="*/2 * * * *" ;;
        2) CRON_TIME="*/5 * * * *" ;;
        3) CRON_TIME="*/10 * * * *" ;;
        4) CRON_TIME="*/30 * * * *" ;;
        5) CRON_TIME="" ;;
        0) return ;;
        *) ui_error "Invalid selection"; pause; return ;;
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
            ui_success "Monitor enabled: $CRON_TIME - Checks every $(echo $CRON_TIME | cut -d' ' -f1)"
            log_monitor "INFO" "Monitor cron scheduled: $CRON_TIME"
            setup_monitor_config
        else
            ui_success "Monitor disabled"
            log_monitor "INFO" "Monitor cron disabled"
        fi
    else
        rm -f "$TMP_CRON"
        ui_error "Failed to install crontab"
        log_monitor "ERROR" "Failed to install crontab"
    fi
    pause
}

test_alerts() {
    clear
    ui_header "TEST TELEGRAM ALERTS"
    if [ ! -f "$TG_CONFIG" ]; then
        ui_error "Telegram not configured! Go to Backup & Restore -> Setup Telegram Bot first"
        pause
        return
    fi
    echo -e "${CYAN}Sending test alerts...${NC}"
    local HOST=$(hostname)
    local DISK=$(get_disk_usage)
    local CPU=$(get_cpu_usage)
    local RAM=$(get_ram_usage_percent)
    local PANEL=$(get_panel_status)
    local MSG="🧪 *MRM Monitor Test*
🖥 Host: $HOST
📊 Panel: $PANEL
💾 Disk: ${DISK}%
🔥 CPU: ${CPU}%
🧠 RAM: ${RAM}%
⏰ $(date '+%Y-%m-%d %H:%M:%S')
✅ Alert system is working!
Version: $(get_mrm_version 2>/dev/null || echo v1.1.19)
"
    if send_telegram_alert "$MSG"; then
        ui_success "Test alert sent to Telegram!"
    else
        ui_error "Failed to send test alert - Check Telegram config"
    fi
    pause
}

view_logs() {
    clear
    ui_header "MONITOR LOGS"
    if [ -f "$MONITOR_LOG" ]; then
        echo -e "${YELLOW}Last 50 lines:${NC}\n"
        tail -n 50 "$MONITOR_LOG"
    else
        ui_warning "No logs found at $MONITOR_LOG"
    fi
    pause
}

clear_states() {
    rm -rf "$MONITOR_STATE" 2>/dev/null
    ui_success "Alert states cleared - Next alerts will be sent immediately on next check"
    pause
}

monitor_menu() {
    init_monitor_logging
    setup_monitor_config 2>/dev/null || true
    while true; do
        clear
        ui_header "MONITOR & ALERTS v1.0.0"
        local PANEL_STATUS=$(get_panel_status)
        local DISK_USAGE=$(get_disk_usage)
        local DISK_FREE=$(get_disk_free)
        local CPU_USAGE=$(get_cpu_usage)
        local RAM_PERCENT=$(get_ram_usage_percent)
        local TG_STATUS="${RED}Not Configured${NC}"
        [ -f "$TG_CONFIG" ] && TG_STATUS="${GREEN}Configured${NC}"
        local CRON_STATUS="${RED}Disabled${NC}"
        crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH check" && CRON_STATUS="${GREEN}Active${NC}"

        echo -e "Panel: ${PANEL_STATUS} | Disk: ${DISK_USAGE}% (${DISK_FREE} free) | CPU: ${CPU_USAGE}% | RAM: ${RAM_PERCENT}%"
        echo -e "Telegram: $TG_STATUS | Monitor: $CRON_STATUS"
        if [ ! -f "$TG_CONFIG" ]; then
            echo -e "${YELLOW}Tip: configure Telegram in Backup & Restore -> Setup Telegram Bot${NC}"
        fi
        echo ""
        echo "1)  ⏰ Setup Monitor Schedule (Every 2/5/10/30 min)"
        echo "2)  🧪 Send Test Alert to Telegram"
        echo "3)  🔍 Run Check Now (Manual)"
        echo "4)  📋 View Monitor Logs"
        echo "5)  🧹 Clear Alert States (Reset cooldown)"
        echo "6)  📦 View Current Config"
        echo ""
        echo "0)  ↩️  Back"
        echo ""
        read -p "Select: " opt
        case $opt in
            1) setup_cron ;;
            2) test_alerts ;;
            3)
                echo -e "${BLUE}Running check now...${NC}"
                check_and_alert
                echo -e "${GREEN}Check completed - See logs${NC}"
                log_monitor "INFO" "Manual check executed"
                pause
                ;;
            4) view_logs ;;
            5) clear_states ;;
            6)
                clear
                ui_header "MONITOR CONFIG"
                cat "$MONITOR_CONFIG" 2>/dev/null || echo "No config found"
                echo ""
                echo "State dir: $MONITOR_STATE"
                ls -lh "$MONITOR_STATE" 2>/dev/null || echo "No states (no recent alerts)"
                pause
                ;;
            0) return ;;
            *) ui_error "Invalid option"; sleep 1 ;;
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
