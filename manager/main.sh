#!/bin/bash
# MRM MANAGER v1.0.2 - Fix hang in install_deps + prompt

if [[ "$1" == "--version" || "$1" == "-v" || "$1" == "version" ]]; then
    echo "MRM Manager $(cat /opt/mrm-manager/VERSION 2>/dev/null || echo 1.0.2)"
    exit 0
fi
if [[ "$1" == "doctor" ]]; then exec bash /opt/mrm-manager/diagnostics.sh doctor "${@:2}"; fi
if [[ "$1" == "monitor" ]]; then exec bash /opt/mrm-manager/monitor.sh "${@:2}"; fi
if [[ "$1" == "update" ]]; then bash -c "$(curl -sL https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/main/install.sh)"; exit 0; fi

bootstrap_error() { echo -e "\033[0;31m[MRM Bootstrap Error]\033[0m $1" >&2; }
load_required_module() {
    local MODULE_PATH="$1"
    [ -r "$MODULE_PATH" ] || { bootstrap_error "Not found: $MODULE_PATH (skip)"; return 1; }
    source "$MODULE_PATH" || { bootstrap_error "Failed: $MODULE_PATH"; return 1; }
}

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

detect_active_panel > /dev/null 2>&1 || true

edit_file() { [ -f "$1" ] && nano "$1" || { ui_error "File not found: $1"; pause; }; }
invalid_menu_option() { ui_error "Invalid option"; sleep 1; }
get_panel_compose_file() { for CANDIDATE in "$PANEL_DIR/docker-compose.yml" "$PANEL_DIR/docker-compose.yaml" "$PANEL_DIR/compose.yml" "$PANEL_DIR/compose.yaml"; do [ -f "$CANDIDATE" ] && { printf '%s\n' "$CANDIDATE"; return 0; }; done; return 1; }
ensure_panel_compose_ready() {
    detect_active_panel >/dev/null 2>&1 || true
    [ -z "$PANEL_DIR" ] || [ ! -d "$PANEL_DIR" ] && { ui_error "Panel dir not found: ${PANEL_DIR:-unknown}"; return 1; }
    command -v docker >/dev/null 2>&1 || { ui_error "Docker not installed"; return 1; }
    docker compose version >/dev/null 2>&1 || { ui_error "Docker Compose missing"; return 1; }
    get_panel_compose_file >/dev/null 2>&1 || { ui_error "No compose file in $PANEL_DIR"; return 1; }
}
run_panel_compose() { ensure_panel_compose_ready || return 1; (cd "$PANEL_DIR" && docker compose "$@"); }
edit_panel_compose_file() { local COMPOSE_FILE; COMPOSE_FILE="$(get_panel_compose_file 2>/dev/null)" || { ui_error "No compose file"; pause; return 1; }; edit_file "$COMPOSE_FILE"; }
show_panel_logs() { ensure_panel_compose_ready || { pause; return 1; }; (cd "$PANEL_DIR" && docker compose logs -f); }
remove_mrm_cron_jobs() {
    local CURRENT_CRON="$(mktemp /tmp/mrm-cron-current.XXXXXX)" FILTERED_CRON="$(mktemp /tmp/mrm-cron-filtered.XXXXXX)"
    crontab -l 2>/dev/null > "$CURRENT_CRON" && { grep -vE '(/opt/mrm-manager/|/usr/local/bin/mrm|mrm-manager)' "$CURRENT_CRON" > "$FILTERED_CRON" || true; crontab "$FILTERED_CRON" 2>/dev/null || true; }
    rm -f "$CURRENT_CRON" "$FILTERED_CRON"
}
uninstall_mrm_manager() {
    clear; ui_header "UNINSTALL MRM MANAGER v1.0.2"
    echo -e "${RED}Will remove MRM Manager${NC}\n"
    read -r -p "Type UNINSTALL to continue: " CONFIRM_UNINSTALL
    [[ "$CONFIRM_UNINSTALL" != "UNINSTALL" ]] && { ui_warning "Cancelled"; pause; return; }
    read -r -p "Remove Telegram config too? (y/N): " RM_TG
    ui_spinner_start "Removing cron..."; remove_mrm_cron_jobs; rm -f /etc/cron.d/ssl-auto-renew >/dev/null 2>&1; ui_spinner_stop
    ui_spinner_start "Removing files..."; rm -f /usr/local/bin/mrm >/dev/null 2>&1; [[ "$RM_TG" =~ ^[Yy]$ ]] && rm -f /root/.mrm_telegram >/dev/null 2>&1; rm -f /var/log/mrm-backup.log /var/log/mrm-monitor.log >/dev/null 2>&1; rm -rf /var/log/ssl-manager /tmp/mrm_workspace /tmp/mrm-monitor-state /opt/mrm-manager >/dev/null 2>&1; ui_spinner_stop
    ui_success "Uninstall completed"; echo -e "${CYAN}Backups kept: /root/mrm-backups${NC}"; read -p "Press Enter..."; clear; exit 0
}
optimize_network() {
    ui_header "NETWORK OPTIMIZATION"
    ui_spinner_start "Enabling BBR..."; grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf; grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf; ui_spinner_stop; ui_success "BBR Enabled"
    ui_spinner_start "Tuning TCP..."; cat <<EOF > /etc/sysctl.d/99-mrm-speed.conf
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
    sysctl -p /etc/sysctl.d/99-mrm-speed.conf >/dev/null 2>&1; sysctl --system >/dev/null 2>&1; ui_spinner_stop; ui_success "TCP Tuned"
    ui_spinner_start "Increasing limits..."; grep -q "^\* soft nofile 1000000" /etc/security/limits.conf || { echo "* soft nofile 1000000" >> /etc/security/limits.conf; echo "* hard nofile 1000000" >> /etc/security/limits.conf; echo "root soft nofile 1000000" >> /etc/security/limits.conf; echo "root hard nofile 1000000" >> /etc/security/limits.conf; }; ui_spinner_stop; ui_success "Limits Increased"; echo ""; ui_success "Complete!"; pause
}
auto_fix() {
    local FIREWALL_APPLIED=false ENV_FIXED=false RESTART_TARGET_FOUND=false
    ui_header "AUTO FIX"
    ui_spinner_start "Firewall..."; if command -v ufw >/dev/null 2>&1; then ufw allow 22,80,443,2096,7431,6432,8443,2083,2097,8080/tcp >/dev/null 2>&1 && ufw --force enable >/dev/null 2>&1 && FIREWALL_APPLIED=true; fi; ui_spinner_stop
    [ "$FIREWALL_APPLIED" = true ] && ui_success "Firewall Fixed" || { command -v ufw >/dev/null 2>&1 || ui_warning "ufw not installed"; }
    ui_spinner_start "Fixing .env..."; if [ -f "$PANEL_ENV" ]; then sed -i 's|\(postgresql+asyncpg://[^"?]*\)\([\"\s]*\)$|\1?ssl=disable\2|' "$PANEL_ENV" && sed -i 's/\([^[:space:]]\)\(UVICORN_\)/\1\n\2/g' "$PANEL_ENV" && sed -i 's/\([^[:space:]]\)\(SSL_\)/\1\n\2/g' "$PANEL_ENV" && ENV_FIXED=true; fi; ui_spinner_stop
    [ "$ENV_FIXED" = true ] && ui_success ".env Fixed" || ui_warning ".env not fixed"
    ui_spinner_start "Restarting..."; [ -d "$PANEL_DIR" ] && { RESTART_TARGET_FOUND=true; restart_service "panel" >/dev/null 2>&1 || true; }; [ -d "$NODE_DIR" ] && { RESTART_TARGET_FOUND=true; restart_service "node" >/dev/null 2>&1 || true; }; ui_spinner_stop
    echo ""; ui_success "Auto Fix Complete!"; pause
}
panel_menu() {
    while true; do
        clear; ui_header "PANEL CONTROL v1.0.2"; detect_active_panel >/dev/null 2>&1 || true
        echo -e "Active: ${CYAN}$PANEL_DIR${NC} | Ver: $(cat /opt/mrm-manager/VERSION 2>/dev/null || echo 1.0.2)"; echo ""
        echo "1) 🔄 Restart Panel"; echo "2) ⏹️  Stop Panel"; echo "3) ▶️  Start Panel"; echo "4) 📋 View Logs"; echo "5) 👤 Create Admin"; echo "6) 🔑 Reset Admin Password"; echo "7) 📝 Edit .env"; echo "8) 📝 Edit docker-compose.yml"; echo ""; echo "0) ↩️  Back"; echo ""; read -p "Select: " OPT
        case $OPT in
            1) restart_service "panel"; pause ;; 2) run_panel_compose down && ui_success "Stopped" || ui_error "Failed"; pause ;; 3) run_panel_compose up -d && ui_success "Started" || ui_error "Failed"; pause ;; 4) show_panel_logs ;; 5) admin_create; pause ;; 6) admin_reset; pause ;; 7) edit_file "$PANEL_ENV" ;; 8) edit_panel_compose_file ;; 0) return ;; *) invalid_menu_option ;;
        esac
    done
}
tools_menu() {
    while true; do
        clear; ui_header "TOOLS v1.0.2"
        echo "1) 🌐 Domain Separator"; echo "2) 🎨 Theme Manager"; echo "3) ⚙️  Settings Center"; echo "4) 🩺 Diagnostics & Doctor"; echo "5) 🇮🇷 Iran / Offline Mode"; echo "6) ♻️  Restore Points"; echo ""; echo "7) ⚡ Optimize Network (BBR)"; echo "8) 🔧 Auto Fix"; echo "9) 🤖 Monitor & Alerts"; echo "10) 🩺 Doctor - Quick Check"; echo ""; echo "0) ↩️  Back"; echo ""; read -p "Select: " OPT
        case $OPT in
            1) domain_menu ;; 2) theme_menu ;; 3) settings_menu ;; 4) diagnostics_menu ;; 5) offline_menu ;; 6) safe_ops_menu ;; 7) optimize_network ;; 8) auto_fix ;; 9) bash /opt/mrm-manager/monitor.sh menu 2>/dev/null || { ui_error "monitor.sh not found"; pause; } ;; 10) clear; bash /opt/mrm-manager/diagnostics.sh doctor; pause ;; 0) return ;; *) invalid_menu_option ;;
        esac
    done
}
main_menu() {
    # FIX: Skip deps if env set (avoid hang after install)
    if [ -z "$MRM_SKIP_DEPS" ]; then
        check_root
        # FIX: Safe install_deps - no hang
        local NEED_INSTALL=false
        for CMD in certbot nginx python3 sqlite3 docker jq lsof curl nano socat tar unzip; do
            command -v "$CMD" >/dev/null 2>&1 || NEED_INSTALL=true
        done
        if [ "$NEED_INSTALL" = true ]; then
            if fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
                echo -e "${YELLOW}apt is locked, skipping dependency install${NC}"
                sleep 2
            else
                echo -e "${BLUE}[INFO] Installing dependencies...${NC}"
                timeout 60 apt-get update -qq >/dev/null 2>&1 || echo -e "${YELLOW}apt update failed/timeout, continuing...${NC}"
                timeout 120 apt-get install -y certbot lsof curl nano socat tar python3 nginx unzip jq sqlite3 -qq >/dev/null 2>&1 || true
                if ! command -v docker >/dev/null 2>&1; then
                    echo -e "${BLUE}[INFO] Installing Docker...${NC}"
                    timeout 120 curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || true
                fi
            fi
        fi
    fi

    while true; do
        clear
        local MRM_VER=$(cat /opt/mrm-manager/VERSION 2>/dev/null || echo "1.0.2")
        ui_header "MRM MANAGER v$MRM_VER" 50
        ui_status_bar 2>/dev/null || true
        declare -f mrm_render_home_dashboard >/dev/null 2>&1 && mrm_render_home_dashboard

        ui_section "MAIN MENU v$MRM_VER"
        echo "1) 🔐 SSL Certificates"
        echo "2) 💾 Backup & Restore (2MB Fixed)"
        echo "3) 🤖 Mirza Pro"
        echo "4) ⚙️  Panel Control"
        echo "5) 🛠️  Tools"
        echo "6) 🔄 Update MRM Manager"
        echo "7) 🗑️  Uninstall MRM Manager"
        echo ""
        echo "0) Exit"
        echo ""
        echo -e "${CYAN}Tip: mrm --version | mrm doctor | mrm monitor${NC}"
        echo ""
        read -p "Select: " OPT
        case $OPT in
            1) ssl_menu ;; 2) backup_menu ;; 3) mirza_menu ;; 4) panel_menu ;; 5) tools_menu ;; 6) bash -c "$(curl -sL https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/main/install.sh)"; pause ;; 7) uninstall_mrm_manager ;; 0) clear; echo -e "${GREEN}Goodbye! MRM v$MRM_VER${NC}"; exit 0 ;; *) invalid_menu_option ;;
        esac
    done
}

main_menu
