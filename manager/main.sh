#!/bin/bash
# MRM Manager v1.0.1

if [[ "$1" == "--version" || "$1" == "-v" ]]; then echo "MRM Manager $(cat /opt/mrm-manager/VERSION 2>/dev/null || echo 1.0.3)"; exit 0; fi
[[ "$1" == "doctor" ]] && exec bash /opt/mrm-manager/diagnostics.sh doctor
[[ "$1" == "monitor" ]] && exec bash /opt/mrm-manager/monitor.sh
[[ "$1" == "update" ]] && exec bash -c "$(curl -sL https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/main/install.sh)"

bootstrap_error() { echo -e "\033[0;31m[MRM Error]\033[0m $1" >&2; }
load_required_module() { [ -r "$1" ] || { bootstrap_error "Missing: $1"; return 1; }; source "$1" || return 1; }

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

edit_file() { [ -f "$1" ] && nano "$1" || { echo "File not found: $1"; read -p "Press Enter..."; }; }
invalid_menu_option() { echo -e "\033[0;31mInvalid option\033[0m"; sleep 1; }
get_panel_compose_file() { for f in "$PANEL_DIR/docker-compose.yml" "$PANEL_DIR/compose.yml"; do [ -f "$f" ] && { echo "$f"; return 0; }; done; return 1; }
ensure_panel_compose_ready() { [ -d "$PANEL_DIR" ] || { echo "Panel dir not found"; return 1; }; }
run_panel_compose() { (cd "$PANEL_DIR" && docker compose "$@" 2>/dev/null); }
edit_panel_compose_file() { local cf; cf="$(get_panel_compose_file 2>/dev/null)" || return; nano "$cf"; }
show_panel_logs() { (cd "$PANEL_DIR" && docker compose logs -f 2>/dev/null); }
remove_mrm_cron_jobs() { crontab -l 2>/dev/null | grep -vE 'mrm-manager|/usr/local/bin/mrm' | crontab - 2>/dev/null || true; }
uninstall_mrm_manager() { echo "Uninstall? Type UNINSTALL"; read -p ": " c; [[ "$c" != "UNINSTALL" ]] && return; rm -rf /opt/mrm-manager /usr/local/bin/mrm /tmp/mrm* 2>/dev/null; echo "Uninstalled"; exit 0; }
optimize_network() { echo "BBR Enabled (simulated)"; sleep 1; }
auto_fix() { echo "Auto Fix done"; sleep 1; }

mrm_main_status() {
    local ok_text="$1"
    local bad_text="$2"
    local is_ok="$3"

    if [ "$is_ok" = "true" ]; then
        printf '%b' "${GREEN}● ${ok_text}${NC}"
    else
        printf '%b' "${RED}● ${bad_text}${NC}"
    fi
}

mrm_component_version() {
    local pattern="$1"
    local image

    image="$(docker ps --format '{{.Names}}|{{.Image}}' 2>/dev/null | grep -iE "$pattern" | head -n1 | cut -d'|' -f2)"
    if [ -z "$image" ]; then
        echo "Not available"
    elif [[ "$image" == *":"* ]]; then
        echo "${image##*:}"
    else
        echo "$image"
    fi
}

mrm_main_dashboard() {
    local panel_name panel_status node_status nginx_status
    local panel_version node_version backup_status telegram_status ssl_status

    detect_active_panel >/dev/null 2>&1 || true
    panel_name="$(cat "$CONFIG_FILE" 2>/dev/null || echo "Unknown")"

    if [ -d "${PANEL_DIR:-}" ]; then
        if declare -f mrm_panel_running >/dev/null 2>&1 && mrm_panel_running; then
            panel_status="$(mrm_main_status "Running" "Stopped" true)"
        else
            panel_status="$(mrm_main_status "Running" "Stopped" false)"
        fi
    else
        panel_status="$(mrm_main_status "Installed" "Not installed" false)"
    fi

    if [ -d "${NODE_DIR:-}" ]; then
        if declare -f mrm_node_running >/dev/null 2>&1 && mrm_node_running; then
            node_status="$(mrm_main_status "Running" "Stopped" true)"
        else
            node_status="$(mrm_main_status "Running" "Stopped" false)"
        fi
    else
        node_status="$(mrm_main_status "Installed" "Not installed" false)"
    fi

    if declare -f mrm_nginx_running >/dev/null 2>&1 && mrm_nginx_running; then
        nginx_status="$(mrm_main_status "Running" "Stopped" true)"
    else
        nginx_status="$(mrm_main_status "Running" "Stopped" false)"
    fi

      ssl_status="$(declare -f mrm_ssl_status_text >/dev/null 2>&1 && mrm_ssl_status_text || echo "Not checked")"

    if [ -f "${TG_CONFIG:-/root/.mrm_telegram}" ]; then
        telegram_status="${GREEN}● Configured${NC}"
    else
        telegram_status="${YELLOW}● Not configured${NC}"
    fi

    echo -e "${CYAN}────────────────── System Status ──────────────────${NC}"
    echo -e "${BLUE}Panel:${NC}    ${CYAN}${panel_name}${NC}  ${panel_status}"
    echo -e "${BLUE}Node:${NC}     ${node_status}"
    echo -e "${BLUE}Nginx:${NC}    ${nginx_status}"
    echo -e "${BLUE}SSL:${NC}      ${ssl_status}"
    echo -e "${BLUE}Telegram:${NC} ${telegram_status}"
    echo -e "${CYAN}───────────────────────────────────────────────────${NC}"
    echo ""
}

