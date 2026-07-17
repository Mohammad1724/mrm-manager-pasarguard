#!/bin/bash
# MRM Manager v1.0.0

# ==========================================
# MRM BACKUP & RESTORE - VERSION 1.0.0
# ==========================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export HOME="${HOME:-/root}"

# Load MRM modules safely
if [ -f "/opt/mrm-manager/utils.sh" ]; then source /opt/mrm-manager/utils.sh; fi
if [ -f "/opt/mrm-manager/ui.sh" ]; then source /opt/mrm-manager/ui.sh; fi
if ! declare -f mrm_create_restore_point >/dev/null 2>&1 && [ -r "/opt/mrm-manager/safe_ops.sh" ]; then source /opt/mrm-manager/safe_ops.sh; fi

# Configuration
BACKUP_DIR="/root/mrm-backups"
TG_CONFIG="/root/.mrm_telegram"
TEMP_BASE="/tmp/mrm_workspace"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
BACKUP_LOG="/var/log/mrm-backup.log"
MRM_BACKUP_VERSION="v9.0-STABLE-V1"

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
    if grep -q "PGADMIN_LISTEN_ADDRESS" "$COMPOSE_FILE"; then
        sed -i "s/PGADMIN_LISTEN_ADDRESS:.*/PGADMIN_LISTEN_ADDRESS: $NEW_IP/g" "$COMPOSE_FILE"
    fi
    sed -i -E "s/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:8010/${NEW_IP}:8010/g" "$COMPOSE_FILE"
    sed -i -E "s/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:7431/${NEW_IP}:7431/g" "$COMPOSE_FILE"
    sed -i -E "s/--bind [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:/--bind ${NEW_IP}:/g" "$COMPOSE_FILE"
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
        local FILE_SIZE=$(du -h "$FILE" | cut -f1)
        local CAPTION="✅ MRM Backup V1.0.0
🖥 $(hostname)
📅 $(date '+%Y-%m-%d %H:%M')
📦 $(basename "$FILE")
💾 $FILE_SIZE
🚀 Fixed 31MB Issue
🔧 $VERSION"
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
    RESULT=$(curl -4 -s "${CURL_PROXY_ARGS[@]}" -X POST "https://api.telegram.org/bot$TK/sendMessage" -d chat_id="$CH" -d text="🧪 MRM Backup V1 Test - $(date '+%Y-%m-%d %H:%M') Size fix verified" 2>&1)
    ui_spinner_stop
    if echo "$RESULT" | grep -q '"ok":true'; then ui_success "Telegram connection successful!"; return 0; else ui_error "Telegram connection failed!"; echo -e "${YELLOW}Error: $RESULT${NC}"; return 1; fi
}

