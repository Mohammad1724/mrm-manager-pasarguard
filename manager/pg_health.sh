#!/bin/bash
# MRM Manager - PasarGuard Health
# Panel & node audit aligned with the official PasarGuard panel (v5.x):
#   - panel /health endpoint + TLS/CA sanity
#   - JOB_* intervals vs official defaults (.env.example / config.py)
#   - nodes table (status, keep_alive, timeouts, last error message)
#   - one-time owner temp key (official CLI: pasarguard-cli generate-temp-key)
# Usage: mrm health  |  bash /opt/mrm-manager/pg_health.sh

# ─── Shared libraries ────────────────────────────────────────────────────────
MRM_DIR="${MRM_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)}"
[ -r "$MRM_DIR/utils.sh" ] || MRM_DIR="/opt/mrm-manager"
# shellcheck source=/dev/null
if [ -z "$PANEL_DIR" ]; then source "$MRM_DIR/utils.sh" 2>/dev/null || true; fi
# shellcheck source=/dev/null
if ! declare -f ui_header >/dev/null 2>&1 && [ -r "$MRM_DIR/ui.sh" ]; then source "$MRM_DIR/ui.sh"; fi
# shellcheck source=/dev/null
if ! declare -f parse_db_credentials >/dev/null 2>&1 && [ -r "$MRM_DIR/backup/init.sh" ]; then
    source "$MRM_DIR/backup/init.sh" 2>/dev/null || true
fi
# shellcheck source=/dev/null
if ! declare -f mrm_probe_database >/dev/null 2>&1 && [ -r "$MRM_DIR/backup/database.sh" ]; then
    source "$MRM_DIR/backup/database.sh" 2>/dev/null || true
fi
# shellcheck source=/dev/null
[ -r "$MRM_DIR/versions.conf" ] && source "$MRM_DIR/versions.conf"

# Official defaults from PasarGuard .env.example / config.py
PH_JOB_DEFAULTS="JOB_CORE_HEALTH_CHECK_INTERVAL:10:node health check (s)|JOB_RECORD_NODE_USAGES_INTERVAL:30:record node usage|JOB_RECORD_USER_USAGES_INTERVAL:10:record user usage|JOB_REVIEW_USERS_INTERVAL:30:review users|JOB_REVIEW_ADMIN_LIMITS_INTERVAL:10:review admin limits|JOB_SEND_NOTIFICATIONS_INTERVAL:30:send notifications|JOB_GATHER_NODES_STATS_INTERVAL:25:gather node stats|JOB_REMOVE_OLD_INBOUNDS_INTERVAL:600:remove old inbounds|JOB_REMOVE_EXPIRED_USERS_INTERVAL:3600:remove expired users|JOB_RESET_USER_DATA_USAGE_INTERVAL:600:reset user usage|JOB_RESET_NODE_USAGE_INTERVAL:60:reset node usage|JOB_CHECK_NODE_LIMITS_INTERVAL:60:check node limits|JOB_CLEANUP_SUBSCRIPTION_UPDATES_INTERVAL:600:clean subscription updates"

ph_env_get() {
    local KEY="$1"
    [ -f "$PANEL_ENV" ] || return 1
    local VAL
    VAL="$(grep -E "^${KEY}[[:space:]]*=" "$PANEL_ENV" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" | xargs)"
    [ -n "$VAL" ] && { printf '%s\n' "$VAL"; return 0; }
    return 1
}

# ─── 1) Panel HTTP health (/health is public, no auth) ──────────────────────
ph_panel_health() {
    local PORT CERT
    PORT="$(ph_env_get UVICORN_PORT)"; PORT="${PORT:-8000}"
    CERT="$(ph_env_get UVICORN_SSL_CERTFILE)"
    local URL
    if [ -n "$CERT" ]; then URL="https://127.0.0.1:$PORT/health"; else URL="http://127.0.0.1:$PORT/health"; fi
    if command -v curl >/dev/null 2>&1 && curl -sk --max-time 8 "$URL" 2>/dev/null | grep -q '"status".*ok'; then
        ui_success "Panel /health OK ($URL)"
    else
        ui_error "Panel /health failed ($URL)"
        ui_note "The panel does not answer on this address — check SSL, the port and the container."
    fi
}

