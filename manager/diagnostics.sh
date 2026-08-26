#!/bin/bash

# ==========================================
# DIAGNOSTICS & DOCTOR v1.1.5
# Full system check: Docker, Disk, RAM, Logs, Panel, Node, Nginx
# ==========================================

# FIX #15: ui_section fallback (not defined in ui.sh)
if ! declare -f ui_section >/dev/null 2>&1; then
    ui_section() { echo -e "\n\033[0;36m══ $1 ══\033[0m"; }
fi

# FIX #3: Add ui_kv fallback if missing
if ! declare -f ui_kv >/dev/null 2>&1; then
    ui_kv() { printf "  \033[0;34m%-20s\033[0m %s\n" "$1:" "$2"; }
fi

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi
if ! declare -f ui_header >/dev/null 2>&1 && [ -r /opt/mrm-manager/ui.sh ]; then source /opt/mrm-manager/ui.sh; fi
if ! declare -f mrm_create_restore_point >/dev/null 2>&1 && [ -r /opt/mrm-manager/safe_ops.sh ]; then source /opt/mrm-manager/safe_ops.sh; fi

# Load monitor if available for health checks
if [ -r /opt/mrm-manager/monitor.sh ]; then source /opt/mrm-manager/monitor.sh 2>/dev/null || true; fi

mrm_panel_running() {
    local COMPOSE_FILE
    COMPOSE_FILE="$(get_panel_compose_file 2>/dev/null || true)"
    if [ -n "$COMPOSE_FILE" ]; then
        docker compose -f "$COMPOSE_FILE" ps 2>/dev/null | grep -q "Up"
    else
        docker ps --format '{{.Names}}' | grep -qiE "pasarguard"
    fi
}

mrm_node_running() {
    local COMPOSE_FILE
    COMPOSE_FILE="$(get_node_compose_file 2>/dev/null || true)"
    if [ -n "$COMPOSE_FILE" ]; then
        docker compose -f "$COMPOSE_FILE" ps 2>/dev/null | grep -q "Up"
    else
        docker ps --format '{{.Names}}' | grep -qiE "pg-node"
    fi
}

mrm_nginx_running() {
    systemctl is-active nginx >/dev/null 2>&1 || pgrep nginx >/dev/null 2>&1
}

mrm_theme_enabled() {
    [ -f "$PANEL_ENV" ] && grep -q "CUSTOM_TEMPLATES_DIRECTORY" "$PANEL_ENV" 2>/dev/null
}

mrm_domain_split_enabled() {
    [ -f "/etc/nginx/conf.d/panel_separate.conf" ]
}

mrm_telegram_enabled() {
    [ -n "${TG_CONFIG:-}" ] && [ -f "$TG_CONFIG" ]
}

mrm_ssl_cert_count() {
    if [ -d "/etc/letsencrypt/live" ]; then
        find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d ! -name README 2>/dev/null | wc -l
    else
        echo 0
    fi
}

mrm_ssl_status_text() {
    local CERT_COUNT
    CERT_COUNT="$(mrm_ssl_cert_count)"
    if [ "$CERT_COUNT" -gt 0 ] 2>/dev/null; then
        printf '%b' "${GREEN}Ready (${CERT_COUNT})${NC}"
    elif grep -qE "UVICORN_SSL_CERTFILE|SSL_CERT_FILE" "$PANEL_ENV" "$NODE_ENV" 2>/dev/null; then
        printf '%b' "${YELLOW}Custom Path${NC}"
    else
        printf '%b' "${RED}Inactive${NC}"
    fi
}

mrm_backup_dir() {
    printf '%s\n' "${BACKUP_DIR:-/root/mrm-backups}"
}

