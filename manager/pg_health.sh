#!/bin/bash
# MRM Manager - PasarGuard Health
# Panel & node audit aligned with the official PasarGuard panel (v5.x):
#   - panel /health endpoint + TLS/CA sanity
#   - JOB_* intervals vs official defaults (.env.example / config.py)
#   - nodes table (status, keep_alive, timeouts, last error message)
#   - one-time owner temp key (official CLI: pasarguard-cli generate-temp-key)
# Usage: mrm health  |  bash /opt/mrm-manager/pg_health.sh

# ─── Module loading ─────────────────────────────────────────────────────────
if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh 2>/dev/null || true; fi
if ! declare -f ui_header >/dev/null 2>&1 && [ -r /opt/mrm-manager/ui.sh ]; then
    source /opt/mrm-manager/ui.sh
fi
if ! declare -f parse_db_credentials >/dev/null 2>&1 && [ -r /opt/mrm-manager/backup/init.sh ]; then
    source /opt/mrm-manager/backup/init.sh 2>/dev/null || true
fi
if ! declare -f mrm_probe_database >/dev/null 2>&1 && [ -r /opt/mrm-manager/backup/database.sh ]; then
    source /opt/mrm-manager/backup/database.sh 2>/dev/null || true
fi
[ -r /opt/mrm-manager/versions.conf ] && source /opt/mrm-manager/versions.conf

# Official defaults from PasarGuard .env.example / config.py
PH_JOB_DEFAULTS="JOB_CORE_HEALTH_CHECK_INTERVAL:10:فرکانس چک سلامت نودها (ثانیه)|JOB_RECORD_NODE_USAGES_INTERVAL:30:ثبت مصرف نود|JOB_RECORD_USER_USAGES_INTERVAL:10:ثبت مصرف کاربران|JOB_REVIEW_USERS_INTERVAL:30:بازبینی کاربران|JOB_REVIEW_ADMIN_LIMITS_INTERVAL:10:بازبینی محدودیت ادمینها|JOB_SEND_NOTIFICATIONS_INTERVAL:30:ارسال اعلانها|JOB_GATHER_NODES_STATS_INTERVAL:25:جمعآوری آمار نودها|JOB_REMOVE_OLD_INBOUNDS_INTERVAL:600:پاکسازی اینباندهای قدیمی|JOB_REMOVE_EXPIRED_USERS_INTERVAL:3600:حذف کاربران منقضی|JOB_RESET_USER_DATA_USAGE_INTERVAL:600:ریست مصرف کاربران|JOB_RESET_NODE_USAGE_INTERVAL:60:ریست مصرف نود|JOB_CHECK_NODE_LIMITS_INTERVAL:60:چک محدودیت نود|JOB_CLEANUP_SUBSCRIPTION_UPDATES_INTERVAL:600:تمیزکاری آپدیتهای سابسکرپشن"

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
        ui_success "Panel /health OK  ($URL)"
    else
        ui_error "Panel /health FAILED  ($URL)"
        ui_warning "پنل روی این آدرس جواب نمیدهد — SSL/پورت/کانتینر را بررسی کنید"
    fi
}

# ─── 2) TLS / UVICORN_SSL_CA_TYPE sanity ────────────────────────────────────
ph_ca_check() {
    local CERT KEY CA_TYPE
    CERT="$(ph_env_get UVICORN_SSL_CERTFILE)"
    KEY="$(ph_env_get UVICORN_SSL_KEYFILE)"
    CA_TYPE="$(ph_env_get UVICORN_SSL_CA_TYPE)"; CA_TYPE="${CA_TYPE:-public}"
    if [ -z "$CERT" ] || [ -z "$KEY" ]; then
        ui_info "پنل بدون SSL است (UVICORN_SSL_CERTFILE/KEYFILE تنظیم نشده)"
        return 0
    fi
    if [[ "$CA_TYPE" != "public" && "$CA_TYPE" != "private" ]]; then
        ui_error "UVICORN_SSL_CA_TYPE='$CA_TYPE' نامعتبر است — فقط public/private (پنل با هشدار public میکند)"
    fi
    if [ -f "$CERT" ]; then
        local ISSUER SUBJECT
        ISSUER="$(openssl x509 -in "$CERT" -noout -issuer 2>/dev/null | cut -d= -f2- | tr -d ' ')"
        SUBJECT="$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null | cut -d= -f2- | tr -d ' ')"
        if [ -n "$ISSUER" ] && [ "$ISSUER" = "$SUBJECT" ]; then
            if [ "$CA_TYPE" = "private" ]; then
                ui_success "سرتیفیکت self-signed + CA_TYPE=private ✓ (درست)"
            else
                ui_error "سرتیفیکت self-signed است ولی UVICORN_SSL_CA_TYPE=public است → پنل بالا نمیآید (main.py)"
                ui_warning "راهحل: UVICORN_SSL_CA_TYPE=private در .env"
            fi
        elif [ -z "$ISSUER" ]; then
            # FIX: unreadable/corrupt cert or missing openssl — otherwise this
            # was reported as "issued by a public CA" (false success) (MRM-086)
            ui_warning "نتوانستم سرتیفیکت را بخوانم (فایل خراب یا openssl موجود نیست): $CERT"
        else
            ui_success "سرتیفیکت توسط یک CA عمومی صادر شده ✓ (CA_TYPE=$CA_TYPE)"
        fi
    else
        ui_error "فایل سرتیفیکت وجود ندارد: $CERT"
    fi
    if [ -n "$KEY" ] && [ ! -f "$KEY" ]; then
        ui_error "فایل کلید وجود ندارد: $KEY"
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
            printf '  %b— %-45s %s\n' "${CYAN}" "$KEY (پیشفرض رسمی $DEF)" "$DESC"
        elif [ "$VAL" != "$DEF" ]; then
            printf '  %b⚠ %-45s %s\n' "${YELLOW}" "$KEY=$VAL (پیشفرض $DEF)" "$DESC"
        else
            printf '  %b✓ %-45s %s\n' "${GREEN}" "$KEY=$VAL" "$DESC"
        fi
    done
    IFS="$IFS_OLD"
}

