#!/bin/bash
# MRM Manager Backup v${BACKUP_VERSION}

# ==========================================
# MRM Backup & Restore v${BACKUP_VERSION}
# ==========================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export HOME="${HOME:-/root}"

# Load MRM modules safely
if [ -f "/opt/mrm-manager/utils.sh" ]; then source /opt/mrm-manager/utils.sh; fi
if [ -f "/opt/mrm-manager/ui.sh" ]; then source /opt/mrm-manager/ui.sh; fi
if ! declare -f mrm_create_restore_point >/dev/null 2>&1 && [ -r "/opt/mrm-manager/safe_ops.sh" ]; then source /opt/mrm-manager/safe_ops.sh; fi
[ -r "/opt/mrm-manager/versions.conf" ] && source /opt/mrm-manager/versions.conf

# Configuration
BACKUP_DIR="/root/mrm-backups"
TG_CONFIG="/root/.mrm_telegram"
TEMP_BASE="/tmp/mrm_workspace"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
BACKUP_LOG="/var/log/mrm-backup.log"
MRM_BACKUP_VERSION="v${BACKUP_VERSION:-1.0.1}"

# ==========================================
# LOGGING
# ==========================================
init_backup_logging() {
    mkdir -p "$(dirname "$BACKUP_LOG")"
    touch "$BACKUP_LOG"
    chmod 600 "$BACKUP_LOG" 2>/dev/null || true
}

log_backup() {
    local LEVEL=$1
    local MESSAGE=$2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$LEVEL] $MESSAGE" >> "$BACKUP_LOG"
}

# ==========================================
# ENVIRONMENT
# ==========================================
setup_env() {
    if declare -f detect_active_panel >/dev/null 2>&1; then
        detect_active_panel > /dev/null 2>&1 || true
    fi
    # Fallback if utils not loaded
    if [ -z "$PANEL_DIR" ]; then
        if [ -d "/opt/pasarguard" ]; then
            PANEL_DIR="/opt/pasarguard"
            PANEL_ENV="/opt/pasarguard/.env"
            DATA_DIR="/var/lib/pasarguard"
            NODE_DIR="/opt/pg-node"
            NODE_ENV="/opt/pg-node/.env"
            NODE_DEF_CERTS="/var/lib/pg-node/certs"
        elif [ -d "/opt/marzban" ]; then
            PANEL_DIR="/opt/marzban"
            PANEL_ENV="/opt/marzban/.env"
            DATA_DIR="/var/lib/marzban"
            NODE_DIR="/opt/marzban-node"
            NODE_ENV="/opt/marzban-node/.env"
            NODE_DEF_CERTS="/var/lib/marzban-node/certs"
        elif [ -d "/opt/rebecca" ]; then
            PANEL_DIR="/opt/rebecca"
            PANEL_ENV="/opt/rebecca/.env"
            DATA_DIR="/var/lib/rebecca"
            NODE_DIR="/opt/rebecca-node"
            NODE_ENV="/opt/rebecca-node/.env"
            NODE_DEF_CERTS="/var/lib/rebecca-node/certs"
        fi
    fi
    log_backup "INFO" "Env: PANEL_DIR=$PANEL_DIR DATA_DIR=$DATA_DIR PANEL_ENV=$PANEL_ENV"
}

get_existing_compose_file() {
    local TARGET="$1"
    local COMPOSE_FILE=""
    local BASE_DIR=""
    local CANDIDATE
    case "$TARGET" in
        panel)
            if declare -f get_panel_compose_file >/dev/null 2>&1; then
                COMPOSE_FILE="$(get_panel_compose_file 2>/dev/null || true)"
            fi
            BASE_DIR="$PANEL_DIR"
            ;;
        node)
            if declare -f get_node_compose_file >/dev/null 2>&1; then
                COMPOSE_FILE="$(get_node_compose_file 2>/dev/null || true)"
            fi
            BASE_DIR="$NODE_DIR"
            ;;
        *) return 1 ;;
    esac
    if [ -n "$COMPOSE_FILE" ] && [ -f "$COMPOSE_FILE" ]; then
        printf '%s\n' "$COMPOSE_FILE"
        return 0
    fi
    [ -n "$BASE_DIR" ] && [ -d "$BASE_DIR" ] || return 1
    for CANDIDATE in \
        "$BASE_DIR/docker-compose.yml" \
        "$BASE_DIR/docker-compose.yaml" \
        "$BASE_DIR/compose.yml" \
        "$BASE_DIR/compose.yaml"
    do
        if [ -f "$CANDIDATE" ]; then
            printf '%s\n' "$CANDIDATE"
            return 0
        fi
    done
    return 1
}

run_compose_file() {
    local COMPOSE_FILE="$1"
    shift
    [ -n "$COMPOSE_FILE" ] && [ -f "$COMPOSE_FILE" ] || return 1
    if docker compose version >/dev/null 2>&1; then
        docker compose -f "$COMPOSE_FILE" "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose -f "$COMPOSE_FILE" "$@"
    else
        return 1
    fi
}

