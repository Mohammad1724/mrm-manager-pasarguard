#!/bin/bash
# MRM Manager diagnostics.sh — status panel, doctor report, service restarts

# ─── Shared libraries ────────────────────────────────────────────────────────
MRM_DIR="${MRM_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)}"
[ -r "$MRM_DIR/utils.sh" ] || MRM_DIR="/opt/mrm-manager"
# shellcheck source=/dev/null
declare -f load_panel_config >/dev/null 2>&1 || source "$MRM_DIR/utils.sh"
# shellcheck source=/dev/null
declare -f ui_header >/dev/null 2>&1 || source "$MRM_DIR/ui.sh"
# shellcheck source=/dev/null
if ! declare -f mrm_create_restore_point >/dev/null 2>&1 && [ -r "$MRM_DIR/safe_ops.sh" ]; then source "$MRM_DIR/safe_ops.sh"; fi
# Monitor helpers are reused for health checks
# shellcheck source=/dev/null
if [ -r "$MRM_DIR/monitor.sh" ]; then source "$MRM_DIR/monitor.sh" 2>/dev/null || true; fi

mrm_panel_running() {
    # Fast path: the official pasarguard/panel image is up (MRM-087 — an exact
    # image match, so pasarguard-node/exporter containers never count as the
    # panel). Compose state is only consulted for custom image names.
    docker ps --format '{{.Image}}' 2>/dev/null | grep -qE "^pasarguard/panel(:|$)" && return 0
    local COMPOSE_FILE
    COMPOSE_FILE="$(get_panel_compose_file 2>/dev/null || true)"
    [ -n "$COMPOSE_FILE" ] && docker compose -f "$COMPOSE_FILE" ps 2>/dev/null | grep -q "Up"
}

mrm_node_running() {
    # Same strategy as mrm_panel_running for the official pasarguard/node image
    # (MRM-087/MRM-039: the old "pg-node" pattern never matched pasarguard-node-1).
    docker ps --format '{{.Image}}' 2>/dev/null | grep -qE "^pasarguard/node(:|$)" && return 0
    local COMPOSE_FILE
    COMPOSE_FILE="$(get_node_compose_file 2>/dev/null || true)"
    [ -n "$COMPOSE_FILE" ] && docker compose -f "$COMPOSE_FILE" ps 2>/dev/null | grep -q "Up"
}

mrm_nginx_running() {
    systemctl is-active nginx >/dev/null 2>&1 || pgrep nginx >/dev/null 2>&1
}

mrm_theme_enabled() {
    # FIX: anchor the key and ignore commented lines (MRM-090) — the official
    # .env.example ships "CUSTOM_TEMPLATES_DIRECTORY" commented out, so a plain
    # grep would report Theme "Active" for a default install
    [ -f "$PANEL_ENV" ] && grep -qE "^[[:space:]]*CUSTOM_TEMPLATES_DIRECTORY[[:space:]]*=" "$PANEL_ENV" 2>/dev/null
}

mrm_domain_split_enabled() {
    [ -f "/etc/nginx/conf.d/panel_separate.conf" ]
}

# 20260916_123942_telegram-settings-remove → "2026-09-16 12:39 — telegram-settings-remove"
mrm_format_restore_point() {
    local ID="$1"
    if [[ "$ID" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})[0-9]{2}_(.+)$ ]]; then
        printf '%s-%s-%s %s:%s — %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
            "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}"
    else
        printf '%s' "$ID"
    fi
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

# Prints "<mode> <text>" for the SSL row: ok|warn|bad + label
mrm_ssl_state() {
    local CERT_COUNT
    CERT_COUNT="$(mrm_ssl_cert_count)"
    if [ "$CERT_COUNT" -gt 0 ] 2>/dev/null; then
        if [ "$CERT_COUNT" -eq 1 ]; then echo "ok 1 certificate"; else echo "ok ${CERT_COUNT} certificates"; fi
    elif grep -qE "^[[:space:]]*(UVICORN_SSL_CERTFILE|UVICORN_SSL_KEYFILE)[[:space:]]*=" "$PANEL_ENV" "$NODE_ENV" 2>/dev/null; then
        echo "warn Custom certificate path"
    else
        echo "bad No certificates"
    fi
}

