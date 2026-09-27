#!/bin/bash
# MRM Backup — post-restore auto-fix
# Runs automatically after a restore to fix the usual follow-up issues:
#   1. Install nginx if missing
#   2. Copy SSL certificates to /etc/letsencrypt/live/
#   3. Set the subscription URL prefix in the panel DB
#   4. Test and start nginx
#   5. Restart the panel

# Enable strict mode ONLY when run directly (standalone). When this file is
# sourced by backup.sh a bare `set -e` would leak into the whole shell and
# break other code (e.g. cron setup on servers with no existing crontab).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -e
fi

# ─── Shared libraries ────────────────────────────────────────────────────────
MRM_DIR="${MRM_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)}"
[ -r "$MRM_DIR/utils.sh" ] || MRM_DIR="/opt/mrm-manager"
if ! declare -f load_panel_config >/dev/null 2>&1 && [ -r "$MRM_DIR/utils.sh" ]; then
    # shellcheck source=/dev/null
    source "$MRM_DIR/utils.sh"
fi
# shellcheck source=/dev/null
declare -f ui_header >/dev/null 2>&1 || { [ -r "$MRM_DIR/ui.sh" ] && source "$MRM_DIR/ui.sh"; }
declare -f detect_active_panel >/dev/null 2>&1 && { detect_active_panel >/dev/null 2>&1 || true; }

# Fallback paths
PANEL_DIR="${PANEL_DIR:-/opt/pasarguard}"
PANEL_ENV="${PANEL_ENV:-/opt/pasarguard/.env}"
DATA_DIR="${DATA_DIR:-/var/lib/pasarguard}"
NODE_DIR="${NODE_DIR:-/opt/pg-node}"

DOMAIN_SEP_CONF="/etc/nginx/conf.d/panel_separate.conf"
PANEL_CERTS_DIR="$DATA_DIR/certs"
LOG_FILE="/var/log/mrm-post-restore.log"

# log_msg LEVEL TEXT — plain text goes to the log file, styled text to the screen.
# LEVEL: ok | warn | err | info | step | text | blank
log_msg() {
    local LEVEL="$1" TEXT="${2:-}"
    if [ "$LEVEL" = "blank" ]; then echo ""; return 0; fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${LEVEL^^}] $TEXT" >> "$LOG_FILE" 2>/dev/null || true
    case "$LEVEL" in
        ok)   ui_success "$TEXT" ;;
        warn) ui_warning "$TEXT" ;;
        err)  ui_error "$TEXT" ;;
        info) ui_info "$TEXT" ;;
        step) ui_note "$TEXT" ;;
        *)    ui_text "$TEXT" ;;
    esac
}

# ─── STEP 1: Install Nginx if not present ──────────────────────────────
ensure_nginx_installed() {
    if command -v nginx >/dev/null 2>&1; then
        log_msg ok "Nginx is already installed: $(nginx -v 2>&1)"
        return 0
    fi

    log_msg warn "Nginx not found — installing"

    # Stop panel temporarily to free port 80/443 if needed
    local NEED_STOP_PANEL=false
    if ss -tlnp 2>/dev/null | grep -qE ':80 |:443 '; then
        NEED_STOP_PANEL=true
        cd "$PANEL_DIR" && docker compose stop 2>/dev/null || true
        sleep 2
    fi

    # Install nginx
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y nginx certbot >/dev/null 2>&1

    if command -v nginx >/dev/null 2>&1; then
        log_msg ok "Nginx installed successfully"
        systemctl enable nginx >/dev/null 2>&1
    else
        log_msg err "Nginx installation failed"
        # Restart panel if we stopped it
        if [ "$NEED_STOP_PANEL" = true ]; then
            cd "$PANEL_DIR" && docker compose start 2>/dev/null || true
        fi
        return 1
    fi

    return 0
}