# ─── 2) TLS / UVICORN_SSL_CA_TYPE sanity ────────────────────────────────────
ph_ca_check() {
    local CERT KEY CA_TYPE
    CERT="$(ph_env_get UVICORN_SSL_CERTFILE)"
    KEY="$(ph_env_get UVICORN_SSL_KEYFILE)"
    CA_TYPE="$(ph_env_get UVICORN_SSL_CA_TYPE)"; CA_TYPE="${CA_TYPE:-public}"
    if [ -z "$CERT" ] || [ -z "$KEY" ]; then
        ui_info "Panel runs without SSL (UVICORN_SSL_CERTFILE/KEYFILE not set)"
        return 0
    fi
    if [[ "$CA_TYPE" != "public" && "$CA_TYPE" != "private" ]]; then
        ui_error "UVICORN_SSL_CA_TYPE='$CA_TYPE' is invalid — only public/private (the panel falls back to public with a warning)"
    fi
    if [ -f "$CERT" ]; then
        local ISSUER SUBJECT
        ISSUER="$(openssl x509 -in "$CERT" -noout -issuer 2>/dev/null | cut -d= -f2- | tr -d ' ')"
        SUBJECT="$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null | cut -d= -f2- | tr -d ' ')"
        if [ -n "$ISSUER" ] && [ "$ISSUER" = "$SUBJECT" ]; then
            if [ "$CA_TYPE" = "private" ]; then
                ui_success "Self-signed certificate with CA_TYPE=private — correct"
            else
                ui_error "Self-signed certificate but UVICORN_SSL_CA_TYPE=public — the panel will not start (main.py)"
                ui_note "Fix: set UVICORN_SSL_CA_TYPE=private in .env"
            fi
        elif [ -z "$ISSUER" ]; then
            # FIX: unreadable/corrupt cert or missing openssl — otherwise this
            # was reported as "issued by a public CA" (false success) (MRM-086)
            ui_warning "Could not read the certificate (corrupt file or openssl missing): $CERT"
        else
            ui_success "Certificate issued by a public CA (CA_TYPE=$CA_TYPE)"
        fi
    else
        ui_error "Certificate file not found: $CERT"
    fi
    if [ -n "$KEY" ] && [ ! -f "$KEY" ]; then
        ui_error "Key file not found: $KEY"
    fi
}

# ─── 3) JOB_* vs official defaults ──────────────────────────────────────────
ph_job_report() {
    local IFS_OLD="$IFS" ENTRY KEY DEF DESC VAL
    IFS='|'
    for ENTRY in $PH_JOB_DEFAULTS; do
        KEY="${ENTRY%%:*}"; REST="${ENTRY#*:}"; DEF="${REST%%:*}"; DESC="${REST#*:}"
        VAL="$(ph_env_get "$KEY")"
        if [ -z "$VAL" ]; then
            # FIX: a standard official install has NO JOB_* keys in .env and
            # uses the config.py defaults — that is HEALTHY, not a failure (MRM-085)
            ui_kv_state "$KEY" ok "official default ($DEF)" "$DESC"
        elif [ "$VAL" != "$DEF" ]; then
            ui_kv_state "$KEY" warn "$VAL (default $DEF)" "$DESC"
        else
            ui_kv_state "$KEY" ok "$VAL" "$DESC"
        fi
    done
    IFS="$IFS_OLD"
}

ph_fix_jobs() {
    local IFS_OLD="$IFS" ENTRY KEY DEF DESC VAL BACKUP_FILE ANS
    BACKUP_FILE="${PANEL_ENV}.mrm-bak-$(date +%Y%m%d-%H%M%S)"
    ui_header "Sync JOB Intervals" "Align JOB_* values with the official PasarGuard defaults"
    [ -f "$PANEL_ENV" ] || { ui_error "Panel .env not found: $PANEL_ENV"; pause; return 1; }
    cp -f "$PANEL_ENV" "$BACKUP_FILE" 2>/dev/null
    ui_note "Backup: $BACKUP_FILE"
    echo ""
    local CHANGED=0
    IFS='|'
    for ENTRY in $PH_JOB_DEFAULTS; do
        KEY="${ENTRY%%:*}"; REST="${ENTRY#*:}"; DEF="${REST%%:*}" # DESC unused here
        VAL="$(ph_env_get "$KEY")"
        [ "$VAL" = "$DEF" ] && continue
        IFS="$IFS_OLD"
        if ui_confirm "${KEY}: ${VAL:-<unset>} → ${DEF}?"; then
            if grep -qE "^${KEY}[[:space:]]*=" "$PANEL_ENV"; then
                sed -i "s|^${KEY}[[:space:]]*=.*|${KEY}=${DEF}|" "$PANEL_ENV"
            else
                echo "${KEY}=${DEF}" >> "$PANEL_ENV"
            fi
            ui_success "${KEY}=${DEF}"
            CHANGED=$((CHANGED + 1))
        fi
        IFS='|'
    done
    IFS="$IFS_OLD"
    echo ""
    if [ "$CHANGED" -eq 0 ]; then
        ui_note "Nothing changed."
        pause; return 0
    fi
    if ui_confirm "Restart the panel to apply?" y; then
        local CF
        CF="$(get_panel_compose_file 2>/dev/null)"
        if [ -n "$CF" ] && (cd "$PANEL_DIR" && docker compose -f "$CF" restart >/dev/null 2>&1); then
            ui_success "Panel restarted"
        else
            ui_warning "Restart it manually:"
            ui_cmd "cd $PANEL_DIR && docker compose restart"
        fi
    fi
    pause
}