mrm_ssl_status_text() {
    local STATE; STATE="$(mrm_ssl_state)"
    ui_state "${STATE%% *}" "${STATE#* }"
}

mrm_backup_dir() {
    printf '%s\n' "${BACKUP_DIR:-/root/mrm-backups}"
}

mrm_latest_backup_file() {
    local DIR
    DIR="$(mrm_backup_dir)"
    # FIX: skip pre_restore_* safety copies (MRM-089) — they are created during
    # restore and are always newer than the last real backup, so they must not
    # be shown as "Latest backup"
    find "$DIR" -maxdepth 1 -name '*.tar.gz' ! -name 'pre_restore_*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-
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
    # Legacy signature: OK_TEXT BAD_TEXT MODE — now rendered through ui_state
    local OK_TEXT="$1" BAD_TEXT="$2" MODE="$3"
    case "$MODE" in
        ok|warn) ui_state "$MODE" "$OK_TEXT" ;;
        *)       ui_state bad "$BAD_TEXT" ;;
    esac
}

mrm_check_disk() {
    local USAGE
    USAGE=$(df / | awk 'NR==2{print $5}' | tr -d '%')
    local FREE
    FREE=$(df -h / | awk 'NR==2{print $4}')
    echo "$USAGE $FREE"
}

mrm_check_ram() {
    free -m | awk 'NR==2{printf "%d %d %d", $3, $2, $3*100/$2 }'
}

mrm_check_cpu() {
    # FIX: report 100-idle, not the 'us' field (MRM-088) — awk '{print $2}'
    # took only the user CPU, under-reporting when sy/wa are busy (same
    # 100-idle parsing as monitor.sh)
    local CPU LOAD
    CPU=$(top -bn1 2>/dev/null | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}' | cut -d'.' -f1)
    [ -z "$CPU" ] && CPU=0
    LOAD=$(cat /proc/loadavg 2>/dev/null | awk '{print $1}')
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
    local IMAGES
    IMAGES=$(docker images --format '{{.Repository}}' 2>/dev/null | wc -l)
    local CONTAINERS
    CONTAINERS=$(docker ps -q 2>/dev/null | wc -l)
    local DANGLING
    DANGLING=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l)
    echo "ok $CONTAINERS $IMAGES $DANGLING"
}

mrm_check_panel_logs() {
    local COMPOSE_FILE="$1"
    local ERRORS=0
    if [ -n "$COMPOSE_FILE" ]; then
        ERRORS=$(docker compose -f "$COMPOSE_FILE" logs --tail 100 2>/dev/null | grep -iE "error|failed|exception|critical" | wc -l)
    else
        local CID
        CID=$(get_panel_container_id 2>/dev/null)
        if [ -n "$CID" ]; then
            ERRORS=$(docker logs "$CID" --tail 100 2>/dev/null | grep -iE "error|failed|exception|critical" | wc -l)
        fi
    fi
    echo "$ERRORS"
}

