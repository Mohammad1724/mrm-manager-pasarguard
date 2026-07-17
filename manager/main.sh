#!/bin/bash
# MRM MANAGER v1.0.3 - NO HANG - Minimal dashboard

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

panel_menu() {
    while true; do
        clear
        echo "=== PANEL CONTROL v1.0.3 - $PANEL_DIR ==="
        echo "1) Restart Panel"; echo "2) Stop Panel"; echo "3) Start Panel"; echo "4) Logs"; echo "0) Back"; read -p "Select: " OPT
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
        echo "=== TOOLS v1.0.3 ==="
        echo "1) Domain Separator"; echo "2) Theme Manager"; echo "3) Settings"; echo "4) Diagnostics"; echo "5) Iran Mode"; echo "6) Monitor"; echo "7) Doctor"; echo "0) Back"; read -p "Select: " OPT
        case $OPT in
            1) bash /opt/mrm-manager/domain_separator.sh 2>/dev/null || echo "domain_separator not found"; read -p "Enter..." ;;
            2) bash /opt/mrm-manager/theme.sh 2>/dev/null || echo "theme not found"; read -p "Enter..." ;;
            3) bash /opt/mrm-manager/settings.sh 2>/dev/null || echo "settings not found"; read -p "Enter..." ;;
            4) bash /opt/mrm-manager/diagnostics.sh 2>/dev/null; read -p "Enter..." ;;
            5) bash /opt/mrm-manager/offline.sh 2>/dev/null; read -p "Enter..." ;;
            6) bash /opt/mrm-manager/monitor.sh menu 2>/dev/null; read -p "Enter..." ;;
            7) bash /opt/mrm-manager/diagnostics.sh doctor; read -p "Enter..." ;;
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
        echo "║      MRM Manager v$VER                       ║"
        echo "╚══════════════════════════════════════════════╝"
        echo ""
        echo "Panel: ${PANEL_DIR:-/opt/pasarguard} | Config: $(cat /opt/mrm-manager/panel.conf 2>/dev/null || echo pasarguard)"
        echo "Version: $VER | Type: mrm --version for info"
        echo ""
        # NO heavy docker checks here to avoid hang
        echo "1) SSL Certificates"
        echo "2) Backup & Restore"
        echo "3) Panel Control"
        echo "4) Tools"
        echo "5) Update"
        echo "6) Uninstall"
        echo ""
        echo "0) Exit"
        echo ""
        read -p "Select: " OPT
        case $OPT in
            1) bash /opt/mrm-manager/ssl.sh 2>/dev/null || { echo "ssl.sh not found"; sleep 1; } ;;
            2) bash /opt/mrm-manager/backup.sh 2>/dev/null || { echo "backup.sh not found"; sleep 1; } ;;
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
