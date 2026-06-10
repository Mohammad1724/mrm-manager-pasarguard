#!/bin/bash

# ==========================================
# MRM MANAGER v4.0
# ==========================================

bootstrap_error() {
    echo -e "\033[0;31m[MRM Bootstrap Error]\033[0m $1" >&2
}

load_required_module() {
    local MODULE_PATH="$1"

    if [ ! -r "$MODULE_PATH" ]; then
        bootstrap_error "Required module not found or not readable: $MODULE_PATH"
        exit 1
    fi

    # shellcheck source=/dev/null
    if ! source "$MODULE_PATH"; then
        bootstrap_error "Failed to load module: $MODULE_PATH"
        exit 1
    fi
}

# Load Modules
load_required_module "/opt/mrm-manager/utils.sh"
load_required_module "/opt/mrm-manager/ui.sh"
load_required_module "/opt/mrm-manager/ssl.sh"
load_required_module "/opt/mrm-manager/backup.sh"
load_required_module "/opt/mrm-manager/domain_separator.sh"
load_required_module "/opt/mrm-manager/site.sh"
load_required_module "/opt/mrm-manager/theme.sh"
load_required_module "/opt/mrm-manager/settings.sh"
load_required_module "/opt/mrm-manager/diagnostics.sh"
load_required_module "/opt/mrm-manager/offline.sh"
load_required_module "/opt/mrm-manager/safe_ops.sh"
load_required_module "/opt/mrm-manager/migrator.sh"
load_required_module "/opt/mrm-manager/mirza.sh"

# Detect panel on startup
detect_active_panel > /dev/null

# ==========================================
# HELPER FUNCTIONS
# ==========================================
edit_file() {
    if [ -f "$1" ]; then
        nano "$1"
    else
        ui_error "File not found: $1"
        pause
    fi
}

invalid_menu_option() {
    ui_error "Invalid option"
    sleep 1
}

get_panel_compose_file() {
    local CANDIDATE

    for CANDIDATE in \
        "$PANEL_DIR/docker-compose.yml" \
        "$PANEL_DIR/docker-compose.yaml" \
        "$PANEL_DIR/compose.yml" \
        "$PANEL_DIR/compose.yaml"
    do
        if [ -f "$CANDIDATE" ]; then
            printf '%s\n' "$CANDIDATE"
            return 0
        fi
    done

    return 1
}

ensure_panel_compose_ready() {
    detect_active_panel > /dev/null

    if [ -z "$PANEL_DIR" ] || [ ! -d "$PANEL_DIR" ]; then
        ui_error "Panel directory not found: ${PANEL_DIR:-unknown}"
        return 1
    fi

    if ! command -v docker >/dev/null 2>&1; then
        ui_error "Docker is not installed."
        return 1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        ui_error "Docker Compose plugin is not available."
        return 1
    fi

    if ! get_panel_compose_file >/dev/null 2>&1; then
        ui_error "No compose file found in $PANEL_DIR"
        return 1
    fi

    return 0
}

run_panel_compose() {
    ensure_panel_compose_ready || return 1
    (
        cd "$PANEL_DIR" && docker compose "$@"
    )
}

edit_panel_compose_file() {
    local COMPOSE_FILE

    if ! COMPOSE_FILE="$(get_panel_compose_file 2>/dev/null)"; then
        ui_error "No compose file found in $PANEL_DIR"
        pause
        return 1
    fi

    edit_file "$COMPOSE_FILE"
}

show_panel_logs() {
    local LOG_STATUS

    if ! ensure_panel_compose_ready; then
        pause
        return 1
    fi

    (
        cd "$PANEL_DIR" && docker compose logs -f
    )
    LOG_STATUS=$?

    if [ "$LOG_STATUS" -ne 0 ] && [ "$LOG_STATUS" -ne 130 ]; then
        ui_error "Unable to show logs"
        pause
        return 1
    fi

    return 0
}

remove_mrm_cron_jobs() {
    local CURRENT_CRON
    local FILTERED_CRON

    CURRENT_CRON="$(mktemp /tmp/mrm-cron-current.XXXXXX)"
    FILTERED_CRON="$(mktemp /tmp/mrm-cron-filtered.XXXXXX)"

    if crontab -l 2>/dev/null > "$CURRENT_CRON"; then
        grep -vE '(/opt/mrm-manager/|/usr/local/bin/mrm)' "$CURRENT_CRON" > "$FILTERED_CRON" || true
        crontab "$FILTERED_CRON" 2>/dev/null || true
    fi

    rm -f "$CURRENT_CRON" "$FILTERED_CRON"
}

