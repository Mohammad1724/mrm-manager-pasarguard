#!/bin/bash
# MRM Manager — main entry point (CLI shortcuts + interactive menus)
# Version is loaded from a single source: versions.conf

set -o pipefail

MRM_DIR="${MRM_DIR:-/opt/mrm-manager}"
MRM_REPO_RAW="https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard"

# ─── Shared libraries ────────────────────────────────────────────────────────
bootstrap_error() { echo -e "\033[0;31m  ✘ MRM Manager:\033[0m $1" >&2; }

load_required_module() {
    [ -r "$1" ] || { bootstrap_error "Missing module: $1"; return 1; }
    # shellcheck source=/dev/null
    source "$1" || return 1
}

# utils/ui are mandatory — without them the whole app is broken (MRM-018)
load_required_module "$MRM_DIR/ui.sh" || {
    bootstrap_error "ui.sh missing — reinstall with: mrm update"
    exit 1
}
load_required_module "$MRM_DIR/utils.sh" || {
    bootstrap_error "utils.sh missing — reinstall with: mrm update"
    exit 1
}
[ -r "$MRM_DIR/versions.conf" ] && source "$MRM_DIR/versions.conf"
export MRM_VERSION="${MRM_VERSION:-$(get_mrm_version)}"

# ─── CLI shortcuts ───────────────────────────────────────────────────────────
mrm_usage() {
    echo ""
    echo -e "  ${BOLD}MRM Manager${NC} v${MRM_VERSION} — PasarGuard server toolkit"
    echo ""
    echo -e "  ${DIM}Usage:${NC} mrm [command] [options]"
    echo ""
    printf '  %b%-14s%b %s\n' "$CYAN" "(none)"     "$NC" "Interactive main menu"
    printf '  %b%-14s%b %s\n' "$CYAN" "theme"      "$NC" "Subscription templates (switch, brand, status)"
    printf '  %b%-14s%b %s\n' "$CYAN" "special"    "$NC" "MRM Special in-panel tab & integration"
    printf '  %b%-14s%b %s\n' "$CYAN" "backup"     "$NC" "Backup & restore database, xray & telegram"
    printf '  %b%-14s%b %s\n' "$CYAN" "ssl"        "$NC" "SSL certificate issuance & management"
    printf '  %b%-14s%b %s\n' "$CYAN" "domain"     "$NC" "Domain separator (panel / subscription)"
    printf '  %b%-14s%b %s\n' "$CYAN" "restart"    "$NC" "Quickly restart PasarGuard panel"
    printf '  %b%-14s%b %s\n' "$CYAN" "logs"       "$NC" "Follow live panel logs"
    printf '  %b%-14s%b %s\n' "$CYAN" "status"     "$NC" "Server & panel diagnostics dashboard"
    printf '  %b%-14s%b %s\n' "$CYAN" "health"     "$NC" "PasarGuard health report (nodes / TLS / jobs)"
    printf '  %b%-14s%b %s\n' "$CYAN" "doctor"     "$NC" "Quick health summary (exit 1 when critical)"
    printf '  %b%-14s%b %s\n' "$CYAN" "monitor"    "$NC" "Telegram monitoring & alerts"
    printf '  %b%-14s%b %s\n' "$CYAN" "temp-key"   "$NC" "Generate a one-time Owner setup key"
    printf '  %b%-14s%b %s\n' "$CYAN" "fix-node"   "$NC" "Repair the node xray-core binary"
    printf '  %b%-14s%b %s\n' "$CYAN" "repair-db"  "$NC" "Re-import ONLY the database from a backup (rescue)"
    printf '  %b%-14s%b %s\n' "$CYAN" "update"     "$NC" "Update MRM Manager to the latest release"
    printf '  %b%-14s%b %s\n' "$CYAN" "--version"  "$NC" "Print the installed version"
    echo ""
}