# ─── STEP 2: Copy SSL certs to /etc/letsencrypt/live/ ──────────────────
copy_ssl_certs() {
    log_msg step "Checking SSL certificates"

    local COPIED=0
    local NEED_COPY=0

    # Extract domain names from panel_separate.conf
    if [ ! -f "$DOMAIN_SEP_CONF" ]; then
        log_msg warn "Domain separator config not found — certificate copy skipped"
        return 0
    fi

    # Get all server_name entries from the config
    local DOMAINS
    DOMAINS=$(grep -oP 'server_name\s+\K[^;]+' "$DOMAIN_SEP_CONF" 2>/dev/null | tr -d ' ' | sort -u)

    if [ -z "$DOMAINS" ]; then
        log_msg warn "No domains found in $DOMAIN_SEP_CONF"
        return 0
    fi

    for DOMAIN in $DOMAINS; do
        # SECURITY: Validate domain format before use
        if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
            log_msg warn "Skipping invalid domain: $DOMAIN"
            continue
        fi
        local LETS_DIR="/etc/letsencrypt/live/$DOMAIN"
        local PANEL_CERT_DIR="$PANEL_CERTS_DIR/$DOMAIN"

        # Check if letsencrypt dir already has valid certs
        if [ -f "$LETS_DIR/fullchain.pem" ] && [ -f "$LETS_DIR/privkey.pem" ]; then
            log_msg ok "$DOMAIN: certificates already in /etc/letsencrypt/live/"
            COPIED=$((COPIED + 1))
            continue
        fi

        # Check if panel certs dir has certs
        if [ -f "$PANEL_CERT_DIR/fullchain.pem" ] && [ -f "$PANEL_CERT_DIR/privkey.pem" ]; then
            log_msg step "$DOMAIN: copying from $PANEL_CERT_DIR to $LETS_DIR"
            mkdir -p "$LETS_DIR"
            cp "$PANEL_CERT_DIR/fullchain.pem" "$LETS_DIR/fullchain.pem"
            cp "$PANEL_CERT_DIR/privkey.pem" "$LETS_DIR/privkey.pem"
            chmod 644 "$LETS_DIR/fullchain.pem"
            chmod 600 "$LETS_DIR/privkey.pem"
            COPIED=$((COPIED + 1))
            NEED_COPY=$((NEED_COPY + 1))
        else
            log_msg err "$DOMAIN: no certificates in $PANEL_CERT_DIR"
            log_msg warn "Issue a new certificate for it from the SSL menu"
        fi
    done

    log_msg ok "SSL certificates: $COPIED domains checked, $NEED_COPY copied"
    return 0
}

