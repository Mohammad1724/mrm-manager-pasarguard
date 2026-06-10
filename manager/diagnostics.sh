#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

DIAG_DOMAIN_CONF="/etc/nginx/conf.d/panel_separate.conf"

mrm_panel_running() {
    local PANEL_NAME
    PANEL_NAME="$(cat "$CONFIG_FILE" 2>/dev/null || echo unknown)"

    case "$PANEL_NAME" in
        pasarguard|marzban|rebecca)
            docker ps --format '{{.Names}}' 2>/dev/null | grep -qi "$PANEL_NAME"
            ;;
        *)
            return 1
            ;;
    esac
}

mrm_node_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qiE "pg-node|marzban-node|rebecca-node|(^|[-_])node($|[-_])"
}

mrm_nginx_running() {
    systemctl is-active --quiet nginx 2>/dev/null || docker ps --format '{{.Names}}' 2>/dev/null | grep -qi "nginx"
}

mrm_theme_enabled() {
    if declare -f is_theme_active >/dev/null 2>&1; then
        is_theme_active
        return $?
    fi

    grep -q "SUBSCRIPTION_PAGE_TEMPLATE" "$PANEL_ENV" 2>/dev/null
}

mrm_domain_split_enabled() {
    [ -f "$DIAG_DOMAIN_CONF" ] && grep -q "server_name" "$DIAG_DOMAIN_CONF" 2>/dev/null
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
        printf '%s\n' "$(basename "$FILE")"
    else
        printf '%s\n' "No backup found"
    fi
}

mrm_colored_state() {
    local OK_TEXT="$1"
    local BAD_TEXT="$2"
    local MODE="$3"

    if [ "$MODE" = "ok" ]; then
        printf '%b' "${GREEN}● ${OK_TEXT}${NC}"
    elif [ "$MODE" = "warn" ]; then
        printf '%b' "${YELLOW}● ${OK_TEXT}${NC}"
    else
        printf '%b' "${RED}● ${BAD_TEXT}${NC}"
    fi
}

mrm_render_home_dashboard() {
    local ACTIVE_PANEL
    local PANEL_STATUS
    local NODE_STATUS
    local NGINX_STATUS
    local THEME_STATUS
    local DOMAIN_STATUS
    local TG_STATUS
    local BACKUP_STATUS

    detect_active_panel > /dev/null
    ACTIVE_PANEL="$(cat "$CONFIG_FILE" 2>/dev/null || echo unknown)"

    if mrm_panel_running; then
        PANEL_STATUS="$(mrm_colored_state "Running" "Stopped" ok)"
    else
        PANEL_STATUS="$(mrm_colored_state "Running" "Stopped" bad)"
    fi

    if [ -n "$NODE_DIR" ] && [ -d "$NODE_DIR" ]; then
        if mrm_node_running; then
            NODE_STATUS="$(mrm_colored_state "Running" "Stopped" ok)"
        else
            NODE_STATUS="$(mrm_colored_state "Expected" "Stopped" warn)"
        fi
    else
        NODE_STATUS="$(mrm_colored_state "Optional" "Not Installed" warn)"
    fi

    if mrm_nginx_running; then
        NGINX_STATUS="$(mrm_colored_state "Running" "Stopped" ok)"
    else
        NGINX_STATUS="$(mrm_colored_state "Running" "Stopped" bad)"
    fi

    if mrm_theme_enabled; then
        THEME_STATUS="$(mrm_colored_state "Active" "Inactive" ok)"
    else
        THEME_STATUS="$(mrm_colored_state "Active" "Inactive" bad)"
    fi

    if mrm_domain_split_enabled; then
        DOMAIN_STATUS="$(mrm_colored_state "Configured" "Inactive" ok)"
    else
        DOMAIN_STATUS="$(mrm_colored_state "Configured" "Inactive" bad)"
    fi

    if mrm_telegram_enabled; then
        TG_STATUS="$(mrm_colored_state "Configured" "Not Configured" ok)"
    else
        TG_STATUS="$(mrm_colored_state "Configured" "Not Configured" bad)"
    fi

    if [ -n "$(mrm_latest_backup_file)" ]; then
        BACKUP_STATUS="$(mrm_colored_state "Ready" "Missing" ok)"
    else
        BACKUP_STATUS="$(mrm_colored_state "Ready" "Missing" bad)"
    fi

    ui_section "HOME DASHBOARD"
    ui_kv "Active Panel" "$ACTIVE_PANEL"
    ui_kv "Panel Directory" "${PANEL_DIR:-unknown}"
    echo -e "${UI_DIM}Services:${UI_NC} Panel ${PANEL_STATUS}   Node ${NODE_STATUS}   Nginx ${NGINX_STATUS}"
    echo -e "${UI_DIM}Features:${UI_NC} SSL $(mrm_ssl_status_text)   Backup ${BACKUP_STATUS}   Telegram ${TG_STATUS}"
    echo -e "${UI_DIM}Extras:${UI_NC} Theme ${THEME_STATUS}   Domain Split ${DOMAIN_STATUS}"
    ui_kv "Last Backup" "$(mrm_latest_backup_text)"
    echo ""
}

diag_report_line() {
    local TYPE="$1"
    local MESSAGE="$2"

    case "$TYPE" in
        ok) ui_success "$MESSAGE" ;;
        warn) ui_warning "$MESSAGE" ;;
        error) ui_error "$MESSAGE" ;;
        info) ui_info "$MESSAGE" ;;
    esac
}