mrm_self_update() {
    # SECURITY: pinned-release update (MRM-001/MRM-012). Resolve the release
    # ref from versions.conf on main (parsed, never sourced), then download
    # install.sh from that exact ref — never from a mutable branch.
    local TMP_SCRIPT TMP_VERSION TMP_SUMS TARGET_REF=""
    TMP_SCRIPT=$(mktemp /tmp/mrm-update.XXXXXX.sh)
    TMP_VERSION=$(mktemp /tmp/mrm-version.XXXXXX)
    TMP_SUMS=$(mktemp /tmp/mrm-sums.XXXXXX)

    echo ""
    ui_step 1 3 "Resolving latest release"
    if curl -fsSL --connect-timeout 10 --max-time 60 \
        "$MRM_REPO_RAW/main/versions.conf" -o "$TMP_VERSION" 2>/dev/null; then
        TARGET_REF="v$(grep -E '^MRM_VERSION=' "$TMP_VERSION" 2>/dev/null | head -1 | cut -d'"' -f2)"
    fi
    rm -f "$TMP_VERSION"
    if [ -z "$TARGET_REF" ] || [ "$TARGET_REF" = "v" ]; then
        ui_error "Could not resolve the latest release version"
        rm -f "$TMP_SCRIPT" "$TMP_SUMS"
        return 1
    fi
    if ! printf '%s' "$TARGET_REF" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        ui_error "Unexpected release tag in versions.conf: ${TARGET_REF}"
        rm -f "$TMP_SCRIPT" "$TMP_SUMS"
        return 1
    fi
    ui_success "Latest release: ${TARGET_REF}  (installed: v${MRM_VERSION})"

    ui_step 2 3 "Downloading installer for ${TARGET_REF}"
    if ! curl -fsSL --connect-timeout 30 --max-time 120 \
        "$MRM_REPO_RAW/${TARGET_REF}/install.sh" -o "$TMP_SCRIPT" 2>/dev/null; then
        ui_error "Failed to download install.sh (ref ${TARGET_REF})"
        rm -f "$TMP_SCRIPT" "$TMP_SUMS"
        return 1
    fi
    if ! head -1 "$TMP_SCRIPT" | grep -q '^#!/bin/bash' || ! bash -n "$TMP_SCRIPT" 2>/dev/null; then
        ui_error "Downloaded installer failed syntax verification"
        rm -f "$TMP_SCRIPT" "$TMP_SUMS"
        return 1
    fi

    # SECURITY: the release ships checksums.txt — the installer must match the
    # SHA-256 recorded for that exact tag, otherwise nothing is executed.
    ui_step 3 3 "Verifying installer checksum"
    local EXPECTED ACTUAL
    if ! curl -fsSL --connect-timeout 30 --max-time 60 \
        "$MRM_REPO_RAW/${TARGET_REF}/checksums.txt" -o "$TMP_SUMS" 2>/dev/null; then
        ui_error "Failed to download checksums.txt (ref ${TARGET_REF})"
        rm -f "$TMP_SCRIPT" "$TMP_SUMS"
        return 1
    fi
    EXPECTED=$(awk '$2 == "install.sh" {print $1; exit}' "$TMP_SUMS")
    ACTUAL=$(sha256sum "$TMP_SCRIPT" | awk '{print $1}')
    rm -f "$TMP_SUMS"
    if [ -z "$EXPECTED" ] || [ "$EXPECTED" != "$ACTUAL" ]; then
        ui_error "Installer checksum mismatch — update aborted"
        ui_note "expected: ${EXPECTED:-missing}"
        ui_note "got:      ${ACTUAL}"
        rm -f "$TMP_SCRIPT"
        return 1
    fi
    ui_success "Installer verified (sha256 ok) — starting update"
    echo ""
    exec bash "$TMP_SCRIPT"
}

case "${1:-}" in
    --version|-v) echo "MRM Manager ${MRM_VERSION}"; exit 0 ;;
    help|--help|-h) mrm_usage; exit 0 ;;
    theme)    exec bash "$MRM_DIR/theme.sh" "${@:2}" ;;
    special)  exec bash "$MRM_DIR/special.sh" "${@:2}" ;;
    backup)   exec bash "$MRM_DIR/backup.sh" "${@:2}" ;;
    ssl)      exec bash "$MRM_DIR/ssl.sh" "${@:2}" ;;
    domain|domains) exec bash "$MRM_DIR/domain_separator.sh" "${@:2}" ;;
    doctor)   exec bash "$MRM_DIR/diagnostics.sh" doctor "${@:2}" ;;
    status|diagnostics) exec bash "$MRM_DIR/diagnostics.sh" "${@:2}" ;;
    monitor)  exec bash "$MRM_DIR/monitor.sh" ;;
    fix-node) exec bash "$MRM_DIR/backup.sh" fix-node "${@:2}" ;;
    repair-db) exec bash "$MRM_DIR/backup.sh" repair-db "${@:2}" ;;
    health)   exec bash "$MRM_DIR/pg_health.sh" ;;
    temp-key) exec bash "$MRM_DIR/pg_health.sh" temp-key ;;
    restart)
        detect_active_panel >/dev/null 2>&1 || true
        if [ -n "$PANEL_DIR" ] && (cd "$PANEL_DIR" && docker compose down && docker compose up -d); then
            ui_success "Panel restarted successfully"
        else
            ui_error "Failed to restart panel at ${PANEL_DIR:-unknown}"
            exit 1
        fi
        exit 0 ;;
    logs)
        detect_active_panel >/dev/null 2>&1 || true
        if [ -n "$PANEL_DIR" ]; then
            exec docker compose -f "$PANEL_DIR/docker-compose.yml" logs -f
        else
            ui_error "Panel directory not detected"
            exit 1
        fi ;;
    update)   mrm_self_update; exit $? ;;
    "") ;;
    *) ui_error "Unknown command: $1"; mrm_usage; exit 1 ;;