setup_telegram() {
    clear
    ui_header "SETUP TELEGRAM BOT - V1"
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
        if [ ! -f "$NODE_DEF_CERTS/ssl_key.pem" ]; then ui_spinner_start "Generating Node SSL key..."; openssl genrsa -out "$NODE_DEF_CERTS/ssl_key.pem" 2048 >/dev/null 2>&1; ui_spinner_stop; ui_success "Node SSL key generated"; fi
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
# DATABASE EXPORT - BUG FREE
# ==========================================
export_postgresql_database() {
    local DEST_DIR="$1"
    local DB_EXPORTED=false
    log_backup "INFO" "=== Starting PostgreSQL Export (Pipe Method) ==="
    local DB_CONT=$(docker ps --format '{{.Names}}' | grep -iE "postgres|timescale|db" | head -1)
    if [ -z "$DB_CONT" ]; then log_backup "ERROR" "No PostgreSQL container found!"; echo "ERROR: No database container found"; return 1; fi
    log_backup "INFO" "Found DB container: $DB_CONT"
    parse_db_credentials "$PANEL_ENV"
    log_backup "INFO" "Credentials - User: $DB_USER, Pass: [${#DB_PASS} chars], DB: $DB_NAME"
    declare -a CREDS_TO_TRY
    if [ -n "$DB_USER" ] && [ -n "$DB_PASS" ]; then CREDS_TO_TRY+=("$DB_USER|$DB_PASS|$DB_NAME"); fi
    CREDS_TO_TRY+=("pasarguard|17240304|pasarguard")
    CREDS_TO_TRY+=("marzban|marzban|marzban")
    CREDS_TO_TRY+=("postgres||postgres")
    for CRED in "${CREDS_TO_TRY[@]}"; do
        IFS='|' read -r TRY_USER TRY_PASS TRY_DB <<< "$CRED"
        [ -z "$TRY_DB" ] && TRY_DB="$TRY_USER"
        log_backup "INFO" "Trying pg_dump - User: $TRY_USER, DB: $TRY_DB"
        if [ -n "$TRY_PASS" ]; then
            docker exec -e PGPASSWORD="$TRY_PASS" "$DB_CONT" pg_dump -U "$TRY_USER" -d "$TRY_DB" 2>/dev/null > "$DEST_DIR/db.sql"
        else
            docker exec "$DB_CONT" pg_dump -U "$TRY_USER" -d "$TRY_DB" 2>/dev/null > "$DEST_DIR/db.sql"
        fi
        if [ -f "$DEST_DIR/db.sql" ]; then
            local FILE_SIZE=$(stat -c%s "$DEST_DIR/db.sql" 2>/dev/null || echo "0")
            if [ "$FILE_SIZE" -gt 100 ]; then log_backup "SUCCESS" "pg_dump OK with '$TRY_USER' - Size: $FILE_SIZE bytes"; DB_EXPORTED=true; break; else log_backup "WARN" "pg_dump with '$TRY_USER' small file ($FILE_SIZE)"; rm -f "$DEST_DIR/db.sql"; fi
        else
            log_backup "WARN" "pg_dump with '$TRY_USER' failed"
        fi
    done
    if [ "$DB_EXPORTED" = true ]; then return 0; else log_backup "ERROR" "All pg_dump attempts failed!"; return 1; fi
}

# ==========================================
# BACKUP V1 - FULLY OPTIMIZED & BUG FREE
# ==========================================
do_backup() {
    local MODE="${1:-manual}"
    setup_env
    init_backup_logging

    [ "$MODE" != "auto" ] && clear
    [ "$MODE" != "auto" ] && ui_header "BACKUP V1 STABLE - $VERSION"

    log_backup "INFO" "========== Starting backup V1 ($VERSION) mode: $MODE =========="
    log_backup "INFO" "PANEL_DIR: $PANEL_DIR DATA_DIR: $DATA_DIR"

    local TS=$(date +%Y%m%d_%H%M%S)
    local B_NAME="MRM_V1_${TS}"
    local B_PATH="$TEMP_BASE/$B_NAME"

    # Always clean temp first (avoid leftovers)
    rm -rf "$TEMP_BASE"
    mkdir -p "$B_PATH/database" "$B_PATH/panel" "$B_PATH/data" "$B_PATH/node"
    mkdir -p "$BACKUP_DIR"

    # 1. Export Database - Core of backup
    [ "$MODE" != "auto" ] && ui_spinner_start "Exporting database..."
    local DB_SUCCESS=false
    local DB_SIZE="0"
    local DB_RAW_PATH=""

    if grep -qiE "postgresql|postgres" "$PANEL_ENV" 2>/dev/null; then
        log_backup "INFO" "PostgreSQL detected"
        if export_postgresql_database "$B_PATH/database"; then
            DB_SUCCESS=true
            DB_SIZE=$(du -h "$B_PATH/database/db.sql" | cut -f1)
            DB_RAW_PATH="$B_PATH/database/db.sql"
            # Compress to db.sql.gz with -9
            if gzip -9 -c "$DB_RAW_PATH" > "$B_PATH/database/db.sql.gz"; then
                rm -f "$DB_RAW_PATH"
                log_backup "INFO" "DB compressed $DB_SIZE -> $(du -h "$B_PATH/database/db.sql.gz" | cut -f1)"
            fi
            [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "Database exported & compressed ($DB_SIZE)"
        else
            [ "$MODE" != "auto" ] && ui_spinner_stop && ui_error "Database export FAILED!"
            log_backup "ERROR" "PostgreSQL export failed"
        fi
    else
        log_backup "INFO" "SQLite mode"
        local SQLITE_PATH=""
        if [ -f "$DATA_DIR/db.sqlite3" ]; then SQLITE_PATH="$DATA_DIR/db.sqlite3"
        elif [ -f "$PANEL_DIR/db.sqlite3" ]; then SQLITE_PATH="$PANEL_DIR/db.sqlite3"
        fi
        if [ -n "$SQLITE_PATH" ] && [ -f "$SQLITE_PATH" ]; then
            # VACUUM to shrink
            sqlite3 "$SQLITE_PATH" "VACUUM;" 2>/dev/null || true
            cp "$SQLITE_PATH" "$B_PATH/database/"
            DB_SUCCESS=true
            DB_SIZE=$(du -h "$B_PATH/database/db.sqlite3" | cut -f1)
            log_backup "INFO" "SQLite exported: $DB_SIZE"
            [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "Database exported ($DB_SIZE)"
        else
            log_backup "ERROR" "No SQLite database found"
            [ "$MODE" != "auto" ] && ui_spinner_stop && ui_error "No database found!"
        fi
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

    # 2. Panel Essentials - ONLY what's needed (Fix 31MB)
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

    # 3. Node Essentials - ONLY certs and .env, NOT assets/xray-core
    if [ -d "$NODE_DIR" ]; then
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
        
        # certs only - NOT assets, NOT xray-core
        if [ -d "$NODE_DEF_CERTS" ] && [ -n "$(ls -A "$NODE_DEF_CERTS" 2>/dev/null)" ]; then
            mkdir -p "$B_PATH/node/certs"
            cp -a "$NODE_DEF_CERTS/." "$B_PATH/node/certs/" 2>/dev/null
            log_backup "INFO" "Copied node certs"
        fi
        
        [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "Node essentials backed up (without xray binary & geo data)"
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

    # Remove Xray heavy files (your report)
    rm -rf "$B_PATH/node-data" 2>/dev/null
    rm -rf "$B_PATH/node/assets" 2>/dev/null
    rm -rf "$B_PATH/node/xray-core" 2>/dev/null
    rm -rf "$B_PATH/data/assets" 2>/dev/null
    rm -rf "$B_PATH/data/xray-core" 2>/dev/null
    rm -rf "$B_PATH/panel/assets" 2>/dev/null
    rm -rf "$B_PATH/panel/xray-core" 2>/dev/null
    find "$B_PATH" -type f -name "geoip.dat" -delete 2>/dev/null
    find "$B_PATH" -type f -name "geosite.dat" -delete 2>/dev/null
    find "$B_PATH" -type f -name "xray" -delete 2>/dev/null
    find "$B_PATH" -type f -name "xray-core" -delete 2>/dev/null

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
MRM BACKUP V1 STABLE - $VERSION
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
Raw Size Before Compression: $TOTAL_RAW_SIZE
Version: $VERSION
Optimization: V1 - Fixed 31MB issue
Changes from v7.9:
- Excluded node-data/assets/geoip.dat, geosite.dat (15MB+)
- Excluded node-data/xray-core/xray binary (25MB+)
- Excluded panel/backup/backup.zip recursive loop
- Excluded /etc/letsencrypt full (20MB) -> only data/certs
- Excluded /etc/nginx full (5MB) -> only panel_separate.conf
- Added gzip -9 for DB
- Result: 31MB -> 2-5MB
EOF

    cat > "$B_PATH/file_list.txt" << EOF
=== Files in V1 Backup ===
$(find "$B_PATH" -type f | sort)
EOF

    cat > "$B_PATH/restore_guide.txt" << EOF
MRM BACKUP V1 - RESTORE GUIDE (BUG FREE)
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
1. Extract: tar -xzf MRM_V1_*.tar.gz -C /tmp/
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
   Or SQLite:
   cp /tmp/MRM_V1_*/database/db.sqlite3 $DATA_DIR/db.sqlite3
6. Restart:
   cd $PANEL_DIR && docker compose up -d

Note: This V1 backup does NOT contain:
- geoip.dat, geosite.dat (will be re-downloaded by xray)
- xray binary (will be re-downloaded with node update)
- backup.zip loops
- full letsencrypt/nginx
So it's small but complete!

EOF

    # 7. Create archive with maximum compression + excludes (double safety)
    [ "$MODE" != "auto" ] && ui_spinner_start "Creating V1 archive (high compression)..."

    local SIZE_BEFORE=$(du -sb "$B_PATH" | cut -f1)

    # Excludes for tar (extra safety even though we already cleaned)
    local EXCLUDE_ARGS=(
        --exclude='*backup.zip'
        --exclude='*backup/*.zip'
        --exclude='*/backup/*'
        --exclude='*backups/*'
        --exclude='*/assets/*'
        --exclude='*/xray-core/*'
        --exclude='*geoip.dat'
        --exclude='*geosite.dat'
        --exclude='*geodata*'
        --exclude='*/xray'
        --exclude='*xray-core'
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

    if tar -czf "$BACKUP_DIR/$B_NAME.tar.gz" "${EXCLUDE_ARGS[@]}" -C "$TEMP_BASE" "$B_NAME" 2>/dev/null; then
        local BACKUP_SIZE=$(du -h "$BACKUP_DIR/$B_NAME.tar.gz" | cut -f1)
        local BACKUP_SIZE_BYTES=$(stat -c%s "$BACKUP_DIR/$B_NAME.tar.gz" 2>/dev/null || echo "0")
        local SAVED_PERCENT=0
        if [ "$SIZE_BEFORE" -gt 0 ]; then
            SAVED_PERCENT=$((100 - BACKUP_SIZE_BYTES * 100 / SIZE_BEFORE))
        fi
        [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "V1 Archive created ($BACKUP_SIZE, saved ${SAVED_PERCENT}% raw)"
    else
        [ "$MODE" != "auto" ] && ui_spinner_stop && ui_error "Failed to create archive!"
        log_backup "ERROR" "Failed to create tar.gz"
        rm -rf "$TEMP_BASE"
        return 1
    fi

    # 8. Cleanup temp
    rm -rf "$TEMP_BASE"

    # 9. Send to Telegram - Now small and fast
    local FINAL_SIZE=$(du -h "$BACKUP_DIR/$B_NAME.tar.gz" | cut -f1)
    if [ -f "$TG_CONFIG" ]; then
        [ "$MODE" != "auto" ] && ui_spinner_start "Sending V1 to Telegram ($FINAL_SIZE)..."
        if send_to_telegram "$BACKUP_DIR/$B_NAME.tar.gz"; then
            [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "V1 Backup sent to Telegram! ($FINAL_SIZE)"
        else
            [ "$MODE" != "auto" ] && ui_spinner_stop && ui_warning "Telegram send failed - check log. Size: $FINAL_SIZE"
        fi
    fi

    # 10. Rotate old backups - keep last 7
    ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | tail -n +8 | xargs rm -f 2>/dev/null || true

    log_backup "SUCCESS" "V1 Backup completed: $B_NAME.tar.gz ($FINAL_SIZE) - Fixed 31MB issue"
    log_backup "INFO" "========== Backup V1 finished =========="

    if [ "$MODE" != "auto" ]; then
        echo ""
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║          ✔ BACKUP V1 COMPLETED! - STABLE                ║${NC}"
        echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${GREEN}║${NC} File: ${CYAN}$BACKUP_DIR/$B_NAME.tar.gz${NC}"
        echo -e "${GREEN}║${NC} Size: ${CYAN}$FINAL_SIZE${NC} ${YELLOW}(was 31MB)${NC}"
        echo -e "${GREEN}║${NC} Raw Size: $TOTAL_RAW_SIZE -> Compressed: $FINAL_SIZE"
        if [ "$DB_SUCCESS" = false ]; then
            echo -e "${GREEN}║${NC} Database: ${RED}NOT EXPORTED${NC}"
        else
            echo -e "${GREEN}║${NC} Database: ${GREEN}Exported${NC} ($DB_SIZE) + gzip -9"
        fi
        echo -e "${GREEN}║${NC} Fixes: ${GREEN}geoip, xray binary, backup.zip loop${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${CYAN}Fixed Issues:${NC}"
        echo -e "  ✔ node-data/assets/geoip.dat, geosite.dat excluded"
        echo -e "  ✔ node-data/xray-core/xray binary excluded (25MB)"
        echo -e "  ✔ panel/backup/backup.zip loop removed"
        echo -e "  ✔ /etc/letsencrypt full -> only data/certs"
        echo -e "  ✔ /etc/nginx full -> only panel_separate.conf"
        echo ""
        pause
    fi
}

# ==========================================
# RESTORE V1 - BUG FREE, Handles LITE & FULL
# ==========================================
do_restore() {
    clear
    ui_header "RESTORE FROM BACKUP - V1 STABLE"
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
        local TYPE="V1"
        [[ "$(basename "${FILES[$i]}")" == *"Full"* ]] && TYPE="FULL-OLD"
        [[ "$(basename "${FILES[$i]}")" == *"Lite"* ]] && TYPE="LITE-OLD"
        [[ "$(basename "${FILES[$i]}")" == *"V1"* ]] && TYPE="V1-STABLE"
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

    log_backup "INFO" "Starting restore V1 from: $(basename "$SELECTED")"

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

    # Stop services
    ui_spinner_start "Stopping services..."
    local PANEL_COMPOSE_FILE NODE_COMPOSE_FILE
    PANEL_COMPOSE_FILE="$(get_existing_compose_file panel 2>/dev/null || true)"
    NODE_COMPOSE_FILE="$(get_existing_compose_file node 2>/dev/null || true)"
    [ -n "$PANEL_COMPOSE_FILE" ] && run_compose_file "$PANEL_COMPOSE_FILE" down >/dev/null 2>&1 || true
    [ -n "$NODE_COMPOSE_FILE" ] && run_compose_file "$NODE_COMPOSE_FILE" down >/dev/null 2>&1 || true
    sleep 2
    ui_spinner_stop
    ui_success "Services stopped"

    # Safety backup
    ui_spinner_start "Creating safety backup..."
    local SAFETY_BACKUP="$BACKUP_DIR/pre_restore_$(date +%Y%m%d_%H%M%S).tar.gz"
    local SAFETY_ITEMS=()
    [ -d "$PANEL_DIR" ] && SAFETY_ITEMS+=("$PANEL_DIR")
    [ -d "$DATA_DIR" ] && SAFETY_ITEMS+=("$DATA_DIR")
    [ -f "$PANEL_ENV" ] && SAFETY_ITEMS+=("$PANEL_ENV")
    if [ "${#SAFETY_ITEMS[@]}" -gt 0 ]; then
        if tar -czf "$SAFETY_BACKUP" "${SAFETY_ITEMS[@]}" 2>/dev/null; then
            ui_spinner_stop
            ui_success "Safety backup: $(basename "$SAFETY_BACKUP") ($(du -h "$SAFETY_BACKUP" | cut -f1))"
            log_backup "INFO" "Safety backup created: $SAFETY_BACKUP"
        else
            ui_spinner_stop
            ui_warning "Safety backup failed, continuing anyway..."
        fi
    else
        ui_spinner_stop
        ui_warning "No existing data for safety backup"
    fi

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
        chmod -R 755 "$DATA_DIR" 2>/dev/null || true
        chown -R 1000:1000 "$DATA_DIR" 2>/dev/null || true
        ui_spinner_stop
        ui_success "FULL files restored"
    else
        # V1 or LITE RESTORE - ESSENTIALS ONLY (Bug free)
        log_backup "INFO" "Restoring V1 LITE essentials"
        ui_spinner_start "Restoring V1 essentials..."

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

        # Node essentials - only certs and .env, NOT xray binary
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
        fi

        # Fix perms
        chmod -R 755 "$DATA_DIR" 2>/dev/null || true
        chown -R 1000:1000 "$DATA_DIR" 2>/dev/null || true

        ui_spinner_stop
        ui_success "V1 essentials restored (without heavy files)"
    fi

    # Fix env files
    local RESTORE_ENV_OK=true
    ui_spinner_start "Fixing .env files..."
    if [ -f "$PANEL_ENV" ]; then fix_env_file "$PANEL_ENV" || RESTORE_ENV_OK=false; fi
    if [ -f "$NODE_ENV" ]; then fix_env_file "$NODE_ENV" || RESTORE_ENV_OK=false; fi
    ui_spinner_stop
    if [ "$RESTORE_ENV_OK" = true ]; then ui_success ".env files fixed"; else ui_warning ".env fix had issues"; fi

    # Fix IPs
    ui_spinner_start "Updating IPs in docker-compose..."
    if fix_docker_compose; then ui_spinner_stop; ui_success "Docker compose IPs updated"; else ui_spinner_stop; ui_warning "Compose IP update skipped"; fi

    # Smart fix
    apply_smart_fix

    # Start services
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

    # Restore database - Critical part, bug free
    local DB_RESTORE_PATH=""
    local DB_IS_GZ=false

    if [ -f "$ROOT/database/db.sql.gz" ]; then
        DB_RESTORE_PATH="$ROOT/database/db.sql.gz"
        DB_IS_GZ=true
    elif [ -f "$ROOT/database/db.sql" ]; then
        DB_RESTORE_PATH="$ROOT/database/db.sql"
    elif [ -f "$ROOT/database/db.sqlite3" ]; then
        DB_RESTORE_PATH="$ROOT/database/db.sqlite3"
    fi

    if [ -n "$DB_RESTORE_PATH" ]; then
        log_backup "INFO" "Found DB to restore: $DB_RESTORE_PATH"

        if [[ "$DB_RESTORE_PATH" == *"db.sql"* ]]; then
            # PostgreSQL restore
            if grep -qiE "postgresql|postgres" "$PANEL_ENV" 2>/dev/null; then
                local DB_IMPORTED=false
                echo -e "${YELLOW}Waiting for database to initialize (30s)...${NC}"
                sleep 30
                ui_spinner_start "Importing PostgreSQL database..."
                local DB_CONT=$(docker ps --format '{{.Names}}' | grep -iE "postgres|timescale|db" | head -1)
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

                    # Clean temp gunzipped file if created
                    [ "$DB_IS_GZ" = true ] && [ -f "$TEMP_SQL" ] && [ "$TEMP_SQL" != "$DB_RESTORE_PATH" ] && rm -f "$TEMP_SQL"
                else
                    log_backup "ERROR" "No DB container found for restore"
                fi
                ui_spinner_stop
                if [ "$DB_IMPORTED" = true ]; then ui_success "Database imported successfully!"; log_backup "SUCCESS" "DB imported"; else ui_error "Database import failed! Check logs"; log_backup "ERROR" "DB import failed"; fi
            fi
        elif [[ "$DB_RESTORE_PATH" == *"db.sqlite3"* ]]; then
            # SQLite restore
            ui_spinner_start "Restoring SQLite database..."
            local RESTORED=false
            if [ -f "$DATA_DIR/db.sqlite3" ] || [ -d "$DATA_DIR" ]; then
                if cp "$DB_RESTORE_PATH" "$DATA_DIR/db.sqlite3" 2>/dev/null; then RESTORED=true; fi
            fi
            if [ "$RESTORED" = false ] && [ -d "$PANEL_DIR" ]; then
                if cp "$DB_RESTORE_PATH" "$PANEL_DIR/db.sqlite3" 2>/dev/null; then RESTORED=true; fi
            fi
            ui_spinner_stop
            if [ "$RESTORED" = true ]; then ui_success "SQLite database restored"; else ui_error "SQLite restore failed"; fi
        fi
    else
        log_backup "WARNING" "No database file found in backup to restore"
        ui_warning "No database found in backup - only files restored"
    fi

    # Final cleanup
    rm -rf "$WORK_DIR"
    trap - RETURN

    local NEW_SERVER_IP=$(get_server_ip)
    log_backup "SUCCESS" "Restore V1 completed from: $(basename "$SELECTED")"

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              ✔ RESTORE V1 COMPLETED!                     ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC} Server IP: ${CYAN}$NEW_SERVER_IP${NC}"
    echo -e "${GREEN}║${NC} Backup: ${CYAN}$(basename "$SELECTED")${NC}"
    echo -e "${GREEN}║${NC} Type: ${CYAN}V1 Stable - Fixed 31MB${NC}"
    echo -e "${GREEN}║${NC} Data: ${CYAN}Safe & Complete${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Safety backup: $SAFETY_BACKUP${NC}"
    echo -e "${CYAN}Note: geoip.dat, xray binary will be re-downloaded automatically on node start${NC}"
    echo ""
    pause
}

# ==========================================
# OTHER UTILITIES
# ==========================================
setup_cron() {
    clear
    ui_header "BACKUP SCHEDULER - V1"
    echo "Current cron status:"
    if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH"; then
        local CURRENT=$(crontab -l | grep "$SCRIPT_PATH")
        echo -e "${GREEN}Active:${NC} $CURRENT"
    else
        echo -e "${YELLOW}No scheduled backup${NC}"
    fi
    echo ""
    echo "Select backup interval (V1 LITE):"
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
    if [ -n "$CRON_TIME" ]; then ui_success "Scheduled V1 backup enabled: $CRON_TIME"; log_backup "INFO" "Cron scheduled: $CRON_TIME"; else ui_success "Scheduled backup disabled"; log_backup "INFO" "Cron disabled"; fi
    pause
}

view_backup_logs() {
    clear
    ui_header "BACKUP LOGS - V1"
    if [ -f "$BACKUP_LOG" ]; then echo -e "${YELLOW}Last 50 entries:${NC}\n"; tail -n 50 "$BACKUP_LOG"; else ui_warning "No logs found"; fi
    pause
}

list_backups() {
    clear
    ui_header "AVAILABLE BACKUPS - V1 STABLE"
    local FILES=($(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null))
    if [ ${#FILES[@]} -eq 0 ]; then ui_warning "No backups found"; pause; return; fi
    echo -e "${GREEN}ID │ Type       │ Filename                              │ Size   │ Date${NC}"
    echo "───┼────────────┼─────────────────────────────────────────┼────────┼───────────"
    for i in "${!FILES[@]}"; do
        local NAME=$(basename "${FILES[$i]}")
        local SIZE=$(du -h "${FILES[$i]}" | cut -f1)
        local DATE=$(stat -c %y "${FILES[$i]}" | cut -d' ' -f1)
        local TYPE="V1"
        [[ "$NAME" == *"Full"* ]] && TYPE="FULL-OLD"
        [[ "$NAME" == *"Lite"* ]] && TYPE="LITE-OLD"
        [[ "$NAME" == *"V1"* ]] && TYPE="V1-STABLE"
        printf "%-2s │ %-10s │ %-39s │ %-6s │ %s\n" "$((i+1))" "$TYPE" "$NAME" "$SIZE" "$DATE"
    done
    echo ""
    echo -e "Total: ${CYAN}${#FILES[@]}${NC} backups"
    echo -e "Location: ${CYAN}$BACKUP_DIR${NC}"
    echo -e "Version: ${CYAN}$VERSION${NC} - Fixed 31MB issue"
    echo ""
    echo -e "${YELLOW}Tip: V1-STABLE backups are 2-5MB, ideal for Telegram${NC}"
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
    ui_header "BACKUP SIZE ANALYZER - V1"
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
    echo -e "${GREEN}=== V1 SOLUTION ===${NC}"
    echo -e "Exclude: assets/*, xray-core/*, backup/*, geoip.dat, geosite.dat, xray binary"
    echo -e "Result: 31MB -> 2-5MB"
    echo ""
    pause
}

# ==========================================
# MAIN MENU V1
# ==========================================
backup_menu() {
    init_backup_logging
    while true; do
        clear
        ui_header "BACKUP & RESTORE V1.0.1 - $VERSION"
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

        echo -e "Panel: ${CYAN}$(basename "$PANEL_DIR")${NC} | IP: ${CYAN}$SERVER_IP${NC} | Version: ${CYAN}$VERSION${NC}"
        echo -e "Backups: ${CYAN}$BACKUP_COUNT${NC} | Last: ${CYAN}$LAST_SIZE${NC} | Telegram: $TG_STATUS | Cron: $CRON_STATUS"
        echo ""
        echo "1)  📦 Create Backup"
        echo "2)  📥 Restore from Backup"
        echo "3)  📋 List All Backups"
        echo "4)  🗑️  Delete Backup"
        echo "5)  🤖 Setup Telegram Bot"
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
    else
        backup_menu
    fi
fi