# ─── Shared status panel (main menu + diagnostics) ───────────────────────────
mrm_status_panel() {
    local PANEL_NAME DISK_INFO RAM_INFO CPU_INFO SSL THEME_TXT BK
    detect_active_panel > /dev/null 2>&1 || true
    PANEL_NAME="$(cat "$CONFIG_FILE" 2>/dev/null || echo pasarguard)"

    local PANEL_HERE=0 NODE_HERE=0
    mrm_panel_installed && PANEL_HERE=1
    mrm_node_installed && NODE_HERE=1

    # Panel
    if [ "$PANEL_HERE" -eq 1 ]; then
        if mrm_panel_running; then ui_kv_state "Panel" ok "Running" "$PANEL_NAME · $PANEL_DIR"
        else ui_kv_state "Panel" bad "Stopped" "$PANEL_NAME · $PANEL_DIR"; fi
    elif [ "$NODE_HERE" -eq 1 ]; then
        ui_kv_state "Panel" off "Not on this server" "node-only server"
    else
        ui_kv_state "Panel" off "Not installed" "${PANEL_DIR:-}"
    fi
    # Node (optional, usually on its own server)
    if [ "$NODE_HERE" -eq 1 ]; then
        if mrm_node_running; then ui_kv_state "Node" ok "Running" "$NODE_DIR"
        else ui_kv_state "Node" warn "Stopped" "$NODE_DIR"; fi
    else
        ui_kv_state "Node" off "Not on this server"
    fi
    # Nginx
    if mrm_nginx_running; then ui_kv_state "Nginx" ok "Running"; else ui_kv_state "Nginx" off "Not running"; fi
    # SSL
    SSL="$(mrm_ssl_state)"
    ui_kv_state "SSL" "${SSL%% *}" "${SSL#* }"
    # Backup
    BK="$(mrm_latest_backup_file)"
    if [ -n "$BK" ] && [ -f "$BK" ]; then
        ui_kv_state "Backup" ok "$(date -r "$BK" '+%Y-%m-%d %H:%M' 2>/dev/null)" "$(basename "$BK") · $(du -h "$BK" | cut -f1)"
    else
        ui_kv_state "Backup" warn "No backup yet"
    fi
    # Telegram
    if [ -f "${TG_CONFIG:-/root/.mrm_telegram}" ]; then ui_kv_state "Telegram" ok "Configured"; else ui_kv_state "Telegram" off "Not configured"; fi
    # Template / domain split — panel features, only meaningful where the panel lives
    if [ "$PANEL_HERE" -eq 1 ]; then
        if mrm_theme_enabled; then THEME_TXT="Custom template active"; ui_kv_state "Template" ok "$THEME_TXT"; else ui_kv_state "Template" off "PasarGuard default"; fi
    fi
    if mrm_domain_split_enabled; then
        if mrm_nginx_running; then ui_kv_state "Domains" ok "Panel / sub separated"
        else ui_kv_state "Domains" warn "Separation configured" "nginx is not running"; fi
    fi
    if declare -f mrm_latest_restore_point_text >/dev/null 2>&1; then
        local RP; RP="$(mrm_latest_restore_point_text 2>/dev/null)"
        [ -n "$RP" ] && [ "$RP" != "None" ] && ui_kv "Restore point" "$(mrm_format_restore_point "$RP")"
    fi
    # System
    DISK_INFO="$(mrm_check_disk)"; RAM_INFO="$(mrm_check_ram)"; CPU_INFO="$(mrm_check_cpu)"
    local DISK_USAGE="${DISK_INFO%% *}" DISK_FREE="${DISK_INFO#* }"
    local RAM_USED RAM_TOTAL LOAD
    RAM_USED="$(echo "$RAM_INFO" | awk '{print $1}')"
    RAM_TOTAL="$(echo "$RAM_INFO" | awk '{print $2}')"
    LOAD="${CPU_INFO#* }"
    local SYS="Disk ${DISK_USAGE}% · ${DISK_FREE} free · RAM ${RAM_USED}/${RAM_TOTAL} MB · Load ${LOAD:-?}"
    if [ "$DISK_USAGE" -gt 85 ] 2>/dev/null; then
        ui_kv_state "System" warn "$SYS"
    else
        ui_kv "System" "$SYS"
    fi
    echo ""
}