# ─── 4) Nodes audit (panel DB: nodes table) ─────────────────────────────────
ph_nodes_report() {
    local CONT PROBE TYPE
    command -v docker >/dev/null 2>&1 || { ui_error "docker not found"; return 1; }
    CONT="$(mrm_find_panel_container 2>/dev/null || true)"
    [ -z "$CONT" ] && { ui_error "PasarGuard panel container not found — is it running?"; return 1; }
    PROBE="$(mrm_probe_database "$CONT" 2>/dev/null || true)"
    TYPE="${PROBE%%|*}"
    local RAW=""
    case "$TYPE" in
        postgres)
            local HOST PORT USER PASS DB PGC SQL
            IFS='|' read -r _ HOST PORT USER PASS DB <<< "$PROBE"
            PASS="$(mrm_b64dec "$PASS" 2>/dev/null)"
            # FIX: precise compose-name match first — bare grep could pick an
            # unrelated container (logs-postgres-1, postgres_exporter…) (MRM-083)
            PGC="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^(pasarguard-)?(postgresql|timescaledb|postgres|timescale)[-_]?[0-9]*$' | head -1)"
            [ -z "$PGC" ] && PGC="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE 'postgres|timescale' | head -1)"
            [ -z "$PGC" ] && { ui_error "PostgreSQL container not found"; return 1; }
            SQL="SELECT id,name,address,port,status,keep_alive,default_timeout,internal_timeout,connection_type,COALESCE(node_version,'-'),COALESCE(xray_version,'-'),COALESCE(substr(message,1,80),'') FROM nodes ORDER BY id;"
            RAW="$(docker exec -e PGPASSWORD="$PASS" "$PGC" psql -w -A -t -F'|' -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" -c "$SQL" 2>/dev/null)"
            if [ -z "$RAW" ] && { [ "$HOST" != "127.0.0.1" ] || [ "$PORT" != "5432" ]; }; then
                RAW="$(docker exec -e PGPASSWORD="$PASS" "$PGC" psql -w -A -t -F'|' -h 127.0.0.1 -p 5432 -U "$USER" -d "$DB" -c "$SQL" 2>/dev/null)"
            fi
            ;;
        mysql|mariadb)
            local HOST PORT USER PASS DB MYSQLC SQL
            IFS='|' read -r _ HOST PORT USER PASS DB <<< "$PROBE"
            PASS="$(mrm_b64dec "$PASS" 2>/dev/null)"
            # FIX: precise compose-name match first (MRM-083)
            MYSQLC="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^(pasarguard-)?(mysql|mariadb)[-_]?[0-9]*$' | head -1)"
            [ -z "$MYSQLC" ] && MYSQLC="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE 'mysql|mariadb' | head -1)"
            [ -z "$MYSQLC" ] && { ui_error "MySQL container not found"; return 1; }
            SQL="SELECT id,name,address,port,status,keep_alive,default_timeout,internal_timeout,connection_type,COALESCE(node_version,'-'),COALESCE(xray_version,'-'),COALESCE(SUBSTRING(message,1,80),'') FROM nodes ORDER BY id;"
            RAW="$(docker exec -e MYSQL_PWD="$PASS" "$MYSQLC" mysql -B -N -h"$HOST" -P"$PORT" -u"$USER" "$DB" -e "$SQL" 2>/dev/null)"
            ;;
        sqlite)
            local DBFILE
            DBFILE="${PROBE#sqlite|}"
            [ -z "$DBFILE" ] && DBFILE="$(mrm_sqlite_path_from_container "$CONT" 2>/dev/null)"
            RAW="$(timeout 20 docker exec -i "$CONT" python - "$DBFILE" <<'PY' 2>/dev/null
import sqlite3, sys
try:
    con = sqlite3.connect(sys.argv[1])
    cur = con.execute("SELECT id,name,address,port,status,keep_alive,default_timeout,internal_timeout,connection_type,COALESCE(node_version,'-'),COALESCE(xray_version,'-'),COALESCE(substr(message,1,80),'') FROM nodes ORDER BY id")
    for r in cur.fetchall():
        print("|".join(str(x) for x in r))
except Exception:
    pass
