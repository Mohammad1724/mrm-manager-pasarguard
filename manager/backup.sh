#!/bin/bash

# ==========================================
# MRM BACKUP & RESTORE PRO v7.9
# Fixed: IPv4 Only, Database Pipe Method
# ==========================================

# ==========================================
# FIX FOR CRON / NON-INTERACTIVE ENV
# ==========================================
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export HOME="${HOME:-/root}"

# Load modules
source /opt/mrm-manager/utils.sh
source /opt/mrm-manager/ui.sh

# Configuration
BACKUP_DIR="/root/mrm-backups"
TG_CONFIG="/root/.mrm_telegram"
TEMP_BASE="/tmp/mrm_workspace"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
BACKUP_LOG="/var/log/mrm-backup.log"

# ==========================================
# LOGGING
# ==========================================
init_backup_logging() {
    mkdir -p "$(dirname "$BACKUP_LOG")"
    touch "$BACKUP_LOG"
}

log_backup() {
    local LEVEL=$1
    local MESSAGE=$2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$LEVEL] $MESSAGE" >> "$BACKUP_LOG"
}

# ==========================================
# ENVIRONMENT DETECTION
# ==========================================
setup_env() {
    detect_active_panel > /dev/null

    DOCKER_CMD="docker compose"
    ! docker compose version >/dev/null 2>&1 && DOCKER_CMD="docker-compose"

    log_backup "INFO" "Environment: PANEL_DIR=$PANEL_DIR, DATA_DIR=$DATA_DIR"
}

get_env_val() {
    [ -f "$PANEL_ENV" ] && grep "^$1=" "$PANEL_ENV" | cut -d'=' -f2- | sed 's/[[:space:]]*#.*$//' | sed 's/^"//;s/"$//' | xargs
}

