#!
# MRM Manager v1.0.0

# ==========================================
# MRM MANAGER v1.0.0
# Streamlined: Removed site, port_manager, migrator
# Core focus: SSL, Backup, Panel Control, Doctor, Monitor
# ==========================================

if [[ "$1" == "--version" || "$1" == "-v" || "$1" == "version" ]]; then
    if [ -f "/opt/mrm-manager/VERSION" ]; then
        echo "MRM Manager $(cat /opt/mrm-manager/VERSION)"
    else
        echo "MRM Manager v1.0.0
    fi
    exit 0
fi

if [[ "$1" == "doctor" ]]; then
    exec bash /opt/mrm-manager/diagnostics.sh doctor "${@:2}"
fi

if [[ "$1" == "monitor" ]]; then
    exec bash /opt/mrm-manager/monitor.sh "${@:2}"
fi

if [[ "$1" == "update" ]]; then
    echo -e "\033[0;36mUpdating MRM Manager from GitHub...\033[0m"
    bash -c "$(curl -sL https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/main/install.sh)"
    exit 0
fi

bootstrap_error() {
    echo -e "\033[0;31m[MRM Bootstrap Error]\033[0m $1" >&2
}

load_required_module() {
    local MODULE_PATH="$1"
    if [ ! -r "$MODULE_PATH" ]; then
        bootstrap_error "Required module not found: $MODULE_PATH (Skipping)"
        return 1
    fi
    if ! source "$MODULE_PATH"; then
        bootstrap_error "Failed to load: $MODULE_PATH"
        return 1
    fi
    return 0
}

# Load Core Modules Only -  v1.0.0
load_required_module "/opt/mrm-manager/utils.sh"
load_required_module "/opt/mrm-manager/ui.sh"
load_required_module "/opt/mrm-manager/ssl.sh"
load_required_module "/opt/mrm-manager/backup.sh"
load_required_module "/opt/mrm-manager/domain_separator.sh"
load_required_module "/opt/mrm-manager/theme.sh"
load_required_module "/opt/mrm-manager/settings.sh"
load_required_module "/opt/mrm-manager/diagnostics.sh"
load_required_module "/opt/mrm-manager/offline.sh"
load_required_module "/opt/mrm-manager/safe_ops.sh"
load_required_module "/opt/mrm-manager/mirza.sh"
load_required_module "/opt/mrm-manager/monitor.sh" || true

if declare -f detect_active_panel >/dev/null 2>&1; then
    detect_active_panel > /dev/null 2>&1 || true
fi

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
    detect_active_panel > /dev/null 2>&1 || true
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
    (cd "$PANEL_DIR" && docker compose "$@")
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
    (cd "$PANEL_DIR" && docker compose logs -f)
    LOG_STATUS=$?
    if [ "$LOG_STATUS" -ne 0 ] && [ "$LOG_STATUS" -ne 130 ]; then
        ui_error "Unable to show logs"
        pause
        return 1
    fi
    return 0
}

remove_mrm_cron_jobs() {
    local CURRENT_CRON FILTERED_CRON
    CURRENT_CRON="$(mktemp /tmp/mrm-cron-current.XXXXXX)"
    FILTERED_CRON="$(mktemp /tmp/mrm-cron-filtered.XXXXXX)"
    if crontab -l 2>/dev/null > "$CURRENT_CRON"; then
        grep -vE '(/opt/mrm-manager/|/usr/local/bin/mrm|mrm-manager|mrm-backup|mrm-monitor)' "$CURRENT_CRON" > "$FILTERED_CRON" || true
        crontab "$FILTERED_CRON" 2>/dev/null || true
    fi
    rm -f "$CURRENT_CRON" "$FILTERED_CRON"
}