# Backwards-compatible name used by older callers
mrm_render_home_dashboard() { mrm_status_panel; }

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
    local PANEL_HERE=0 NODE_HERE=0 ROLE_TXT
    detect_active_panel > /dev/null
    mrm_panel_installed && PANEL_HERE=1
    mrm_node_installed && NODE_HERE=1
    if [ "$PANEL_HERE" -eq 1 ] && [ "$NODE_HERE" -eq 1 ]; then ROLE_TXT="panel + node"
    elif [ "$PANEL_HERE" -eq 1 ]; then ROLE_TXT="panel"
    elif [ "$NODE_HERE" -eq 1 ]; then ROLE_TXT="node-only"
    else ROLE_TXT="no panel or node detected"; fi
    ui_header "Doctor — Full System Diagnostics" "$(cat "$CONFIG_FILE" 2>/dev/null || echo unknown) · ${ROLE_TXT} · $(date '+%Y-%m-%d %H:%M')"

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
    if [ "$PANEL_HERE" -eq 1 ]; then
        diag_report_line ok "Active panel: $(cat "$CONFIG_FILE" 2>/dev/null || echo unknown) · $PANEL_DIR"
        [ -f "$PANEL_ENV" ] && diag_report_line ok "Panel .env found: $PANEL_ENV" || diag_report_line warn "Panel .env missing: ${PANEL_ENV:-unknown}"
        [ -n "$PANEL_COMPOSE" ] && diag_report_line ok "Panel compose file: $(basename "$PANEL_COMPOSE")" || diag_report_line warn "Panel compose file not found"
    elif [ "$NODE_HERE" -eq 1 ]; then
        diag_report_line info "Panel is not on this server (node-only server)"
    else
        diag_report_line warn "No panel installed here (expected ${PANEL_DIR:-/opt/pasarguard})"
    fi
    echo ""

    ui_section "Node Detection"
    if [ "$NODE_HERE" -eq 1 ]; then
        diag_report_line ok "Node directory: $NODE_DIR"
        [ -f "$NODE_ENV" ] && diag_report_line ok "Node .env found: $NODE_ENV" || diag_report_line warn "Node .env missing: ${NODE_ENV:-unknown}"
        [ -n "$NODE_COMPOSE" ] && diag_report_line ok "Node compose file: $(basename "$NODE_COMPOSE")" || diag_report_line warn "Node compose file not found"
    else
        diag_report_line info "No node on this server (${NODE_DIR:-unknown}) — optional"
    fi
    echo ""

    ui_section "Service Health"
    if [ "$PANEL_HERE" -eq 1 ]; then
        if mrm_panel_running; then diag_report_line ok "Panel containers are running"; else diag_report_line error "Panel containers are stopped — panel is DOWN"; fi
    fi
    if [ "$NODE_HERE" -eq 1 ]; then
        if mrm_node_running; then diag_report_line ok "Node containers are running"
        elif [ "$PANEL_HERE" -eq 1 ]; then diag_report_line warn "Node containers are stopped"
        else diag_report_line error "Node containers are stopped — node is DOWN"; fi
    fi
    if [ "$PANEL_HERE" -eq 0 ] && [ "$NODE_HERE" -eq 0 ]; then
        diag_report_line warn "Nothing to check — neither the panel nor a node is installed here"
    fi
    if command -v nginx >/dev/null 2>&1; then
        if mrm_nginx_running; then diag_report_line ok "Nginx is running"; else diag_report_line warn "Nginx is installed but not running"; fi
    else
        diag_report_line info "Nginx is not installed (only needed for domain separation / reverse proxy)"
    fi
    case "$DOCKER_INFO" in
        not_installed) diag_report_line error "Docker is not installed" ;;
        stopped) diag_report_line error "Docker daemon is stopped" ;;
        ok*)
            local CONTAINERS IMAGES DANGLING
            CONTAINERS=$(echo "$DOCKER_INFO" | awk '{print $2}')
            IMAGES=$(echo "$DOCKER_INFO" | awk '{print $3}')
            DANGLING=$(echo "$DOCKER_INFO" | awk '{print $4}')
            diag_report_line ok "Docker: $CONTAINERS containers · $IMAGES images"
            [ "$DANGLING" -gt 5 ] 2>/dev/null && diag_report_line warn "Dangling images: $DANGLING — run: docker system prune" ;;
    esac
    echo ""

    ui_section "System Resources"
    if [ "$DISK_USAGE" -gt 90 ] 2>/dev/null; then
        diag_report_line error "Disk usage critical: ${DISK_USAGE}% used · ${DISK_FREE} free"
    elif [ "$DISK_USAGE" -gt 80 ] 2>/dev/null; then
        diag_report_line warn "Disk usage high: ${DISK_USAGE}% used · ${DISK_FREE} free"
    else
        diag_report_line ok "Disk usage: ${DISK_USAGE}% used · ${DISK_FREE} free"
    fi
    if [ "${RAM_PERCENT%.*}" -gt 90 ] 2>/dev/null; then
        diag_report_line error "RAM usage high: ${RAM_USED}/${RAM_TOTAL} MB (${RAM_PERCENT}%)"
    elif [ "${RAM_PERCENT%.*}" -gt 80 ] 2>/dev/null; then
        diag_report_line warn "RAM usage: ${RAM_USED}/${RAM_TOTAL} MB (${RAM_PERCENT}%)"
    else
        diag_report_line ok "RAM usage: ${RAM_USED}/${RAM_TOTAL} MB (${RAM_PERCENT}%)"
    fi
    diag_report_line info "CPU load: $LOAD · CPU used: ${CPU_USED}% (approx.)"
    if dmesg --ctime 2>/dev/null | tail -n 20 | grep -qi "out of memory"; then
        diag_report_line warn "Kernel OOM killer seen in dmesg — check RAM"
    fi
    echo ""

    local LOG_ERRORS=0
    if [ "$PANEL_HERE" -eq 1 ]; then
        ui_section "Panel Logs — last 100 lines"
        LOG_ERRORS=$(mrm_check_panel_logs "$PANEL_COMPOSE")
        if [ "$LOG_ERRORS" -gt 10 ] 2>/dev/null; then
            diag_report_line error "Found $LOG_ERRORS errors in the panel logs"
            ui_note "Last errors:"
            if [ -n "$PANEL_COMPOSE" ]; then
                docker compose -f "$PANEL_COMPOSE" logs --tail 100 2>/dev/null | grep -iE "error|failed|exception|critical" | tail -n 5
            else
                local CID
                CID=$(get_panel_container_id 2>/dev/null)
                [ -n "$CID" ] && docker logs "$CID" --tail 100 2>/dev/null | grep -iE "error|failed|exception|critical" | tail -n 5
            fi
            echo ""
        elif [ "$LOG_ERRORS" -gt 0 ] 2>/dev/null; then
            diag_report_line warn "Found $LOG_ERRORS warnings/errors in the panel logs"
        else
            diag_report_line ok "No critical errors in the last 100 log lines"
        fi
        if [ ! -f "$PANEL_ENV" ]; then
            diag_report_line error "Panel .env missing — the panel cannot start"
        fi
        if [ -n "$PANEL_COMPOSE" ] && ! docker compose -f "$PANEL_COMPOSE" config >/dev/null 2>&1; then
            diag_report_line error "docker compose config is invalid — check $PANEL_COMPOSE"
        fi
        echo ""
    fi

    ui_section "Feature Health"
    [ "$CERT_COUNT" -gt 0 ] 2>/dev/null && diag_report_line ok "SSL certificates: $CERT_COUNT" || diag_report_line warn "No Let's Encrypt certificates found"
    if [ "$PANEL_HERE" -eq 1 ]; then
        mrm_theme_enabled && diag_report_line ok "Theme is active" || diag_report_line info "Theme is inactive"
        mrm_domain_split_enabled && diag_report_line ok "Domain separation is configured" || diag_report_line info "Domain separation is inactive"
        mrm_telegram_enabled && diag_report_line ok "Telegram backup is configured" || diag_report_line info "Telegram backup is not configured"
        [ -n "$(mrm_latest_backup_file)" ] && diag_report_line ok "Latest backup: $(mrm_latest_backup_text)" || diag_report_line warn "No backups found in $(mrm_backup_dir)"
    else
        diag_report_line info "Theme, domain separation and backups apply to the panel server"
    fi
    echo ""

    ui_section "Nginx & Network"
    if ! command -v nginx >/dev/null 2>&1; then
        diag_report_line info "Nginx is not installed — configuration test skipped"
    elif nginx -t >/dev/null 2>&1; then
        diag_report_line ok "Nginx configuration test passed"
    else
        diag_report_line error "Nginx configuration test failed"
        nginx -t 2>&1 | head -n 10 | sed "s/^/${UI_PAD}  /"
    fi
    local PORT LISTENING=""
    for PORT in 443 80 2096 7431 8000; do
        if ss -tln 2>/dev/null | grep -q ":$PORT "; then
            LISTENING="${LISTENING:+$LISTENING · }$PORT"
        fi
    done
    if [ -n "$LISTENING" ]; then diag_report_line info "Listening ports: $LISTENING"; else diag_report_line info "None of the usual ports (80, 443, 2096, 7431, 8000) are listening"; fi
    echo ""

    ui_section "Recommendations"
    local ADVICE=0
    if [ "$DISK_USAGE" -gt 80 ] 2>/dev/null; then diag_report_line warn "Free disk space: docker system prune · remove old backups in $(mrm_backup_dir)"; ADVICE=1; fi
    if [ "$LOG_ERRORS" -gt 5 ] 2>/dev/null; then diag_report_line warn "Inspect the panel logs: docker compose logs -f"; ADVICE=1; fi
    if [ "$PANEL_HERE" -eq 1 ] && ! mrm_panel_running; then diag_report_line error "Panel is DOWN — run: cd $PANEL_DIR && docker compose up -d"; ADVICE=1; fi
    if [ "$NODE_HERE" -eq 1 ] && ! mrm_node_running; then diag_report_line error "Node is DOWN — run: cd $NODE_DIR && docker compose up -d"; ADVICE=1; fi
    if command -v nginx >/dev/null 2>&1 && ! mrm_nginx_running && [ -f "/etc/nginx/conf.d/panel_separate.conf" ]; then diag_report_line warn "Nginx is down but domain separation is configured"; ADVICE=1; fi
    if [ "$PANEL_HERE" -eq 0 ] && [ "$NODE_HERE" -eq 0 ]; then diag_report_line warn "Install PasarGuard (panel or node) on this server, or run MRM on the right machine"; ADVICE=1; fi
    [ "$ADVICE" -eq 0 ] && diag_report_line ok "No action needed"
    ui_note "Run 'mrm monitor' to set up Telegram alerts for service-down / CPU / disk."
    ui_pause
}

