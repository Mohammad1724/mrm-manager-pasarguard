#!/bin/bash
# MRM Manager Backup v1.1.13

# ==========================================
# MRM Backup & Restore v1.1.13
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
# FIX: unique per-run workspace — a shared /tmp/mrm_workspace could be
# wiped by a concurrent run (cron + manual) and corrupt that backup (MRM-041)
TEMP_BASE="$(mktemp -d /tmp/mrm_workspace.XXXXXX 2>/dev/null || echo /tmp/mrm_workspace)"
trap '[ -n "${TEMP_BASE}" ] && rm -rf "$TEMP_BASE"' EXIT
# FIX: BASH_SOURCE[0] inside a sourced init.sh points at init.sh, which made
# cron run init.sh directly (it only defines functions, never calls do_backup).
# Resolve to the real entry script (backup.sh) so cron invokes it.
if [ -n "${BASH_SOURCE[1]:-}" ]; then
    SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[1]}")"
else
    SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
fi
if [ "$(basename "$SCRIPT_PATH")" = "init.sh" ]; then
    SCRIPT_PATH="$(readlink -f "$(dirname "$SCRIPT_PATH")/../backup.sh")"
fi
BACKUP_LOG="/var/log/mrm-backup.log"
MRM_BACKUP_VERSION="v${BACKUP_VERSION:-1.0.5}"

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


# ==========================================
# PARSE DB CREDENTIALS
# ==========================================
# ==========================================
# PARSE DB CREDENTIALS
# ==========================================
parse_db_credentials() {
    local ENV_FILE="$1"
    DB_USER=""; DB_PASS=""; DB_NAME=""; DB_HOST=""
    if [ ! -f "$ENV_FILE" ]; then return 1; fi
    local DB_URI=$(grep "^SQLALCHEMY_DATABASE_URL" "$ENV_FILE" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    if [ -n "$DB_URI" ]; then
        # SECURITY: Use Python urllib for proper URL parsing (handles @ in passwords)
        local PARSED
        PARSED=$(python3 -c "
import sys, urllib.parse
try:
    u = urllib.parse.urlparse(sys.stdin.read().strip())
    print('USER=' + urllib.parse.unquote(u.username or ''))
    print('PASS=' + urllib.parse.unquote(u.password or ''))
    print('HOST=' + (u.hostname or ''))
    print('DB=' + (u.path.lstrip('/') or ''))
except Exception:
    pass
" <<< "$DB_URI" 2>/dev/null)
        if [ -n "$PARSED" ]; then
            DB_USER=$(echo "$PARSED" | grep "^USER=" | cut -d= -f2-)
            DB_PASS=$(echo "$PARSED" | grep "^PASS=" | cut -d= -f2-)
            DB_NAME=$(echo "$PARSED" | grep "^DB=" | cut -d= -f2-)
            DB_HOST=$(echo "$PARSED" | grep "^HOST=" | cut -d= -f2-)
            # FIX: a URI without credentials (e.g. sqlite) parses fine but yields
            # empty user/name — treat as failure like the plain vars branch (MRM-042)
            if [ -z "$DB_USER" ] || [ -z "$DB_NAME" ]; then
                log_backup "WARNING" "URI parsed but no DB user/name (sqlite URI?)"
                return 1
            fi
            log_backup "INFO" "Parsed from URI - User: $DB_USER, DB: $DB_NAME, Host: $DB_HOST"
            return 0
        fi
        # Fallback to sed (less reliable but works for simple cases)
        DB_USER=$(echo "$DB_URI" | sed -n 's|.*://\([^:]*\):.*|\1|p')
        DB_PASS=$(echo "$DB_URI" | sed -n 's|.*://[^:]*:\([^@]*\)@.*|\1|p')
        DB_NAME=$(echo "$DB_URI" | sed -n 's|.*/\([^?]*\).*|\1|p')
        DB_HOST=$(echo "$DB_URI" | sed -n 's|.*@\([^:/]*\).*|\1|p')
        log_backup "INFO" "Parsed from URI (fallback) - User: $DB_USER, DB: $DB_NAME, Host: $DB_HOST"
        return 0
    fi
    DB_USER=$(grep "^POSTGRES_USER" "$ENV_FILE" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    DB_PASS=$(grep "^POSTGRES_PASSWORD" "$ENV_FILE" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    DB_NAME=$(grep "^POSTGRES_DB" "$ENV_FILE" | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    if [ -n "$DB_USER" ]; then log_backup "INFO" "Parsed from vars - User: $DB_USER, DB: $DB_NAME"; return 0; fi
    return 1
}