# ==========================================
# GET CURRENT SERVER IP (IPv4 ONLY)
# ==========================================
get_server_ip() {
    local IP=""

    # Force IPv4 with -4 flag
    IP=$(curl -4 -s --connect-timeout 5 icanhazip.com 2>/dev/null)

    if [ -z "$IP" ]; then
        IP=$(curl -4 -s --connect-timeout 5 ipv4.icanhazip.com 2>/dev/null)
    fi

    if [ -z "$IP" ]; then
        IP=$(curl -4 -s --connect-timeout 5 api.ipify.org 2>/dev/null)
    fi

    if [ -z "$IP" ]; then
        IP=$(curl -4 -s --connect-timeout 5 checkip.amazonaws.com 2>/dev/null)
    fi

    if [ -z "$IP" ]; then
        # Get from network interface (IPv4 only)
        IP=$(ip -4 route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[^ ]+')
    fi

    # Validate IPv4 format
    if [[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$IP"
    else
        # Fallback: try to extract IPv4 from hostname
        IP=$(hostname -I 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        echo "$IP"
    fi
}

# ==========================================
# FIX ENV FILE (Broken Lines)
# ==========================================
fix_env_file() {
    local ENV_FILE=$1

    if [ ! -f "$ENV_FILE" ]; then
        return
    fi

    log_backup "INFO" "Fixing .env file: $ENV_FILE"

    # Create temp file
    local TEMP_FILE=$(mktemp)

    # Read and fix broken lines
    local prev_line=""
    while IFS= read -r line || [ -n "$line" ]; do
        # Check if previous line ends with UVICORN_ or SSL_ without value
        if [[ "$prev_line" =~ ^UVICORN_$ ]] || [[ "$prev_line" =~ ^SSL_$ ]]; then
            # Merge with current line
            echo "${prev_line}${line}" >> "$TEMP_FILE"
            prev_line=""
        elif [[ "$line" =~ ^UVICORN_$ ]] || [[ "$line" =~ ^SSL_$ ]]; then
            # Save for next iteration
            prev_line="$line"
        else
            if [ -n "$prev_line" ]; then
                echo "$prev_line" >> "$TEMP_FILE"
            fi
            echo "$line" >> "$TEMP_FILE"
            prev_line=""
        fi
    done < "$ENV_FILE"

    # Write last line if exists
    if [ -n "$prev_line" ]; then
        echo "$prev_line" >> "$TEMP_FILE"
    fi

    # Also fix with sed for any remaining issues
    sed -i ':a;N;$!ba;s/UVICORN_\nSSL_CERTFILE/UVICORN_SSL_CERTFILE/g' "$TEMP_FILE"
    sed -i ':a;N;$!ba;s/UVICORN_\nSSL_KEYFILE/UVICORN_SSL_KEYFILE/g' "$TEMP_FILE"
    sed -i ':a;N;$!ba;s/UVICORN_\n/UVICORN_/g' "$TEMP_FILE"
    sed -i ':a;N;$!ba;s/SSL_\n/SSL_/g' "$TEMP_FILE"

    # Fix spaces around =
    sed -i 's/[[:space:]]*=[[:space:]]*/=/g' "$TEMP_FILE"

    # Fix UVICORN_ SSL_ pattern (space instead of underscore continuation)
    sed -i 's/UVICORN_ SSL_CERTFILE/UVICORN_SSL_CERTFILE/g' "$TEMP_FILE"
    sed -i 's/UVICORN_ SSL_KEYFILE/UVICORN_SSL_KEYFILE/g' "$TEMP_FILE"

    # Remove duplicate empty lines
    cat -s "$TEMP_FILE" > "$ENV_FILE"
    rm -f "$TEMP_FILE"

    log_backup "SUCCESS" "Fixed .env file: $ENV_FILE"
}

# ==========================================
# FIX DOCKER COMPOSE (Update IPs)
# ==========================================
fix_docker_compose() {
    local COMPOSE_FILE="$PANEL_DIR/docker-compose.yml"

    if [ ! -f "$COMPOSE_FILE" ]; then
        log_backup "WARNING" "docker-compose.yml not found"
        return
    fi

    # Get current server IP
    local NEW_IP=$(get_server_ip)

    if [ -z "$NEW_IP" ]; then
        log_backup "WARNING" "Could not detect server IP"
        return
    fi

    log_backup "INFO" "Updating docker-compose with new IP: $NEW_IP"

    # Update PGADMIN_LISTEN_ADDRESS
    if grep -q "PGADMIN_LISTEN_ADDRESS" "$COMPOSE_FILE"; then
        sed -i "s/PGADMIN_LISTEN_ADDRESS:.*/PGADMIN_LISTEN_ADDRESS: $NEW_IP/g" "$COMPOSE_FILE"
        log_backup "SUCCESS" "Updated PGADMIN_LISTEN_ADDRESS to $NEW_IP"
    fi

    # Update any IP:port patterns (like 185.117.0.100:8010)
    sed -i -E "s/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:8010/${NEW_IP}:8010/g" "$COMPOSE_FILE"
    sed -i -E "s/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:7431/${NEW_IP}:7431/g" "$COMPOSE_FILE"

    # Update gunicorn bind address if exists
    sed -i -E "s/--bind [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:/--bind ${NEW_IP}:/g" "$COMPOSE_FILE"

    log_backup "SUCCESS" "Updated docker-compose.yml with IP: $NEW_IP"
}

# ==========================================
# TELEGRAM INTEGRATION
# ==========================================
send_to_telegram() {
    local FILE="$1"
    local MESSAGE="${2:-}"

    if [ ! -f "$TG_CONFIG" ]; then
        log_backup "WARNING" "Telegram not configured"
        return 1
    fi

    local TK=$(grep "TG_TOKEN" "$TG_CONFIG" | cut -d'=' -f2 | tr -d '"')
    local CH=$(grep "TG_CHAT" "$TG_CONFIG" | cut -d'=' -f2 | tr -d '"')
    local PROXY=$(grep "TG_PROXY" "$TG_CONFIG" | cut -d'=' -f2 | tr -d '"')
    local CURL_PROXY=""

if [[ "$PROXY" == socks5://* ]]; then
    PROXY_STR="${PROXY#socks5://}"

    if [[ "$PROXY_STR" == *"@"* ]]; then
        AUTH="${PROXY_STR%@*}"
        HOSTPORT="${PROXY_STR##*@}"
        CURL_PROXY="--socks5-hostname $HOSTPORT -U $AUTH"
    else
        CURL_PROXY="--socks5-hostname $PROXY_STR"
    fi
fi

    if [ -z "$TK" ] || [ -z "$CH" ]; then
        log_backup "ERROR" "Invalid Telegram config"
        return 1
    fi

    if [ -n "$FILE" ] && [ -f "$FILE" ]; then
        local CAPTION="✅ MRM Backup
🖥 $(hostname)
📅 $(date '+%Y-%m-%d %H:%M')
📦 $(basename "$FILE")"

        local RESULT=$(curl -4 -s -m 600 $CURL_PROXY -F chat_id="$CH" -F caption="$CAPTION" -F document=@"$FILE" "https://api.telegram.org/bot$TK/sendDocument")

        log_backup "DEBUG" "Telegram API response: $RESULT"

        if echo "$RESULT" | grep -q '"ok":true'; then
            log_backup "SUCCESS" "File sent to Telegram: $(basename "$FILE")"
            return 0
        else
            log_backup "ERROR" "Failed to send file to Telegram"
            return 1
        fi
    elif [ -n "$MESSAGE" ]; then
        curl -4 -s $CURL_PROXY -X POST "https://api.telegram.org/bot$TK/sendMessage" \
            -d chat_id="$CH" \
            -d text="$MESSAGE" > /dev/null
        return $?
    fi

    return 1
}

test_telegram() {
    if [ ! -f "$TG_CONFIG" ]; then
        ui_error "Telegram not configured!"
        return 1
    fi

    ui_spinner_start "Testing Telegram connection..."

    local TK=$(grep "TG_TOKEN" "$TG_CONFIG" | cut -d'=' -f2 | tr -d '"')
    local CH=$(grep "TG_CHAT" "$TG_CONFIG" | cut -d'=' -f2 | tr -d '"')
    local PROXY=$(grep "TG_PROXY" "$TG_CONFIG" | cut -d'=' -f2 | tr -d '"')
    local CURL_PROXY=""

if [[ "$PROXY" == socks5://* ]]; then
    PROXY_STR="${PROXY#socks5://}"

    if [[ "$PROXY_STR" == *"@"* ]]; then
        AUTH="${PROXY_STR%@*}"
        HOSTPORT="${PROXY_STR##*@}"
        CURL_PROXY="--socks5-hostname $HOSTPORT -U $AUTH"
    else
        CURL_PROXY="--socks5-hostname $PROXY_STR"
    fi
fi

    local RESULT=$(curl -4 -s $CURL_PROXY -X POST "https://api.telegram.org/bot$TK/sendMessage" \
        -d chat_id="$CH" \
        -d text="🧪 MRM Backup Test - $(date '+%Y-%m-%d %H:%M')" 2>&1)

    ui_spinner_stop

    if echo "$RESULT" | grep -q '"ok":true'; then
        ui_success "Telegram connection successful!"
        return 0
    else
        ui_error "Telegram connection failed!"
        echo -e "${YELLOW}Error: $RESULT${NC}"
        return 1
    fi
}

setup_telegram() {
    clear
    ui_header "SETUP TELEGRAM BOT"

    echo -e "${CYAN}To get Bot Token:${NC}"
    echo "  1. Message @BotFather on Telegram"
    echo "  2. Send /newbot and follow instructions"
    echo "  3. Copy the token"
    echo ""
    echo -e "${CYAN}To get Chat ID:${NC}"
    echo "  1. Message @userinfobot on Telegram"
    echo "  2. It will show your Chat ID"
    echo ""

    read -p "Enter Bot Token: " TK
    if [ -z "$TK" ]; then
        ui_error "Token is required!"
        pause
        return
    fi

    read -p "Enter Chat ID: " CI
    if [ -z "$CI" ]; then
        ui_error "Chat ID is required!"
        pause
        return
    fi
    
    echo ""
    read -p "Use SOCKS5 proxy for Telegram? (y/N): " USE_PROXY

    if [[ "$USE_PROXY" =~ ^[Yy]$ ]]; then
    echo ""
    echo "Enter proxy in this format:"
    echo "  socks5://127.0.0.1:1080"
    echo "  socks5://user:pass@127.0.0.1:1080"
    echo ""
    read -p "Proxy: " PROXY_URL
    else
    PROXY_URL=""
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
    if [[ ! "$TEST" =~ ^[Nn]$ ]]; then
        test_telegram
    fi

    pause
}

# ==========================================
# SMART FIX ENGINE
# ==========================================
apply_smart_fix() {
    clear
    echo -e "${CYAN}Applying Intelligent System Repairs...${NC}"
    log_backup "INFO" "Starting smart fix"

    # A. Get current server IP
    local SERVER_IP=$(get_server_ip)
    echo -e "${BLUE}Detected Server IP: ${CYAN}$SERVER_IP${NC}"

    # B. Secure Port Detection & Firewall
    ui_spinner_start "Configuring Firewall..."
    local SSH_PORT=$(ss -tlnp | grep sshd | grep -Po '(?<=:)\d+' | head -1)
    [ -z "$SSH_PORT" ] && SSH_PORT=22

    ufw allow "$SSH_PORT"/tcp >/dev/null 2>&1
    ufw allow 80,443,2096,7431,6432,8443,2083,2097,8080/tcp >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1
    ui_spinner_stop
    ui_success "Firewall configured (SSH: $SSH_PORT)"

    # C. Fix Panel .env
    ui_spinner_start "Fixing .env files..."
    fix_env_file "$PANEL_ENV"
    fix_env_file "$NODE_ENV"
    ui_spinner_stop
    ui_success ".env files repaired"

    # D. Fix docker-compose.yml IPs
    ui_spinner_start "Updating docker-compose IPs..."
    fix_docker_compose
    ui_spinner_stop
    ui_success "Docker compose updated with IP: $SERVER_IP"

    # E. Fix Node .env
    if [ -f "$NODE_ENV" ]; then
        ui_spinner_start "Fixing Node configuration..."
        sed -i 's/=[[:space:]]*/=/g' "$NODE_ENV"
        sed -i 's/[[:space:]]*=/=/g' "$NODE_ENV"
        ui_spinner_stop
        ui_success "Node .env fixed"
    fi

    # F. Generate Node SSL key if missing
    if [ -d "$NODE_DIR" ]; then
        mkdir -p "$NODE_DEF_CERTS"
        if [ ! -f "$NODE_DEF_CERTS/ssl_key.pem" ]; then
            ui_spinner_start "Generating Node SSL key..."
            openssl genrsa -out "$NODE_DEF_CERTS/ssl_key.pem" 2048 >/dev/null 2>&1
            ui_spinner_stop
            ui_success "Node SSL key generated"
        fi
    fi

    # G. Nginx Proxy Repair
    local NG_CONF="/etc/nginx/conf.d/panel_separate.conf"
    if [ -f "$NG_CONF" ]; then
        ui_spinner_start "Fixing Nginx config..."
        sed -i 's|proxy_pass http://127.0.0.1:7431;|proxy_pass https://127.0.0.1:7431;\n        proxy_ssl_verify off;|g' "$NG_CONF"
        systemctl restart nginx >/dev/null 2>&1
        ui_spinner_stop
        ui_success "Nginx configuration repaired"
    fi

    log_backup "SUCCESS" "Smart fix completed"
}

# ==========================================
# PARSE DATABASE CREDENTIALS FROM URI
# ==========================================
parse_db_credentials() {
    local ENV_FILE="$1"
    
    # Reset globals
    DB_USER=""
    DB_PASS=""
    DB_NAME=""
    DB_HOST=""
    
    if [ ! -f "$ENV_FILE" ]; then
        return 1
    fi
    
    # Try SQLALCHEMY_DATABASE_URL first
    local DB_URI=$(grep "^SQLALCHEMY_DATABASE_URL" "$ENV_FILE" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    
    if [ -n "$DB_URI" ]; then
        # Parse: postgresql+asyncpg://user:pass@host:port/dbname
        # or: postgresql://user:pass@host:port/dbname
        
        # Extract user
        DB_USER=$(echo "$DB_URI" | sed -n 's|.*://\([^:]*\):.*|\1|p')
        
        # Extract password (between first : after // and @)
        DB_PASS=$(echo "$DB_URI" | sed -n 's|.*://[^:]*:\([^@]*\)@.*|\1|p')
        
        # Extract database name (after last /)
        DB_NAME=$(echo "$DB_URI" | sed -n 's|.*/\([^?]*\).*|\1|p')
        
        # Extract host
        DB_HOST=$(echo "$DB_URI" | sed -n 's|.*@\([^:/]*\).*|\1|p')
        
        log_backup "INFO" "Parsed from URI - User: $DB_USER, DB: $DB_NAME, Host: $DB_HOST"
        return 0
    fi
    
    # Fallback to individual vars
    DB_USER=$(grep "^POSTGRES_USER" "$ENV_FILE" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    DB_PASS=$(grep "^POSTGRES_PASSWORD" "$ENV_FILE" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    DB_NAME=$(grep "^POSTGRES_DB" "$ENV_FILE" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    
    if [ -n "$DB_USER" ]; then
        log_backup "INFO" "Parsed from vars - User: $DB_USER, DB: $DB_NAME"
        return 0
    fi
    
    return 1
}

# ==========================================
# DATABASE EXPORT FUNCTION (PIPE METHOD)
# ==========================================
export_postgresql_database() {
    local DEST_DIR="$1"
    local DB_EXPORTED=false
    
    log_backup "INFO" "=== Starting PostgreSQL Export (Pipe Method) ==="
    
    # Find database container
    local DB_CONT=$(docker ps --format '{{.Names}}' | grep -iE "postgres|timescale|db" | head -1)
    
    if [ -z "$DB_CONT" ]; then
        log_backup "ERROR" "No PostgreSQL container found!"
        echo "ERROR: No database container found"
        return 1
    fi
    
    log_backup "INFO" "Found DB container: $DB_CONT"
    
    # Parse credentials from .env
    parse_db_credentials "$PANEL_ENV"
    
    log_backup "INFO" "Credentials - User: $DB_USER, Pass: [${#DB_PASS} chars], DB: $DB_NAME"
    
    # Build list of credentials to try
    declare -a CREDS_TO_TRY
    
    # Add parsed credentials first
    if [ -n "$DB_USER" ] && [ -n "$DB_PASS" ]; then
        CREDS_TO_TRY+=("$DB_USER|$DB_PASS|$DB_NAME")
    fi
    
    # Add common fallbacks
    CREDS_TO_TRY+=("pasarguard|17240304|pasarguard")
    CREDS_TO_TRY+=("marzban|marzban|marzban")
    CREDS_TO_TRY+=("postgres||postgres")
    
    # Try each set of credentials using PIPE method
    for CRED in "${CREDS_TO_TRY[@]}"; do
        IFS='|' read -r TRY_USER TRY_PASS TRY_DB <<< "$CRED"
        
        [ -z "$TRY_DB" ] && TRY_DB="$TRY_USER"
        
        log_backup "INFO" "Trying pg_dump (pipe) - User: $TRY_USER, DB: $TRY_DB"
        
        # Use PIPE method - dump directly to host filesystem
        if [ -n "$TRY_PASS" ]; then
            docker exec -e PGPASSWORD="$TRY_PASS" "$DB_CONT" pg_dump -U "$TRY_USER" -d "$TRY_DB" 2>/dev/null > "$DEST_DIR/db.sql"
        else
            docker exec "$DB_CONT" pg_dump -U "$TRY_USER" -d "$TRY_DB" 2>/dev/null > "$DEST_DIR/db.sql"
        fi
        
        # Check if file exists and has content (more than 100 bytes)
        if [ -f "$DEST_DIR/db.sql" ]; then
            local FILE_SIZE=$(stat -c%s "$DEST_DIR/db.sql" 2>/dev/null || echo "0")
            
            if [ "$FILE_SIZE" -gt 100 ]; then
                log_backup "SUCCESS" "pg_dump successful with user '$TRY_USER' - Size: $FILE_SIZE bytes"
                DB_EXPORTED=true
                break
            else
                log_backup "WARN" "pg_dump with '$TRY_USER' created empty/small file ($FILE_SIZE bytes)"
                rm -f "$DEST_DIR/db.sql"
            fi
        else
            log_backup "WARN" "pg_dump with '$TRY_USER' failed - no file created"
        fi
    done
    
    if [ "$DB_EXPORTED" = true ]; then
        return 0
    else
        log_backup "ERROR" "All pg_dump attempts failed!"
        return 1
    fi
}

# ==========================================
# BACKUP FUNCTIONS
# ==========================================
do_backup() {
    local MODE="${1:-manual}"
    setup_env
    init_backup_logging

    [ "$MODE" != "auto" ] && clear
    [ "$MODE" != "auto" ] && ui_header "FULL SYSTEM BACKUP"

    log_backup "INFO" "========== Starting backup (mode: $MODE) =========="
    log_backup "INFO" "PANEL_DIR: $PANEL_DIR"
    log_backup "INFO" "DATA_DIR: $DATA_DIR"
    log_backup "INFO" "PANEL_ENV: $PANEL_ENV"

    local TS=$(date +%Y%m%d_%H%M%S)
    local B_NAME="MRM_Full_${TS}"
    local B_PATH="$TEMP_BASE/$B_NAME"

    mkdir -p "$B_PATH/database" "$B_PATH/panel" "$B_PATH/data"
    mkdir -p "$BACKUP_DIR"

    # 1. Export Database
    [ "$MODE" != "auto" ] && ui_spinner_start "Exporting database..."

    local DB_SUCCESS=false

    if grep -qiE "postgresql|postgres" "$PANEL_ENV" 2>/dev/null; then
        log_backup "INFO" "PostgreSQL detected in .env"
        
        if export_postgresql_database "$B_PATH/database"; then
            DB_SUCCESS=true
            [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "Database exported"
        else
            [ "$MODE" != "auto" ] && ui_spinner_stop && ui_error "Database export FAILED!"
            log_backup "ERROR" "PostgreSQL export failed"
        fi
    else
        log_backup "INFO" "SQLite mode - looking for db.sqlite3"
        
        if [ -f "$DATA_DIR/db.sqlite3" ]; then
            cp "$DATA_DIR/db.sqlite3" "$B_PATH/database/"
            DB_SUCCESS=true
            log_backup "INFO" "SQLite exported from DATA_DIR"
        elif [ -f "$PANEL_DIR/db.sqlite3" ]; then
            cp "$PANEL_DIR/db.sqlite3" "$B_PATH/database/"
            DB_SUCCESS=true
            log_backup "INFO" "SQLite exported from PANEL_DIR"
        else
            log_backup "ERROR" "No SQLite database found!"
        fi
        
        [ "$MODE" != "auto" ] && ui_spinner_stop
        [ "$DB_SUCCESS" = true ] && [ "$MODE" != "auto" ] && ui_success "Database exported"
        [ "$DB_SUCCESS" = false ] && [ "$MODE" != "auto" ] && ui_error "No database found!"
    fi

    # Show warning if DB export failed
    if [ "$DB_SUCCESS" = false ] && [ "$MODE" != "auto" ]; then
        echo ""
        echo -e "${RED}⚠️  WARNING: Database export failed!${NC}"
        echo -e "${YELLOW}The backup will be created but WITHOUT database.${NC}"
        echo ""
        read -p "Continue anyway? (y/N): " CONT
        if [[ ! "$CONT" =~ ^[Yy]$ ]]; then
            rm -rf "$TEMP_BASE"
            return
        fi
    fi

    # 2. Collect Panel Files
    [ "$MODE" != "auto" ] && ui_spinner_start "Backing up panel files..."
    cp -a "$PANEL_DIR/." "$B_PATH/panel/" 2>/dev/null
    cp -a "$DATA_DIR/." "$B_PATH/data/" 2>/dev/null
    [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "Panel files backed up"

    # 3. Collect Node Files
    if [ -d "$NODE_DIR" ]; then
        [ "$MODE" != "auto" ] && ui_spinner_start "Backing up node files..."
        mkdir -p "$B_PATH/node" "$B_PATH/node-data"
        cp -a "$NODE_DIR/." "$B_PATH/node/" 2>/dev/null
        [ -d "$(dirname "$NODE_DEF_CERTS")" ] && cp -a "$(dirname "$NODE_DEF_CERTS")/." "$B_PATH/node-data/" 2>/dev/null
        [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "Node files backed up"
    fi

    # 4. Collect SSL Certificates
    if [ -d "/etc/letsencrypt" ]; then
        [ "$MODE" != "auto" ] && ui_spinner_start "Backing up SSL certificates..."
        mkdir -p "$B_PATH/ssl"
        cp -a /etc/letsencrypt/. "$B_PATH/ssl/" 2>/dev/null
        [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "SSL certificates backed up"
    fi

    # 5. Collect Nginx Config
    if [ -d "/etc/nginx" ]; then
        [ "$MODE" != "auto" ] && ui_spinner_start "Backing up Nginx config..."
        mkdir -p "$B_PATH/nginx"
        cp -a /etc/nginx/. "$B_PATH/nginx/" 2>/dev/null
        [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "Nginx config backed up"
    fi

    # 6. Save metadata
    local SERVER_IP=$(get_server_ip)
    cat > "$B_PATH/backup_info.txt" << EOF
Backup Date: $(date '+%Y-%m-%d %H:%M:%S')
Hostname: $(hostname)
Server IP: $SERVER_IP
Panel: $(basename "$PANEL_DIR")
Panel Dir: $PANEL_DIR
Data Dir: $DATA_DIR
Node Dir: $NODE_DIR
Database Exported: $DB_SUCCESS
MRM Version: 3.0
EOF

    # 7. Create archive
    [ "$MODE" != "auto" ] && ui_spinner_start "Creating backup archive..."
    tar -czf "$BACKUP_DIR/$B_NAME.tar.gz" -C "$TEMP_BASE" "$B_NAME"
    local BACKUP_SIZE=$(du -h "$BACKUP_DIR/$B_NAME.tar.gz" | cut -f1)
    [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "Archive created ($BACKUP_SIZE)"

    # 8. Cleanup temp
    rm -rf "$TEMP_BASE"

    # 9. Send to Telegram
    if [ -f "$TG_CONFIG" ]; then
        [ "$MODE" != "auto" ] && ui_spinner_start "Sending to Telegram..."
        if send_to_telegram "$BACKUP_DIR/$B_NAME.tar.gz"; then
            [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "Backup sent to Telegram!"
        else
            [ "$MODE" != "auto" ] && ui_spinner_stop && ui_warning "Failed to send to Telegram"
        fi
    fi

    # 10. Cleanup old backups (keep last 5)
    ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null

    log_backup "SUCCESS" "Backup completed: $B_NAME.tar.gz ($BACKUP_SIZE)"
    log_backup "INFO" "========== Backup finished =========="

    if [ "$MODE" != "auto" ]; then
        echo ""
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║              ✔ BACKUP COMPLETED!                         ║${NC}"
        echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${GREEN}║${NC} File: ${CYAN}$BACKUP_DIR/$B_NAME.tar.gz${NC}"
        echo -e "${GREEN}║${NC} Size: ${CYAN}$BACKUP_SIZE${NC}"
        if [ "$DB_SUCCESS" = false ]; then
            echo -e "${GREEN}║${NC} Database: ${RED}NOT EXPORTED${NC}"
        else
            echo -e "${GREEN}║${NC} Database: ${GREEN}Exported${NC}"
        fi
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
        pause
    fi
}

# ==========================================
# RESTORE FUNCTIONS
# ==========================================
do_restore() {
    setup_env
    clear
    ui_header "FULL SYSTEM RESTORE"

    # List available backups
    local FILES=($(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null))

    if [ ${#FILES[@]} -eq 0 ]; then
        ui_error "No backups found in $BACKUP_DIR"
        echo ""
        echo "Options:"
        echo "1) Upload backup file manually to $BACKUP_DIR"
        echo "2) Download from Telegram and place in $BACKUP_DIR"
        pause
        return
    fi

    echo -e "${YELLOW}Available Backups:${NC}"
    echo ""
    for i in "${!FILES[@]}"; do
        local SIZE=$(du -h "${FILES[$i]}" | cut -f1)
        local DATE=$(stat -c %y "${FILES[$i]}" | cut -d' ' -f1)
        echo "$((i+1))) $(basename "${FILES[$i]}") [$SIZE] - $DATE"
    done

    echo ""
    read -p "Select backup to restore (0 to cancel): " CH

    [ "$CH" == "0" ] && return

    local SELECTED="${FILES[$((CH-1))]}"
    if [ -z "$SELECTED" ] || [ ! -f "$SELECTED" ]; then
        ui_error "Invalid selection!"
        pause
        return
    fi

    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║              ⚠️  WARNING  ⚠️                              ║${NC}"
    echo -e "${RED}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}║  This will OVERWRITE all current data!                   ║${NC}"
    echo -e "${RED}║  Make sure you have a backup of current state.           ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -p "Type 'CONFIRM' to proceed: " CONF

    if [ "$CONF" != "CONFIRM" ]; then
        echo "Cancelled."
        pause
        return
    fi

    log_backup "INFO" "Starting restore from: $(basename "$SELECTED")"

    # Get new server IP before restore
    local NEW_SERVER_IP=$(get_server_ip)
    echo -e "${BLUE}Current Server IP: ${CYAN}$NEW_SERVER_IP${NC}"

    # Extract backup
    local WORK_DIR="/tmp/mrm_restore_$(date +%s)"
    mkdir -p "$WORK_DIR"

    ui_spinner_start "Extracting backup..."
    tar -xzf "$SELECTED" -C "$WORK_DIR"
    ui_spinner_stop

    local ROOT=$(ls -d "$WORK_DIR"/* | head -1)

    if [ ! -d "$ROOT" ]; then
        ui_error "Invalid backup archive!"
        rm -rf "$WORK_DIR"
        pause
        return
    fi

    # Show backup info if available
    if [ -f "$ROOT/backup_info.txt" ]; then
        echo ""
        echo -e "${CYAN}Backup Info:${NC}"
        cat "$ROOT/backup_info.txt"
        echo ""

        # Show IP change warning
        local OLD_IP=$(grep "Server IP:" "$ROOT/backup_info.txt" | awk '{print $3}')
        if [ -n "$OLD_IP" ] && [ "$OLD_IP" != "$NEW_SERVER_IP" ]; then
            echo -e "${YELLOW}⚠ IP Changed: $OLD_IP → $NEW_SERVER_IP${NC}"
            echo -e "${GREEN}Will auto-update configurations...${NC}"
            echo ""
        fi
    fi

    # Stop services
    ui_spinner_start "Stopping services..."
    $DOCKER_CMD -f "$PANEL_DIR/docker-compose.yml" down >/dev/null 2>&1
    $DOCKER_CMD -f "$NODE_DIR/docker-compose.yml" down >/dev/null 2>&1
    ui_spinner_stop
    ui_success "Services stopped"

    # Backup current state (just in case)
    ui_spinner_start "Creating safety backup..."
    local SAFETY_BACKUP="$BACKUP_DIR/pre_restore_$(date +%Y%m%d_%H%M%S).tar.gz"
    tar -czf "$SAFETY_BACKUP" "$PANEL_DIR" "$DATA_DIR" 2>/dev/null
    ui_spinner_stop
    ui_success "Safety backup created"

    # Remove old files
    ui_spinner_start "Cleaning old files..."
    rm -rf "$PANEL_DIR" "$DATA_DIR" "$NODE_DIR" "$(dirname "$NODE_DEF_CERTS")"
    ui_spinner_stop

    # Restore files
    ui_spinner_start "Restoring panel files..."
    mkdir -p "$PANEL_DIR" "$DATA_DIR"
    cp -a "$ROOT/panel/." "$PANEL_DIR/" 2>/dev/null
    cp -a "$ROOT/data/." "$DATA_DIR/" 2>/dev/null
    
    # FIX: Permissions for Database
    chmod -R 755 "$DATA_DIR" 2>/dev/null
    chown -R 1000:1000 "$DATA_DIR" 2>/dev/null || true
    
    ui_spinner_stop
    ui_success "Panel files restored"

    if [ -d "$ROOT/node" ]; then
        ui_spinner_start "Restoring node files..."
        mkdir -p "$NODE_DIR" "$(dirname "$NODE_DEF_CERTS")"
        cp -a "$ROOT/node/." "$NODE_DIR/" 2>/dev/null
        cp -a "$ROOT/node-data/." "$(dirname "$NODE_DEF_CERTS")/" 2>/dev/null
        ui_spinner_stop
        ui_success "Node files restored"
    fi

    if [ -d "$ROOT/ssl" ]; then
        ui_spinner_start "Restoring SSL certificates..."
        rm -rf /etc/letsencrypt
        mkdir -p /etc/letsencrypt
        cp -a "$ROOT/ssl/." /etc/letsencrypt/ 2>/dev/null
        ui_spinner_stop
        ui_success "SSL certificates restored"
    fi

    if [ -d "$ROOT/nginx" ]; then
        ui_spinner_start "Restoring Nginx config..."
        cp -a "$ROOT/nginx/." /etc/nginx/ 2>/dev/null
        ui_spinner_stop
        ui_success "Nginx config restored"
    fi

    # ⭐ FIX CONFIGURATIONS (Important!)
    echo ""
    echo -e "${CYAN}Fixing configurations for new server...${NC}"

    ui_spinner_start "Fixing .env files..."
    fix_env_file "$PANEL_ENV"
    fix_env_file "$NODE_ENV"
    ui_spinner_stop
    ui_success ".env files fixed"

    ui_spinner_start "Updating IPs in docker-compose..."
    fix_docker_compose
    ui_spinner_stop
    ui_success "Docker compose IPs updated"

    # Apply smart fixes
    apply_smart_fix

    # Start services
    ui_spinner_start "Starting services..."
    if [ -d "$NODE_DIR" ] && [ -f "$NODE_DIR/docker-compose.yml" ]; then
        cd "$NODE_DIR" && $DOCKER_CMD up -d >/dev/null 2>&1
    fi
    cd "$PANEL_DIR" && $DOCKER_CMD up -d >/dev/null 2>&1
    ui_spinner_stop
    ui_success "Services started"

    # Restore database
    if grep -qiE "postgresql|postgres" "$PANEL_ENV" 2>/dev/null && [ -f "$ROOT/database/db.sql" ]; then
        echo -e "${YELLOW}Waiting for database to initialize (30s)...${NC}"
        sleep 30

        ui_spinner_start "Importing database..."
        local DB_CONT=$(docker ps --format '{{.Names}}' | grep -iE "timescale|postgres|db" | head -1)
        if [ -n "$DB_CONT" ]; then
            # Parse credentials
            parse_db_credentials "$PANEL_ENV"
            
            [ -z "$DB_USER" ] && DB_USER="pasarguard"
            [ -z "$DB_NAME" ] && DB_NAME="$DB_USER"
            
            # Drop and restore WITH PASSWORD using pipe
            if [ -n "$DB_PASS" ]; then
                docker exec -e PGPASSWORD="$DB_PASS" "$DB_CONT" psql -U "$DB_USER" -d "$DB_NAME" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null 2>&1
                cat "$ROOT/database/db.sql" | docker exec -i -e PGPASSWORD="$DB_PASS" "$DB_CONT" psql -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1
            else
                docker exec "$DB_CONT" psql -U "$DB_USER" -d "$DB_NAME" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null 2>&1
                cat "$ROOT/database/db.sql" | docker exec -i "$DB_CONT" psql -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1
            fi
        fi
        ui_spinner_stop
        ui_success "Database imported"
    fi

    # Cleanup
    rm -rf "$WORK_DIR"

    log_backup "SUCCESS" "Restore completed from: $(basename "$SELECTED")"

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              ✔ RESTORE COMPLETED!                        ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC} Server IP: ${CYAN}$NEW_SERVER_IP${NC}"
    echo -e "${GREEN}║${NC} Configurations auto-fixed for new server"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Safety backup: $SAFETY_BACKUP${NC}"

    pause
}

# ==========================================
# CRON SCHEDULER
# ==========================================
setup_cron() {
    clear
    ui_header "BACKUP SCHEDULER"

    echo "Current cron status:"
    if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH"; then
        local CURRENT=$(crontab -l | grep "$SCRIPT_PATH")
        echo -e "${GREEN}Active:${NC} $CURRENT"
    else
        echo -e "${YELLOW}No scheduled backup${NC}"
    fi

    echo ""
    echo "Select backup interval:"
    echo "1) Every 6 hours"
    echo "2) Every 12 hours"
    echo "3) Every 24 hours (Daily)"
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

    if [ -n "$CRON_TIME" ]; then
        ui_success "Scheduled backup enabled: $CRON_TIME"
        log_backup "INFO" "Cron scheduled: $CRON_TIME"
    else
        ui_success "Scheduled backup disabled"
        log_backup "INFO" "Cron disabled"
    fi

    pause
}

# ==========================================
# VIEW LOGS
# ==========================================
view_backup_logs() {
    clear
    ui_header "BACKUP LOGS"

    if [ -f "$BACKUP_LOG" ]; then
        echo -e "${YELLOW}Last 30 entries:${NC}"
        echo ""
        tail -n 30 "$BACKUP_LOG"
    else
        ui_warning "No logs found"
    fi

    pause
}

# ==========================================
# LIST BACKUPS
# ==========================================
list_backups() {
    clear
    ui_header "AVAILABLE BACKUPS"

    local FILES=($(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null))

    if [ ${#FILES[@]} -eq 0 ]; then
        ui_warning "No backups found"
        pause
        return
    fi

    echo -e "${GREEN}ID │ Filename                              │ Size   │ Date${NC}"
    echo "───┼─────────────────────────────────────────┼────────┼───────────"

    for i in "${!FILES[@]}"; do
        local NAME=$(basename "${FILES[$i]}")
        local SIZE=$(du -h "${FILES[$i]}" | cut -f1)
        local DATE=$(stat -c %y "${FILES[$i]}" | cut -d' ' -f1)
        printf "%-2s │ %-39s │ %-6s │ %s\n" "$((i+1))" "$NAME" "$SIZE" "$DATE"
    done

    echo ""
    echo -e "Total: ${CYAN}${#FILES[@]}${NC} backups"
    echo -e "Location: ${CYAN}$BACKUP_DIR${NC}"

    pause
}

# ==========================================
# DELETE BACKUP
# ==========================================
delete_backup() {
    clear
    ui_header "DELETE BACKUP"

    local FILES=($(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null))

    if [ ${#FILES[@]} -eq 0 ]; then
        ui_warning "No backups found"
        pause
        return
    fi

    echo -e "${YELLOW}Select backup to delete:${NC}"
    echo ""

    for i in "${!FILES[@]}"; do
        local SIZE=$(du -h "${FILES[$i]}" | cut -f1)
        echo "$((i+1))) $(basename "${FILES[$i]}") [$SIZE]"
    done

    echo ""
    read -p "Select (0 to cancel): " SEL

    [ "$SEL" == "0" ] && return

    local SELECTED="${FILES[$((SEL-1))]}"
    if [ -z "$SELECTED" ]; then
        ui_error "Invalid selection"
        pause
        return
    fi

    echo ""
    read -p "Delete $(basename "$SELECTED")? (y/N): " CONFIRM

    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        rm -f "$SELECTED"
        ui_success "Backup deleted"
        log_backup "INFO" "Deleted backup: $(basename "$SELECTED")"
    else
        echo "Cancelled"
    fi

    pause
}

# ==========================================
# MAIN MENU
# ==========================================
backup_menu() {
    init_backup_logging

    while true; do
        clear
        ui_header "BACKUP & RESTORE v7.9"
        setup_env

        # Show status
        local BACKUP_COUNT=$(ls "$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l)
        local TG_STATUS="${RED}Not Configured${NC}"
        [ -f "$TG_CONFIG" ] && TG_STATUS="${GREEN}Configured${NC}"
        local CRON_STATUS="${RED}Disabled${NC}"
        crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH" && CRON_STATUS="${GREEN}Active${NC}"
        local SERVER_IP=$(get_server_ip)

        echo -e "Panel: ${CYAN}$(basename "$PANEL_DIR")${NC} | IP: ${CYAN}$SERVER_IP${NC}"
        echo -e "Backups: ${CYAN}$BACKUP_COUNT${NC} | Telegram: $TG_STATUS | Cron: $CRON_STATUS"
        echo ""

        echo "1)  📦 Create Full Backup"
        echo "2)  📥 Restore from Backup"
        echo "3)  📋 List All Backups"
        echo "4)  🗑️  Delete Backup"
        echo "5)  🤖 Setup Telegram Bot"
        echo "6)  🧪 Test Telegram"
        echo "7)  ⏰ Setup Cron Scheduler"
        echo "8)  🔧 Run Smart Fix Only"
        echo "9)  📋 View Logs"
        echo ""
        echo "0)  ↩️  Back"
        echo ""
        read -p "Select: " opt

        case $opt in
            1) do_backup "manual" ;;
            2) do_restore ;;
            3) list_backups ;;
            4) delete_backup ;;
            5) setup_telegram ;;
            6) test_telegram; pause ;;
            7) setup_cron ;;
            8) apply_smart_fix; pause ;;
            9) view_backup_logs ;;
            0) return ;;
            *) ;;
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
