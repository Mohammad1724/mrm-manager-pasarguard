#!/bin/bash
# MRM Manager - Main Entry Point
# Version loaded from single source: versions.conf

set -o pipefail

# CLI shortcuts
if [[ "$1" == "--version" || "$1" == "-v" ]]; then
    source /opt/mrm-manager/versions.conf 2>/dev/null || true
    echo "MRM Manager ${MRM_VERSION:-$(cat /opt/mrm-manager/VERSION 2>/dev/null || echo 1.1.15)}"
    exit 0
fi
[[ "$1" == "doctor" ]] && exec bash /opt/mrm-manager/diagnostics.sh doctor "${@:2}"
[[ "$1" == "monitor" ]] && exec bash /opt/mrm-manager/monitor.sh
[[ "$1" == "fix-node" ]] && exec bash /opt/mrm-manager/backup.sh fix-node "${@:2}"
[[ "$1" == "health" ]] && exec bash /opt/mrm-manager/pg_health.sh
[[ "$1" == "temp-key" ]] && exec bash /opt/mrm-manager/pg_health.sh temp-key
[[ "$1" == "update" ]] && {
    # SECURITY: pinned-release update (MRM-001/MRM-012). Resolve the release
    # ref from versions.conf on main (parsed, never sourced), then download
    # install.sh from that exact ref — never from a mutable branch.
    _MRM_UPDATE_TMP=$(mktemp /tmp/mrm-update.XXXXXX.sh)
    _MRM_VERSION_FILE=$(mktemp /tmp/mrm-version.XXXXXX)
    if curl -fsSL --connect-timeout 10 --max-time 60 \
        "https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/main/versions.conf" \
        -o "$_MRM_VERSION_FILE" 2>/dev/null; then
        _MRM_TARGET_REF="v$(grep -E '^MRM_VERSION=' "$_MRM_VERSION_FILE" 2>/dev/null | head -1 | cut -d'"' -f2)"
    fi
    rm -f "$_MRM_VERSION_FILE"
    if [ -z "${_MRM_TARGET_REF:-}" ]; then
        echo -e "\033[0;31m[ERROR] Could not resolve release version for update\033[0m" >&2
        rm -f "$_MRM_UPDATE_TMP"
        exit 1
    fi
    if curl -fsSL --connect-timeout 30 --max-time 120 \
        "https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/${_MRM_TARGET_REF}/install.sh" \
        -o "$_MRM_UPDATE_TMP" 2>/dev/null; then
        # Verify it's a valid bash script
        if head -1 "$_MRM_UPDATE_TMP" | grep -q '^#!/bin/bash' && \
           bash -n "$_MRM_UPDATE_TMP" 2>/dev/null; then
            exec bash "$_MRM_UPDATE_TMP"
        else
            echo -e "\033[0;31m[ERROR] Downloaded script failed syntax verification\033[0m" >&2
            rm -f "$_MRM_UPDATE_TMP"
            exit 1
        fi
    else
        echo -e "\033[0;31m[ERROR] Failed to download update (ref ${_MRM_TARGET_REF})\033[0m" >&2
        rm -f "$_MRM_UPDATE_TMP"
        exit 1
    fi
}

# ─── Module Loader ───────────────────────────────────────────────────────────
bootstrap_error() { echo -e "\033[0;31m[MRM Error]\033[0m $1" >&2; }

load_required_module() {
    [ -r "$1" ] || { bootstrap_error "Missing: $1"; return 1; }
    source "$1" || return 1
}

# Core modules (order matters: utils first, then ui, then features)
# utils/ui are mandatory — without them the whole app is broken (MRM-018)
load_required_module "/opt/mrm-manager/utils.sh" || {
    bootstrap_error "utils.sh missing — reinstall with: mrm update"
    exit 1
}
load_required_module "/opt/mrm-manager/ui.sh" || {
    bootstrap_error "ui.sh missing — reinstall with: mrm update"
    exit 1
}
load_required_module "/opt/mrm-manager/ssl.sh"
load_required_module "/opt/mrm-manager/backup.sh"
load_required_module "/opt/mrm-manager/domain_separator.sh"
load_required_module "/opt/mrm-manager/theme.sh"
load_required_module "/opt/mrm-manager/diagnostics.sh"
load_required_module "/opt/mrm-manager/offline.sh"
load_required_module "/opt/mrm-manager/monitor.sh" || true

[ -r "/opt/mrm-manager/versions.conf" ] && source /opt/mrm-manager/versions.conf

detect_active_panel > /dev/null 2>&1 || true

# ─── Helpers ─────────────────────────────────────────────────────────────────

invalid_menu_option() { echo -e "\033[0;31mInvalid option\033[0m"; sleep 1; }

uninstall_mrm_manager() {
    echo "Uninstall? Type UNINSTALL"
    read -p ": " c
    [[ "$c" != "UNINSTALL" ]] && return
    # Remove MRM cron jobs (backup schedule + monitor) BEFORE removing files,
    # otherwise they keep logging "No such file" forever (MRM-014).
    crontab -l 2>/dev/null | grep -v -E "mrm-manager|/usr/local/bin/mrm" | crontab - 2>/dev/null || true
    rm -rf /opt/mrm-manager /usr/local/bin/mrm /tmp/mrm* 2>/dev/null
    echo "Uninstalled"
    exit 0
}