run_doctor_cli() {
    detect_active_panel > /dev/null
    ui_header "MRM Doctor" "$(cat "$CONFIG_FILE" 2>/dev/null || echo unknown) · $(date '+%Y-%m-%d %H:%M:%S')"

    local DISK_INFO DISK_USAGE DISK_FREE RAM_INFO RAM_USED RAM_TOTAL RAM_PERCENT ERRORS
    DISK_INFO=$(mrm_check_disk)
    DISK_USAGE=$(echo "$DISK_INFO" | awk '{print $1}')
    DISK_FREE=$(echo "$DISK_INFO" | awk '{print $2}')
    RAM_INFO=$(mrm_check_ram)
    RAM_USED=$(echo "$RAM_INFO" | awk '{print $1}')
    RAM_TOTAL=$(echo "$RAM_INFO" | awk '{print $2}')
    RAM_PERCENT=$(echo "$RAM_INFO" | awk '{print $3}')

    local PANEL_HERE=0 NODE_HERE=0
    mrm_panel_installed && PANEL_HERE=1
    mrm_node_installed && NODE_HERE=1

    if [ "$PANEL_HERE" -eq 1 ]; then
        if mrm_panel_running; then ui_kv_state "Panel" ok "Running" "$PANEL_DIR"; else ui_kv_state "Panel" bad "Stopped" "$PANEL_DIR"; fi
    elif [ "$NODE_HERE" -eq 1 ]; then
        ui_kv_state "Panel" off "Not on this server" "node-only server"
    else
        ui_kv_state "Panel" off "Not installed" "${PANEL_DIR:-}"
    fi
    if [ "$NODE_HERE" -eq 1 ]; then
        if mrm_node_running; then ui_kv_state "Node" ok "Running" "$NODE_DIR"; else ui_kv_state "Node" bad "Stopped" "$NODE_DIR"; fi
    else
        ui_kv_state "Node" off "Not on this server"
    fi
    if ! command -v nginx >/dev/null 2>&1; then ui_kv_state "Nginx" off "Not installed"
    elif mrm_nginx_running; then ui_kv_state "Nginx" ok "Running"
    else ui_kv_state "Nginx" warn "Not running"; fi
    if command -v docker >/dev/null 2>&1; then ui_kv_state "Docker" ok "Installed"; else ui_kv_state "Docker" bad "Not installed"; fi
    if [ "$DISK_USAGE" -gt 90 ] 2>/dev/null; then ui_kv_state "Disk" bad "${DISK_USAGE}% used" "${DISK_FREE} free"
    elif [ "$DISK_USAGE" -gt 80 ] 2>/dev/null; then ui_kv_state "Disk" warn "${DISK_USAGE}% used" "${DISK_FREE} free"
    else ui_kv_state "Disk" ok "${DISK_USAGE}% used" "${DISK_FREE} free"; fi
    if [ "${RAM_PERCENT%.*}" -gt 90 ] 2>/dev/null; then ui_kv_state "RAM" warn "${RAM_USED}/${RAM_TOTAL} MB" "${RAM_PERCENT}%"
    else ui_kv_state "RAM" ok "${RAM_USED}/${RAM_TOTAL} MB" "${RAM_PERCENT}%"; fi
    if [ "$PANEL_HERE" -eq 1 ]; then
        ERRORS=$(mrm_check_panel_logs "$(get_panel_compose_file 2>/dev/null || true)")
        if [ "$ERRORS" -gt 10 ] 2>/dev/null; then ui_kv_state "Panel logs" bad "$ERRORS errors" "last 100 lines"
        elif [ "$ERRORS" -gt 0 ] 2>/dev/null; then ui_kv_state "Panel logs" warn "$ERRORS errors" "last 100 lines"
        else ui_kv_state "Panel logs" ok "No errors" "last 100 lines"; fi
    fi
    echo ""
    # The primary service is the panel where it is installed, otherwise the node.
    local SERVICE_DOWN=0
    if [ "$PANEL_HERE" -eq 1 ]; then mrm_panel_running || SERVICE_DOWN=1
    elif [ "$NODE_HERE" -eq 1 ]; then mrm_node_running || SERVICE_DOWN=1; fi
    if [ "$DISK_USAGE" -gt 90 ] 2>/dev/null || [ "$SERVICE_DOWN" -eq 1 ]; then
        ui_result bad "STATUS: CRITICAL — action required"
        return 1
    elif [ "$DISK_USAGE" -gt 80 ] 2>/dev/null || [ "${RAM_PERCENT%.*}" -gt 90 ] 2>/dev/null; then
        ui_result warn "STATUS: WARNING"
        return 0
    else
        ui_result ok "STATUS: OK"
        return 0
    fi
}