run_full_diagnostics() {
    local PANEL_COMPOSE
    local NODE_COMPOSE
    local CERT_COUNT
    local DISK_FREE

    clear
    detect_active_panel > /dev/null
    ui_header "DIAGNOSTICS & SELF-HEAL"

    PANEL_COMPOSE="$(get_panel_compose_file 2>/dev/null || true)"
    NODE_COMPOSE="$(get_node_compose_file 2>/dev/null || true)"
    CERT_COUNT="$(mrm_ssl_cert_count)"
    DISK_FREE="$(df -h / 2>/dev/null | awk 'NR==2{print $4}' || echo unknown)"

    ui_section "Panel Detection"
    [ -n "$PANEL_DIR" ] && diag_report_line ok "Active panel: $(cat "$CONFIG_FILE" 2>/dev/null || echo unknown)" || diag_report_line error "No active panel detected"
    [ -d "$PANEL_DIR" ] && diag_report_line ok "Panel directory exists: $PANEL_DIR" || diag_report_line error "Panel directory missing: ${PANEL_DIR:-unknown}"
    [ -f "$PANEL_ENV" ] && diag_report_line ok "Panel .env found: $PANEL_ENV" || diag_report_line warn "Panel .env missing: ${PANEL_ENV:-unknown}"
    [ -n "$PANEL_COMPOSE" ] && diag_report_line ok "Panel compose file found" || diag_report_line warn "Panel compose file not found"
    echo ""

    ui_section "Node Detection"
    if [ -d "$NODE_DIR" ]; then
        diag_report_line ok "Node directory exists: $NODE_DIR"
        [ -f "$NODE_ENV" ] && diag_report_line ok "Node .env found: $NODE_ENV" || diag_report_line warn "Node .env missing: ${NODE_ENV:-unknown}"
        [ -n "$NODE_COMPOSE" ] && diag_report_line ok "Node compose file found" || diag_report_line warn "Node compose file not found"
    else
        diag_report_line warn "Node directory not found: ${NODE_DIR:-unknown}"
    fi
    echo ""

    ui_section "Service Health"
    mrm_panel_running && diag_report_line ok "Panel containers are running" || diag_report_line warn "Panel containers appear stopped"
    if [ -d "$NODE_DIR" ]; then
        mrm_node_running && diag_report_line ok "Node containers are running" || diag_report_line warn "Node containers appear stopped"
    fi
    mrm_nginx_running && diag_report_line ok "Nginx is running" || diag_report_line warn "Nginx is not running"
    command -v docker >/dev/null 2>&1 && diag_report_line ok "Docker is installed" || diag_report_line error "Docker is not installed"
    echo ""

    ui_section "Feature Health"
    [ "$CERT_COUNT" -gt 0 ] 2>/dev/null && diag_report_line ok "SSL certificates detected: $CERT_COUNT" || diag_report_line warn "No Let's Encrypt certificates found"
    mrm_theme_enabled && diag_report_line ok "Theme is active" || diag_report_line info "Theme is inactive"
    mrm_domain_split_enabled && diag_report_line ok "Domain separation config detected" || diag_report_line info "Domain separation is inactive"
    mrm_telegram_enabled && diag_report_line ok "Telegram backup is configured" || diag_report_line info "Telegram backup is not configured"
    [ -n "$(mrm_latest_backup_file)" ] && diag_report_line ok "Latest backup: $(mrm_latest_backup_text)" || diag_report_line warn "No backups found in $(mrm_backup_dir)"
    echo ""

    ui_section "System Health"
    diag_report_line info "Free disk space on / : $DISK_FREE"
    if nginx -t >/dev/null 2>&1; then
        diag_report_line ok "Nginx configuration test passed"
    else
        diag_report_line error "Nginx configuration test failed"
    fi
    echo ""

    pause
}

diagnostics_restart_nginx() {
    if nginx -t >/dev/null 2>&1 && systemctl restart nginx >/dev/null 2>&1; then
        ui_success "Nginx restarted successfully"
    else
        ui_error "Nginx restart failed"
    fi
    pause
}

diagnostics_restart_panel() {
    if restart_service "panel"; then
        ui_success "Panel restart command completed"
    else
        ui_error "Panel restart failed"
    fi
    pause
}

diagnostics_restart_node() {
    if [ -d "$NODE_DIR" ]; then
        if restart_service "node"; then
            ui_success "Node restart command completed"
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
        ui_header "DIAGNOSTICS & SELF-HEAL"
        mrm_render_home_dashboard

        echo "1) 🩺 Run Full Diagnostics"
        echo "2) 🔧 Run Auto Fix"
        echo "3) 🔄 Restart Panel"
        echo "4) 🔄 Restart Node"
        echo "5) 🌐 Test Nginx Config"
        echo "6) 🌐 Restart Nginx"
        echo "0) ↩️  Back"
        echo ""
        read -p "Select: " OPT

        case "$OPT" in
            1) run_full_diagnostics ;;
            2)
                if declare -f auto_fix >/dev/null 2>&1; then
                    auto_fix
                else
                    ui_error "Auto Fix is not available"
                    pause
                fi
                ;;
            3) diagnostics_restart_panel ;;
            4) diagnostics_restart_node ;;
            5)
                if nginx -t; then
                    ui_success "Nginx configuration is valid"
                else
                    ui_error "Nginx configuration test failed"
                fi
                pause
                ;;
            6) diagnostics_restart_nginx ;;
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