# ─── Dashboard Status Components ─────────────────────────────────────────────

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
    echo -e "${BLUE}Panel:${NC} ${CYAN}${panel_name}${NC} ${panel_status}"
    echo -e "${BLUE}Node:${NC} ${node_status}"
    echo -e "${BLUE}Nginx:${NC} ${nginx_status}"
    echo -e "${BLUE}SSL:${NC} ${ssl_status}"
    echo -e "${BLUE}Telegram:${NC} ${telegram_status}"
    echo -e "${CYAN}───────────────────────────────────────────────────${NC}"
    echo ""
}

# ─── Menus ───────────────────────────────────────────────────────────────────

panel_menu() {
    while true; do
        clear
        echo "=== 🎛️ PANEL CONTROL v${MRM_VERSION:-1.1.15} ==="
        echo ""
        echo "1) 🔄 Restart Panel"
        echo "2) ⏹️ Stop Panel"
        echo "3) ▶️ Start Panel"
        echo "4) 📜 View Logs"
        echo ""
        echo "0) ↩️ Back"
        read -p "Select: " OPT
        case $OPT in
            1) (cd "$PANEL_DIR" 2>/dev/null && docker compose down && docker compose up -d) || echo -e "\033[0;31mFailed to restart panel (check: $PANEL_DIR exists, docker-compose.yml present)\033[0m"; read -p "Press Enter..." ;;
            2) (cd "$PANEL_DIR" 2>/dev/null && docker compose down) || echo -e "\033[0;31mFailed to stop panel (check: $PANEL_DIR exists)\033[0m"; read -p "Press Enter..." ;;
            3) (cd "$PANEL_DIR" 2>/dev/null && docker compose up -d) || echo -e "\033[0;31mFailed to start panel (check: $PANEL_DIR exists)\033[0m"; read -p "Press Enter..." ;;
            4) (cd "$PANEL_DIR" 2>/dev/null || exit 1) && docker compose logs -f || echo -e "\033[0;31mPanel dir not found: $PANEL_DIR\033[0m" ;;
            0) return ;;
        esac
    done
}

tools_menu() {
    while true; do
        clear
        echo "=== 🛠️ TOOLS v${MRM_VERSION:-1.1.15} ==="
        echo ""
        echo "1) 🌐 Domain Separator"
        echo "2) 🎨 Theme Manager"
        echo "3) 🩺 System Diagnostics"
        echo "4) 🇮🇷 Iran Mode"
        echo "5) 📊 Monitor"
        echo "6) ❤️  PasarGuard Health (nodes / TLS / jobs)"
        echo ""
        echo "0) ↩️ Back"
        read -p "Select: " OPT
        case $OPT in
            1) bash /opt/mrm-manager/domain_separator.sh || echo "Domain Separator could not be started" ;;
            2) bash /opt/mrm-manager/theme.sh || echo "Theme Manager could not be started" ;;
            3) bash /opt/mrm-manager/diagnostics.sh ;;
            4) bash /opt/mrm-manager/offline.sh ;;
            5) bash /opt/mrm-manager/monitor.sh menu ;;
            6) bash /opt/mrm-manager/pg_health.sh ;;
            0) return ;;
        esac
    done
}

main_menu() {
    # Quick check for deps on first run
    if [ -z "$MRM_FIRST_RUN" ]; then
        for cmd in docker curl; do command -v $cmd >/dev/null 2>&1 || echo "Missing $cmd"; done
    fi

    while true; do
        clear
        local VER="${MRM_VERSION:-$(cat /opt/mrm-manager/VERSION 2>/dev/null || echo "1.1.1")}"
        echo "╔══════════════════════════════════════════════╗"
        echo "║ MRM Manager v$VER                            ║"
        echo "╚══════════════════════════════════════════════╝"
        echo ""
        mrm_main_dashboard
        echo "1) 🔐 SSL Certificates"
        echo "2) 💾 Backup & Restore"
        echo "3) 🎛️ Panel Control"
        echo "4) 🛠️ Tools"
        echo "5) 🔄 Update Script"
        echo "6) 🗑️ Uninstall"
        echo ""
        echo "0) 🚪 Exit"
        echo ""
        read -p "Select: " OPT
        case $OPT in
            1) bash /opt/mrm-manager/ssl.sh || { echo "SSL Manager could not be started"; sleep 1; } ;;
            2) bash /opt/mrm-manager/backup.sh || { echo "Backup Manager could not be started"; sleep 1; } ;;
            3) panel_menu ;;
            4) tools_menu ;;
            5) # single update path — fixes apply in one place (MRM-015)
                bash /opt/mrm-manager/main.sh update
                ;;
            6) uninstall_mrm_manager ;;
            0) clear; echo "Goodbye!"; exit 0 ;;
            *) echo "Invalid option"; sleep 1 ;;
        esac
    done
}

main_menu