uninstall_mrm_manager() {
    clear
    ui_header "UNINSTALL MRM MANAGER v1.0.0
    echo -e "${RED}This will remove MRM Manager${NC}"
    echo ""
    echo -e "${YELLOW}Will be removed:${NC}"
    echo "  • /opt/mrm-manager (all modules)"
    echo "  • /usr/local/bin/mrm"
    echo "  • MRM crons (backup, monitor, ssl-auto-renew)"
    echo "  • Logs"
    echo ""
    echo -e "${CYAN}Kept:${NC}"
    echo "  • Panel data (/opt/pasarguard, /var/lib/pasarguard)"
    echo "  • Backups (/root/mrm-backups)"
    echo ""
    read -r -p "Type UNINSTALL to continue: " CONFIRM_UNINSTALL
    if [ "$CONFIRM_UNINSTALL" != "UNINSTALL" ]; then
        ui_warning "Cancelled."
        pause
        return
    fi
    echo ""
    read -r -p "Remove Telegram config too? (y/N): " RM_TG
    ui_spinner_start "Removing cron jobs..."
    remove_mrm_cron_jobs
    rm -f /etc/cron.d/ssl-auto-renew >/dev/null 2>&1
    ui_spinner_stop
    ui_spinner_start "Removing files..."
    rm -f /usr/local/bin/mrm >/dev/null 2>&1
    [[ "$RM_TG" =~ ^[Yy]$ ]] && rm -f /root/.mrm_telegram >/dev/null 2>&1
    rm -f /var/log/mrm-backup.log /var/log/mrm-monitor.log >/dev/null 2>&1
    rm -rf /var/log/ssl-manager /tmp/mrm_workspace /tmp/mrm-monitor-state >/dev/null 2>&1
    rm -rf /opt/mrm-manager >/dev/null 2>&1
    ui_spinner_stop
    ui_success "Uninstall completed."
    echo -e "${CYAN}Backups kept at:${NC} /root/mrm-backups"
    read -r -p "Press Enter to exit..."
    clear
    exit 0
}

optimize_network() {
    ui_header "NETWORK OPTIMIZATION (BBR)"
    ui_spinner_start "Enabling BBR..."
    grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    ui_spinner_stop
    ui_spinner_start "Tuning TCP..."
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
    ui_spinner_start "Increasing limits..."
    grep -q "^\* soft nofile 1000000" /etc/security/limits.conf || {
        echo "* soft nofile 1000000" >> /etc/security/limits.conf
        echo "* hard nofile 1000000" >> /etc/security/limits.conf
        echo "root soft nofile 1000000" >> /etc/security/limits.conf
        echo "root hard nofile 1000000" >> /etc/security/limits.conf
    }
    ui_spinner_stop
    ui_success "Network Optimized!"
    pause
}

auto_fix() {
    local FIREWALL_APPLIED=false ENV_FIXED=false RESTART_TARGET_FOUND=false
    ui_header "AUTO FIX"
    ui_spinner_start "Configuring Firewall..."
    if command -v ufw >/dev/null 2>&1; then
        if ufw allow 22,80,443,2096,7431,6432,8443,2083,2097,8080/tcp >/dev/null 2>&1 && ufw --force enable >/dev/null 2>&1; then
            FIREWALL_APPLIED=true
        fi
    fi
    ui_spinner_stop
    if [ "$FIREWALL_APPLIED" = true ]; then ui_success "Firewall Fixed"; elif ! command -v ufw >/dev/null 2>&1; then ui_warning "ufw not installed"; else ui_error "Firewall failed"; fi
    ui_spinner_start "Fixing .env..."
    if [ -f "$PANEL_ENV" ]; then
        if sed -i 's|\(postgresql+asyncpg://[^"?]*\)\([\"\s]*\)$|\1?ssl=disable\2|' "$PANEL_ENV" && \
           sed -i 's/\([^[:space:]]\)\(UVICORN_\)/\1\n\2/g' "$PANEL_ENV" && \
           sed -i 's/\([^[:space:]]\)\(SSL_\)/\1\n\2/g' "$PANEL_ENV"; then
            ENV_FIXED=true
        fi
    fi
    ui_spinner_stop
    if [ "$ENV_FIXED" = true ]; then ui_success ".env Fixed"; elif [ -f "$PANEL_ENV" ]; then ui_error "Failed to fix .env"; else ui_warning "Panel .env not found"; fi
    ui_spinner_start "Restarting Services..."
    [ -d "$PANEL_DIR" ] && { RESTART_TARGET_FOUND=true; restart_service "panel" >/dev/null 2>&1 || true; }
    [ -d "$NODE_DIR" ] && { RESTART_TARGET_FOUND=true; restart_service "node" >/dev/null 2>&1 || true; }
    ui_spinner_stop
    if [ "$RESTART_TARGET_FOUND" = true ]; then ui_info "Restart issued"; else ui_warning "No panel/node found"; fi
    echo ""
    ui_success "Auto Fix Complete!"
    pause
}