# ─── STEP 3: Update the subscription URL prefix in the panel DB (settings.subscription.url_prefix) 
set_subscription_url_prefix() {
    log_msg step "Updating the subscription URL prefix in the panel DB"

    if [ ! -f "$PANEL_ENV" ]; then
        log_msg err "Panel .env not found at $PANEL_ENV"
        return 1
    fi

    # Extract sub domain from panel_separate.conf (second server_name, typically)
    local SUB_DOMAIN=""
    local ADMIN_DOMAIN=""
    local SUB_PORT=""

    if [ -f "$DOMAIN_SEP_CONF" ]; then
        # Get all domains IN FILE ORDER — first is admin, second is sub.
        # FIX: sort -u reordered them alphabetically and could swap
        # admin/sub, writing the wrong subscription prefix (MRM-065)
        local ALL_DOMAINS
        ALL_DOMAINS=$(grep -oP 'server_name\s+\K[^;]+' "$DOMAIN_SEP_CONF" 2>/dev/null | tr -d ' ')

        # First domain is typically admin, second is sub
        ADMIN_DOMAIN=$(echo "$ALL_DOMAINS" | head -1)
        SUB_DOMAIN=$(echo "$ALL_DOMAINS" | sed -n '2p')

        # Get port from listen directive
        SUB_PORT=$(grep -oP 'listen\s+\K[0-9]+' "$DOMAIN_SEP_CONF" 2>/dev/null | head -1)
        [ -z "$SUB_PORT" ] && SUB_PORT="2096"
    fi

    # Determine the correct URL prefix
    local SUB_URL=""

    if [ -n "$SUB_DOMAIN" ]; then
        # Domain separator is active - use sub domain
        if [ "$SUB_PORT" = "443" ]; then
            SUB_URL="https://$SUB_DOMAIN"
        else
            SUB_URL="https://$SUB_DOMAIN:$SUB_PORT"
        fi
    elif [ -n "$ADMIN_DOMAIN" ]; then
        # No separate sub domain - use admin domain
        local ADMIN_PORT
        ADMIN_PORT=$(grep -oP 'listen\s+\K[0-9]+' "$DOMAIN_SEP_CONF" 2>/dev/null | head -1)
        [ -z "$ADMIN_PORT" ] && ADMIN_PORT="2096"
        if [ "$ADMIN_PORT" = "443" ]; then
            SUB_URL="https://$ADMIN_DOMAIN"
        else
            SUB_URL="https://$ADMIN_DOMAIN:$ADMIN_PORT"
        fi
    else
        # No domain separator - check if panel has SSL cert
        local PANEL_SSL
        PANEL_SSL=$(grep -oP 'UVICORN_SSL_CERTFILE\s*=\s*"?\K[^"]+' "$PANEL_ENV" 2>/dev/null)
        if [ -n "$PANEL_SSL" ]; then
            # Panel has SSL - extract domain from cert path
            local CERT_DOMAIN
            CERT_DOMAIN=$(echo "$PANEL_SSL" | grep -oP '/certs/\K[^/]+')
            if [ -n "$CERT_DOMAIN" ]; then
                local PANEL_PORT
                PANEL_PORT=$(grep -oP 'UVICORN_PORT\s*=\s*\K[0-9]+' "$PANEL_ENV" 2>/dev/null)
                [ -z "$PANEL_PORT" ] && PANEL_PORT="8000"
                if [ "$PANEL_PORT" = "443" ]; then
                    SUB_URL="https://$CERT_DOMAIN"
                else
                    SUB_URL="https://$CERT_DOMAIN:$PANEL_PORT"
                fi
            fi
        fi
    fi

    # Fallback to server IP if nothing else works
    if [ -z "$SUB_URL" ]; then
        local SERVER_IP
        SERVER_IP=$(curl -4 -s --connect-timeout 5 icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
        local PANEL_PORT
        PANEL_PORT=$(grep -oP 'UVICORN_PORT\s*=\s*\K[0-9]+' "$PANEL_ENV" 2>/dev/null)
        [ -z "$PANEL_PORT" ] && PANEL_PORT="8000"
        SUB_URL="https://$SERVER_IP:$PANEL_PORT"
        log_msg warn "Using server IP as fallback"
    fi

    # PasarGuard reads XRAY_SUBSCRIPTION_URL_PREFIX from .env ONLY during the
    # first-time DB migration. At runtime the subscription URL prefix is read
    # from the panel DB (settings.subscription -> url_prefix) — writing .env
    # here would be a no-op, so we update the panel DB instead.
    if _apply_subscription_url_db "$SUB_URL"; then
        log_msg ok "Subscription URL prefix updated in panel DB: $SUB_URL"
        return 0
    else
        log_msg warn "Could not update the panel DB automatically"
        log_msg warn "Set it manually: Dashboard › Settings › Subscription › URL prefix = $SUB_URL"
        # FIX: propagate failure so main() reports this step as failed
        # instead of printing "All 5 steps completed successfully" (MRM-063)
        return 1
    fi
}

# Apply the subscription URL prefix straight into the panel DB (settings table,
# subscription JSON -> url_prefix). Returns 0 on success.
_apply_subscription_url_db() {
    local SUB_URL="$1"
    local MOD_PATH PROBE TYPE CONT
    MOD_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if ! declare -f mrm_probe_database >/dev/null 2>&1; then
        [ -r "$MOD_PATH/database.sh" ] && source "$MOD_PATH/database.sh" 2>/dev/null || true
    fi
    command -v docker >/dev/null 2>&1 || return 1
    CONT="$(mrm_find_panel_container 2>/dev/null || true)"
    [ -z "$CONT" ] && return 1
    PROBE="$(mrm_probe_database "$CONT" 2>/dev/null || true)"
    TYPE="${PROBE%%|*}"
    case "$TYPE" in
        postgres)
            local HOST PORT USER PASS DB PGC SQL
            IFS='|' read -r _ HOST PORT USER PASS DB <<< "$PROBE"
            PASS="$(mrm_b64dec "$PASS" 2>/dev/null)"
            # FIX: precise compose-name match first (MRM-064); bare grep could
            # pick an unrelated postgres container and update the WRONG DB
            PGC="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^(pasarguard-)?(postgresql|timescaledb|postgres|timescale)[-_]?[0-9]*$' | head -1)"
            [ -z "$PGC" ] && PGC="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE 'postgres|timescale' | head -1)"
            [ -z "$PGC" ] && return 1
            SQL="UPDATE settings SET subscription = (jsonb_set(subscription::jsonb, '{url_prefix}', to_jsonb(:'url_prefix'::text), true))::json WHERE id = (SELECT id FROM settings ORDER BY id LIMIT 1);"
            # Attempt 1: exactly where the panel connects (may be a pooler like pgbouncer)
            if docker exec -e PGPASSWORD="$PASS" "$PGC" psql -w -v ON_ERROR_STOP=1 -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" -v url_prefix="$SUB_URL" -c "$SQL" >/dev/null 2>&1; then
                return 0
            fi
            # Attempt 2: direct local postgres inside the container
            if [ "$HOST" != "127.0.0.1" ] || [ "$PORT" != "5432" ]; then
                docker exec -e PGPASSWORD="$PASS" "$PGC" psql -w -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 5432 -U "$USER" -d "$DB" -v url_prefix="$SUB_URL" -c "$SQL" >/dev/null 2>&1 && return 0
            fi
            return 1
            ;;
        mysql|mariadb)
            local HOST PORT USER PASS DB MYSQLC ESC
            IFS='|' read -r _ HOST PORT USER PASS DB <<< "$PROBE"
            PASS="$(mrm_b64dec "$PASS" 2>/dev/null)"
            # FIX: precise compose-name match first (MRM-064)
            MYSQLC="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^(pasarguard-)?(mysql|mariadb)[-_]?[0-9]*$' | head -1)"
            [ -z "$MYSQLC" ] && MYSQLC="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE 'mysql|mariadb' | head -1)"
            [ -z "$MYSQLC" ] && return 1
            ESC="${SUB_URL//\'/\'\'}"
            # MySQL forbids selecting the same table in a subquery — nest it.
            docker exec -e MYSQL_PWD="$PASS" "$MYSQLC" mysql -h"$HOST" -P"$PORT" -u"$USER" "$DB" \
                -e "UPDATE settings SET subscription = JSON_SET(subscription, '\$.url_prefix', '$ESC') WHERE id = (SELECT id FROM (SELECT id FROM settings ORDER BY id LIMIT 1) t);" >/dev/null 2>&1
            ;;
        sqlite)
            local DBFILE ESC
            DBFILE="${PROBE#sqlite|}"
            [ -z "$DBFILE" ] && return 1
            command -v sqlite3 >/dev/null 2>&1 || return 1
            ESC="${SUB_URL//\'/\'\'}"
            sqlite3 "$DBFILE" "UPDATE settings SET subscription = json_set(subscription, '\$.url_prefix', '$ESC') WHERE id = (SELECT id FROM settings LIMIT 1);" >/dev/null 2>&1
            ;;
        *) return 1 ;;
    esac
}