ph_fix_jobs() {
    local IFS_OLD="$IFS" ENTRY KEY DEF DESC VAL BACKUP_FILE ANS
    BACKUP_FILE="${PANEL_ENV}.mrm-bak-$(date +%Y%m%d-%H%M%S)"
    ui_header "SYNC JOB INTERVALS WITH OFFICIAL DEFAULTS"
    [ -f "$PANEL_ENV" ] || { ui_error "Panel .env not found: $PANEL_ENV"; pause; return 1; }
    cp -f "$PANEL_ENV" "$BACKUP_FILE" 2>/dev/null
    ui_info "Backup: $BACKUP_FILE"
    IFS='|'
    for ENTRY in $PH_JOB_DEFAULTS; do
        KEY="${ENTRY%%:*}"; REST="${ENTRY#*:}"; DEF="${REST%%:*}" # DESC unused here
        VAL="$(ph_env_get "$KEY")"
        [ "$VAL" = "$DEF" ] && continue
        read -r -p "  ${KEY}=${VAL:-<empty>} → ${DEF}؟ [y/N]: " ANS
        if [[ "$ANS" =~ ^[Yy]$ ]]; then
            if grep -qE "^${KEY}[[:space:]]*=" "$PANEL_ENV"; then
                sed -i "s|^${KEY}[[:space:]]*=.*|${KEY}=${DEF}|" "$PANEL_ENV"
            else
                echo "${KEY}=${DEF}" >> "$PANEL_ENV"
            fi
            ui_success "${KEY}=${DEF}"
        fi
    done
    IFS="$IFS_OLD"
    echo ""
    read -r -p "برای اعمال، پنل را ریاستارت کنید (Y/n): " ANS
    if [[ ! "$ANS" =~ ^[Nn]$ ]]; then
        local CF
        CF="$(get_panel_compose_file 2>/dev/null)"
        if [ -n "$CF" ] && (cd "$PANEL_DIR" && docker compose -f "$CF" restart >/dev/null 2>&1); then
            ui_success "Panel restarted"
        else
            ui_warning "ریاستارت دستی: cd $PANEL_DIR && docker compose restart"
        fi
    fi
    pause
}

# ─── 4) Nodes audit (panel DB: nodes table) ─────────────────────────────────
ph_nodes_report() {
    local CONT PROBE TYPE
    command -v docker >/dev/null 2>&1 || { ui_error "docker not found"; return 1; }
    CONT="$(mrm_find_panel_container 2>/dev/null || true)"
    [ -z "$CONT" ] && { ui_error "پنل PasarGuard پیدا نشد (کانتینر در حال اجرا؟)"; return 1; }
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
            [ -z "$PGC" ] && { ui_error "کانتینر PostgreSQL پیدا نشد"; return 1; }
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
            [ -z "$MYSQLC" ] && { ui_error "کانتینر MySQL پیدا نشد"; return 1; }
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
        *) ui_error "نوع دیتابیس ناشناخته: $TYPE"; return 1 ;;
    esac
    [ -z "$RAW" ] && { ui_warning "داده نودها دریافت نشد (جدول nodes خالی یا دسترسی نیست)"; return 1; }

    local CORE
    CORE="$(ph_env_get JOB_CORE_HEALTH_CHECK_INTERVAL)"; CORE="${CORE:-10}"
    echo ""
    printf '  %b%-4s %-18s %-16s %-7s %-6s %-6s %-8s %-10s %s%b\n' \
        "${CYAN}" "ID" "NAME" "ADDRESS:PORT" "STATUS" "KA" "TO" "ITMO" "TYPE" "MSG" "${NC}"
    while IFS='|' read -r ID NAME ADDRESS PORT STATUS KA TO ITMO CTYPE NVER XVER MSG; do
        [ -z "$ID" ] && continue
        local MARK="✓" COLOR="${GREEN}"
        if [ "$STATUS" != "connected" ]; then MARK="⚠"; COLOR="${YELLOW}"; fi
        printf '  %b%-4s %-18s %-16s%-7s %-6s %-6s %-8s %-10s %s%b\n' \
            "$COLOR" "$ID" "$NAME" "$ADDRESS:$PORT" "$STATUS" "$KA" "$TO" "$ITMO" "$CTYPE" "$MARK" "${NC}"
        [ "$STATUS" != "connected" ] && printf '      %b→ وضعیت: %s (آخرین تغییر: %s)%b\n' "${YELLOW}" "$STATUS" "—" "${NC}"
        if [ -n "$MSG" ] && [ "$MSG" != "-" ]; then
            printf '      %b→ پیام نود: %s%b\n' "${RED}" "$MSG" "${NC}"
        fi
        if [ "$KA" -gt 0 ] 2>/dev/null && [ "$KA" -lt $((CORE * 2)) ]; then
            printf '      %b→ keep_alive=%s با فاصله چک سلامت (%ss) تداخل دارد؛ ریسک قطعخودکار — مقدار را 0 یا ≥%s بگذارید%b\n' \
                "${RED}" "$KA" "$CORE" $((CORE * 3)) "${NC}"
        fi
    done <<< "$RAW"
    echo ""
    ui_info "KA=keep_alive  TO=default_timeout  ITMO=internal_timeout (ثانیه)"
    ui_info "keep_alive=0 یعنی نود هرگز خودکار قطع نمیشود (پیشفرض امن پنل)"
}