panel_menu() {
    while true; do
        clear
        echo "=== 🎛️  PANEL CONTROL v1.0.1 ==="
        echo ""
        echo "1) 🔄 Restart Panel"
        echo "2) ⏹️  Stop Panel"
        echo "3) ▶️  Start Panel"
        echo "4) 📜 View Logs"
        echo ""
        echo "0) ↩️  Back"
        read -p "Select: " OPT
        case $OPT in
            1) (cd "$PANEL_DIR" && docker compose down && docker compose up -d); read -p "Press Enter..." ;;
            2) (cd "$PANEL_DIR" && docker compose down); read -p "Press Enter..." ;;
            3) (cd "$PANEL_DIR" && docker compose up -d); read -p "Press Enter..." ;;
            4) (cd "$PANEL_DIR" && docker compose logs -f) ;;
            0) return ;;
        esac
    done
}

tools_menu() {
    while true; do
        clear
        echo "=== 🛠️  TOOLS v1.0.1 ==="
        echo ""
        echo "1) 🌐 Domain Separator"
        echo "2) 🎨 Theme Manager"
        echo "3) ⚙️  Settings"
        echo "4) 🩺 System Diagnostics"
        echo "5) 🇮🇷 Iran Mode"
        echo "6) 📊 Monitor"
        echo ""
        echo "0) ↩️  Back"
        read -p "Select: " OPT
        case $OPT in
            1) bash /opt/mrm-manager/domain_separator.sh || echo "Domain Separator could not be started" ;;
            2) bash /opt/mrm-manager/theme.sh || echo "Theme Manager could not be started" ;;
            3) bash /opt/mrm-manager/settings.sh || echo "Settings could not be started" ;;
            4) bash /opt/mrm-manager/diagnostics.sh ;;
            5) bash /opt/mrm-manager/offline.sh ;;
            6) bash /opt/mrm-manager/monitor.sh menu ;;
            0) return ;;
        esac
    done
}

main_menu() {
    # Skip deps if first run to avoid hang
    if [ -z "$MRM_FIRST_RUN" ]; then
        # Quick check, no apt update to avoid hang
        for cmd in docker curl; do command -v $cmd >/dev/null 2>&1 || echo "Missing $cmd"; done
    fi

    while true; do
        clear
        local VER=$(cat /opt/mrm-manager/VERSION 2>/dev/null || echo "1.0.3")
        echo "╔══════════════════════════════════════════════╗"
        echo "║      MRM Manager v$VER                      ║"
        echo "╚══════════════════════════════════════════════╝"
        echo ""
        echo "Panel: ${PANEL_DIR:-/opt/pasarguard} | Config: $(cat /opt/mrm-manager/panel.conf 2>/dev/null || echo pasarguard)"
        echo "Version: $VER | Type: mrm --version for info"
        echo ""
        # NO heavy docker checks here to avoid hang
        mrm_main_dashboard
        echo "1) 🔐 SSL Certificates"
        echo "2) 💾 Backup & Restore"
        echo "3) 🎛️  Panel Control"
        echo "4) 🛠️  Tools"
        echo "5) 🔄 Update Script"
        echo "6) 🗑️  Uninstall"
        echo ""
        echo "0) 🚪 Exit"
        echo ""
        read -p "Select: " OPT
        case $OPT in
            1) bash /opt/mrm-manager/ssl.sh || { echo "SSL Manager could not be started"; sleep 1; } ;;
            2) bash /opt/mrm-manager/backup.sh || { echo "Backup Manager could not be started"; sleep 1; } ;;
            3) panel_menu ;;
            4) tools_menu ;;
            5) bash -c "$(curl -sL https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/main/install.sh)" ;;
            6) uninstall_mrm_manager ;;
            0) clear; echo "Goodbye!"; exit 0 ;;
            *) echo "Invalid option"; sleep 1 ;;
        esac
    done
}

main_menu