PY
)"
            ;;
        *) ui_error "Unknown database type: $TYPE"; return 1 ;;
    esac
    [ -z "$RAW" ] && { ui_warning "No node data (nodes table empty or not accessible)"; return 1; }

    local CORE
    CORE="$(ph_env_get JOB_CORE_HEALTH_CHECK_INTERVAL)"; CORE="${CORE:-10}"
    ui_table_header "%-3s  %-16s  %-22s  %-4s  %-4s  %-5s  %-8s  %s" "ID" "Name" "Address" "KA" "TO" "ITMO" "Type" "Status"
    while IFS='|' read -r ID NAME ADDRESS PORT STATUS KA TO ITMO CTYPE NVER XVER MSG; do
        [ -z "$ID" ] && continue
        local STATE_TXT
        if [ "$STATUS" = "connected" ]; then
            STATE_TXT="$(ui_state ok "$STATUS")"
        else
            STATE_TXT="$(ui_state warn "$STATUS")"
        fi
        ui_table_row "$ID" "${NAME:0:16}" "${ADDRESS:0:16}:${PORT}" "$KA" "$TO" "$ITMO" "${CTYPE:0:8}" "$STATE_TXT"
        if [ -n "$MSG" ] && [ "$MSG" != "-" ]; then
            printf '%s     %b%s%b\n' "$UI_PAD" "$UI_C_ERR" "last message: $MSG" "$NC"
        fi
        if [ "$KA" -gt 0 ] 2>/dev/null && [ "$KA" -lt $((CORE * 2)) ]; then
            printf '%s     %b%s%b\n' "$UI_PAD" "$UI_C_WARN" "keep_alive=$KA conflicts with the health check interval (${CORE}s) — risk of auto-disconnect; use 0 or at least $((CORE * 3))" "$NC"
        fi
    done <<< "$RAW"
    echo ""
    ui_note "KA = keep_alive · TO = default_timeout · ITMO = internal_timeout (seconds)"
    ui_note "keep_alive=0 means the node is never disconnected automatically (safe panel default)."
}

# ─── 5) Owner temp key (official CLI) ───────────────────────────────────────
ph_temp_key() {
    local CONT
    CONT="$(mrm_find_panel_container 2>/dev/null || true)"
    if [ -z "$CONT" ]; then
        ui_error "Panel container not found"
        return 1
    fi
    ui_header "Owner Temp Key" "official CLI: pasarguard-cli generate-temp-key"
    ui_kv "Container" "${CONT:0:12}"
    echo ""
    # FIX: -t requires a TTY on stdin; generate-temp-key only prints output
    # (no interactive prompt) so -i is enough and works in non-TTY runs (MRM-084)
    docker exec -i "$CONT" pasarguard-cli generate-temp-key 2>/dev/null \
        || docker exec -i "$CONT" python /code/pasarguard-cli.py generate-temp-key 2>/dev/null \
        || ui_error "Could not run the CLI inside the container"
    echo ""
    ui_warning "The key is valid for 5 minutes and single-use — use it on the login page as Owner."
    pause
}

# ─── Full report ────────────────────────────────────────────────────────────
ph_diagnose() {
    detect_active_panel > /dev/null 2>&1 || true
    ui_header "PasarGuard Health" "Panel: $(basename "$PANEL_DIR" 2>/dev/null) · Env: $PANEL_ENV"
    ui_section "1  Panel HTTP health"
    ph_panel_health
    echo ""
    ui_section "2  TLS / CA type"
    ph_ca_check
    echo ""
    ui_section "3  Nodes (panel DB)"
    ph_nodes_report
    echo ""
    ui_section "4  JOB intervals vs official defaults"
    ph_job_report
    pause
}

ph_tips() {
    ui_header "Health Checks Explained"
    ui_bullet "keep_alive=0 (default) means the node is never disconnected automatically; a non-zero value must be at least 3× the health check interval."
    ui_bullet "JOB_CORE_HEALTH_CHECK_INTERVAL defaults to 10 s; raising it slows down node-outage detection."
    ui_bullet "UVICORN_SSL_CA_TYPE: public CA certificate → public, self-signed → private — otherwise the panel refuses to start."
    ui_bullet "If /health does not answer, check the container and its log:"
    ui_cmd "docker compose ps" "in the panel directory"
    ui_cmd "docker compose logs --tail 50"
    ui_bullet "Nodes on other servers must be restarted there; 'Restart node' here only affects the local node."
    pause
}

ph_menu() {
    local OPT
    while true; do
        ui_header "PasarGuard Health" "Panel, TLS, nodes and job intervals"
        ui_menu_item 1 "Full health report"
        ui_menu_item 2 "Generate owner temp key" "official CLI"
        ui_menu_item 3 "Sync JOB_* intervals" "official defaults"
        ui_menu_item 4 "What these checks mean"
        ui_menu_back
        ui_select OPT
        case $OPT in
            1) ph_diagnose ;;
            2) ph_temp_key ;;
            3) ph_fix_jobs ;;
            4) ph_tips ;;
            0) return ;;
            *) ui_invalid ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "$1" == "temp-key" ]]; then
        ph_temp_key
    else
        ph_menu
    fi
fi