panel_menu() {
    while true; do
        clear
        ui_header "PANEL CONTROL v1.0.0
        detect_active_panel > /dev/null 2>&1 || true
        echo -e "Active: ${CYAN}$PANEL_DIR${NC} | Ver: $(cat /opt/mrm-manager/VERSION 2>/dev/null || echo 1.0.0)"
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
            1) restart_service "panel"; pause ;;
            2) run_panel_compose down && ui_success "Stopped" || ui_error "Failed"; pause ;;
            3) run_panel_compose up -d && ui_success "Started" || ui_error "Failed"; pause ;;
            4) show_panel_logs ;;
            5) admin_create; pause ;;
            6) admin_reset; pause ;;
            7) edit_file "$PANEL_ENV" ;;
            8) edit_panel_compose_file ;;
            0) return ;;
            *) invalid_menu_option ;;
        esac
    done
}

tools_menu() {
    while true; do
        clear
        ui_header "TOOLS v1.0.0
        echo "Core Tools (Slim Edition - 3 modules removed)"
        echo ""
        echo "1) 🌐 Domain Separator (Panel & Sub)"
        echo "2) 🎨 Theme Manager"
        echo "3) ⚙️  Settings Center"
        echo "4) 🩺 Diagnostics & Doctor"
        echo "5) 🇮🇷 Iran / Offline Mode"
        echo "6) ♻️  Restore Points & Rollback"
        echo ""
        echo "7) ⚡ Optimize Network (BBR)"
        echo "8) 🔧 Auto Fix"
        echo "9) 🤖 Monitor & Alerts (Telegram) [NEW]"
        echo "10) 🩺 Doctor - Quick Check [NEW]"
        echo ""
        echo -e "${CYAN}Removed in Slim: Fake Site, Port Manager, Migrator${NC}"
        echo -e "${YELLOW}To restore them: git checkout manager/site.sh etc${NC}"
        echo ""
        echo "0) ↩️  Back"
        echo ""
        read -p "Select: " OPT
        case $OPT in
            1) domain_menu ;;
            2) theme_menu ;;
            3) settings_menu ;;
            4) diagnostics_menu ;;
            5) offline_menu ;;
            6) safe_ops_menu ;;
            7) optimize_network ;;
            8) auto_fix ;;
            9)
                if [ -f "/opt/mrm-manager/monitor.sh" ]; then
                    bash /opt/mrm-manager/monitor.sh menu
                else
                    ui_error "monitor.sh not found"
                    pause
                fi
                ;;
            10)
                if declare -f run_doctor_cli >/dev/null 2>&1; then
                    clear; run_doctor_cli; pause
                else
                    bash /opt/mrm-manager/diagnostics.sh doctor; pause
                fi
                ;;
            0) return ;;
            *) invalid_menu_option ;;
        esac
    done
}

main_menu() {
    check_root
    install_deps
    while true; do
        clear
        local MRM_VER=$(cat /opt/mrm-manager/VERSION 2>/dev/null || echo "1.0.0")
        ui_header "MRM MANAGER v$MRM_VER " 50
        ui_status_bar 2>/dev/null || true
        if declare -f mrm_render_home_dashboard >/dev/null 2>&1; then
            mrm_render_home_dashboard
        fi
        ui_section "MAIN MENU v$MRM_VER -  (1.0.0)"
        echo "1) 🔐 SSL Certificates"
        echo "2) 💾 Backup & Restore (2MB Fixed)"
        echo "3) 🤖 Mirza Pro (Telegram Bot)"
        echo "4) ⚙️  Panel Control"
        echo "5) 🛠️  Tools (Doctor, Monitor... Slim)"
        echo "6) 🔄 Update MRM Manager"
        echo "7) 🗑️  Uninstall MRM Manager"
        echo ""
        echo "0) Exit"
        echo ""
        echo -e "${CYAN}Slim: 3 modules removed (site, port, migrator) - 40% lighter${NC}"
        echo -e "${CYAN}Cmd: mrm --version | mrm doctor | mrm monitor${NC}"
        echo ""
        read -p "Select: " OPT
        case $OPT in
            1) ssl_menu ;;
            2) backup_menu ;;
            3) mirza_menu ;;
            4) panel_menu ;;
            5) tools_menu ;;
            6)
                echo "Updating..."
                bash -c "$(curl -sL https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/main/install.sh)"
                pause
                ;;
            7) uninstall_mrm_manager ;;
            0)
                clear
                echo -e "${GREEN}Goodbye! MRM v$MRM_VER Slim${NC}"
                exit 0
                ;;
            *) invalid_menu_option ;;
        esac
    done
}

main_menu