diagnostics_restart_nginx() {
    if ! command -v nginx >/dev/null 2>&1; then
        ui_warning "Nginx is not installed on this server"
    elif nginx -t >/dev/null 2>&1 && systemctl restart nginx >/dev/null 2>&1; then
        ui_success "Nginx restarted"
    else
        ui_error "Nginx restart failed"
        nginx -t 2>&1 | tail -n 5 | sed "s/^/${UI_PAD}  /"
    fi
    ui_pause
}

diagnostics_restart_panel() {
    if restart_service "panel"; then
        ui_success "Panel restarted"
    fi
    ui_pause
}

diagnostics_restart_node() {
    # PasarGuard nodes normally run on their OWN server and connect to the
    # panel via gRPC/rest — docker restart here only works for a co-located node.
    if [ -d "$NODE_DIR" ]; then
        if restart_service "node"; then
            ui_success "Node restarted"
        fi
    else
        ui_warning "No node directory on this server ($NODE_DIR) — restart the node on its own server."
    fi
    ui_pause
}

diagnostics_test_nginx() {
    if ! command -v nginx >/dev/null 2>&1; then
        ui_warning "Nginx is not installed on this server"
    elif nginx -t >/dev/null 2>&1; then
        ui_success "Nginx configuration is valid"
    else
        ui_error "Nginx configuration test failed"
        nginx -t 2>&1 | tail -n 10 | sed "s/^/${UI_PAD}  /"
    fi
    ui_pause
}