# ─── STEP 4: Test and start Nginx ──────────────────────────────────────
test_and_start_nginx() {
    if ! command -v nginx >/dev/null 2>&1; then
        log_msg err "Nginx is not installed — skipped"
        return 1
    fi

    log_msg step "Testing nginx configuration"

    if nginx -t 2>&1; then
        log_msg ok "Nginx configuration is valid"
        systemctl restart nginx 2>/dev/null
        sleep 1
        if systemctl is-active --quiet nginx 2>/dev/null; then
            log_msg ok "Nginx is running"
        else
            log_msg warn "Nginx failed to start — check: journalctl -xeu nginx"
            return 1
        fi
    else
        log_msg err "Nginx configuration test failed"
        nginx -t 2>&1 | head -5
        return 1
    fi

    return 0
}

# ─── STEP 5: Restart panel ─────────────────────────────────────────────
restart_panel() {
    log_msg step "Restarting panel"

    if [ -d "$PANEL_DIR" ] && { [ -f "$PANEL_DIR/docker-compose.yml" ] || [ -f "$PANEL_DIR/compose.yml" ]; }; then
        cd "$PANEL_DIR"
        docker compose restart 2>/dev/null && {
            log_msg ok "Panel restarted"
            return 0
        }
    fi

    log_msg warn "Panel restart failed — try: cd $PANEL_DIR && docker compose restart"
    return 1
}

# ─── MAIN ──────────────────────────────────────────────────────────────
main() {
    log_msg blank
    log_msg text "Post-restore auto-fix: nginx · SSL certificates · subscription URL"
    log_msg blank

    local STEP=0
    local TOTAL=5
    local FAILED=0

    STEP=$((STEP + 1))
    ui_step "$STEP" "$TOTAL" "Ensuring nginx is installed"
    ensure_nginx_installed || FAILED=$((FAILED + 1))
    log_msg blank

    STEP=$((STEP + 1))
    ui_step "$STEP" "$TOTAL" "Copying SSL certificates"
    copy_ssl_certs || FAILED=$((FAILED + 1))
    log_msg blank

    STEP=$((STEP + 1))
    ui_step "$STEP" "$TOTAL" "Updating the subscription URL prefix in the panel DB"
    set_subscription_url_prefix || FAILED=$((FAILED + 1))
    log_msg blank

    STEP=$((STEP + 1))
    ui_step "$STEP" "$TOTAL" "Testing and starting nginx"
    test_and_start_nginx || FAILED=$((FAILED + 1))
    log_msg blank

    STEP=$((STEP + 1))
    ui_step "$STEP" "$TOTAL" "Restarting the panel"
    restart_panel || FAILED=$((FAILED + 1))
    log_msg blank

    if [ "$FAILED" -eq 0 ]; then
        log_msg ok "All $TOTAL post-restore steps completed — subscription links should work now"
    else
        log_msg warn "$FAILED of $TOTAL steps had issues — see $LOG_FILE"
    fi
}

# Only run main if executed directly, not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