mrm_latest_backup_file() {
    local DIR
    DIR="$(mrm_backup_dir)"
    ls -1t "$DIR"/*.tar.gz 2>/dev/null | head -1
}

mrm_latest_backup_text() {
    local FILE
    FILE="$(mrm_latest_backup_file)"
    if [ -n "$FILE" ] && [ -f "$FILE" ]; then
        printf '%s\n' "$(basename "$FILE") ($(du -h "$FILE" | cut -f1))"
    else
        printf '%s\n' "No backup found"
    fi
}

mrm_colored_state() {
    local OK_TEXT="$1" BAD_TEXT="$2" MODE="$3"
    if [ "$MODE" = "ok" ]; then
        printf '%b' "${GREEN}● ${OK_TEXT}${NC}"
    elif [ "$MODE" = "warn" ]; then
        printf '%b' "${YELLOW}● ${OK_TEXT}${NC}"
    else
        printf '%b' "${RED}● ${BAD_TEXT}${NC}"
    fi
}

mrm_check_disk() {
    local USAGE=$(df / | awk 'NR==2{print $5}' | tr -d '%')
    local FREE=$(df -h / | awk 'NR==2{print $4}')
    echo "$USAGE $FREE"
}

mrm_check_ram() {
    free -m | awk 'NR==2{printf "%d %d %d", $3, $2, $3*100/$2 }'
}

mrm_check_cpu() {
    local CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 || echo 0)
    local LOAD=$(cat /proc/loadavg | awk '{print $1}')
    echo "$CPU $LOAD"
}

mrm_check_docker_health() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "not_installed"
        return
    fi
    if ! systemctl is-active docker >/dev/null 2>&1 && ! pgrep dockerd >/dev/null 2>&1; then
        echo "stopped"
        return
    fi
    local IMAGES=$(docker images --format '{{.Repository}}' 2>/dev/null | wc -l)
    local CONTAINERS=$(docker ps -q 2>/dev/null | wc -l)
    local DANGLING=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l)
    echo "ok $CONTAINERS $IMAGES $DANGLING"
}

mrm_check_panel_logs() {
    local COMPOSE_FILE="$1"
    local ERRORS=0
    if [ -n "$COMPOSE_FILE" ]; then
        ERRORS=$(docker compose -f "$COMPOSE_FILE" logs --tail 100 2>/dev/null | grep -iE "error|failed|exception|critical" | wc -l)
    else
        local CID=$(get_panel_container_id 2>/dev/null)
        if [ -n "$CID" ]; then
            ERRORS=$(docker logs "$CID" --tail 100 2>/dev/null | grep -iE "error|failed|exception|critical" | wc -l)
        fi
    fi
    echo "$ERRORS"
}

mrm_render_home_dashboard() {
    local ACTIVE_PANEL PANEL_STATUS NODE_STATUS NGINX_STATUS THEME_STATUS DOMAIN_STATUS TG_STATUS BACKUP_STATUS
    detect_active_panel > /dev/null
    ACTIVE_PANEL="$(cat "$CONFIG_FILE" 2>/dev/null || echo unknown)"
    if mrm_panel_running; then PANEL_STATUS="$(mrm_colored_state "Running" "Stopped" ok)"; else PANEL_STATUS="$(mrm_colored_state "Running" "Stopped" bad)"; fi
    if [ -n "$NODE_DIR" ] && [ -d "$NODE_DIR" ]; then
        if mrm_node_running; then NODE_STATUS="$(mrm_colored_state "Running" "Stopped" ok)"; else NODE_STATUS="$(mrm_colored_state "Expected" "Stopped" warn)"; fi
    else
        NODE_STATUS="$(mrm_colored_state "Optional" "Not Installed" warn)"
    fi
    if mrm_nginx_running; then NGINX_STATUS="$(mrm_colored_state "Running" "Stopped" ok)"; else NGINX_STATUS="$(mrm_colored_state "Running" "Stopped" bad)"; fi
    if mrm_theme_enabled; then THEME_STATUS="$(mrm_colored_state "Active" "Inactive" ok)"; else THEME_STATUS="$(mrm_colored_state "Active" "Inactive" bad)"; fi
    if mrm_domain_split_enabled; then DOMAIN_STATUS="$(mrm_colored_state "Configured" "Inactive" ok)"; else DOMAIN_STATUS="$(mrm_colored_state "Configured" "Inactive" bad)"; fi
    if mrm_telegram_enabled; then TG_STATUS="$(mrm_colored_state "Configured" "Not Configured" ok)"; else TG_STATUS="$(mrm_colored_state "Configured" "Not Configured" bad)"; fi
    if [ -n "$(mrm_latest_backup_file)" ]; then BACKUP_STATUS="$(mrm_colored_state "Ready" "Missing" ok)"; else BACKUP_STATUS="$(mrm_colored_state "Ready" "Missing" bad)"; fi

    ui_section "HOME DASHBOARD - $(get_mrm_version 2>/dev/null || echo v1.1.5)"
    ui_kv "Active Panel" "$ACTIVE_PANEL"
    ui_kv "Panel Directory" "${PANEL_DIR:-unknown}"
    echo -e "${UI_DIM:-}\033[2mServices:\033[0m${NC:-} Panel ${PANEL_STATUS} Node ${NODE_STATUS} Nginx ${NGINX_STATUS}"
    echo -e "${UI_DIM:-}\033[2mFeatures:\033[0m${NC:-} SSL $(mrm_ssl_status_text) Backup ${BACKUP_STATUS} Telegram ${TG_STATUS}"
    echo -e "${UI_DIM:-}\033[2mExtras:\033[0m${NC:-} Theme ${THEME_STATUS} Domain Split ${DOMAIN_STATUS}"
    ui_kv "Last Backup" "$(mrm_latest_backup_text)"
    if declare -f mrm_latest_restore_point_text >/dev/null 2>&1; then
        ui_kv "Last Restore Point" "$(mrm_latest_restore_point_text)"
    fi
    local DISK_INFO=$(mrm_check_disk)
    local DISK_USAGE=$(echo "$DISK_INFO" | awk '{print $1}')
    local DISK_FREE=$(echo "$DISK_INFO" | awk '{print $2}')
    local RAM_INFO=$(mrm_check_ram)
    local RAM_USED=$(echo "$RAM_INFO" | awk '{print $1}')
    local RAM_TOTAL=$(echo "$RAM_INFO" | awk '{print $2}')
    if [ "$DISK_USAGE" -gt 85 ] 2>/dev/null; then
        echo -e "${RED}⚠ Disk Usage: ${DISK_USAGE}% (Free: $DISK_FREE)${NC}"
    else
        echo -e "${CYAN}Disk: ${DISK_USAGE}% used, Free: $DISK_FREE | RAM: ${RAM_USED}MB/${RAM_TOTAL}MB${NC}"
    fi
    echo ""
}

diag_report_line() {
    local TYPE="$1" MESSAGE="$2"
    case "$TYPE" in
        ok) ui_success "$MESSAGE" ;;
        warn) ui_warning "$MESSAGE" ;;
        error) ui_error "$MESSAGE" ;;
        info) ui_info "$MESSAGE" ;;
    esac
}

run_full_diagnostics() {
    local PANEL_COMPOSE NODE_COMPOSE CERT_COUNT DISK_INFO DISK_USAGE DISK_FREE RAM_INFO RAM_USED RAM_TOTAL RAM_PERCENT CPU_INFO CPU_USED LOAD DOCKER_INFO
    clear
    detect_active_panel > /dev/null
    ui_header "DOCTOR - FULL SYSTEM DIAGNOSTICS v1.1.5"

    PANEL_COMPOSE="$(get_panel_compose_file 2>/dev/null || true)"
    NODE_COMPOSE="$(get_node_compose_file 2>/dev/null || true)"
    CERT_COUNT="$(mrm_ssl_cert_count)"
    DISK_INFO="$(mrm_check_disk)"
    DISK_USAGE="$(echo "$DISK_INFO" | awk '{print $1}')"
    DISK_FREE="$(echo "$DISK_INFO" | awk '{print $2}')"
    RAM_INFO="$(mrm_check_ram)"
    RAM_USED="$(echo "$RAM_INFO" | awk '{print $1}')"
    RAM_TOTAL="$(echo "$RAM_INFO" | awk '{print $2}')"
    RAM_PERCENT="$(echo "$RAM_INFO" | awk '{print $3}')"
    CPU_INFO="$(mrm_check_cpu)"
    CPU_USED="$(echo "$CPU_INFO" | awk '{print $1}')"
    LOAD="$(echo "$CPU_INFO" | awk '{print $2}')"
    DOCKER_INFO="$(mrm_check_docker_health)"

    ui_section "Panel Detection"
    [ -n "$PANEL_DIR" ] && diag_report_line ok "Active panel: $(cat "$CONFIG_FILE" 2>/dev/null || echo unknown)" || diag_report_line error "No active panel detected"
    [ -d "$PANEL_DIR" ] && diag_report_line ok "Panel directory exists: $PANEL_DIR" || diag_report_line error "Panel directory missing: ${PANEL_DIR:-unknown}"
    [ -f "$PANEL_ENV" ] && diag_report_line ok "Panel .env found: $PANEL_ENV" || diag_report_line warn "Panel .env missing: ${PANEL_ENV:-unknown}"
    [ -n "$PANEL_COMPOSE" ] && diag_report_line ok "Panel compose file found: $(basename "$PANEL_COMPOSE")" || diag_report_line warn "Panel compose file not found"
    echo ""

    ui_section "Node Detection"
    if [ -d "$NODE_DIR" ]; then
        diag_report_line ok "Node directory exists: $NODE_DIR"
        [ -f "$NODE_ENV" ] && diag_report_line ok "Node .env found: $NODE_ENV" || diag_report_line warn "Node .env missing: ${NODE_ENV:-unknown}"
        [ -n "$NODE_COMPOSE" ] && diag_report_line ok "Node compose file found" || diag_report_line warn "Node compose file not found"
    else
        diag_report_line info "Node directory not found: ${NODE_DIR:-unknown} (Optional)"
    fi
    echo ""

    ui_section "Service Health"
    if mrm_panel_running; then diag_report_line ok "Panel containers are running"; else diag_report_line error "Panel containers are STOPPED - Panel DOWN!"; fi
    if [ -d "$NODE_DIR" ]; then
        if mrm_node_running; then diag_report_line ok "Node containers are running"; else diag_report_line warn "Node containers stopped"; fi
    fi
    if mrm_nginx_running; then diag_report_line ok "Nginx is running"; else diag_report_line warn "Nginx is not running"; fi
    if command -v docker >/dev/null 2>&1; then diag_report_line ok "Docker is installed"; else diag_report_line error "Docker is not installed"; fi
    case "$DOCKER_INFO" in
        not_installed) diag_report_line error "Docker not installed" ;;
        stopped) diag_report_line error "Docker daemon is stopped" ;;
        ok*)
            local CONTAINERS=$(echo "$DOCKER_INFO" | awk '{print $2}')
            local IMAGES=$(echo "$DOCKER_INFO" | awk '{print $3}')
            local DANGLING=$(echo "$DOCKER_INFO" | awk '{print $4}')
            diag_report_line ok "Docker: $CONTAINERS containers, $IMAGES images"
            [ "$DANGLING" -gt 5 ] 2>/dev/null && diag_report_line warn "Dangling images: $DANGLING (run docker system prune)" ;;
    esac
    echo ""

    ui_section "System Resources"
    if [ "$DISK_USAGE" -gt 90 ] 2>/dev/null; then
        diag_report_line error "Disk usage CRITICAL: ${DISK_USAGE}% - Free: $DISK_FREE - ACTION REQUIRED!"
    elif [ "$DISK_USAGE" -gt 80 ] 2>/dev/null; then
        diag_report_line warn "Disk usage HIGH: ${DISK_USAGE}% - Free: $DISK_FREE"
    else
        diag_report_line ok "Disk usage: ${DISK_USAGE}% - Free: $DISK_FREE"
    fi
    if [ "${RAM_PERCENT%.*}" -gt 90 ] 2>/dev/null; then
        diag_report_line error "RAM usage HIGH: ${RAM_USED}MB/${RAM_TOTAL}MB (${RAM_PERCENT}%)"
    elif [ "${RAM_PERCENT%.*}" -gt 80 ] 2>/dev/null; then
        diag_report_line warn "RAM usage: ${RAM_USED}MB/${RAM_TOTAL}MB (${RAM_PERCENT}%)"
    else
        diag_report_line ok "RAM usage: ${RAM_USED}MB/${RAM_TOTAL}MB (${RAM_PERCENT}%)"
    fi
    diag_report_line info "CPU Load: $LOAD | CPU Used: ${CPU_USED}% (approx)"
    if dmesg --ctime 2>/dev/null | tail -n 20 | grep -qi "out of memory"; then
        diag_report_line warn "Kernel OOM detected in dmesg - Check RAM"
    fi
    echo ""

    ui_section "Panel Logs - Error Check (last 100 lines)"
    local LOG_ERRORS=$(mrm_check_panel_logs "$PANEL_COMPOSE")
    if [ "$LOG_ERRORS" -gt 10 ] 2>/dev/null; then
        diag_report_line error "Found $LOG_ERRORS errors in panel logs (last 100 lines)"
        echo -e "${YELLOW}--- Last errors ---${NC}"
        if [ -n "$PANEL_COMPOSE" ]; then
            docker compose -f "$PANEL_COMPOSE" logs --tail 100 2>/dev/null | grep -iE "error|failed|exception|critical" | tail -n 5
        else
            local CID=$(get_panel_container_id 2>/dev/null)
            [ -n "$CID" ] && docker logs "$CID" --tail 100 2>/dev/null | grep -iE "error|failed|exception|critical" | tail -n 5
        fi
        echo ""
    elif [ "$LOG_ERRORS" -gt 0 ] 2>/dev/null; then
        diag_report_line warn "Found $LOG_ERRORS warnings/errors in logs"
    else
        diag_report_line ok "No critical errors in last 100 log lines"
    fi
    if [ ! -f "$PANEL_ENV" ]; then
        diag_report_line error "Panel .env missing - panel cannot start"
    fi
    if [ -n "$PANEL_COMPOSE" ] && ! docker compose -f "$PANEL_COMPOSE" config >/dev/null 2>&1; then
        diag_report_line error "docker-compose config invalid - check $PANEL_COMPOSE"
    fi
    echo ""

    ui_section "Feature Health"
    [ "$CERT_COUNT" -gt 0 ] 2>/dev/null && diag_report_line ok "SSL certificates detected: $CERT_COUNT" || diag_report_line warn "No Let's Encrypt certificates found"
    mrm_theme_enabled && diag_report_line ok "Theme is active" || diag_report_line info "Theme is inactive"
    mrm_domain_split_enabled && diag_report_line ok "Domain separation config detected" || diag_report_line info "Domain separation is inactive"
    mrm_telegram_enabled && diag_report_line ok "Telegram backup is configured" || diag_report_line info "Telegram backup is not configured"
    [ -n "$(mrm_latest_backup_file)" ] && diag_report_line ok "Latest backup: $(mrm_latest_backup_text)" || diag_report_line warn "No backups found in $(mrm_backup_dir)"
    echo ""

    ui_section "Nginx & Network"
    if nginx -t >/dev/null 2>&1; then
        diag_report_line ok "Nginx configuration test passed"
    else
        diag_report_line error "Nginx configuration test FAILED"
        nginx -t 2>&1 | head -n 10
    fi
    for PORT in 443 80 2096 7431 8000; do
        if ss -tln 2>/dev/null | grep -q ":$PORT "; then
            diag_report_line info "Port $PORT is listening"
        fi
    done
    echo ""

    ui_section "Recommendations"
    [ "$DISK_USAGE" -gt 80 ] 2>/dev/null && diag_report_line warn "Clean up: docker system prune, rm old backups in /root/mrm-backups"
    [ "$LOG_ERRORS" -gt 5 ] 2>/dev/null && diag_report_line warn "Check panel logs: docker compose logs -f"
    ! mrm_panel_running && diag_report_line error "ACTION: Panel is DOWN - Run: cd $PANEL_DIR && docker compose up -d"
    ! mrm_nginx_running && [ -f "/etc/nginx/conf.d/panel_separate.conf" ] && diag_report_line warn "Nginx down but domain split enabled"
    echo ""
    echo -e "${CYAN}Run 'mrm monitor' to setup Telegram alerts for down/CPU/disk${NC}"
    echo ""

    pause
}

run_doctor_cli() {
    local MODE="${1:-full}"
    detect_active_panel > /dev/null
    echo "=== MRM DOCTOR v1.1.5"
    echo "Date: $(date)"
    echo "Version: $(get_mrm_version 2>/dev/null || echo v1.1.5)"
    echo "Panel: $(cat "$CONFIG_FILE" 2>/dev/null || echo unknown) - $PANEL_DIR"
    echo ""

    local DISK_INFO=$(mrm_check_disk)
    local DISK_USAGE=$(echo "$DISK_INFO" | awk '{print $1}')
    local DISK_FREE=$(echo "$DISK_INFO" | awk '{print $2}')
    local RAM_INFO=$(mrm_check_ram)
    local RAM_USED=$(echo "$RAM_INFO" | awk '{print $1}')
    local RAM_TOTAL=$(echo "$RAM_INFO" | awk '{print $2}')
    local RAM_PERCENT=$(echo "$RAM_INFO" | awk '{print $3}')

    echo "[Disk] Usage: ${DISK_USAGE}% Free: $DISK_FREE"
    [ "$DISK_USAGE" -gt 90 ] 2>/dev/null && echo " -> CRITICAL"
    echo "[RAM]  Usage: ${RAM_USED}MB/${RAM_TOTAL}MB (${RAM_PERCENT}%)"
    echo "[Panel] $(mrm_panel_running && echo Running || echo STOPPED)"
    echo "[Node] $( [ -d "$NODE_DIR" ] && (mrm_node_running && echo Running || echo Stopped) || echo Not Installed)"
    echo "[Nginx] $(mrm_nginx_running && echo Running || echo Stopped)"
    echo "[Docker] $(command -v docker >/dev/null 2>&1 && echo OK || echo NOT INSTALLED)"

    local ERRORS=$(mrm_check_panel_logs "$(get_panel_compose_file 2>/dev/null || true)")
    echo "[Logs] $ERRORS errors in last 100 lines"

    echo ""
    if [ "$DISK_USAGE" -gt 90 ] 2>/dev/null || ! mrm_panel_running; then
        echo "STATUS: CRITICAL - Action required!"
        return 1
    elif [ "$DISK_USAGE" -gt 80 ] 2>/dev/null || [ "${RAM_PERCENT%.*}" -gt 90 ] 2>/dev/null; then
        echo "STATUS: WARNING"
        return 0
    else
        echo "STATUS: OK"
        return 0
    fi
}

diagnostics_restart_nginx() {
    if nginx -t >/dev/null 2>&1 && systemctl restart nginx >/dev/null 2>&1; then
        ui_success "Nginx restarted successfully"
    else
        ui_error "Nginx restart failed"
        nginx -t 2>&1 | tail -n 5
    fi
    pause
}

diagnostics_restart_panel() {
    if restart_service "panel"; then
        ui_success "Panel restart completed"
    else
        ui_error "Panel restart failed"
    fi
    pause
}

diagnostics_restart_node() {
    # PasarGuard nodes normally run on their OWN server and connect to the
    # panel via gRPC/rest — docker restart here only works for a co-located node.
    ui_info "This restarts the node only if it runs on this server ($NODE_DIR)."
    ui_info "Remote node? Restart it on the node server instead."
    if [ -d "$NODE_DIR" ]; then
        if restart_service "node"; then
            ui_success "Node restart completed"
        else
            ui_error "Node restart failed"
        fi
    else
        ui_warning "Node directory not found"
    fi
    pause
}

diagnostics_menu() {
    while true; do
        clear
        ui_header "DIAGNOSTICS & DOCTOR v1.1.5"
        mrm_render_home_dashboard

        echo "1) 🩺 Run Full Doctor Diagnostics"
        echo "2) 🔄 Restart Panel"
        echo "3) 🔄 Restart Node (only if node runs on THIS server)"
        echo "4) 🌐 Test Nginx Config"
        echo "5) 🌐 Restart Nginx"
        echo "6) 📊 Quick Doctor (CLI mode)"
        echo "7) 🤖 Setup Monitor Alerts (Telegram)"
        echo "0) ↩️ Back"
        echo ""
        read -p "Select: " OPT
        case "$OPT" in
            1) run_full_diagnostics ;;
            2) diagnostics_restart_panel ;;
            3) diagnostics_restart_node ;;
            4)
                if nginx -t; then
                    ui_success "Nginx configuration is valid"
                else
                    ui_error "Nginx configuration test failed"
                fi
                pause
                ;;
            5) diagnostics_restart_nginx ;;
            6) clear; run_doctor_cli; echo ""; pause ;;
            7)
                if [ -f "/opt/mrm-manager/monitor.sh" ]; then
                    bash /opt/mrm-manager/monitor.sh menu
                else
                    ui_error "monitor.sh not found, reinstall MRM"
                    pause
                fi
                ;;
            0) return ;;
            *)
                if declare -f invalid_menu_option >/dev/null 2>&1; then
                    invalid_menu_option
                else
                    ui_error "Invalid option"
                    sleep 1
                fi
                ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "$1" == "doctor" ]]; then
        run_doctor_cli "$2"
    else
        diagnostics_menu
    fi
fi