esac

# ─── Feature modules (interactive mode only) ─────────────────────────────────
load_required_module "$MRM_DIR/ssl.sh"
load_required_module "$MRM_DIR/backup.sh"
load_required_module "$MRM_DIR/domain_separator.sh"
load_required_module "$MRM_DIR/theme.sh"
load_required_module "$MRM_DIR/diagnostics.sh"
load_required_module "$MRM_DIR/offline.sh"
load_required_module "$MRM_DIR/monitor.sh" || true

detect_active_panel > /dev/null 2>&1 || true

# ─── Helpers ─────────────────────────────────────────────────────────────────

mrm_home_subtitle() {
    local PANEL HOST
    PANEL="$(cat "$CONFIG_FILE" 2>/dev/null || echo "pasarguard")"
    HOST="$(hostname 2>/dev/null || echo "server")"
    if declare -f mrm_panel_installed >/dev/null 2>&1 && ! mrm_panel_installed; then
        if declare -f mrm_node_installed >/dev/null 2>&1 && mrm_node_installed; then
            printf 'Host: %s · Node server · %s' "$HOST" "${NODE_DIR:-/opt/pg-node}"
        else
            printf 'Host: %s · Panel: not installed' "$HOST"
        fi
        return 0
    fi
    printf 'Host: %s · Panel: %s · Data: %s' "$HOST" "$PANEL" "${DATA_DIR:-/var/lib/pasarguard}"
}

uninstall_mrm_manager() {
    ui_header "Uninstall MRM Manager"
    ui_text "This removes MRM Manager itself:"
    ui_bullet "$MRM_DIR and the ${BOLD}mrm${NC} command"
    ui_bullet "MRM cron jobs (backup schedule, monitor)"
    echo ""
    ui_note "PasarGuard, your backups, certificates and templates are NOT touched."
    echo ""
    if ! ui_confirm_word "UNINSTALL" "Remove MRM Manager?"; then
        ui_cancelled
        sleep 1
        return
    fi
    # Remove MRM cron jobs BEFORE removing files, otherwise they keep logging
    # "No such file" forever (MRM-014).
    crontab -l 2>/dev/null | grep -v -E "mrm-manager|/usr/local/bin/mrm" | crontab - 2>/dev/null || true
    rm -rf "$MRM_DIR" /usr/local/bin/mrm /tmp/mrm* 2>/dev/null
    echo ""
    ui_success "MRM Manager has been removed."
    echo ""
    exit 0
}

# ─── Menus ───────────────────────────────────────────────────────────────────

panel_menu() {
    local OPT
    while true; do
        ui_header "Panel Control" "Compose: ${PANEL_DIR:-unknown}"
        if declare -f mrm_panel_running >/dev/null 2>&1 && mrm_panel_running; then
            ui_kv_state "Panel" ok "Running"
        else
            ui_kv_state "Panel" bad "Stopped"
        fi
        echo ""
        ui_menu_item 1 "Restart panel"
        ui_menu_item 2 "Stop panel"
        ui_menu_item 3 "Start panel"
        ui_menu_item 4 "Follow logs" "Ctrl+C to return"
        ui_menu_back
        ui_select OPT
        case "$OPT" in
            1)
                if (cd "$PANEL_DIR" 2>/dev/null && docker compose down && docker compose up -d); then
                    ui_success "Panel restarted"
                else
                    ui_error "Restart failed — check that $PANEL_DIR contains a docker-compose.yml"
                fi
                ui_pause ;;
            2)
                if (cd "$PANEL_DIR" 2>/dev/null && docker compose down); then
                    ui_success "Panel stopped"
                else
                    ui_error "Stop failed — check that $PANEL_DIR exists"
                fi
                ui_pause ;;
            3)
                if (cd "$PANEL_DIR" 2>/dev/null && docker compose up -d); then
                    ui_success "Panel started"
                else
                    ui_error "Start failed — check that $PANEL_DIR exists"
                fi
                ui_pause ;;
            4)
                if [ -d "$PANEL_DIR" ]; then
                    (cd "$PANEL_DIR" && docker compose logs -f)
                else
                    ui_error "Panel directory not found: $PANEL_DIR"
                    ui_pause
                fi ;;
            0) return ;;
            *) ui_invalid ;;
        esac
    done
}