# ─── 5) Owner temp key (official CLI) ───────────────────────────────────────
ph_temp_key() {
    local CONT
    CONT="$(mrm_find_panel_container 2>/dev/null || true)"
    if [ -z "$CONT" ]; then
        ui_error "کانتینر پنل پیدا نشد"
        return 1
    fi
    ui_info "Container: ${CONT:0:12}…"
    # FIX: -t requires a TTY on stdin; generate-temp-key only prints output
    # (no interactive prompt) so -i is enough and works in non-TTY runs (MRM-084)
    docker exec -i "$CONT" pasarguard-cli generate-temp-key 2>/dev/null \
        || docker exec -i "$CONT" python /code/pasarguard-cli.py generate-temp-key 2>/dev/null \
        || ui_error "اجرای CLI در کانتینر ممکن نشد"
    echo ""
    ui_warning "این کلید ۵ دقیقه اعتبار دارد و یکبارمصرف است (برای ورود Owner از صفحه لاگین)"
    pause
}

# ─── Full report ────────────────────────────────────────────────────────────
ph_diagnose() {
    clear
    ui_header "PASARGUARD HEALTH v${MRM_VERSION:-1.1.24}"
    detect_active_panel > /dev/null 2>&1 || true
    echo -e "  ${BLUE}Panel:${NC} $(basename "$PANEL_DIR" 2>/dev/null) | Env: $PANEL_ENV"
    echo ""
    echo -e "${CYAN}── 1) Panel HTTP Health ──────────────────────────${NC}"
    ph_panel_health
    echo ""
    echo -e "${CYAN}── 2) TLS / CA Type ──────────────────────────────${NC}"
    ph_ca_check
    echo ""
    echo -e "${CYAN}── 3) Nodes (panel DB) ───────────────────────────${NC}"
    ph_nodes_report
    echo ""
    echo -e "${CYAN}── 4) JOB intervals vs official defaults ─────────${NC}"
    ph_job_report
    echo ""
    pause
}

ph_menu() {
    while true; do
        clear
        ui_header "PASARGUARD HEALTH"
        echo "1)  🩺 Full Health Report"
        echo "2)  🔑 Generate Owner Temp Key (official CLI)"
        echo "3)  ⏱️  Sync JOB_* Intervals with Official Defaults"
        echo "4)  📖 What These Checks Mean / Tips"
        echo ""
        echo "0)  ↩️  Back"
        echo ""
        read -p "Select: " OPT
        case $OPT in
            1) ph_diagnose ;;
            2) ph_temp_key ;;
            3) ph_fix_jobs ;;
            4)
                clear
                echo -e "${CYAN}Tips:${NC}"
                echo -e "  • keep_alive=0 (پیشفرض) = نود خودکار قطع نمیشود. اگر مقدار دارد، باید ≥ 3× فاصله چک سلامت باشد."
                echo -e "  • JOB_CORE_HEALTH_CHECK_INTERVAL پیشفرض رسمی ۱۰ ثانیه است؛ بیشتر کردن آن تشخیص قطعی نود را کند میکند."
                echo -e "  • UVICORN_SSL_CA_TYPE: سرتیفیکت عمومی → public / self-signed (خصوصی) → private — در غیر این صورت پنل بالا نمیآید."
                echo -e "  • اگر پنل پاسخ /health نداد: docker compose ps و لاگ پنل را ببینید (`docker compose logs --tail 50`)."
                echo -e "  • نود روی سرور دیگری است؟ آنجا ریاستارت کنید؛ گزینه Restart Node اینجا فقط نود محلی را میگیرد."
                pause
                ;;
            0) return ;;
            *) invalid_menu_option 2>/dev/null || { echo "Invalid"; sleep 1; } ;;
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