uninstall_mrm_manager() {
    clear
    ui_header "UNINSTALL MRM MANAGER"

    echo -e "${RED}This will remove MRM Manager from this server.${NC}"
    echo ""
    echo -e "${YELLOW}Items that WILL be removed:${NC}"
    echo "  • /opt/mrm-manager"
    echo "  • /usr/local/bin/mrm"
    echo "  • MRM-related cron jobs"
    echo "  • /etc/cron.d/ssl-auto-renew"
    echo "  • /root/.mrm_telegram"
    echo "  • /var/log/mrm-backup.log"
    echo "  • /var/log/ssl-manager"
    echo ""
    echo -e "${CYAN}Items that will be KEPT:${NC}"
    echo "  • Panel files and panel data"
    echo "  • Nginx and system configuration changes"
    echo "  • Backups in /root/mrm-backups"
    echo ""

    read -r -p "Type UNINSTALL to continue: " CONFIRM_UNINSTALL
    if [ "$CONFIRM_UNINSTALL" != "UNINSTALL" ]; then
        ui_warning "Uninstall cancelled."
        pause
        return
    fi

    ui_spinner_start "Removing MRM scheduled tasks..."
    remove_mrm_cron_jobs
    rm -f /etc/cron.d/ssl-auto-renew >/dev/null 2>&1
    ui_spinner_stop
    ui_success "MRM scheduled tasks removed"

    ui_spinner_start "Removing MRM files and logs..."
    rm -f /usr/local/bin/mrm >/dev/null 2>&1
    rm -f /root/.mrm_telegram >/dev/null 2>&1
    rm -f /var/log/mrm-backup.log >/dev/null 2>&1
    rm -rf /var/log/ssl-manager >/dev/null 2>&1
    rm -rf /tmp/mrm_workspace >/dev/null 2>&1
    rm -rf /opt/mrm-manager >/dev/null 2>&1
    ui_spinner_stop
    ui_success "MRM Manager files removed"

    echo ""
    ui_success "Uninstall completed successfully."
    echo -e "${CYAN}Backups preserved at:${NC} /root/mrm-backups"
    echo ""
    read -r -p "Press Enter to exit..."
    clear
    exit 0
}

# ==========================================
# NETWORK OPTIMIZATION (BBR)
# ==========================================
optimize_network() {
    ui_header "NETWORK OPTIMIZATION"

    ui_spinner_start "Enabling BBR..."
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    ui_spinner_stop
    ui_success "BBR Enabled"

    ui_spinner_start "Tuning TCP Stack..."
    cat <<EOF > /etc/sysctl.d/99-mrm-speed.conf
fs.file-max = 1000000
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 65536
net.core.somaxconn = 65536
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_mtu_probing = 1
EOF
    sysctl -p /etc/sysctl.d/99-mrm-speed.conf >/dev/null 2>&1
    sysctl --system >/dev/null 2>&1
    ui_spinner_stop
    ui_success "TCP Tuned"

    ui_spinner_start "Increasing System Limits..."
    if ! grep -q "* soft nofile 1000000" /etc/security/limits.conf; then
        echo "* soft nofile 1000000" >> /etc/security/limits.conf
        echo "* hard nofile 1000000" >> /etc/security/limits.conf
        echo "root soft nofile 1000000" >> /etc/security/limits.conf
        echo "root hard nofile 1000000" >> /etc/security/limits.conf
    fi
    ui_spinner_stop
    ui_success "Limits Increased"

    echo ""
    ui_success "Network Optimization Complete!"
    pause
}

# ==========================================
# AUTO FIX
# ==========================================
auto_fix() {
    local FIREWALL_APPLIED=false
    local ENV_FIXED=false
    local RESTART_TARGET_FOUND=false

    ui_header "AUTO FIX"

    ui_spinner_start "Configuring Firewall..."
    if command -v ufw >/dev/null 2>&1; then
        if ufw allow 22,80,443,2096,7431,6432,8443,2083,2097,8080/tcp >/dev/null 2>&1 && \
           ufw --force enable >/dev/null 2>&1; then
            for r in "192.0.0.0/8" "102.0.0.0/8" "198.0.0.0/8" "172.0.0.0/8"; do
                ufw delete deny from "$r" >/dev/null 2>&1 || true
                ufw delete deny out to "$r" >/dev/null 2>&1 || true
            done
            FIREWALL_APPLIED=true
        fi
    fi
    ui_spinner_stop

    if [ "$FIREWALL_APPLIED" = true ]; then
        ui_success "Firewall Fixed"
    elif ! command -v ufw >/dev/null 2>&1; then
        ui_warning "ufw is not installed. Firewall step skipped."
    else
        ui_error "Firewall configuration failed"
    fi

    ui_spinner_start "Fixing .env files..."
    if [ -f "$PANEL_ENV" ]; then
        if sed -i 's|\(postgresql+asyncpg://[^"?]*\)\(["\s]*\)$|\1?ssl=disable\2|' "$PANEL_ENV" && \
           sed -i 's/\([^[:space:]]\)\(UVICORN_\)/\1\n\2/g' "$PANEL_ENV" && \
           sed -i 's/\([^[:space:]]\)\(SSL_\)/\1\n\2/g' "$PANEL_ENV"; then
            ENV_FIXED=true
        fi
    fi
    ui_spinner_stop

    if [ "$ENV_FIXED" = true ]; then
        ui_success ".env Files Fixed"
    elif [ -f "$PANEL_ENV" ]; then
        ui_error "Failed to fix .env file"
    else
        ui_warning "Panel .env file not found: ${PANEL_ENV:-unknown}"
    fi

    ui_spinner_start "Restarting Services..."
    if [ -d "$PANEL_DIR" ]; then
        RESTART_TARGET_FOUND=true
        restart_service "panel" >/dev/null 2>&1 || true
    fi
    if [ -d "$NODE_DIR" ]; then
        RESTART_TARGET_FOUND=true
        restart_service "node" >/dev/null 2>&1 || true
    fi
    ui_spinner_stop

    if [ "$RESTART_TARGET_FOUND" = true ]; then
        ui_info "Service restart commands issued"
    else
        ui_warning "No panel/node directories found to restart"
    fi

    echo ""
    ui_success "Auto Fix Complete!"
    pause
}