diagnostics_menu() {
    local OPT
    while true; do
        ui_header "Diagnostics & Doctor"
        mrm_status_panel
        ui_menu_item 1 "Run full doctor diagnostics"
        ui_menu_item 2 "Quick doctor" "compact status summary"
        ui_menu_item 3 "Restart panel"
        ui_menu_item 4 "Restart node" "only if the node runs on this server"
        ui_menu_item 5 "Test nginx configuration"
        ui_menu_item 6 "Restart nginx"
        ui_menu_item 7 "Monitor & alerts" "Telegram"
        ui_menu_back
        ui_select OPT
        case "$OPT" in
            1) run_full_diagnostics ;;
            2) ui_header "Quick Doctor"; run_doctor_cli; ui_pause ;;
            3) diagnostics_restart_panel ;;
            4) diagnostics_restart_node ;;
            5) diagnostics_test_nginx ;;
            6) diagnostics_restart_nginx ;;
            7)
                if [ -f "$MRM_DIR/monitor.sh" ]; then
                    bash "$MRM_DIR/monitor.sh" menu
                else
                    ui_error "monitor.sh not found — reinstall MRM Manager"
                    ui_pause
                fi
                ;;
            0) return ;;
            *) ui_invalid ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "${1:-}" == "doctor" ]]; then
        run_doctor_cli "${2:-}"
    else
        diagnostics_menu
    fi
fi