tools_menu() {
    local OPT
    while true; do
        ui_header "Tools & Diagnostics"
        ui_menu_item 1 "Domain Separator" "separate panel and subscription domains"
        ui_menu_item 2 "Theme Manager" "subscription page templates"
        ui_menu_item 3 "MRM Special" "in-panel integration & settings"
        ui_menu_item 4 "Diagnostics Dashboard" "system and panel status"
        ui_menu_item 5 "Health Check & Doctor" "PasarGuard health report"
        ui_menu_item 6 "Iran / Offline Mode" "mirrors and local installs"
        ui_menu_item 7 "Monitor & Alerts" "Telegram alerts"
        ui_menu_back
        ui_select OPT
        case "$OPT" in
            1) bash "$MRM_DIR/domain_separator.sh" || { ui_error "Domain Separator could not be started"; sleep 1; } ;;
            2) bash "$MRM_DIR/theme.sh" || { ui_error "Theme Manager could not be started"; sleep 1; } ;;
            3) bash "$MRM_DIR/special.sh" || { ui_error "MRM Special could not be started"; sleep 1; } ;;
            4) bash "$MRM_DIR/diagnostics.sh" ;;
            5) bash "$MRM_DIR/pg_health.sh" ;;
            6) bash "$MRM_DIR/offline.sh" ;;
            7) bash "$MRM_DIR/monitor.sh" menu ;;
            0) return ;;
            *) ui_invalid ;;
        esac
    done
}

main_menu() {
    local OPT MISSING=""
    # Quick dependency check on first run
    if [ -z "${MRM_FIRST_RUN:-}" ]; then
        for cmd in docker curl; do command -v "$cmd" >/dev/null 2>&1 || MISSING+=" $cmd"; done
    fi

    while true; do
        ui_header "Main Menu" "$(mrm_home_subtitle)"
        if declare -f mrm_status_panel >/dev/null 2>&1; then
            mrm_status_panel
        fi
        [ -n "$MISSING" ] && { ui_warning "Missing tools:${MISSING}"; echo ""; }
        ui_menu_item 1 "Subscription Templates" "MRM Special & Classic switcher, branding"
        ui_menu_item 2 "In-Panel Integration" "MRM Special tab, theme studio, API bridge"
        ui_menu_item 3 "SSL Certificates" "issue, renew, multi-domain certificates"
        ui_menu_item 4 "Backup & Restore" "database, xray, auto-backup, Telegram"
        ui_menu_item 5 "Panel Control" "restart, stop, start, live logs"
        ui_menu_item 6 "Tools & Diagnostics" "domain separator, monitor, health doctor"
        ui_menu_item 7 "Update MRM Manager"
        ui_menu_item 8 "Uninstall MRM Manager"
        ui_menu_back "Exit"
        ui_select OPT
        case "$OPT" in
            1) bash "$MRM_DIR/theme.sh" || { ui_error "Theme Manager could not be started"; sleep 1; } ;;
            2) bash "$MRM_DIR/special.sh" || { ui_error "MRM Special could not be started"; sleep 1; } ;;
            3) bash "$MRM_DIR/ssl.sh" || { ui_error "SSL Manager could not be started"; sleep 1; } ;;
            4) bash "$MRM_DIR/backup.sh" || { ui_error "Backup Manager could not be started"; sleep 1; } ;;
            5) panel_menu ;;
            6) tools_menu ;;
            7) # single update path — fixes apply in one place (MRM-015)
                bash "$MRM_DIR/main.sh" update
                ui_pause ;;
            8) uninstall_mrm_manager ;;
            0) ui_clear; echo ""; ui_note "Goodbye."; echo ""; exit 0 ;;
            *) ui_invalid ;;
        esac
    done
}

main_menu