# ==========================================
# PANEL CONTROL MENU
# ==========================================
panel_menu() {
    while true; do
        clear
        ui_header "PANEL CONTROL"
        detect_active_panel > /dev/null

        echo -e "Active Panel: ${UI_CYAN}$PANEL_DIR${UI_NC}"
        echo ""
        echo "1) 🔄 Restart Panel"
        echo "2) ⏹️  Stop Panel"
        echo "3) ▶️  Start Panel"
        echo "4) 📋 View Logs (Live)"
        echo "5) 👤 Create Admin"
        echo "6) 🔑 Reset Admin Password"
        echo "7) 📝 Edit .env"
        echo "8) 📝 Edit docker-compose.yml"
        echo ""
        echo "0) ↩️  Back"
        echo ""
        read -p "Select: " OPT

        case $OPT in
            1)
                restart_service "panel"
                pause
                ;;
            2)
                if run_panel_compose down; then
                    ui_success "Stopped"
                else
                    ui_error "Failed to stop panel"
                fi
                pause
                ;;
            3)
                if run_panel_compose up -d; then
                    ui_success "Started"
                else
                    ui_error "Failed to start panel"
                fi
                pause
                ;;
            4)
                show_panel_logs
                ;;
            5)
                admin_create
                pause
                ;;
            6)
                admin_reset
                pause
                ;;
            7)
                edit_file "$PANEL_ENV"
                ;;
            8)
                edit_panel_compose_file
                ;;
            0)
                return
                ;;
            *)
                invalid_menu_option
                ;;
        esac
    done
}

# ==========================================
# TOOLS MENU
# ==========================================
tools_menu() {
    while true; do
        clear
        ui_header "TOOLS"

        echo "1) 🌐 Domain Separator (Panel & Sub)"
        echo "2) 🎭 Fake Site Manager"
        echo "3) 🎨 Theme Manager"
        echo "4) ⚙️  Settings Center"
        echo "5) 🩺 Diagnostics & Self-Heal"
        echo "6) 🇮🇷 Iran / Offline Mode"
        echo "7) ♻️  Restore Points & Rollback"
        echo "8) 🔄 Migration (Pasarguard → Rebecca)"
        echo ""
        echo "9) ⚡ Optimize Network (BBR)"
        echo "10) 🔧 Auto Fix"
        echo ""
        echo "0) ↩️  Back"
        echo ""
        read -p "Select: " OPT

        case $OPT in
            1) domain_menu ;;
            2) site_menu ;;
            3) theme_menu ;;
            4) settings_menu ;;
            5) diagnostics_menu ;;
            6) offline_menu ;;
            7) safe_ops_menu ;;
            8) migrator_menu ;;
            9) optimize_network ;;
            10) auto_fix ;;
            0) return ;;
            *) invalid_menu_option ;;
        esac
    done
}

# ==========================================
# MAIN MENU
# ==========================================
main_menu() {
    check_root
    install_deps

    while true; do
        clear
        ui_header "MRM MANAGER v4.0" 50
        ui_status_bar
        if declare -f mrm_render_home_dashboard >/dev/null 2>&1; then
            mrm_render_home_dashboard
        fi

        ui_section "MAIN MENU"
        echo "1) 🔐 SSL Certificates"
        echo "2) 💾 Backup & Restore"
        echo "3) 🤖 Mirza Pro (Telegram Bot)"
        echo "4) ⚙️  Panel Control"
        echo "5) 🛠️  Tools"
        echo "6) 🗑️  Uninstall MRM Manager"
        echo ""
        echo "0) Exit"
        echo ""
        read -p "Select: " OPT

        case $OPT in
            1) ssl_menu ;;
            2) backup_menu ;;
            3) mirza_menu ;;
            4) panel_menu ;;
            5) tools_menu ;;
            6) uninstall_mrm_manager ;;
            0)
                clear
                echo -e "${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                invalid_menu_option
                ;;
        esac
    done
}

# Run
main_menu