build_telegram_proxy_args() {
    local PROXY="$1"
    local PROXY_STR AUTH HOSTPORT
    if [[ "$PROXY" == socks5://* ]]; then
        PROXY_STR="${PROXY#socks5://}"
        if [[ "$PROXY_STR" == *"@"* ]]; then
            AUTH="${PROXY_STR%@*}"
            HOSTPORT="${PROXY_STR##*@}"
            printf '%s\n' "--socks5-hostname" "$HOSTPORT" "-U" "$AUTH"
        else
            printf '%s\n' "--socks5-hostname" "$PROXY_STR"
        fi
    fi
}

get_server_ip() {
    local IP=""
    IP=$(curl -4 -s --connect-timeout 5 icanhazip.com 2>/dev/null)
    [ -z "$IP" ] && IP=$(curl -4 -s --connect-timeout 5 ipv4.icanhazip.com 2>/dev/null)
    [ -z "$IP" ] && IP=$(curl -4 -s --connect-timeout 5 api.ipify.org 2>/dev/null)
    [ -z "$IP" ] && IP=$(curl -4 -s --connect-timeout 5 checkip.amazonaws.com 2>/dev/null)
    [ -z "$IP" ] && IP=$(ip -4 route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[^ ]+')
    if [[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$IP"
    else
        IP=$(hostname -I 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        echo "$IP"
    fi
}

# ==========================================
# ENV FIXER
# ==========================================
fix_env_file() {
    local ENV_FILE=$1
    local TEMP_FILE prev_line=""
    if [ ! -f "$ENV_FILE" ]; then return 1; fi
    log_backup "INFO" "Fixing .env file: $ENV_FILE"
    TEMP_FILE=$(mktemp) || return 1
    trap 'rm -f "$TEMP_FILE"' RETURN
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$prev_line" =~ ^UVICORN_$ ]] || [[ "$prev_line" =~ ^SSL_$ ]]; then
            echo "${prev_line}${line}" >> "$TEMP_FILE"
            prev_line=""
        elif [[ "$line" =~ ^UVICORN_$ ]] || [[ "$line" =~ ^SSL_$ ]]; then
            prev_line="$line"
        else
            if [ -n "$prev_line" ]; then echo "$prev_line" >> "$TEMP_FILE"; fi
            echo "$line" >> "$TEMP_FILE"
            prev_line=""
        fi
    done < "$ENV_FILE"
    if [ -n "$prev_line" ]; then echo "$prev_line" >> "$TEMP_FILE"; fi
    sed -i ':a;N;$!ba;s/UVICORN_\nSSL_CERTFILE/UVICORN_SSL_CERTFILE/g' "$TEMP_FILE"
    sed -i ':a;N;$!ba;s/UVICORN_\nSSL_KEYFILE/UVICORN_SSL_KEYFILE/g' "$TEMP_FILE"
    sed -i ':a;N;$!ba;s/UVICORN_\n/UVICORN_/g' "$TEMP_FILE"
    sed -i ':a;N;$!ba;s/SSL_\n/SSL_/g' "$TEMP_FILE"
    sed -i 's/[[:space:]]*=[[:space:]]*/=/g' "$TEMP_FILE"
    sed -i 's/UVICORN_ SSL_CERTFILE/UVICORN_SSL_CERTFILE/g' "$TEMP_FILE"
    sed -i 's/UVICORN_ SSL_KEYFILE/UVICORN_SSL_KEYFILE/g' "$TEMP_FILE"
    if cat -s "$TEMP_FILE" > "$ENV_FILE"; then
        rm -f "$TEMP_FILE"
        trap - RETURN
        log_backup "SUCCESS" "Fixed .env file: $ENV_FILE"
        return 0
    fi
    rm -f "$TEMP_FILE"
    trap - RETURN
    log_backup "ERROR" "Failed to fix .env file: $ENV_FILE"
    return 1
}

fix_docker_compose() {
    local COMPOSE_FILE NEW_IP
    COMPOSE_FILE="$(get_existing_compose_file panel 2>/dev/null || true)"
    if [ -z "$COMPOSE_FILE" ] || [ ! -f "$COMPOSE_FILE" ]; then
        log_backup "WARNING" "Panel compose file not found"
        return 1
    fi
    NEW_IP=$(get_server_ip)
    if [ -z "$NEW_IP" ]; then log_backup "WARNING" "Could not detect server IP"; return 1; fi
    log_backup "INFO" "Updating docker-compose with new IP: $NEW_IP"

    # A) First, fix any old hard-coded bind IPs (X.X.X.X:8010 / :7431 / --bind X.X.X.X:)
    #    -> replace with the current server IP. 127.0.0.1 and 0.0.0.0 are treated
    #    as safe and left alone.
    local FOUND_OLD_IP
    FOUND_OLD_IP="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$COMPOSE_FILE" 2>/dev/null \
        | grep -vE '^(127\.0\.0\.1|0\.0\.0\.0)$' | grep -v "^$NEW_IP$" | head -1)"
    if [ -n "$FOUND_OLD_IP" ]; then
        sed -i -E "s/${FOUND_OLD_IP}:8010/${NEW_IP}:8010/g; s/${FOUND_OLD_IP}:7431/${NEW_IP}:7431/g; s/--bind ${FOUND_OLD_IP}:/--bind ${NEW_IP}:/g" "$COMPOSE_FILE"
        log_backup "INFO" "Replaced old bind IP $FOUND_OLD_IP with $NEW_IP"
    fi

    # B) PGADMIN_LISTEN_ADDRESS: use the server's public IP ONLY if it is actually
    #    assigned to this host; otherwise fall back to the safe 127.0.0.1
    #    (default in the official template). Prevents "Address not available".
    local PGADMIN_IP="$NEW_IP"
    if ! ip -4 addr show 2>/dev/null | grep -qw "$NEW_IP"; then
        log_backup "WARNING" "IP $NEW_IP not assigned to this host - using 127.0.0.1 for pgadmin"
        PGADMIN_IP="127.0.0.1"
    fi
    if grep -q "PGADMIN_LISTEN_ADDRESS" "$COMPOSE_FILE"; then
        sed -i "s/^[[:space:]]*PGADMIN_LISTEN_ADDRESS:.*/      PGADMIN_LISTEN_ADDRESS: $PGADMIN_IP/g" "$COMPOSE_FILE"
        log_backup "INFO" "PGADMIN_LISTEN_ADDRESS set to $PGADMIN_IP"
    fi
    log_backup "SUCCESS" "Updated compose file with IP: $NEW_IP"
    return 0
}

# ==========================================
# TELEGRAM
# ==========================================
send_to_telegram() {
    local FILE="$1"
    local MESSAGE="${2:-}"
    local TK CH PROXY RESULT
    local -a CURL_PROXY_ARGS=()
    if [ ! -f "$TG_CONFIG" ]; then log_backup "WARNING" "Telegram not configured"; return 1; fi
    TK=$(grep "TG_TOKEN" "$TG_CONFIG" | cut -d'=' -f2 | tr -d '"')
    CH=$(grep "TG_CHAT" "$TG_CONFIG" | cut -d'=' -f2 | tr -d '"')
    PROXY=$(grep "TG_PROXY" "$TG_CONFIG" | cut -d'=' -f2 | tr -d '"')
    mapfile -t CURL_PROXY_ARGS < <(build_telegram_proxy_args "$PROXY")
    if [ -z "$TK" ] || [ -z "$CH" ]; then log_backup "ERROR" "Invalid Telegram config"; return 1; fi
    if [ -n "$FILE" ] && [ -f "$FILE" ]; then
        local FILE_SIZE
        local SERVER_IP
        local BACKUP_LABEL
        local CAPTION

        FILE_SIZE="$(du -h "$FILE" | cut -f1)"
        SERVER_IP="$(get_server_ip)"
        [ -z "$SERVER_IP" ] && SERVER_IP="Unknown"

        BACKUP_LABEL="$(basename "$FILE" .tar.gz)"

        CAPTION="🛡️ MRM Backup
━━━━━━━━━━━━━━━━━━
🌐 ${SERVER_IP}
🗓️ $(date '+%Y-%m-%d %H:%M')
📦 ${BACKUP_LABEL}
💾 ${FILE_SIZE}
🏷️ ${MRM_BACKUP_VERSION}"
        RESULT=$(curl -4 -s -m 600 "${CURL_PROXY_ARGS[@]}" -F chat_id="$CH" -F caption="$CAPTION" -F document=@"$FILE" "https://api.telegram.org/bot$TK/sendDocument")
        log_backup "DEBUG" "Telegram response: $RESULT"
        if echo "$RESULT" | grep -q '"ok":true'; then log_backup "SUCCESS" "File sent to Telegram: $(basename "$FILE") $FILE_SIZE"; return 0; else log_backup "ERROR" "Failed to send to Telegram: $RESULT"; return 1; fi
    elif [ -n "$MESSAGE" ]; then
        curl -4 -s "${CURL_PROXY_ARGS[@]}" -X POST "https://api.telegram.org/bot$TK/sendMessage" -d chat_id="$CH" -d text="$MESSAGE" > /dev/null
        return $?
    fi
    return 1
}

test_telegram() {
    local TK CH PROXY RESULT
    local -a CURL_PROXY_ARGS=()
    if [ ! -f "$TG_CONFIG" ]; then ui_error "Telegram not configured!"; return 1; fi
    ui_spinner_start "Testing Telegram connection..."
    TK=$(grep "TG_TOKEN" "$TG_CONFIG" | cut -d'=' -f2 | tr -d '"')
    CH=$(grep "TG_CHAT" "$TG_CONFIG" | cut -d'=' -f2 | tr -d '"')
    PROXY=$(grep "TG_PROXY" "$TG_CONFIG" | cut -d'=' -f2 | tr -d '"')
    mapfile -t CURL_PROXY_ARGS < <(build_telegram_proxy_args "$PROXY")
    RESULT=$(curl -4 -s "${CURL_PROXY_ARGS[@]}" -X POST "https://api.telegram.org/bot$TK/sendMessage" -d chat_id="$CH" -d text="🧪 MRM Backup test - $(date '+%Y-%m-%d %H:%M')" 2>&1)
    ui_spinner_stop
    if echo "$RESULT" | grep -q '"ok":true'; then ui_success "Telegram connection successful!"; return 0; else ui_error "Telegram connection failed!"; echo -e "${YELLOW}Error: $RESULT${NC}"; return 1; fi
}

setup_telegram() {
    clear
    ui_header "SETUP TELEGRAM BOT - v${BACKUP_VERSION}"
    echo -e "${CYAN}To get Bot Token:${NC}\n  1. Message @BotFather on Telegram\n  2. Send /newbot and follow instructions\n  3. Copy the token\n"
    echo -e "${CYAN}To get Chat ID:${NC}\n  1. Message @userinfobot on Telegram\n  2. It will show your Chat ID\n"
    read -p "Enter Bot Token: " TK
    if [ -z "$TK" ]; then ui_error "Token is required!"; pause; return; fi
    read -p "Enter Chat ID: " CI
    if [ -z "$CI" ]; then ui_error "Chat ID is required!"; pause; return; fi
    echo ""
    read -p "Use SOCKS5 proxy for Telegram? (y/N): " USE_PROXY
    if [[ "$USE_PROXY" =~ ^[Yy]$ ]]; then
        echo ""
        echo "Enter proxy format: socks5://127.0.0.1:1080 or socks5://user:pass@127.0.0.1:1080"
        read -p "Proxy: " PROXY_URL
    else
        PROXY_URL=""
    fi
    if declare -f mrm_create_restore_point >/dev/null 2>&1; then
        local RESTORE_POINT_ID
        RESTORE_POINT_ID="$(mrm_create_restore_point "telegram-settings" "none" "$TG_CONFIG")"
        [ -n "$RESTORE_POINT_ID" ] && echo -e "${BLUE}Restore point created: $RESTORE_POINT_ID${NC}"
    fi
    cat > "$TG_CONFIG" << EOF
TG_TOKEN="$TK"
TG_CHAT="$CI"
TG_PROXY="$PROXY_URL"
EOF
    chmod 600 "$TG_CONFIG"
    ui_success "Telegram configured!"
    log_backup "INFO" "Telegram bot configured"
    echo ""
    read -p "Test connection now? (Y/n): " TEST
    if [[ ! "$TEST" =~ ^[Nn]$ ]]; then test_telegram; fi
    pause
}

remove_telegram_settings() {
    clear
    ui_header "REMOVE TELEGRAM SETTINGS"
    if [ ! -f "$TG_CONFIG" ]; then ui_warning "Telegram settings are not configured."; pause; return; fi
    echo -e "${YELLOW}This will delete Telegram bot settings.${NC}"
    echo -e "${CYAN}Scheduled backups will keep working locally.${NC}\n"
    read -p "Delete? (y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        if declare -f mrm_create_restore_point >/dev/null 2>&1; then
            local RESTORE_POINT_ID
            RESTORE_POINT_ID="$(mrm_create_restore_point "telegram-settings-remove" "none" "$TG_CONFIG")"
            [ -n "$RESTORE_POINT_ID" ] && echo -e "${BLUE}Restore point: $RESTORE_POINT_ID${NC}"
        fi
        rm -f "$TG_CONFIG"
        ui_success "Telegram settings removed."
        log_backup "INFO" "Telegram settings removed"
    else
        echo "Cancelled"
    fi
    pause
}

# ==========================================
# SMART FIX ENGINE
# ==========================================
apply_smart_fix() {
    local FIREWALL_OK=false ENV_FILES_FOUND=false ENV_FIX_OK=true COMPOSE_FIX_OK=false
    clear
    echo -e "${CYAN}Applying Intelligent System Repairs...${NC}"
    log_backup "INFO" "Starting smart fix"
    local SERVER_IP=$(get_server_ip)
    echo -e "${BLUE}Detected Server IP: ${CYAN}$SERVER_IP${NC}"
    ui_spinner_start "Configuring Firewall..."
    local SSH_PORT=$(ss -tlnp 2>/dev/null | grep sshd | grep -Po '(?<=:)\d+' | head -1)
    [ -z "$SSH_PORT" ] && SSH_PORT=22
    if command -v ufw >/dev/null 2>&1; then
        if ufw allow "$SSH_PORT"/tcp >/dev/null 2>&1 && ufw allow 80,443,2096,7431,6432,8443,2083,2097,8080/tcp >/dev/null 2>&1 && ufw --force enable >/dev/null 2>&1; then FIREWALL_OK=true; fi
    fi
    ui_spinner_stop
    if [ "$FIREWALL_OK" = true ]; then ui_success "Firewall configured (SSH: $SSH_PORT)"; elif ! command -v ufw >/dev/null 2>&1; then ui_warning "ufw not installed, skipped."; else ui_error "Firewall configuration failed"; fi
    ui_spinner_start "Fixing .env files..."
    for ENV_FILE in "$PANEL_ENV" "$NODE_ENV"; do if [ -f "$ENV_FILE" ]; then ENV_FILES_FOUND=true; fix_env_file "$ENV_FILE" || ENV_FIX_OK=false; fi; done
    ui_spinner_stop
    if [ "$ENV_FILES_FOUND" = true ] && [ "$ENV_FIX_OK" = true ]; then ui_success ".env files repaired"; elif [ "$ENV_FILES_FOUND" = true ]; then ui_error "One or more .env files could not be repaired"; else ui_warning "No .env files found"; fi
    ui_spinner_start "Updating docker-compose IPs..."
    if fix_docker_compose; then COMPOSE_FIX_OK=true; fi
    ui_spinner_stop
    if [ "$COMPOSE_FIX_OK" = true ]; then ui_success "Docker compose updated with IP: $SERVER_IP"; else ui_warning "Compose file not found or IP update failed"; fi
    if [ -f "$NODE_ENV" ]; then
        ui_spinner_start "Fixing Node configuration..."
        if sed -i 's/=[[:space:]]*/=/g' "$NODE_ENV" && sed -i 's/[[:space:]]*=/=/g' "$NODE_ENV"; then ui_spinner_stop; ui_success "Node .env fixed"; else ui_spinner_stop; ui_error "Failed to normalize Node .env"; fi
    fi
    if [ -d "$NODE_DIR" ]; then
        mkdir -p "$NODE_DEF_CERTS"
        # Generate BOTH key AND self-signed cert (node needs both for SSL)
        if [ ! -f "$NODE_DEF_CERTS/ssl_key.pem" ] || [ ! -f "$NODE_DEF_CERTS/ssl_cert.pem" ]; then
            ui_spinner_start "Generating Node SSL certificate..."
            openssl req -x509 -newkey rsa:2048 \
                -keyout "$NODE_DEF_CERTS/ssl_key.pem" \
                -out "$NODE_DEF_CERTS/ssl_cert.pem" \
                -days 3650 -nodes \
                -subj "/CN=PasarGuard-Node" 2>/dev/null
            ui_spinner_stop
            ui_success "Node SSL key + cert generated (self-signed, 10yr)"
            log_backup "INFO" "Generated self-signed SSL for node: $NODE_DEF_CERTS"
        fi
    fi
    local NG_CONF="/etc/nginx/conf.d/panel_separate.conf"
    if [ -f "$NG_CONF" ]; then ui_spinner_start "Fixing Nginx config..."; sed -i 's|proxy_pass http://127.0.0.1:7431;|proxy_pass https://127.0.0.1:7431;\n        proxy_ssl_verify off;|g' "$NG_CONF"; systemctl restart nginx >/dev/null 2>&1; ui_spinner_stop; ui_success "Nginx configuration repaired"; fi
    log_backup "SUCCESS" "Smart fix completed"
}

# ==========================================
# PARSE DB CREDENTIALS
# ==========================================
parse_db_credentials() {
    local ENV_FILE="$1"
    DB_USER=""; DB_PASS=""; DB_NAME=""; DB_HOST=""
    if [ ! -f "$ENV_FILE" ]; then return 1; fi
    local DB_URI=$(grep "^SQLALCHEMY_DATABASE_URL" "$ENV_FILE" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    if [ -n "$DB_URI" ]; then
        DB_USER=$(echo "$DB_URI" | sed -n 's|.*://\([^:]*\):.*|\1|p')
        DB_PASS=$(echo "$DB_URI" | sed -n 's|.*://[^:]*:\([^@]*\)@.*|\1|p')
        DB_NAME=$(echo "$DB_URI" | sed -n 's|.*/\([^?]*\).*|\1|p')
        DB_HOST=$(echo "$DB_URI" | sed -n 's|.*@\([^:/]*\).*|\1|p')
        log_backup "INFO" "Parsed from URI - User: $DB_USER, DB: $DB_NAME, Host: $DB_HOST"
        return 0
    fi
    DB_USER=$(grep "^POSTGRES_USER" "$ENV_FILE" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    DB_PASS=$(grep "^POSTGRES_PASSWORD" "$ENV_FILE" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    DB_NAME=$(grep "^POSTGRES_DB" "$ENV_FILE" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    if [ -n "$DB_USER" ]; then log_backup "INFO" "Parsed from vars - User: $DB_USER, DB: $DB_NAME"; return 0; fi
    return 1
}

# ==========================================
# DATABASE LAYER - FIXED for PasarGuard v5
# PasarGuard v5 stores SQLite INSIDE the panel
# container (/code/db.sqlite3 by default), so
# host-path checks alone silently miss the DB.
# We ask the panel itself where its DB lives.
# ==========================================

# Find the RUNNING panel container. Prefers the compose project, falls back to
# a precise name/image match (must NOT match node containers like "pasarguard-node").
mrm_panel_container() {
    local COMPOSE_FILE CID
    COMPOSE_FILE="$(get_existing_compose_file panel 2>/dev/null || true)"
    if [ -n "$COMPOSE_FILE" ] && [ -f "$COMPOSE_FILE" ]; then
        CID="$(docker compose -f "$COMPOSE_FILE" ps -q 2>/dev/null | head -1)"
        [ -n "$CID" ] && { printf '%s\n' "$CID"; return 0; }
    fi
    # Fallback: running container whose IMAGE is the panel image, or whose name
    # is exactly "pasarguard" (exclude *-node / node-*).
    docker ps --format '{{.ID}}|{{.Names}}|{{.Image}}' 2>/dev/null \
        | grep -iE "pasarguard/panel:|pasarguard/panel$|pasarguard/panel\b" \
        | head -1 | cut -d'|' -f1
}

# Find the panel container even if it is STOPPED (needed to copy the DB out/in
# while the panel is down). Same precise matching, using `docker ps -a`.
mrm_find_panel_container() {
    local COMPOSE_FILE CID
    COMPOSE_FILE="$(get_existing_compose_file panel 2>/dev/null || true)"
    if [ -n "$COMPOSE_FILE" ] && [ -f "$COMPOSE_FILE" ]; then
        CID="$(docker compose -f "$COMPOSE_FILE" ps -a -q 2>/dev/null | head -1)"
        [ -n "$CID" ] && { printf '%s\n' "$CID"; return 0; }
    fi
    docker ps -a --format '{{.ID}}|{{.Names}}|{{.Image}}' 2>/dev/null \
        | grep -iE "pasarguard/panel:|pasarguard/panel$|pasarguard/panel\b|(^|\|)pasarguard(\||$)" \
        | grep -viE "node" \
        | head -1 | cut -d'|' -f1
}

# Ask the panel itself. Prints: TYPE|INFO
#   sqlite   -> sqlite|/abs/path/to/db.sqlite3
#   postgres -> postgres|host|port|user|b64pass|db
#   mysql    -> mysql|host|port|user|b64pass|db
#   UNKNOWN  -> UNKNOWN|<raw url>
mrm_probe_database() {
    local CONT="$1"
    [ -z "$CONT" ] && return 1
    docker exec -i "$CONT" python - <<'PY' 2>/dev/null
import os, base64
try:
    from sqlalchemy.engine import make_url
except ImportError:
    try:
        from sqlalchemy import make_url
    except Exception:
        print("UNKNOWN|"); raise SystemExit(0)
try:
    from config import database_settings as s
    url = s.url
except Exception:
    print("UNKNOWN|"); raise SystemExit(0)
try:
    u = make_url(url)
    dr = (u.drivername or "").lower()
    if dr.startswith("sqlite"):
        path = u.database or ""
        if path and path != ":memory:" and not path.startswith("/"):
            path = os.path.abspath(path)
        print("sqlite|" + path)
    elif dr.startswith("postgres"):
        b64 = base64.b64encode((u.password or "").encode()).decode()
        print("postgres|%s|%s|%s|%s|%s" % (u.host or "localhost", u.port or 5432, u.username or "", b64, u.database or ""))
    elif dr.startswith(("mysql", "mariadb")):
        b64 = base64.b64encode((u.password or "").encode()).decode()
        print("mysql|%s|%s|%s|%s|%s" % (u.host or "localhost", u.port or 3306, u.username or "", b64, u.database or ""))
    else:
        print("UNKNOWN|" + url)
except Exception:
    print("UNKNOWN|" + url)
PY
}

mrm_b64dec() { printf '%s' "$1" | base64 -d 2>/dev/null; }

# Sanity check: is this file a valid SQLite database? (magic header)
mrm_is_sqlite_file() {
    [ -s "$1" ] && head -c 16 "$1" 2>/dev/null | grep -q "SQLite format 3"
}

# Parse a sqlite+aiosqlite://... URL and print the DB path.
#   absolute: sqlite+aiosqlite:////var/lib/db.sqlite3 -> /var/lib/db.sqlite3
#   relative: sqlite+aiosqlite:///db.sqlite3          -> db.sqlite3
mrm_sqlite_path_from_url() {
    local URL="$1" SCHEME REST
    SCHEME="${URL%%:*}"         # scheme = everything before the first ':'
    REST="${URL#*://}"          # everything after the first ://
    case "$SCHEME" in
        sqlite*)
            # REST starts with "//"  -> absolute path (drop ONE leading slash)
            # REST starts with "/"   -> relative path  (drop the leading slash)
            printf '%s\n' "${REST#/}"
            return 0
            ;;
    esac
    return 1
}

# Live-safe SQLite export via host sqlite3 CLI (.backup handles concurrent access).
mrm_sqlite_host_backup() {
    local SRC="$1" DEST="$2"
    [ -n "$SRC" ] && [ -f "$SRC" ] || return 1
    if command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 "$SRC" ".backup '$DEST'" 2>/dev/null && mrm_is_sqlite_file "$DEST" && return 0
    fi
    # Fallback: plain copy (fine for rollback-journal SQLite, panel may be running)
    cp -f "$SRC" "$DEST" 2>/dev/null && mrm_is_sqlite_file "$DEST"
}

# Export SQLite safely (live-safe backup API) from inside the panel container
mrm_export_sqlite() {
    local CONT="$1" SRC="$2" DEST="$3"
    log_backup "INFO" "SQLite export: container=$CONT src=$SRC -> $DEST"
    docker exec -i "$CONT" python - "$SRC" <<'PY' 2>/dev/null || return 1
import sqlite3, sys, os
src_path = sys.argv[1]
if not src_path or not os.path.exists(src_path):
    raise SystemExit("MISSING")
src = sqlite3.connect(src_path)
dst = sqlite3.connect("/tmp/mrm_db_backup.sqlite3")
src.backup(dst)
src.close(); dst.close()
PY
    docker cp "$CONT:/tmp/mrm_db_backup.sqlite3" "$DEST" >/dev/null 2>&1 || return 1
    docker exec "$CONT" rm -f /tmp/mrm_db_backup.sqlite3 2>/dev/null || true
    mrm_is_sqlite_file "$DEST" || return 1
    log_backup "SUCCESS" "SQLite exported via container ($(du -h "$DEST" | cut -f1))"
    return 0
}

# Cold-copy SQLite from a STOPPED container (docker cp works while stopped).
mrm_sqlite_cold_export() {
    local CONT="$1" IN_PATH="$2" DEST="$3"
    [ -n "$CONT" ] && [ -n "$IN_PATH" ] || return 1
    docker cp "$CONT:$IN_PATH" "$DEST" >/dev/null 2>&1 && mrm_is_sqlite_file "$DEST"
}

# Try to find the sqlite path inside a (possibly stopped) container using
# docker inspect: WORKDIR + Config.Env SQLALCHEMY_DATABASE_URL.
mrm_sqlite_path_from_container() {
    local CONT="$1" ENV_URL WORKDIR
    ENV_URL="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONT" 2>/dev/null | grep -m1 '^SQLALCHEMY_DATABASE_URL=' | cut -d'=' -f2- | tr -d '"' | tr -d "'")"
    if [ -n "$ENV_URL" ]; then
        local P
        P="$(mrm_sqlite_path_from_url "$ENV_URL" 2>/dev/null)"
        if [ -n "$P" ]; then
            if [[ "$P" == /* ]]; then printf '%s\n' "$P"; return 0; fi
            WORKDIR="$(docker inspect -f '{{.Config.WorkingDir}}' "$CONT" 2>/dev/null)"
            [ -z "$WORKDIR" ] && WORKDIR="/code"
            printf '%s/%s\n' "${WORKDIR%/}" "$P"
            return 0
        fi
    fi
    # Common defaults (docker cp also works on STOPPED containers; errors if missing)
    for CAND in "/code/db.sqlite3" "/var/lib/pasarguard/db.sqlite3" "/app/db.sqlite3"; do
        if docker cp "$CONT:$CAND" /dev/null 2>/dev/null; then printf '%s\n' "$CAND"; return 0; fi
    done
    printf '%s\n' "/code/db.sqlite3"
    return 0
}

# Export PostgreSQL (try: dedicated postgres container, then host pg_dump).
# Always sets PGPASSWORD (even empty) and passes -w so pg_dump NEVER prompts
# for a password interactively (would hang the menu / cron job).
mrm_export_postgres() {
    local DEST="$1" HOST="$2" PORT="$3" USER="$4" PASS="$5" DBNAME="$6"
    local CONT
    export PGPASSWORD="$PASS"
    CONT=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE "postgres|timescale" | head -1)
    if [ -n "$CONT" ]; then
        log_backup "INFO" "pg_dump via container: $CONT ($USER@$HOST:$PORT/$DBNAME)"
        if docker exec -e PGPASSWORD="$PASS" "$CONT" pg_dump -w -h "$HOST" -p "$PORT" -U "$USER" -d "$DBNAME" 2>/dev/null > "$DEST" \
           && [ -s "$DEST" ] && [ "$(stat -c%s "$DEST" 2>/dev/null || echo 0)" -gt 100 ]; then
            unset PGPASSWORD; return 0
        fi
    fi
    if command -v pg_dump >/dev/null 2>&1; then
        log_backup "INFO" "pg_dump via host: $HOST:$PORT ($USER/$DBNAME)"
        if pg_dump -w -h "$HOST" -p "$PORT" -U "$USER" -d "$DBNAME" 2>/dev/null > "$DEST" \
           && [ -s "$DEST" ] && [ "$(stat -c%s "$DEST" 2>/dev/null || echo 0)" -gt 100 ]; then
            unset PGPASSWORD; return 0
        fi
    fi
    unset PGPASSWORD
    return 1
}

# Export MySQL/MariaDB (try: container mysqldump, then host mysqldump).
# MYSQL_PWD is always set (even empty) so the client never prompts for a password.
mrm_export_mysql() {
    local DEST="$1" HOST="$2" PORT="$3" USER="$4" PASS="$5" DBNAME="$6"
    local CONT
    export MYSQL_PWD="$PASS"
    CONT=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE "mysql|mariadb" | head -1)
    if [ -n "$CONT" ]; then
        if docker exec -e MYSQL_PWD="$PASS" "$CONT" mysqldump --connect-timeout=5 -h"$HOST" -P"$PORT" -u"$USER" "$DBNAME" 2>/dev/null > "$DEST" \
           && [ -s "$DEST" ] && [ "$(stat -c%s "$DEST" 2>/dev/null || echo 0)" -gt 100 ]; then
            unset MYSQL_PWD; return 0
        fi
    fi
    if command -v mysqldump >/dev/null 2>&1; then
        if mysqldump --connect-timeout=5 -h"$HOST" -P"$PORT" -u"$USER" "$DBNAME" 2>/dev/null > "$DEST" \
           && [ -s "$DEST" ] && [ "$(stat -c%s "$DEST" 2>/dev/null || echo 0)" -gt 100 ]; then
            unset MYSQL_PWD; return 0
        fi
    fi
    unset MYSQL_PWD
    return 1
}

# Main DB backup entry: mrm_backup_database <dest_dir>
# Sets globals: DB_BACKUP_FILE, DB_BACKUP_DESC. Returns 0 = success.
DB_BACKUP_FILE=""; DB_BACKUP_DESC=""
mrm_backup_database() {
    local DEST_DIR="$1" CONT PROBE TYPE
    DB_BACKUP_FILE=""; DB_BACKUP_DESC=""
    CONT="$(mrm_panel_container)"
    log_backup "INFO" "Panel container: ${CONT:-NOT FOUND}"
    if [ -n "$CONT" ]; then
        PROBE="$(mrm_probe_database "$CONT")"
    fi
    TYPE="$(printf '%s' "$PROBE" | cut -d'|' -f1)"
    log_backup "INFO" "Database probe: ${PROBE:-none}"

    if [ "$TYPE" = "sqlite" ]; then
        local SQLITE_PATH
        SQLITE_PATH="$(printf '%s' "$PROBE" | cut -d'|' -f2-)"
        # 1) Host-visible path (official PasarGuard installs put the DB at
        #    /var/lib/pasarguard/db.sqlite3, which IS on the host volume)
        if [ -n "$SQLITE_PATH" ] && [ -f "$SQLITE_PATH" ]; then
            if mrm_sqlite_host_backup "$SQLITE_PATH" "$DEST_DIR/db.sqlite3"; then
                DB_BACKUP_FILE="$DEST_DIR/db.sqlite3"
                DB_BACKUP_DESC="SQLite ($(du -h "$DB_BACKUP_FILE" | cut -f1))"
                log_backup "SUCCESS" "SQLite exported from host path: $SQLITE_PATH"
                return 0
            fi
        fi
        # 2) Live backup API inside the running container (covers in-container DBs)
        if [ -n "$SQLITE_PATH" ] && [ -n "$CONT" ] && mrm_export_sqlite "$CONT" "$SQLITE_PATH" "$DEST_DIR/db.sqlite3"; then
            DB_BACKUP_FILE="$DEST_DIR/db.sqlite3"
            DB_BACKUP_DESC="SQLite ($(du -h "$DB_BACKUP_FILE" | cut -f1))"
            return 0
        fi
        # 3) Panel stopped? Cold-copy from the container filesystem
        local PCONT
        PCONT="$(mrm_find_panel_container)"
        if [ -n "$PCONT" ]; then
            local IN_PATH
            IN_PATH="$(mrm_sqlite_path_from_container "$PCONT")"
            if mrm_sqlite_cold_export "$PCONT" "$IN_PATH" "$DEST_DIR/db.sqlite3"; then
                DB_BACKUP_FILE="$DEST_DIR/db.sqlite3"
                DB_BACKUP_DESC="SQLite (cold copy $IN_PATH)"
                log_backup "SUCCESS" "SQLite cold-copied from stopped container: $IN_PATH"
                return 0
            fi
        fi
        # 4) Last resort: known host paths (older PasarGuard versions)
        local HOST_CAND
        for HOST_CAND in "$DATA_DIR/db.sqlite3" "$PANEL_DIR/db.sqlite3"; do
            if [ -f "$HOST_CAND" ] && [ -s "$HOST_CAND" ]; then
                cp "$HOST_CAND" "$DEST_DIR/db.sqlite3" 2>/dev/null || continue
                DB_BACKUP_FILE="$DEST_DIR/db.sqlite3"
                DB_BACKUP_DESC="SQLite (host copy)"
                log_backup "SUCCESS" "SQLite exported from host path: $HOST_CAND"
                return 0
            fi
        done
        log_backup "ERROR" "SQLite not found (probe=$SQLITE_PATH, host=$DATA_DIR|$PANEL_DIR)"
        return 1
    elif [ "$TYPE" = "postgres" ]; then
        local PHOST PPORT PUSER PPASS PDB
        PHOST="$(printf '%s' "$PROBE" | cut -d'|' -f2)"
        PPORT="$(printf '%s' "$PROBE" | cut -d'|' -f3)"
        PUSER="$(printf '%s' "$PROBE" | cut -d'|' -f4)"
        PPASS="$(mrm_b64dec "$(printf '%s' "$PROBE" | cut -d'|' -f5)")"
        PDB="$(printf '%s' "$PROBE" | cut -d'|' -f6)"
        if [ -n "$PUSER" ] && [ -n "$PDB" ] && mrm_export_postgres "$DEST_DIR/db.sql" "$PHOST" "$PPORT" "$PUSER" "$PPASS" "$PDB"; then
            DB_BACKUP_FILE="$DEST_DIR/db.sql"; DB_BACKUP_DESC="PostgreSQL"
            return 0
        fi
        # Legacy fallback credential sets
        local CRED TU TP TDB
        for CRED in "pasarguard|17240304|pasarguard" "marzban|marzban|marzban" "postgres||postgres"; do
            IFS='|' read -r TU TP TDB <<< "$CRED"
            [ -z "$TDB" ] && TDB="$TU"
            if mrm_export_postgres "$DEST_DIR/db.sql" "127.0.0.1" "5432" "$TU" "$TP" "$TDB"; then
                DB_BACKUP_FILE="$DEST_DIR/db.sql"; DB_BACKUP_DESC="PostgreSQL (fallback)"
                return 0
            fi
        done
        log_backup "ERROR" "PostgreSQL export failed ($PDB@$PHOST:$PPORT)"
        return 1
    elif [ "$TYPE" = "mysql" ]; then
        local MHOST MPORT MUSER MPASS MDB
        MHOST="$(printf '%s' "$PROBE" | cut -d'|' -f2)"
        MPORT="$(printf '%s' "$PROBE" | cut -d'|' -f3)"
        MUSER="$(printf '%s' "$PROBE" | cut -d'|' -f4)"
        MPASS="$(mrm_b64dec "$(printf '%s' "$PROBE" | cut -d'|' -f5)")"
        MDB="$(printf '%s' "$PROBE" | cut -d'|' -f6)"
        if [ -n "$MUSER" ] && [ -n "$MDB" ] && mrm_export_mysql "$DEST_DIR/db.sql" "$MHOST" "$MPORT" "$MUSER" "$MPASS" "$MDB"; then
            DB_BACKUP_FILE="$DEST_DIR/db.sql"; DB_BACKUP_DESC="MySQL/MariaDB"
            return 0
        fi
        log_backup "ERROR" "MySQL export failed"
        return 1
    fi

    # Probe failed / unknown -> fall back to old .env grep behavior
    log_backup "WARN" "DB probe failed, falling back to .env detection"
    if grep -qiE "postgresql|postgres" "$PANEL_ENV" 2>/dev/null; then
        parse_db_credentials "$PANEL_ENV"
        if mrm_export_postgres "$DEST_DIR/db.sql" "${DB_HOST:-127.0.0.1}" "5432" "${DB_USER:-pasarguard}" "$DB_PASS" "${DB_NAME:-pasarguard}"; then
            DB_BACKUP_FILE="$DEST_DIR/db.sql"; DB_BACKUP_DESC="PostgreSQL"
            return 0
        fi
        return 1
    fi
    # Assume sqlite, try host paths
    local HOST_CAND
    for HOST_CAND in "$DATA_DIR/db.sqlite3" "$PANEL_DIR/db.sqlite3"; do
        if mrm_sqlite_host_backup "$HOST_CAND" "$DEST_DIR/db.sqlite3"; then
            DB_BACKUP_FILE="$DEST_DIR/db.sqlite3"; DB_BACKUP_DESC="SQLite (host copy)"
            return 0
        fi
    done
    log_backup "ERROR" "No database found/exportable"
    return 1
}

# ==========================================
# Backup v${BACKUP_VERSION}
# ==========================================
do_backup() {
    local MODE="${1:-manual}"
    setup_env
    init_backup_logging

    [ "$MODE" != "auto" ] && clear
    [ "$MODE" != "auto" ] && ui_header "BACKUP v${BACKUP_VERSION}"

    log_backup "INFO" "========== Starting backup $MRM_BACKUP_VERSION mode: $MODE =========="
    log_backup "INFO" "PANEL_DIR: $PANEL_DIR DATA_DIR: $DATA_DIR"

    local TS
    local B_NAME
    local B_PATH
    local ARCHIVE_BASE
    local ARCHIVE_PATH
    local COPY_NUMBER=2

    TS="$(date +%Y%m%d_%H%M%S)"
    B_NAME="MRM_V1_${TS}"
    B_PATH="$TEMP_BASE/$B_NAME"
    ARCHIVE_BASE="MRM-${TS/_/-}"

    # Always clean temp first (avoid leftovers)
    rm -rf "$TEMP_BASE"
    mkdir -p "$B_PATH/database" "$B_PATH/panel" "$B_PATH/data" "$B_PATH/node"
    mkdir -p "$BACKUP_DIR"

    ARCHIVE_PATH="$BACKUP_DIR/${ARCHIVE_BASE}.tar.gz"
    while [ -e "$ARCHIVE_PATH" ]; do
        ARCHIVE_PATH="$BACKUP_DIR/${ARCHIVE_BASE}-${COPY_NUMBER}.tar.gz"
        COPY_NUMBER=$((COPY_NUMBER + 1))
    done

    # 1. Export Database - Core of backup
    [ "$MODE" != "auto" ] && ui_spinner_start "Exporting database..."
    local DB_SUCCESS=false
    local DB_SIZE="0"
    local DB_RAW_PATH=""

    if mrm_backup_database "$B_PATH/database"; then
        DB_SUCCESS=true
        DB_RAW_PATH="$DB_BACKUP_FILE"
        DB_SIZE=$(du -h "$DB_RAW_PATH" 2>/dev/null | cut -f1)
        log_backup "INFO" "DB exported: $DB_BACKUP_DESC ($DB_SIZE)"
        # Compress SQL dumps (postgres/mysql); sqlite stays raw (already compact)
        if [[ "$DB_RAW_PATH" == *.sql ]]; then
            if gzip -9 -c "$DB_RAW_PATH" > "$B_PATH/database/db.sql.gz"; then
                rm -f "$DB_RAW_PATH"
                DB_BACKUP_FILE="$B_PATH/database/db.sql.gz"
                DB_BACKUP_DESC="$DB_BACKUP_DESC (gzip -9)"
                log_backup "INFO" "DB compressed -> $(du -h "$DB_BACKUP_FILE" | cut -f1)"
            fi
        fi
        [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "Database exported ($DB_SIZE) [$DB_BACKUP_DESC]"
    else
        [ "$MODE" != "auto" ] && ui_spinner_stop && ui_error "Database export FAILED!"
        log_backup "ERROR" "Database export failed - backup will NOT contain the DB"
    fi

    if [ "$DB_SUCCESS" = false ] && [ "$MODE" != "auto" ]; then
        echo ""
        echo -e "${RED}⚠️  WARNING: Database export failed!${NC}"
        echo -e "${YELLOW}Backup will be created WITHOUT database.${NC}"
        echo -e "${YELLOW}You can still restore panel files but users will be lost.${NC}\n"
        read -p "Continue anyway? (y/N): " CONT
        if [[ ! "$CONT" =~ ^[Yy]$ ]]; then
            rm -rf "$TEMP_BASE"
            return
        fi
    fi

    # 2. Panel Essentials - ONLY what's needed
    [ "$MODE" != "auto" ] && ui_spinner_start "Backing up panel essentials..."
    
    # .env - most important
    if [ -f "$PANEL_ENV" ]; then
        cp "$PANEL_ENV" "$B_PATH/panel/.env" 2>/dev/null
        log_backup "INFO" "Copied PANEL_ENV"
    fi

    # docker-compose.yml - essential
    local PANEL_COMPOSE
    PANEL_COMPOSE="$(get_existing_compose_file panel 2>/dev/null || true)"
    if [ -n "$PANEL_COMPOSE" ] && [ -f "$PANEL_COMPOSE" ]; then
        cp "$PANEL_COMPOSE" "$B_PATH/panel/" 2>/dev/null
        log_backup "INFO" "Copied compose: $PANEL_COMPOSE"
    fi

    # templates - if customized
    if [ -d "$DATA_DIR/templates" ]; then
        mkdir -p "$B_PATH/data/templates"
        cp -a "$DATA_DIR/templates/." "$B_PATH/data/templates/" 2>/dev/null
        log_backup "INFO" "Copied templates"
    fi

    # certs - PasarGuard stores certs here, NOT in /etc/letsencrypt
    if [ -d "$DATA_DIR/certs" ]; then
        mkdir -p "$B_PATH/data/certs"
        cp -a "$DATA_DIR/certs/." "$B_PATH/data/certs/" 2>/dev/null
        log_backup "INFO" "Copied certs: $(du -sh "$DATA_DIR/certs" 2>/dev/null | cut -f1)"
    fi

    # xray_config.json if custom
    if [ -f "$DATA_DIR/xray_config.json" ]; then
        cp "$DATA_DIR/xray_config.json" "$B_PATH/data/" 2>/dev/null
    fi

    [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "Panel essentials backed up"

    # 3. Node Essentials - certs, .env, compose (+ xray-core & geo assets OPTIONAL).
    #    Default (MRM_BACKUP_XRAY unset/0): EXCLUDE xray binary & geo files so the
    #    backup stays small (~3-5MB, Telegram-safe). Restore auto-downloads them.
    #    Set MRM_BACKUP_XRAY=1 to include them for a fully OFFLINE self-contained
    #    restore (bigger backup ~40-50MB - may exceed the 50MB Telegram limit).
    local NODE_DATA_DIR
    NODE_DATA_DIR="$(dirname "$NODE_DEF_CERTS" 2>/dev/null)"
    [ -z "$NODE_DATA_DIR" ] && NODE_DATA_DIR="/var/lib/pg-node"
    if [ -d "$NODE_DIR" ] || [ -d "$NODE_DATA_DIR" ]; then
        [ "$MODE" != "auto" ] && ui_spinner_start "Backing up node essentials..."
        mkdir -p "$B_PATH/node"

        # .env
        if [ -f "$NODE_ENV" ]; then
            cp "$NODE_ENV" "$B_PATH/node/.env" 2>/dev/null
        fi

        # compose
        local NODE_COMPOSE_FILE
        NODE_COMPOSE_FILE="$(get_existing_compose_file node 2>/dev/null || true)"
        if [ -n "$NODE_COMPOSE_FILE" ] && [ -f "$NODE_COMPOSE_FILE" ]; then
            cp "$NODE_COMPOSE_FILE" "$B_PATH/node/" 2>/dev/null
        fi

        # certs
        if [ -d "$NODE_DEF_CERTS" ] && [ -n "$(ls -A "$NODE_DEF_CERTS" 2>/dev/null)" ]; then
            mkdir -p "$B_PATH/node/certs"
            cp -a "$NODE_DEF_CERTS/." "$B_PATH/node/certs/" 2>/dev/null
            log_backup "INFO" "Copied node certs"
        fi

        # xray-core binary + geo assets - only when MRM_BACKUP_XRAY=1 (offline restore)
        if [ "${MRM_BACKUP_XRAY:-0}" = "1" ]; then
            if [ -d "$NODE_DATA_DIR/xray-core" ] && [ -n "$(ls -A "$NODE_DATA_DIR/xray-core" 2>/dev/null)" ]; then
                mkdir -p "$B_PATH/node/xray-core"
                cp -a "$NODE_DATA_DIR/xray-core/." "$B_PATH/node/xray-core/" 2>/dev/null
                log_backup "INFO" "Copied node xray-core ($(du -sh "$NODE_DATA_DIR/xray-core" 2>/dev/null | cut -f1))"
            fi
            if [ -d "$NODE_DATA_DIR/assets" ] && [ -n "$(ls -A "$NODE_DATA_DIR/assets" 2>/dev/null)" ]; then
                mkdir -p "$B_PATH/node/assets"
                cp -a "$NODE_DATA_DIR/assets/." "$B_PATH/node/assets/" 2>/dev/null
                log_backup "INFO" "Copied node assets/geo ($(du -sh "$NODE_DATA_DIR/assets" 2>/dev/null | cut -f1))"
            fi
        else
            log_backup "INFO" "xray-core/geo excluded (MRM_BACKUP_XRAY=0) - restore will auto-download"
        fi

        [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "Node essentials backed up"
    fi

    # 4. Nginx - ONLY panel_separate.conf, NOT full /etc/nginx
    if [ -f "/etc/nginx/conf.d/panel_separate.conf" ]; then
        mkdir -p "$B_PATH/nginx"
        cp "/etc/nginx/conf.d/panel_separate.conf" "$B_PATH/nginx/" 2>/dev/null
        log_backup "INFO" "Copied nginx panel_separate.conf (not full nginx)"
    fi

    # 5. CLEANUP - Remove any heavy files that accidentally slipped in
    # This is the FIX for the 31MB issue you reported
    [ "$MODE" != "auto" ] && ui_spinner_start "Cleaning unnecessary heavy files..."

    # Remove backup loops
    rm -rf "$B_PATH/panel/backup" 2>/dev/null
    rm -rf "$B_PATH/data/backup" 2>/dev/null
    rm -rf "$B_PATH/panel/backups" 2>/dev/null
    rm -rf "$B_PATH/data/backups" 2>/dev/null
    find "$B_PATH" -type f -name "backup.zip" -delete 2>/dev/null
    find "$B_PATH" -type f -name "*.tar.gz" -path "*backup*" -delete 2>/dev/null
    find "$B_PATH" -type f -name "MRM_*.tar.gz" -delete 2>/dev/null

    # Remove Xray heavy files from PANEL/data copies (never needed there).
    # node/xray-core + node/assets are stripped by default (small backup);
    # kept only when MRM_BACKUP_XRAY=1 (offline self-contained restore).
    rm -rf "$B_PATH/node-data" 2>/dev/null
    rm -rf "$B_PATH/data/assets" 2>/dev/null
    rm -rf "$B_PATH/data/xray-core" 2>/dev/null
    rm -rf "$B_PATH/panel/assets" 2>/dev/null
    rm -rf "$B_PATH/panel/xray-core" 2>/dev/null
    find "$B_PATH/data" -type f \( -name "geoip.dat" -o -name "geosite.dat" -o -name "xray" \) -delete 2>/dev/null
    find "$B_PATH/panel" -type f \( -name "geoip.dat" -o -name "geosite.dat" -o -name "xray" \) -delete 2>/dev/null
    if [ "${MRM_BACKUP_XRAY:-0}" != "1" ]; then
        rm -rf "$B_PATH/node/assets" 2>/dev/null
        rm -rf "$B_PATH/node/xray-core" 2>/dev/null
        find "$B_PATH/node" -type f \( -name "geoip.dat" -o -name "geosite.dat" -o -name "xray" \) -delete 2>/dev/null
    fi

    # Remove logs, cache, tmp
    find "$B_PATH" -type f -name "*.log" -delete 2>/dev/null
    find "$B_PATH" -type f -name "*.tmp" -delete 2>/dev/null
    find "$B_PATH" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
    find "$B_PATH" -type d -name ".git" -exec rm -rf {} + 2>/dev/null || true
    find "$B_PATH" -type f -name "*.sqlite-wal" -delete 2>/dev/null
    find "$B_PATH" -type f -name "*.sqlite-shm" -delete 2>/dev/null
    find "$B_PATH" -type f -name "*.sock" -delete 2>/dev/null

    [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "Heavy files cleaned (fixed 31MB issue)"

    # 6. Metadata
    local SERVER_IP=$(get_server_ip)
    local TOTAL_RAW_SIZE=$(du -sh "$B_PATH" 2>/dev/null | cut -f1)
    
    cat > "$B_PATH/backup_info.txt" << EOF
========================================
MRM BACKUP  - $MRM_BACKUP_VERSION
========================================
Backup Date: $(date '+%Y-%m-%d %H:%M:%S')
Hostname: $(hostname)
Server IP: $SERVER_IP
Panel: $(basename "$PANEL_DIR")
Panel Dir: $PANEL_DIR
Data Dir: $DATA_DIR
Node Dir: $NODE_DIR
Database Exported: $DB_SUCCESS
Database Size: $DB_SIZE
Database Type: ${DB_BACKUP_DESC:-N/A}
Raw Size Before Compression: $TOTAL_RAW_SIZE
Version: $MRM_BACKUP_VERSION
Backup profile: v${BACKUP_VERSION}
Changes from v7.9:
- Excluded panel/backup/backup.zip recursive loop
- Excluded /etc/letsencrypt full (20MB) -> only data/certs
- Excluded /etc/nginx full (5MB) -> only panel_separate.conf
- Added gzip -9 for DB
- xray binary + geo files EXCLUDED by default -> small backup (~3-5MB)
- Restore auto-downloads xray + geo (needs internet on the target server)
- Set MRM_BACKUP_XRAY=1 to embed them for a fully offline restore (bigger backup)
EOF

    cat > "$B_PATH/file_list.txt" << EOF
=== Files in v${BACKUP_VERSION} Backup ===
$(find "$B_PATH" -type f | sort)
EOF

    cat > "$B_PATH/restore_guide.txt" << EOF
MRM BACKUP v${BACKUP_VERSION} - RESTORE GUIDE
=========================================

Auto Restore (Recommended):
1. mrm -> Backup & Restore -> Restore from Backup
2. Select this file
3. Done! Script will:
   - Stop services
   - Create safety backup
   - Restore .env, compose, certs, templates
   - Fix IPs for new server
   - Restore database (with gunzip if needed)
   - Start services
   - Apply smart fixes

Manual Restore (if needed):
1. Extract: tar -xzf MRM-*.tar.gz -C /tmp/
2. Panel:
   cp /tmp/MRM_V1_*/panel/.env $PANEL_DIR/.env
   cp /tmp/MRM_V1_*/panel/*.yml $PANEL_DIR/
3. Data:
   cp -a /tmp/MRM_V1_*/data/certs/* $DATA_DIR/certs/
   cp -a /tmp/MRM_V1_*/data/templates/* $DATA_DIR/templates/
4. Node (if exists):
   cp /tmp/MRM_V1_*/node/.env $NODE_DIR/.env
   cp -a /tmp/MRM_V1_*/node/certs/* /var/lib/pg-node/certs/
5. Database PostgreSQL:
   gunzip -c /tmp/MRM_V1_*/database/db.sql.gz | docker exec -i \$(docker ps --format '{{.Names}}' | grep -iE "postgres|timescale" | head -1) psql -U pasarguard -d pasarguard
   Or SQLite (PasarGuard v5 keeps it INSIDE the panel container at /code/db.sqlite3):
   docker cp /tmp/MRM_V1_*/database/db.sqlite3 \$(docker ps -q -f name=pasarguard | head -1):/tmp/restore.sqlite3
   docker exec -i \$(docker ps -q -f name=pasarguard | head -1) python -c "
import sqlite3
src=sqlite3.connect('/tmp/restore.sqlite3')
dst=sqlite3.connect('/code/db.sqlite3')
src.backup(dst); dst.close(); src.close()"
6. Restart:
   cd $PANEL_DIR && docker compose up -d

Note: This v${BACKUP_VERSION} backup does NOT contain the node xray binary or
geo files (kept small for Telegram). On restore, MRM re-downloads them
automatically - no manual steps, but the target server needs internet.
(Set MRM_BACKUP_XRAY=1 to embed them for a fully offline restore; backup will
be ~40-50MB and may exceed the 50MB Telegram upload limit.)

EOF

    # 7. Create archive with maximum compression + excludes (double safety)
    [ "$MODE" != "auto" ] && ui_spinner_start "Creating v${BACKUP_VERSION} archive (high compression)..."

    local SIZE_BEFORE=$(du -sb "$B_PATH" | cut -f1)

    # Excludes for tar (extra safety even though we already cleaned)
    local EXCLUDE_ARGS=(
        --exclude='*backup.zip'
        --exclude='*backup/*.zip'
        --exclude='*/backup/*'
        --exclude='*backups/*'
        --exclude='*.log'
        --exclude='*.tmp'
        --exclude='*.pid'
        --exclude='__pycache__'
        --exclude='*.pyc'
        --exclude='.git'
        --exclude='node_modules'
        --exclude='*.sqlite-wal'
        --exclude='*.sqlite-shm'
        --exclude='*.sock'
        --exclude='*MRM_*.tar.gz'
    )
    # Strip xray/geo only when they are excluded from the backup (default).
    if [ "${MRM_BACKUP_XRAY:-0}" != "1" ]; then
        EXCLUDE_ARGS+=(
            --exclude='*/assets/*'
            --exclude='*/xray-core/*'
            --exclude='*geoip.dat'
            --exclude='*geosite.dat'
            --exclude='*geodata*'
            --exclude='*/xray'
            --exclude='*xray-core'
        )
    fi

    if tar -czf "$ARCHIVE_PATH" "${EXCLUDE_ARGS[@]}" -C "$TEMP_BASE" "$B_NAME" 2>/dev/null; then
        local BACKUP_SIZE=$(du -h "$ARCHIVE_PATH" | cut -f1)
        local BACKUP_SIZE_BYTES=$(stat -c%s "$ARCHIVE_PATH" 2>/dev/null || echo "0")
        local SAVED_PERCENT=0
        if [ "$SIZE_BEFORE" -gt 0 ]; then
            SAVED_PERCENT=$((100 - BACKUP_SIZE_BYTES * 100 / SIZE_BEFORE))
        fi
        [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "v${BACKUP_VERSION} archive created ($BACKUP_SIZE, saved ${SAVED_PERCENT}% raw)"
    else
        [ "$MODE" != "auto" ] && ui_spinner_stop && ui_error "Failed to create archive!"
        log_backup "ERROR" "Failed to create tar.gz"
        rm -rf "$TEMP_BASE"
        return 1
    fi

    # 8. Cleanup temp
    rm -rf "$TEMP_BASE"

    # 9. Send to Telegram - Now small and fast
    local FINAL_SIZE=$(du -h "$ARCHIVE_PATH" | cut -f1)
    if [ -f "$TG_CONFIG" ]; then
        [ "$MODE" != "auto" ] && ui_spinner_start "Sending v${BACKUP_VERSION} backup to Telegram ($FINAL_SIZE)..."
        if send_to_telegram "$ARCHIVE_PATH"; then
            [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "v${BACKUP_VERSION} backup sent to Telegram! ($FINAL_SIZE)"
        else
            [ "$MODE" != "auto" ] && ui_spinner_stop && ui_warning "Telegram send failed - check log. Size: $FINAL_SIZE"
        fi
        # Loud warning when the DB is missing (how the 39KB backups happened)
        if [ "$DB_SUCCESS" = false ]; then
            send_to_telegram "" "⚠️ MRM Backup created WITHOUT DATABASE!
File: $(basename "$ARCHIVE_PATH") ($FINAL_SIZE)
Reason: Database export failed - see /var/log/mrm-backup.log
Check: SQLite lives inside the panel container in PasarGuard v5." >/dev/null 2>&1 || true
            log_backup "ERROR" "Backup has NO DATABASE - sent Telegram warning"
        fi
    fi

    # 10. Rotate old backups - keep last 7
    ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | tail -n +8 | xargs rm -f 2>/dev/null || true

    log_backup "SUCCESS" "v${BACKUP_VERSION} backup completed: $(basename "$ARCHIVE_PATH") ($FINAL_SIZE)"
    log_backup "INFO" "========== Backup v${BACKUP_VERSION} finished =========="

    if [ "$MODE" != "auto" ]; then
        echo ""
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║          ✔ BACKUP v${BACKUP_VERSION} COMPLETED!                ║${NC}"
        echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${GREEN}║${NC} File: ${CYAN}$(basename "$ARCHIVE_PATH")${NC}"
        echo -e "${GREEN}║${NC} Size: ${CYAN}$FINAL_SIZE${NC}"
        echo -e "${GREEN}║${NC} Raw Size: $TOTAL_RAW_SIZE -> Compressed: $FINAL_SIZE"
        if [ "$DB_SUCCESS" = false ]; then
            echo -e "${GREEN}║${NC} Database: ${RED}NOT EXPORTED${NC}"
        else
            echo -e "${GREEN}║${NC} Database: ${GREEN}Exported${NC} ($DB_SIZE) [${DB_BACKUP_DESC}]"
        fi
        if [ "${MRM_BACKUP_XRAY:-0}" = "1" ]; then
            echo -e "${GREEN}║${NC} xray/geo: ${GREEN}included (offline restore)${NC}"
        else
            echo -e "${GREEN}║${NC} xray/geo: ${YELLOW}excluded - auto-download on restore${NC}"
        fi
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
                echo ""
        pause
    fi
}

# ==========================================
# RESTORE v${BACKUP_VERSION}
# ==========================================
do_restore() {
    clear
    ui_header "RESTORE FROM BACKUP - v${BACKUP_VERSION}"
    setup_env
    init_backup_logging

    local FILES=($(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null))
    if [ ${#FILES[@]} -eq 0 ]; then
        ui_error "No backups found in $BACKUP_DIR"
        echo -e "Upload backup manually to $BACKUP_DIR or download from Telegram"
        pause
        return 1
    fi

    echo -e "${YELLOW}Select backup to restore:${NC}\n"
    for i in "${!FILES[@]}"; do
        local SIZE=$(du -h "${FILES[$i]}" | cut -f1)
        local DATE=$(stat -c %y "${FILES[$i]}" | cut -d' ' -f1)
        local TYPE="v${BACKUP_VERSION}"
        [[ "$(basename "${FILES[$i]}")" == *"Full"* ]] && TYPE="FULL-OLD"
        [[ "$(basename "${FILES[$i]}")" == *"Lite"* ]] && TYPE="LITE-OLD"
        [[ "$(basename "${FILES[$i]}")" == *"V1"* ]] && TYPE="v${BACKUP_VERSION}"
        echo "$((i+1))) [$TYPE] $(basename "${FILES[$i]}") [$SIZE] - $DATE"
    done
    echo ""
    read -p "Select (0 to cancel): " SEL
    [ "$SEL" == "0" ] && return
    local SELECTED="${FILES[$((SEL-1))]}"
    if [ -z "$SELECTED" ] || [ ! -f "$SELECTED" ]; then ui_error "Invalid selection"; pause; return 1; fi

    echo ""
    echo -e "${RED}⚠️  WARNING: This will overwrite current panel data!${NC}"
    echo -e "${YELLOW}Selected: $(basename "$SELECTED") ($(du -h "$SELECTED" | cut -f1))${NC}"
    echo -e "${CYAN}Safety backup will be created automatically.${NC}\n"
    read -p "Continue restore? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then echo "Cancelled"; pause; return; fi

    log_backup "INFO" "Starting restore v${BACKUP_VERSION} from: $(basename "$SELECTED")"

    local WORK_DIR="$TEMP_BASE/restore_$(date +%s)"
    mkdir -p "$WORK_DIR"
    
    # Cleanup trap
    trap 'rm -rf "$WORK_DIR"; trap - RETURN' RETURN

    ui_spinner_start "Extracting backup..."
    if ! tar -xzf "$SELECTED" -C "$WORK_DIR" 2>/dev/null; then
        ui_spinner_stop
        ui_error "Failed to extract backup! File may be corrupted."
        rm -rf "$WORK_DIR"
        trap - RETURN
        pause
        return 1
    fi
    ui_spinner_stop

    local ROOT=$(find "$WORK_DIR" -maxdepth 3 -type d -name "MRM_*" | head -1)
    if [ -z "$ROOT" ]; then ROOT=$(find "$WORK_DIR" -maxdepth 2 -type f -name "backup_info.txt" -printf "%h" | head -1); fi
    if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
        # Try to find any directory
        ROOT=$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)
    fi
    if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
        ui_error "Invalid backup structure - no root found"
        log_backup "ERROR" "Invalid backup structure"
        rm -rf "$WORK_DIR"
        trap - RETURN
        pause
        return 1
    fi

    log_backup "INFO" "Restore root: $ROOT"

    # Detect backup type
    local IS_V1=false IS_LITE=false IS_FULL=false
    if [[ "$(basename "$SELECTED")" == *"V1"* ]]; then IS_V1=true
    elif tar -tzf "$SELECTED" 2>/dev/null | grep -q "MRM_V1" || [ -f "$ROOT/backup_info.txt" ] && grep -q "V1" "$ROOT/backup_info.txt" 2>/dev/null; then IS_V1=true
    elif [[ "$(basename "$SELECTED")" == *"Full"* ]]; then IS_FULL=true
    else IS_LITE=true; fi

    # Show info if available
    if [ -f "$ROOT/backup_info.txt" ]; then
        echo -e "\n${CYAN}Backup Info:${NC}"
        cat "$ROOT/backup_info.txt"
        echo ""
    fi

    # =========================================================
    # 0) SAFETY BACKUP FIRST - while everything is STILL RUNNING.
    #    Includes a live export of the current database, so a failed
    #    restore can NEVER destroy the original data.
    # =========================================================
    ui_spinner_start "Creating safety backup (with live database)..."
    local SAFETY_BACKUP="$BACKUP_DIR/pre_restore_$(date +%Y%m%d_%H%M%S).tar.gz"
    local SAFETY_DIR="$TEMP_BASE/safety_$(date +%s)"
    mkdir -p "$SAFETY_DIR"
    local SAFETY_DB_OK=false
    if mrm_backup_database "$SAFETY_DIR" >/dev/null 2>&1; then
        if [ -n "$DB_BACKUP_FILE" ] && [ -f "$DB_BACKUP_FILE" ]; then
            mv -f "$DB_BACKUP_FILE" "$SAFETY_DIR/current_db_backup" 2>/dev/null
            SAFETY_DB_OK=true
            log_backup "INFO" "Safety backup includes live DB: $DB_BACKUP_DESC"
        fi
    else
        log_backup "WARN" "Could not export live DB for safety backup"
    fi
    local SAFETY_ITEMS=()
    [ -d "$PANEL_DIR" ] && SAFETY_ITEMS+=("$PANEL_DIR")
    [ -d "$DATA_DIR" ] && SAFETY_ITEMS+=("$DATA_DIR")
    [ -f "$PANEL_ENV" ] && SAFETY_ITEMS+=("$PANEL_ENV")
    [ -f "$SAFETY_DIR/current_db_backup" ] && SAFETY_ITEMS+=("$SAFETY_DIR/current_db_backup")
    if [ "${#SAFETY_ITEMS[@]}" -gt 0 ]; then
        if tar -czf "$SAFETY_BACKUP" "${SAFETY_ITEMS[@]}" 2>/dev/null; then
            ui_spinner_stop
            if [ "$SAFETY_DB_OK" = true ]; then
                ui_success "Safety backup incl. live DB: $(basename "$SAFETY_BACKUP")"
            else
                ui_warning "Safety backup created WITHOUT database"
            fi
            log_backup "INFO" "Safety backup created: $SAFETY_BACKUP (db=$SAFETY_DB_OK)"
            rm -rf "$SAFETY_DIR"
        else
            ui_spinner_stop
            ui_warning "Safety backup FAILED - keeping raw files for manual recovery:"
            if [ -f "$SAFETY_DIR/current_db_backup" ]; then
                local KEEP_DB="$BACKUP_DIR/pre_restore_db_$(date +%Y%m%d_%H%M%S)$(basename "$DB_BACKUP_FILE")"
                mv -f "$SAFETY_DIR/current_db_backup" "$KEEP_DB" 2>/dev/null
                echo -e "  ${RED}⚠ Raw DB saved: ${YELLOW}$KEEP_DB${NC}"
                log_backup "ERROR" "Safety tar failed; raw DB kept at $KEEP_DB"
            fi
        fi
    else
        ui_spinner_stop
        ui_warning "No existing data for safety backup"
        rm -rf "$SAFETY_DIR"
    fi

    # Stop services. We use `stop` (NOT `down`) so the container and its
    # writable layer are preserved - needed to copy the DB in/out safely.
    ui_spinner_start "Stopping services..."
    local PANEL_COMPOSE_FILE NODE_COMPOSE_FILE
    PANEL_COMPOSE_FILE="$(get_existing_compose_file panel 2>/dev/null || true)"
    NODE_COMPOSE_FILE="$(get_existing_compose_file node 2>/dev/null || true)"
    [ -n "$PANEL_COMPOSE_FILE" ] && run_compose_file "$PANEL_COMPOSE_FILE" stop >/dev/null 2>&1 || true
    [ -n "$NODE_COMPOSE_FILE" ] && run_compose_file "$NODE_COMPOSE_FILE" stop >/dev/null 2>&1 || true
    sleep 2
    ui_spinner_stop
    ui_success "Services stopped"

    # Restore based on type
    if [ "$IS_FULL" = true ]; then
        # FULL LEGACY RESTORE
        log_backup "INFO" "Restoring FULL legacy backup"
        ui_spinner_start "Restoring FULL backup files..."
        mkdir -p "$PANEL_DIR" "$DATA_DIR"
        # Remove old (except we already have safety)
        # For FULL, we restore everything but still exclude heavy files loop
        if [ -d "$ROOT/panel" ]; then cp -a "$ROOT/panel/." "$PANEL_DIR/" 2>/dev/null; fi
        if [ -d "$ROOT/data" ]; then cp -a "$ROOT/data/." "$DATA_DIR/" 2>/dev/null; fi
        if [ -d "$ROOT/node" ]; then
            mkdir -p "$NODE_DIR"
            cp -a "$ROOT/node/." "$NODE_DIR/" 2>/dev/null
        fi
        if [ -d "$ROOT/node-data" ]; then
            mkdir -p "$(dirname "$NODE_DEF_CERTS")"
            cp -a "$ROOT/node-data/." "$(dirname "$NODE_DEF_CERTS")/" 2>/dev/null
        fi
        if [ -d "$ROOT/ssl" ] && [ -n "$(ls -A "$ROOT/ssl" 2>/dev/null)" ]; then
            mkdir -p /etc/letsencrypt
            cp -a "$ROOT/ssl/." /etc/letsencrypt/ 2>/dev/null
        fi
        if [ -d "$ROOT/nginx" ] && [ -n "$(ls -A "$ROOT/nginx" 2>/dev/null)" ]; then
            mkdir -p /etc/nginx
            cp -a "$ROOT/nginx/." /etc/nginx/ 2>/dev/null
        fi
        # Safety net: Ensure node SSL certs exist (FULL restore)
        if [ -n "$NODE_DEF_CERTS" ]; then
            mkdir -p "$NODE_DEF_CERTS" 2>/dev/null
            if [ ! -f "$NODE_DEF_CERTS/ssl_cert.pem" ] || [ ! -f "$NODE_DEF_CERTS/ssl_key.pem" ]; then
                openssl req -x509 -newkey rsa:2048 \
                    -keyout "$NODE_DEF_CERTS/ssl_key.pem" \
                    -out "$NODE_DEF_CERTS/ssl_cert.pem" \
                    -days 3650 -nodes \
                    -subj "/CN=PasarGuard-Node" 2>/dev/null || true
                log_backup "INFO" "Generated self-signed SSL for node (FULL restore)"
            fi
        fi

        chmod -R 755 "$DATA_DIR" 2>/dev/null || true
        chown -R 1000:1000 "$DATA_DIR" 2>/dev/null || true
        ui_spinner_stop
        ui_success "FULL files restored"
    else
        # Restore essentials
        log_backup "INFO" "Restoring v${BACKUP_VERSION} essentials"
        ui_spinner_start "Restoring v${BACKUP_VERSION} essentials..."

        mkdir -p "$PANEL_DIR" "$DATA_DIR"

        # Panel .env
        if [ -f "$ROOT/panel/.env" ]; then
            cp "$ROOT/panel/.env" "$PANEL_ENV" 2>/dev/null
            log_backup "INFO" "Restored panel .env"
        fi

        # Panel compose
        local RESTORED_COMPOSE=false
        for f in "$ROOT/panel/"*.yml "$ROOT/panel/"*.yaml; do
            if [ -f "$f" ]; then
                cp "$f" "$PANEL_DIR/" 2>/dev/null
                RESTORED_COMPOSE=true
            fi
        done

        # Data templates
        if [ -d "$ROOT/data/templates" ]; then
            mkdir -p "$DATA_DIR/templates"
            cp -a "$ROOT/data/templates/." "$DATA_DIR/templates/" 2>/dev/null
            log_backup "INFO" "Restored templates"
        fi

        # Data certs
        if [ -d "$ROOT/data/certs" ]; then
            mkdir -p "$DATA_DIR/certs"
            cp -a "$ROOT/data/certs/." "$DATA_DIR/certs/" 2>/dev/null
            log_backup "INFO" "Restored certs"
        fi

        # xray_config.json if exists
        if [ -f "$ROOT/data/xray_config.json" ]; then
            cp "$ROOT/data/xray_config.json" "$DATA_DIR/" 2>/dev/null
        fi

        # Nginx panel_separate.conf
        if [ -f "$ROOT/nginx/panel_separate.conf" ]; then
            mkdir -p "/etc/nginx/conf.d"
            cp "$ROOT/nginx/panel_separate.conf" "/etc/nginx/conf.d/" 2>/dev/null
        fi

        # Node essentials - certs, .env, compose + xray-core & geo assets
        if [ -d "$ROOT/node" ]; then
            mkdir -p "$NODE_DIR"
            if [ -f "$ROOT/node/.env" ]; then
                cp "$ROOT/node/.env" "$NODE_ENV" 2>/dev/null
            fi
            for f in "$ROOT/node/"*.yml "$ROOT/node/"*.yaml; do
                [ -f "$f" ] && cp "$f" "$NODE_DIR/" 2>/dev/null
            done
            if [ -d "$ROOT/node/certs" ]; then
                mkdir -p "$NODE_DEF_CERTS"
                cp -a "$ROOT/node/certs/." "$NODE_DEF_CERTS/" 2>/dev/null
            fi
            # xray-core + geo assets -> restore works OFFLINE, zero manual steps
            local NODE_DATA_DIR
            NODE_DATA_DIR="$(dirname "$NODE_DEF_CERTS" 2>/dev/null)"
            [ -z "$NODE_DATA_DIR" ] && NODE_DATA_DIR="/var/lib/pg-node"
            if [ -d "$ROOT/node/xray-core" ]; then
                mkdir -p "$NODE_DATA_DIR/xray-core"
                cp -a "$ROOT/node/xray-core/." "$NODE_DATA_DIR/xray-core/" 2>/dev/null
                chmod +x "$NODE_DATA_DIR/xray-core/xray" 2>/dev/null || true
                log_backup "INFO" "Restored node xray-core -> $NODE_DATA_DIR/xray-core"
            fi
            if [ -d "$ROOT/node/assets" ]; then
                mkdir -p "$NODE_DATA_DIR/assets"
                cp -a "$ROOT/node/assets/." "$NODE_DATA_DIR/assets/" 2>/dev/null
                log_backup "INFO" "Restored node assets/geo -> $NODE_DATA_DIR/assets"
            fi
        fi

        # Safety net: Ensure node SSL certs exist (generate if missing from backup)
        if [ -n "$NODE_DEF_CERTS" ]; then
            mkdir -p "$NODE_DEF_CERTS" 2>/dev/null
            if [ ! -f "$NODE_DEF_CERTS/ssl_cert.pem" ] || [ ! -f "$NODE_DEF_CERTS/ssl_key.pem" ]; then
                log_backup "INFO" "Node SSL certs missing - generating self-signed"
                openssl req -x509 -newkey rsa:2048 \
                    -keyout "$NODE_DEF_CERTS/ssl_key.pem" \
                    -out "$NODE_DEF_CERTS/ssl_cert.pem" \
                    -days 3650 -nodes \
                    -subj "/CN=PasarGuard-Node" 2>/dev/null || true
                [ -f "$NODE_DEF_CERTS/ssl_cert.pem" ] && log_backup "SUCCESS" "Node SSL certs generated"
            fi
        fi

        # Fix perms
        chmod -R 755 "$DATA_DIR" 2>/dev/null || true
        chown -R 1000:1000 "$DATA_DIR" 2>/dev/null || true

        ui_spinner_stop
        ui_success "v${BACKUP_VERSION} essentials restored"
    fi

    # NOTE: We deliberately do NOT rewrite .env / apply smart fixes here.
    # fix_env_file + apply_smart_fix used to mangle the panel .env during
    # restore, which caused DB connection errors after restore.
    # Restored files are used as-is from the backup.
    echo -e "${CYAN}✓ Restored files are used as-is (no auto .env rewrite).${NC}"
    echo -e "${YELLOW}If you need firewall fixes, use 'Smart Fix' from the Backup menu.${NC}"
    sleep 1

    # Fix IPs in docker-compose ONLY (safe: touches the compose file, NEVER .env).
    # Needed when restoring on a server with a different IP (e.g. pgadmin
    # "Address not available" because PGADMIN_LISTEN_ADDRESS points to an
    # IP that no longer exists on this host).
    ui_spinner_start "Updating IPs in docker-compose..."
    if fix_docker_compose; then
        ui_spinner_stop
        ui_success "Docker compose IPs updated to current server IP"
    else
        ui_spinner_stop
        ui_warning "Compose IP update skipped (compose not found or IP undetectable)"
    fi

    # =========================================================
    # DATABASE RESTORE - while the panel is STOPPED (no locks, no
    # live-write races, no "database is being accessed by other users").
    # =========================================================
    local DB_RESTORE_PATH=""
    local DB_IS_GZ=false
    local DB_IS_SQLITE=false
    local DB_PICK
    DB_PICK="$(mrm_pick_db_restore "$ROOT")"
    case "$(printf '%s' "$DB_PICK" | cut -d'|' -f1)" in
        sqlite) DB_IS_SQLITE=true ;;
        gz)     DB_IS_GZ=true ;;
    esac
    DB_RESTORE_PATH="$(printf '%s' "$DB_PICK" | cut -d'|' -f2-)"

    if [ -n "$DB_RESTORE_PATH" ]; then
        log_backup "INFO" "Found DB to restore: $DB_RESTORE_PATH (sqlite=$DB_IS_SQLITE gz=$DB_IS_GZ)"

        if [ "$DB_IS_SQLITE" = true ]; then
            # --- SQLite restore (panel stopped -> plain file copy is safe) ---
            ui_spinner_start "Restoring SQLite database..."
            local DB_IMPORTED=false
            local TARGET_SQLITE=""
            # Where does the RESTORED config want the DB? (parse the restored .env)
            local ENV_URL
            ENV_URL="$(grep -m1 '^SQLALCHEMY_DATABASE_URL' "$PANEL_ENV" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            if [ -n "$ENV_URL" ]; then
                TARGET_SQLITE="$(mrm_sqlite_path_from_url "$ENV_URL")"
                log_backup "INFO" "SQLite target from restored .env: $TARGET_SQLITE"
            fi

            # 1) Host-visible absolute path (official installs: /var/lib/pasarguard/db.sqlite3)
            if [ -n "$TARGET_SQLITE" ] && [[ "$TARGET_SQLITE" == /* ]]; then
                local TARGET_DIR D_OWNER
                TARGET_DIR="$(dirname "$TARGET_SQLITE")"
                mkdir -p "$TARGET_DIR" 2>/dev/null
                if [ -d "$TARGET_DIR" ] && cp -f "$DB_RESTORE_PATH" "$TARGET_SQLITE" 2>/dev/null; then
                    # Match ownership of the data dir (panel may run as non-root)
                    D_OWNER="$(stat -c '%u:%g' "$TARGET_DIR" 2>/dev/null)"
                    [ -n "$D_OWNER" ] && chown "$D_OWNER" "$TARGET_SQLITE" 2>/dev/null || true
                    chmod 600 "$TARGET_SQLITE" 2>/dev/null || true
                    DB_IMPORTED=true
                    log_backup "SUCCESS" "SQLite restored to host path: $TARGET_SQLITE"
                fi
            fi

            # 2) In-container DB: copy directly into the (stopped) container filesystem
            if [ "$DB_IMPORTED" = false ]; then
                local PCONT IN_PATH WD
                PCONT="$(mrm_find_panel_container)"
                if [ -n "$PCONT" ]; then
                    if [ -n "$TARGET_SQLITE" ]; then
                        if [[ "$TARGET_SQLITE" == /* ]]; then
                            IN_PATH="$TARGET_SQLITE"
                        else
                            WD="$(docker inspect -f '{{.Config.WorkingDir}}' "$PCONT" 2>/dev/null)"
                            [ -z "$WD" ] && WD="/code"
                            IN_PATH="${WD%/}/$TARGET_SQLITE"
                        fi
                    else
                        IN_PATH="$(mrm_sqlite_path_from_container "$PCONT")"
                    fi
                    if docker cp "$DB_RESTORE_PATH" "$PCONT:$IN_PATH" >/dev/null 2>&1; then
                        DB_IMPORTED=true
                        log_backup "SUCCESS" "SQLite restored into container: $IN_PATH"
                    else
                        log_backup "ERROR" "docker cp to container failed: $IN_PATH"
                    fi
                else
                    log_backup "ERROR" "No panel container found for SQLite restore"
                fi
            fi

            # 3) Last resort: known host paths (older PasarGuard stored DB on volume)
            if [ "$DB_IMPORTED" = false ]; then
                local HOST_CAND
                for HOST_CAND in "$DATA_DIR/db.sqlite3" "$PANEL_DIR/db.sqlite3"; do
                    if cp -f "$DB_RESTORE_PATH" "$HOST_CAND" 2>/dev/null; then
                        DB_IMPORTED=true
                        log_backup "SUCCESS" "SQLite restored to host path: $HOST_CAND"
                        break
                    fi
                done
            fi

            ui_spinner_stop
            if [ "$DB_IMPORTED" = true ]; then
                ui_success "SQLite database restored!"
            else
                ui_error "SQLite import failed - check /var/log/mrm-backup.log"
            fi
        else
            # --- PostgreSQL / MySQL dump restore (panel stopped -> no locks) ---
            local DB_IMPORTED=false
            if grep -qiE "postgresql|postgres" "$PANEL_ENV" 2>/dev/null; then
                ui_spinner_start "Importing PostgreSQL database..."
                # Find the DB container even if stopped; start it if needed
                local DB_CONT
                DB_CONT=$(docker ps --format '{{.Names}}' | grep -iE "postgres|timescale" | head -1)
                if [ -z "$DB_CONT" ]; then
                    DB_CONT=$(docker ps -a --format '{{.Names}}' | grep -iE "postgres|timescale" | head -1)
                    [ -n "$DB_CONT" ] && docker start "$DB_CONT" >/dev/null 2>&1
                fi
                # NEW SERVER FIX: If no postgres container exists at all (brand new server),
                # start it from the restored docker-compose to create it
                if [ -z "$DB_CONT" ] && [ -n "$PANEL_COMPOSE_FILE" ] && [ -f "$PANEL_COMPOSE_FILE" ]; then
                    log_backup "INFO" "No postgres container found - starting from restored compose (new server)"
                    run_compose_file "$PANEL_COMPOSE_FILE" up -d postgres db postgresql >/dev/null 2>&1 || true
                    sleep 3
                    DB_CONT=$(docker ps --format '{{.Names}}' | grep -iE "postgres|timescale" | head -1)
                    if [ -n "$DB_CONT" ]; then
                        log_backup "SUCCESS" "Postgres container created from compose: $DB_CONT"
                    else
                        log_backup "ERROR" "Could not create postgres container from compose"
                    fi
                fi
                # Wait until it accepts connections (max ~30s)
                local TRIES=0
                while [ "$TRIES" -lt 30 ]; do
                    if [ -n "$DB_CONT" ] && docker exec "$DB_CONT" pg_isready -U postgres >/dev/null 2>&1; then break; fi
                    sleep 1; TRIES=$((TRIES+1))
                done
                if [ -n "$DB_CONT" ]; then
                    parse_db_credentials "$PANEL_ENV"
                    [ -z "$DB_USER" ] && DB_USER="pasarguard"
                    [ -z "$DB_NAME" ] && DB_NAME="$DB_USER"

                    local SQL_FILE="$DB_RESTORE_PATH"
                    local TEMP_SQL=""

                    if [ "$DB_IS_GZ" = true ]; then
                        TEMP_SQL="$ROOT/database/db.sql"
                        if gunzip -c "$DB_RESTORE_PATH" > "$TEMP_SQL" 2>/dev/null; then
                            SQL_FILE="$TEMP_SQL"
                        else
                            log_backup "ERROR" "Failed to gunzip DB"
                        fi
                    fi

                    if [ -n "$DB_PASS" ]; then
                        if docker exec -e PGPASSWORD="$DB_PASS" "$DB_CONT" psql -U "$DB_USER" -d "$DB_NAME" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null 2>&1 && \
                           cat "$SQL_FILE" | docker exec -i -e PGPASSWORD="$DB_PASS" "$DB_CONT" psql -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
                            DB_IMPORTED=true
                        fi
                    else
                        if docker exec "$DB_CONT" psql -U "$DB_USER" -d "$DB_NAME" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null 2>&1 && \
                           cat "$SQL_FILE" | docker exec -i "$DB_CONT" psql -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
                            DB_IMPORTED=true
                        fi
                    fi

                    [ "$DB_IS_GZ" = true ] && [ -f "$TEMP_SQL" ] && [ "$TEMP_SQL" != "$DB_RESTORE_PATH" ] && rm -f "$TEMP_SQL"
                else
                    # Try host psql as a fallback
                    if command -v psql >/dev/null 2>&1; then
                        local SQL_FILE2="$DB_RESTORE_PATH"
                        if [ "$DB_IS_GZ" = true ]; then
                            SQL_FILE2="$ROOT/database/db.sql"
                            gunzip -c "$DB_RESTORE_PATH" > "$SQL_FILE2" 2>/dev/null
                        fi
                        parse_db_credentials "$PANEL_ENV"
                        [ -z "$DB_USER" ] && DB_USER="pasarguard"
                        [ -z "$DB_NAME" ] && DB_NAME="$DB_USER"
                        export PGPASSWORD="$DB_PASS"
                        if psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null 2>&1 && \
                           psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -f "$SQL_FILE2" >/dev/null 2>&1; then
                            DB_IMPORTED=true
                        fi
                        unset PGPASSWORD
                        [ "$DB_IS_GZ" = true ] && [ -f "$SQL_FILE2" ] && rm -f "$SQL_FILE2"
                    else
                        log_backup "ERROR" "No DB container or psql found for restore"
                    fi
                fi
                ui_spinner_stop
                if [ "$DB_IMPORTED" = true ]; then ui_success "PostgreSQL database imported successfully!"; log_backup "SUCCESS" "PostgreSQL DB imported"; else ui_error "PostgreSQL database import failed! Check logs"; log_backup "ERROR" "PostgreSQL DB import failed"; fi
            elif grep -qiE "mysql|mariadb" "$PANEL_ENV" 2>/dev/null; then
                ui_spinner_start "Importing MySQL/MariaDB database..."
                local DB_CONT
                DB_CONT=$(docker ps --format '{{.Names}}' | grep -iE "mysql|mariadb" | head -1)
                if [ -z "$DB_CONT" ]; then
                    DB_CONT=$(docker ps -a --format '{{.Names}}' | grep -iE "mysql|mariadb" | head -1)
                    [ -n "$DB_CONT" ] && docker start "$DB_CONT" >/dev/null 2>&1
                fi
                # NEW SERVER FIX: If no mysql container exists at all (brand new server),
                # start it from the restored docker-compose to create it
                if [ -z "$DB_CONT" ] && [ -n "$PANEL_COMPOSE_FILE" ] && [ -f "$PANEL_COMPOSE_FILE" ]; then
                    log_backup "INFO" "No MySQL container found - starting from restored compose (new server)"
                    run_compose_file "$PANEL_COMPOSE_FILE" up -d mysql mariadb db >/dev/null 2>&1 || true
                    sleep 3
                    DB_CONT=$(docker ps --format '{{.Names}}' | grep -iE "mysql|mariadb" | head -1)
                    if [ -n "$DB_CONT" ]; then
                        log_backup "SUCCESS" "MySQL container created from compose: $DB_CONT"
                    fi
                fi
                if [ -n "$DB_CONT" ]; then
                    # Wait for MySQL to be ready (max 30s)
                    local MYSQL_TRIES=0
                    while [ "$MYSQL_TRIES" -lt 30 ]; do
                        if docker exec "$DB_CONT" mysqladmin ping -u root >/dev/null 2>&1; then break; fi
                        sleep 1; MYSQL_TRIES=$((MYSQL_TRIES+1))
                    done
                fi
                if [ -n "$DB_CONT" ]; then
                    parse_db_credentials "$PANEL_ENV"
                    [ -z "$DB_USER" ] && DB_USER="pasarguard"
                    [ -z "$DB_NAME" ] && DB_NAME="$DB_USER"
                    local SQL_FILE="$DB_RESTORE_PATH"
                    local TEMP_SQL=""
                    if [ "$DB_IS_GZ" = true ]; then
                        TEMP_SQL="$ROOT/database/db.sql"
                        gunzip -c "$DB_RESTORE_PATH" > "$TEMP_SQL" 2>/dev/null && SQL_FILE="$TEMP_SQL"
                    fi
                    if docker exec -e MYSQL_PWD="$DB_PASS" "$DB_CONT" mysql -u "$DB_USER" "$DB_NAME" < "$SQL_FILE" 2>/dev/null; then
                        DB_IMPORTED=true
                    fi
                    [ "$DB_IS_GZ" = true ] && [ -f "$TEMP_SQL" ] && [ "$TEMP_SQL" != "$DB_RESTORE_PATH" ] && rm -f "$TEMP_SQL"
                fi
                ui_spinner_stop
                if [ "$DB_IMPORTED" = true ]; then ui_success "MySQL database imported successfully!"; log_backup "SUCCESS" "MySQL DB imported"; else ui_error "MySQL database import failed!"; log_backup "ERROR" "MySQL DB import failed"; fi
            fi
        fi
    else
        log_backup "WARNING" "No database file found in backup to restore"
        ui_warning "No database found in backup - only files restored"
    fi

    # Ensure xray-core binary BEFORE starting services (fixes Error_Node on restore)
    # xray-core is excluded from small backups (MRM_BACKUP_XRAY=0 by default),
    # so on a new server the binary is missing. We must download it BEFORE the
    # node container starts, otherwise the node fails with:
    #   "fork/exec /var/lib/pg-node/xray-core/xray: no such file or directory"
    local XRAY_WAS_DOWNLOADED=false
    local XRAY_BIN_PATH=""
    XRAY_BIN_PATH="$(dirname "${NODE_DEF_CERTS:-/var/lib/pg-node/certs}" 2>/dev/null)"
    [ -z "$XRAY_BIN_PATH" ] && XRAY_BIN_PATH="/var/lib/pg-node"
    XRAY_BIN_PATH="$XRAY_BIN_PATH/xray-core/xray"

    ui_spinner_start "Checking xray-core binary (must exist before node starts)..."
    if [ -x "$XRAY_BIN_PATH" ] && "$XRAY_BIN_PATH" -version >/dev/null 2>&1; then
        ui_spinner_stop
        ui_success "xray-core already present and working"
        log_backup "INFO" "xray-core already present: $XRAY_BIN_PATH"
    else
        ui_spinner_stop
        log_backup "INFO" "xray-core missing at $XRAY_BIN_PATH - downloading before service start"
        ui_spinner_start "Downloading xray-core (needed before node starts)..."
        if mrm_ensure_xray_core; then
            XRAY_WAS_DOWNLOADED=true
            ui_spinner_stop
            ui_success "xray-core downloaded successfully"
            log_backup "SUCCESS" "xray-core downloaded to $XRAY_BIN_PATH"
        else
            ui_spinner_stop
            ui_error "xray-core download FAILED! Node will not work."
            echo -e "    ${YELLOW}Possible causes:${NC}"
            echo -e "    ${YELLOW}- GitHub is blocked on this server (common in Iran)${NC}"
            echo -e "    ${YELLOW}- No internet connection${NC}"
            echo -e "    ${YELLOW}- Try: mrm fix-node${NC}"
            log_backup "ERROR" "xray-core download failed during restore"
        fi
    fi

    # Start services (AFTER the DB is restored AND xray-core is ensured)
    local STARTED_ANY=false START_FAILED=false
    PANEL_COMPOSE_FILE="$(get_existing_compose_file panel 2>/dev/null || true)"
    NODE_COMPOSE_FILE="$(get_existing_compose_file node 2>/dev/null || true)"

    ui_spinner_start "Starting services..."
    if [ -n "$NODE_COMPOSE_FILE" ]; then
        if run_compose_file "$NODE_COMPOSE_FILE" up -d >/dev/null 2>&1; then STARTED_ANY=true; else START_FAILED=true; fi
    fi
    if [ -n "$PANEL_COMPOSE_FILE" ]; then
        if run_compose_file "$PANEL_COMPOSE_FILE" up -d >/dev/null 2>&1; then STARTED_ANY=true; else START_FAILED=true; fi
    fi
    ui_spinner_stop

    if [ "$START_FAILED" = true ]; then ui_error "Failed to start one or more services"; elif [ "$STARTED_ANY" = true ]; then ui_success "Services started"; else ui_warning "No compose services found to start"; fi

    # If xray was freshly downloaded, restart the node container to pick it up
    if [ "$XRAY_WAS_DOWNLOADED" = true ] && [ -n "$NODE_COMPOSE_FILE" ]; then
        ui_spinner_start "Restarting node to apply new xray-core..."
        if run_compose_file "$NODE_COMPOSE_FILE" restart >/dev/null 2>&1; then
            ui_spinner_stop
            ui_success "Node restarted with new xray-core"
            log_backup "INFO" "Node restarted after xray-core download"
        else
            ui_spinner_stop
            ui_warning "Node restart failed - try: docker restart \$(docker ps -a --format '{{.Names}}' | grep -i node | head -1)"
            log_backup "WARNING" "Node restart failed after xray-core download"
        fi
    fi

    # Final cleanup
    rm -rf "$WORK_DIR"
    trap - RETURN

    local NEW_SERVER_IP=$(get_server_ip)
    log_backup "SUCCESS" "Restore v${BACKUP_VERSION} completed from: $(basename "$SELECTED")"

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              ✔ RESTORE v${BACKUP_VERSION} COMPLETED!                     ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC} Server IP: ${CYAN}$NEW_SERVER_IP${NC}"
    echo -e "${GREEN}║${NC} Backup: ${CYAN}$(basename "$SELECTED")${NC}"
    echo -e "${GREEN}║${NC} Type: ${CYAN}v${BACKUP_VERSION}${NC}"
    echo -e "${GREEN}║${NC} Data: ${CYAN}Safe & Complete${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Safety backup: $SAFETY_BACKUP${NC}"
    if [ "$XRAY_WAS_DOWNLOADED" = true ]; then
        echo -e "${YELLOW}Note: xray-core was downloaded during restore (not in backup)${NC}"
    elif [ -x "$XRAY_BIN_PATH" ]; then
        echo -e "${CYAN}Note: xray-core was present or restored from backup${NC}"
    else
        echo -e "${RED}⚠ WARNING: xray-core is MISSING! Run: mrm fix-node${NC}"
    fi
    echo ""
    pause
}

# Xray release asset name for this machine's architecture.
# IMPORTANT: XTLS/Xray-core assets are Xray-linux-64.zip (x86_64) and
# Xray-linux-arm64-v8a.zip (aarch64) - NOT x64/arm64 (those URLs 404!).
mrm_xray_arch() {
    case "$(uname -m 2>/dev/null)" in
        aarch64|arm64)          echo "arm64-v8a" ;;
        armv7l|armv7)           echo "arm32-v7a" ;;
        x86_64|amd64|*)         echo "64" ;;
    esac
}

# Download Xray-core binary if missing (backups intentionally exclude the ~25MB
# binary + geo files; the panel needs them at /var/lib/pg-node/xray-core/xray).
# Mirrors the official installer's download logic. No-op if already present.
mrm_ensure_xray_core() {
    local VERBOSE="${MRM_XRAY_VERBOSE:-false}"
    local XRAY_DIR ASSETS_DIR XRAY_BIN
    local NODE_DATA
    NODE_DATA="$(dirname "${NODE_DEF_CERTS:-/var/lib/pg-node/certs}" 2>/dev/null)"
    [ -z "$NODE_DATA" ] && NODE_DATA="/var/lib/pg-node"
    XRAY_DIR="$NODE_DATA/xray-core"
    ASSETS_DIR="$NODE_DATA/assets"
    XRAY_BIN="$XRAY_DIR/xray"

    _xlog() { [ "$VERBOSE" = true ] && echo -e "  ${CYAN}→${NC} $*" || true; log_backup "INFO" "$*"; }
    _xerr() { [ "$VERBOSE" = true ] && echo -e "  ${RED}✘${NC} $*" || true; log_backup "ERROR" "$*"; }
    _xok()  { [ "$VERBOSE" = true ] && echo -e "  ${GREEN}✔${NC} $*" || true; log_backup "SUCCESS" "$*"; }

    # --- Step 0: Check if already working ---
    local XRAY_OK=false
    if [ -x "$XRAY_BIN" ]; then
        if "$XRAY_BIN" -version >/dev/null 2>&1; then
            XRAY_OK=true
            _xok "xray-core already working: $XRAY_BIN"
        else
            _xlog "xray binary present but not runnable (wrong arch?) - re-downloading"
            rm -f "$XRAY_BIN"
        fi
    fi

    mkdir -p "$XRAY_DIR" "$ASSETS_DIR" 2>/dev/null || { _xerr "Cannot create dirs: $XRAY_DIR $ASSETS_DIR"; return 1; }

    # --- Step 1: Ensure prerequisites ---
    if ! command -v curl >/dev/null 2>&1; then
        _xerr "curl is NOT installed! Installing..."
        if [ "$VERBOSE" = true ]; then
            apt-get update -qq && apt-get install -y -qq curl 2>/dev/null || yum install -y curl 2>/dev/null || { _xerr "Cannot install curl"; return 1; }
        else
            apt-get update -qq && apt-get install -y -qq curl 2>/dev/null || yum install -y curl 2>/dev/null || { log_backup "ERROR" "Cannot install curl"; return 1; }
        fi
        _xok "curl installed"
    fi

    if ! command -v unzip >/dev/null 2>&1; then
        _xlog "unzip is NOT installed! Installing..."
        if [ "$VERBOSE" = true ]; then
            apt-get update -qq && apt-get install -y -qq unzip 2>/dev/null || yum install -y unzip 2>/dev/null || { _xerr "Cannot install unzip"; return 1; }
        else
            apt-get update -qq && apt-get install -y -qq unzip 2>/dev/null || yum install -y unzip 2>/dev/null || { log_backup "ERROR" "Cannot install unzip"; return 1; }
        fi
        _xok "unzip installed"
    fi

    if ! command -v unzip >/dev/null 2>&1; then
        _xerr "unzip still not available after install attempt!"
        return 1
    fi

    # --- Step 2: Download geo files if missing ---
    if [ ! -f "$ASSETS_DIR/geoip.dat" ] || [ ! -f "$ASSETS_DIR/geosite.dat" ]; then
        _xlog "Downloading geo files..."
        local GEO_MIRRORS=(
            "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
            "https://gh.api.99988866.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
            "https://ghfast.top/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
            "https://mirror.ghproxy.com/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
        )
        local GEO_OK=false
        for MIRROR in "${GEO_MIRRORS[@]}"; do
            [ "$GEO_OK" = true ] && break
            _xlog "Trying geo mirror: $MIRROR"
            local CURL_ERR
            CURL_ERR="$(mktemp /tmp/geo_err.XXXXXX)"
            curl -fsSL --connect-timeout 20 --max-time 120 "$MIRROR/geoip.dat" -o "$ASSETS_DIR/geoip.dat" 2>"$CURL_ERR" || true
            curl -fsSL --connect-timeout 20 --max-time 120 "$MIRROR/geosite.dat" -o "$ASSETS_DIR/geosite.dat" 2>>"$CURL_ERR" || true
            if [ -s "$ASSETS_DIR/geoip.dat" ] && [ -s "$ASSETS_DIR/geosite.dat" ]; then
                GEO_OK=true
                _xok "Geo files downloaded from mirror"
            else
                if [ "$VERBOSE" = true ] && [ -s "$CURL_ERR" ]; then
                    _xlog "Mirror failed: $(head -1 "$CURL_ERR")"
                fi
                rm -f "$ASSETS_DIR/geoip.dat" "$ASSETS_DIR/geosite.dat" 2>/dev/null
            fi
            rm -f "$CURL_ERR"
        done
        [ "$GEO_OK" = false ] && _xerr "All geo mirrors failed"
    fi

    if [ "$XRAY_OK" = true ]; then
        return 0
    fi

    # --- Step 3: Download xray-core binary ---
    local ARCH
    ARCH="$(mrm_xray_arch)"
    _xlog "System arch: $(uname -m) → xray arch: $ARCH"
    _xlog "Target path: $XRAY_BIN"

    # Test basic internet connectivity first
    if ! curl -fsSL --connect-timeout 10 "https://www.google.com" -o /dev/null 2>/dev/null &&        ! curl -fsSL --connect-timeout 10 "https://1.1.1.1" -o /dev/null 2>/dev/null; then
        _xerr "NO INTERNET CONNECTION detected! Cannot download xray-core."
        _xerr "Check: curl -v https://github.com 2>&1 | head -20"
        return 1
    fi
    _xok "Internet connectivity confirmed"

    local XRAY_MIRRORS=(
        "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH}.zip"
        "https://gh.api.99988866.xyz/https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH}.zip"
        "https://ghfast.top/https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH}.zip"
        "https://mirror.ghproxy.com/https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH}.zip"
    )

    local TMPZ DOWNLOADED=false LAST_ERR=""
    TMPZ="$(mktemp /tmp/xray.XXXXXX.zip)" || { _xerr "Cannot create temp file"; return 1; }

    for MIRROR_URL in "${XRAY_MIRRORS[@]}"; do
        [ "$DOWNLOADED" = true ] && break
        _xlog "Trying: $MIRROR_URL"
        local CURL_ERR_FILE
        CURL_ERR_FILE="$(mktemp /tmp/xray_err.XXXXXX)"
        if curl -fsSL --connect-timeout 20 --max-time 180 "$MIRROR_URL" -o "$TMPZ" 2>"$CURL_ERR_FILE"; then
            if [ -s "$TMPZ" ]; then
                local ZIP_SIZE
                ZIP_SIZE="$(stat -c%s "$TMPZ" 2>/dev/null || echo 0)"
                _xlog "Downloaded: $(( ZIP_SIZE / 1024 ))KB"
                if unzip -o "$TMPZ" -d "$XRAY_DIR" >/dev/null 2>/dev/null; then
                    chmod +x "$XRAY_DIR/xray" 2>/dev/null
                    if [ -x "$XRAY_BIN" ] && "$XRAY_BIN" -version >/dev/null 2>&1; then
                        DOWNLOADED=true
                        _xok "xray-core downloaded and verified!"
                    else
                        _xerr "xray binary not runnable after extraction (wrong arch: $(uname -m))"
                        rm -f "$XRAY_BIN" 2>/dev/null
                    fi
                else
                    _xerr "unzip failed! Trying to install unzip..."
                    apt-get install -y -qq unzip 2>/dev/null || yum install -y -qq unzip 2>/dev/null || true
                    if command -v unzip >/dev/null 2>&1; then
                        unzip -o "$TMPZ" -d "$XRAY_DIR" >/dev/null 2>/dev/null &&                         chmod +x "$XRAY_DIR/xray" 2>/dev/null &&                         [ -x "$XRAY_BIN" ] && "$XRAY_BIN" -version >/dev/null 2>&1 &&                         DOWNLOADED=true && _xok "xray-core downloaded after unzip reinstall!"
                    fi
                fi
            else
                _xerr "Downloaded file is empty (0 bytes)"
            fi
        else
            LAST_ERR="$(cat "$CURL_ERR_FILE" 2>/dev/null | head -1)"
            if [ "$VERBOSE" = true ] && [ -n "$LAST_ERR" ]; then
                _xlog "curl error: $LAST_ERR"
            fi
        fi
        rm -f "$CURL_ERR_FILE" "$TMPZ" 2>/dev/null
        TMPZ="$(mktemp /tmp/xray.XXXXXX.zip)" 2>/dev/null || true
    done

    rm -f "$TMPZ" 2>/dev/null

    if [ "$DOWNLOADED" = true ]; then
        return 0
    fi

    _xerr "ALL MIRRORS FAILED!"
    _xerr "Target: $XRAY_BIN"
    _xerr "Arch: $ARCH ($(uname -m))"
    if [ -n "$LAST_ERR" ]; then
        _xerr "Last error: $LAST_ERR"
    fi
    _xerr ""
    _xerr "Manual fix options:"
    _xerr "  1. mrm fix-node --verbose  (show detailed errors)"
    _xerr "  2. curl -v https://github.com  (test connectivity)"
    _xerr "  3. Download manually and place at: $XRAY_BIN"
    return 1
}

# Pick which DB file to restore from a backup root. Prints "TYPE|PATH"
# (sqlite MUST be checked before *.sql - "db.sqlite3" matches "*db.sql*"!)
mrm_pick_db_restore() {
    local ROOT="$1"
    if [ -f "$ROOT/database/db.sqlite3" ]; then
        printf 'sqlite|%s\n' "$ROOT/database/db.sqlite3"; return 0
    fi
    if [ -f "$ROOT/database/db.sql.gz" ]; then
        printf 'gz|%s\n' "$ROOT/database/db.sql.gz"; return 0
    fi
    if [ -f "$ROOT/database/db.sql" ]; then
        printf 'sql|%s\n' "$ROOT/database/db.sql"; return 0
    fi
    printf 'none|\n'; return 1
}

# ==========================================
# OTHER UTILITIES
# ==========================================
setup_cron() {
    clear
    ui_header "BACKUP SCHEDULER - v${BACKUP_VERSION}"
    echo "Current cron status:"
    if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH"; then
        local CURRENT=$(crontab -l | grep "$SCRIPT_PATH")
        echo -e "${GREEN}Active:${NC} $CURRENT"
    else
        echo -e "${YELLOW}No scheduled backup${NC}"
    fi
    echo ""
    echo "Select backup interval (v${BACKUP_VERSION}):"
    echo "1) Every 6 hours"
    echo "2) Every 12 hours"
    echo "3) Every 24 hours (Daily) [Recommended]"
    echo "4) Every week (Sunday)"
    echo "5) Disable scheduled backup"
    echo "0) Cancel"
    echo ""
    read -p "Select: " c
    local CRON_TIME=""
    case $c in
        1) CRON_TIME="0 */6 * * *" ;;
        2) CRON_TIME="0 */12 * * *" ;;
        3) CRON_TIME="0 0 * * *" ;;
        4) CRON_TIME="0 0 * * 0" ;;
        5) CRON_TIME="" ;;
        0) return ;;
        *) ui_error "Invalid selection"; pause; return ;;
    esac
    (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | grep -v "/opt/mrm-manager/main.sh auto" | grep -v "/opt/mrm-manager/backup.sh auto"
     [ -n "$CRON_TIME" ] && echo "$CRON_TIME /bin/bash $SCRIPT_PATH auto >> $BACKUP_LOG 2>&1"
    ) | crontab -
    if [ -n "$CRON_TIME" ]; then ui_success "Scheduled v${BACKUP_VERSION} backup enabled: $CRON_TIME"; log_backup "INFO" "Cron scheduled: $CRON_TIME"; else ui_success "Scheduled backup disabled"; log_backup "INFO" "Cron disabled"; fi
    pause
}

view_backup_logs() {
    clear
    ui_header "BACKUP LOGS - v${BACKUP_VERSION}"
    if [ -f "$BACKUP_LOG" ]; then echo -e "${YELLOW}Last 50 entries:${NC}\n"; tail -n 50 "$BACKUP_LOG"; else ui_warning "No logs found"; fi
    pause
}

list_backups() {
    clear
    ui_header "AVAILABLE BACKUPS - v${BACKUP_VERSION}"
    local FILES=($(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null))
    if [ ${#FILES[@]} -eq 0 ]; then ui_warning "No backups found"; pause; return; fi
    echo -e "${GREEN}ID │ Type       │ Filename                              │ Size   │ Date${NC}"
    echo "───┼────────────┼─────────────────────────────────────────┼────────┼───────────"
    for i in "${!FILES[@]}"; do
        local NAME=$(basename "${FILES[$i]}")
        local SIZE=$(du -h "${FILES[$i]}" | cut -f1)
        local DATE=$(stat -c %y "${FILES[$i]}" | cut -d' ' -f1)
        local TYPE="v${BACKUP_VERSION}"
        [[ "$NAME" == *"Full"* ]] && TYPE="FULL-OLD"
        [[ "$NAME" == *"Lite"* ]] && TYPE="LITE-OLD"
        [[ "$NAME" == *"V1"* ]] && TYPE="v${BACKUP_VERSION}"
        printf "%-2s │ %-10s │ %-39s │ %-6s │ %s\n" "$((i+1))" "$TYPE" "$NAME" "$SIZE" "$DATE"
    done
    echo ""
    echo -e "Total: ${CYAN}${#FILES[@]}${NC} backups"
    echo -e "Location: ${CYAN}$BACKUP_DIR${NC}"
    echo -e "Version: ${CYAN}$MRM_BACKUP_VERSION${NC}"
    echo ""
    echo -e "${YELLOW}Tip: v${BACKUP_VERSION} backups are ready for Telegram${NC}"
    pause
}

delete_backup() {
    clear
    ui_header "DELETE BACKUP"
    local FILES=($(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null))
    if [ ${#FILES[@]} -eq 0 ]; then ui_warning "No backups found"; pause; return; fi
    echo -e "${YELLOW}Select backup to delete:${NC}\n"
    for i in "${!FILES[@]}"; do
        local SIZE=$(du -h "${FILES[$i]}" | cut -f1)
        echo "$((i+1))) $(basename "${FILES[$i]}") [$SIZE]"
    done
    echo ""
    read -p "Select (0 to cancel): " SEL
    [ "$SEL" == "0" ] && return
    local SELECTED="${FILES[$((SEL-1))]}"
    if [ -z "$SELECTED" ]; then ui_error "Invalid selection"; pause; return; fi
    echo ""
    read -p "Delete $(basename "$SELECTED")? (y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then rm -f "$SELECTED"; ui_success "Backup deleted"; log_backup "INFO" "Deleted backup: $(basename "$SELECTED")"; else echo "Cancelled"; fi
    pause
}

debug_backup_size() {
    clear
    ui_header "BACKUP SIZE ANALYZER - v${BACKUP_VERSION}"
    setup_env
    echo -e "${CYAN}Analyzing current data sizes (find 31MB cause):${NC}\n"
    echo -e "${YELLOW}=== PANEL_DIR ($PANEL_DIR) ===${NC}"
    if [ -d "$PANEL_DIR" ]; then
        echo "Total: $(du -sh "$PANEL_DIR" 2>/dev/null | cut -f1)"
        du -sh "$PANEL_DIR"/* 2>/dev/null | sort -rh | head -n 20
        echo ""
        if [ -d "$PANEL_DIR/backup" ]; then
            echo -e "${RED}FOUND backup folder (LOOP CAUSE):${NC}"
            du -sh "$PANEL_DIR/backup"/* 2>/dev/null | head -n 20
            ls -lh "$PANEL_DIR/backup/" 2>/dev/null | head -n 20
            echo ""
        fi
    else
        echo "Not found"
    fi
    echo -e "${YELLOW}=== DATA_DIR ($DATA_DIR) ===${NC}"
    if [ -d "$DATA_DIR" ]; then
        echo "Total: $(du -sh "$DATA_DIR" 2>/dev/null | cut -f1)"
        du -sh "$DATA_DIR"/* 2>/dev/null | sort -rh | head -n 20
    else
        echo "Not found"
    fi
    echo ""
    echo -e "${YELLOW}=== NODE_DIR ($NODE_DIR) & NODE_DATA ===${NC}"
    if [ -d "$NODE_DIR" ]; then
        echo "NODE_DIR Total: $(du -sh "$NODE_DIR" 2>/dev/null | cut -f1)"
        du -sh "$NODE_DIR"/* 2>/dev/null | sort -rh | head -n 20
        echo ""
    fi
    local NODE_DATA_DIR="$(dirname "$NODE_DEF_CERTS")"
    if [ -d "$NODE_DATA_DIR" ]; then
        echo "NODE_DATA_DIR ($NODE_DATA_DIR) Total: $(du -sh "$NODE_DATA_DIR" 2>/dev/null | cut -f1)"
        du -sh "$NODE_DATA_DIR"/* 2>/dev/null | sort -rh | head -n 30
        echo ""
        if [ -d "$NODE_DATA_DIR/assets" ]; then
            echo -e "${RED}FOUND assets (HEAVY - geoip.dat):${NC}"
            ls -lh "$NODE_DATA_DIR/assets/" 2>/dev/null
            echo ""
        fi
        if [ -d "$NODE_DATA_DIR/xray-core" ]; then
            echo -e "${RED}FOUND xray-core (HEAVY - xray binary):${NC}"
            ls -lh "$NODE_DATA_DIR/xray-core/" 2>/dev/null
            echo ""
        fi
    fi
    echo -e "${YELLOW}=== /etc/letsencrypt ===${NC} $(du -sh /etc/letsencrypt 2>/dev/null | cut -f1 || echo "Not found")"
    echo -e "${YELLOW}=== /etc/nginx ===${NC} $(du -sh /etc/nginx 2>/dev/null | cut -f1 || echo "Not found")"
    echo ""
    echo -e "${GREEN}=== v${BACKUP_VERSION} ===${NC}"
    echo -e "Exclude: assets/*, xray-core/*, backup/*, geoip.dat, geosite.dat, xray binary"
    echo -e "Result: 31MB -> 2-5MB"
    echo ""
    pause
}

# ==========================================
# Main menu
# ==========================================
backup_menu() {
    init_backup_logging
    while true; do
        clear
        ui_header "BACKUP & RESTORE"
        setup_env
        local BACKUP_COUNT=$(ls "$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l)
        local TG_STATUS="${RED}Not Configured${NC}"
        [ -f "$TG_CONFIG" ] && TG_STATUS="${GREEN}Configured${NC}"
        local CRON_STATUS="${RED}Disabled${NC}"
        crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH" && CRON_STATUS="${GREEN}Active${NC}"
        local SERVER_IP=$(get_server_ip)
        local LAST_SIZE="None"
        local LAST_FILE=$(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | head -1)
        [ -n "$LAST_FILE" ] && LAST_SIZE=$(du -h "$LAST_FILE" | cut -f1)

        echo -e "Panel: ${CYAN}$(basename "$PANEL_DIR")${NC} | IP: ${CYAN}$SERVER_IP${NC} | Version: ${CYAN}$MRM_BACKUP_VERSION${NC}"
        echo -e "Backups: ${CYAN}$BACKUP_COUNT${NC} | Last: ${CYAN}$LAST_SIZE${NC} | Telegram: $TG_STATUS | Cron: $CRON_STATUS"
        echo ""
        echo "1)  📦 Create Backup"
        echo "2)  📥 Restore from Backup"
        echo "3)  📋 List All Backups"
        echo "4)  🗑️  Delete Backup"
        echo "5)  🧑‍💻 Setup Telegram Bot"
        echo "6)  🧪 Test Telegram"
        echo "7)  ❌ Remove Telegram Settings"
        echo "8)  ⏰ Setup Cron Scheduler"
        echo "9)  🔧 Run Smart Fix Only"
        echo "10) 📋 View Logs"
        echo "11) 🔍 Analyze Size"
        echo ""
        echo "0)  ↩️  Back to Main"
        echo ""
        read -p "Select: " opt
        case $opt in
            1) do_backup "manual" ;;
            2) do_restore ;;
            3) list_backups ;;
            4) delete_backup ;;
            5) setup_telegram ;;
            6) test_telegram; pause ;;
            7) remove_telegram_settings ;;
            8) setup_cron ;;
            9) apply_smart_fix; pause ;;
            10) view_backup_logs ;;
            11) debug_backup_size ;;
            0) return ;;
            *) ui_error "Invalid option"; sleep 1 ;;
        esac
    done
}

# ==========================================
# ENTRY POINT
# ==========================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ "$1" == "auto" ]; then
        do_backup "auto"
    elif [ "$1" == "fix-node" ]; then
        # mrm fix-node [--verbose] : repair xray-core + geo files
        setup_env
        init_backup_logging

        FIX_VERBOSE=false
        [[ "$2" == "--verbose" ]] || [[ "$2" == "-v" ]] && FIX_VERBOSE=true
        export MRM_XRAY_VERBOSE="$FIX_VERBOSE"

        NODE_DATA_DIR="$(dirname "${NODE_DEF_CERTS:-/var/lib/pg-node/certs}" 2>/dev/null)"
        [ -z "$NODE_DATA_DIR" ] && NODE_DATA_DIR="/var/lib/pg-node"

        echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║  🔧 Node xray-core Repair Tool          ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${CYAN}Node data dir:${NC} $NODE_DATA_DIR"
        echo -e "  ${CYAN}Expected path:${NC} $NODE_DATA_DIR/xray-core/xray"
        echo -e "  ${CYAN}System arch:${NC}   $(uname -m)"
        echo -e "  ${CYAN}Verbose:${NC}       $FIX_VERBOSE"
        echo ""

        # Pre-flight checks
        echo -e "${YELLOW}Pre-flight checks:${NC}"
        if command -v curl >/dev/null 2>&1; then
            echo -e "  ${GREEN}✔${NC} curl: $(curl --version | head -1)"
        else
            echo -e "  ${RED}✘${NC} curl: NOT INSTALLED"
        fi
        if command -v unzip >/dev/null 2>&1; then
            echo -e "  ${GREEN}✔${NC} unzip: installed"
        else
            echo -e "  ${RED}✘${NC} unzip: NOT INSTALLED"
        fi
        if [ -x "$NODE_DATA_DIR/xray-core/xray" ]; then
            echo -e "  ${YELLOW}⚠${NC} xray binary exists but may be broken"
        else
            echo -e "  ${RED}✘${NC} xray binary: MISSING"
        fi
        echo ""

        echo -e "${YELLOW}Downloading/repairing xray-core...${NC}"
        if mrm_ensure_xray_core; then
            echo ""
            echo -e "${GREEN}✔ xray-core ready: $NODE_DATA_DIR/xray-core/xray${NC}"
            "$NODE_DATA_DIR/xray-core/xray" -version 2>/dev/null | head -1 && true
            echo ""
            echo -e "${YELLOW}Restarting node container...${NC}"
            NODE_CNAME="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -i node | head -1)"
            if [ -n "$NODE_CNAME" ]; then
                if docker restart "$NODE_CNAME" >/dev/null 2>&1; then
                    echo -e "${GREEN}✔ Node restarted: $NODE_CNAME${NC}"
                else
                    echo -e "${RED}✘ Node restart failed: $NODE_CNAME${NC}"
                fi
            else
                echo -e "${YELLOW}⚠ No node container found (is the node docker-compose running?)${NC}"
            fi
            exit 0
        else
            echo ""
            echo -e "${RED}╔══════════════════════════════════════════╗${NC}"
            echo -e "${RED}║  ✘ REPAIR FAILED                        ║${NC}"
            echo -e "${RED}╚══════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${YELLOW}Try these steps:${NC}"
            echo -e "  1. ${CYAN}mrm fix-node --verbose${NC}  (see detailed errors)"
            echo -e "  2. ${CYAN}apt install -y curl unzip${NC}  (ensure tools exist)"
            echo -e "  3. ${CYAN}curl -v https://github.com 2>&1 | head -5${NC}  (test internet)"
            echo -e "  4. Manual download:"
            echo -e "     ${CYAN}ARCH=$( [ "$(uname -m)" = "aarch64" ] && echo arm64-v8a || echo 64 )${NC}"
            echo -e "     ${CYAN}curl -L "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-\$ARCH.zip" -o /tmp/xray.zip${NC}"
            echo -e "     ${CYAN}unzip -o /tmp/xray.zip -d $NODE_DATA_DIR/xray-core/${NC}"
            echo -e "     ${CYAN}chmod +x $NODE_DATA_DIR/xray-core/xray${NC}"
            echo -e "     ${CYAN}docker restart \$(docker ps -a --format '{{.Names}}' | grep -i node | head -1)${NC}"
            echo ""
            echo -e "${YELLOW}Full log: $BACKUP_LOG${NC}"
            exit 1
        fi
    else
        backup_menu
    fi
fi
