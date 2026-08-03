#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# MRM Manager - Post-Restore Auto-Fix Script
# This runs automatically after backup restore to fix common issues:
#   1. Install Nginx if not present
#   2. Copy SSL certs to /etc/letsencrypt/live/
#   3. Set XRAY_SUBSCRIPTION_URL_PREFIX in .env
#   4. Test and start Nginx
#   5. Restart panel
# ═══════════════════════════════════════════════════════════════════════════════

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# Load MRM utils
if [ -f "/opt/mrm-manager/utils.sh" ]; then
    source /opt/mrm-manager/utils.sh
    detect_active_panel >/dev/null 2>&1 || true
fi

# Fallback paths
PANEL_DIR="${PANEL_DIR:-/opt/pasarguard}"
PANEL_ENV="${PANEL_ENV:-/opt/pasarguard/.env}"
DATA_DIR="${DATA_DIR:-/var/lib/pasarguard}"
NODE_DIR="${NODE_DIR:-/opt/pg-node}"

DOMAIN_SEP_CONF="/etc/nginx/conf.d/panel_separate.conf"
PANEL_CERTS_DIR="$DATA_DIR/certs"
LOG_FILE="/var/log/mrm-post-restore.log"

log_msg() {
    local MSG="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$MSG" >> "$LOG_FILE"
    echo -e "$1"
}

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 1: Install Nginx if not present
# ═══════════════════════════════════════════════════════════════════════════════
ensure_nginx_installed() {
    if command -v nginx >/dev/null 2>&1; then
        log_msg "${GREEN}✅ Nginx is already installed: $(nginx -v 2>&1)${NC}"
        return 0
    fi

    log_msg "${YELLOW}⚠️  Nginx not found - installing...${NC}"

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
        log_msg "${GREEN}✅ Nginx installed successfully${NC}"
        systemctl enable nginx >/dev/null 2>&1
    else
        log_msg "${RED}❌ Nginx installation failed!${NC}"
        # Restart panel if we stopped it
        if [ "$NEED_STOP_PANEL" = true ]; then
            cd "$PANEL_DIR" && docker compose start 2>/dev/null || true
        fi
        return 1
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 2: Copy SSL certs to /etc/letsencrypt/live/
# ═══════════════════════════════════════════════════════════════════════════════
copy_ssl_certs() {
    log_msg "${CYAN}📋 Checking SSL certificates...${NC}"

    local COPIED=0
    local NEED_COPY=0

    # Extract domain names from panel_separate.conf
    if [ ! -f "$DOMAIN_SEP_CONF" ]; then
        log_msg "${YELLOW}⚠️  Domain separator config not found - skipping cert copy${NC}"
        return 0
    fi

    # Get all server_name entries from the config
    local DOMAINS
    DOMAINS=$(grep -oP 'server_name\s+\K[^;]+' "$DOMAIN_SEP_CONF" 2>/dev/null | tr -d ' ' | sort -u)

    if [ -z "$DOMAINS" ]; then
        log_msg "${YELLOW}⚠️  No domains found in $DOMAIN_SEP_CONF${NC}"
        return 0
    fi

    for DOMAIN in $DOMAINS; do
        local LETS_DIR="/etc/letsencrypt/live/$DOMAIN"
        local PANEL_CERT_DIR="$PANEL_CERTS_DIR/$DOMAIN"

        # Check if letsencrypt dir already has valid certs
        if [ -f "$LETS_DIR/fullchain.pem" ] && [ -f "$LETS_DIR/privkey.pem" ]; then
            log_msg "${GREEN}  ✅ $DOMAIN: certs already in /etc/letsencrypt/live/${NC}"
            COPIED=$((COPIED + 1))
            continue
        fi

        # Check if panel certs dir has certs
        if [ -f "$PANEL_CERT_DIR/fullchain.pem" ] && [ -f "$PANEL_CERT_DIR/privkey.pem" ]; then
            log_msg "${YELLOW}  📁 $DOMAIN: copying from $PANEL_CERT_DIR to $LETS_DIR${NC}"
            mkdir -p "$LETS_DIR"
            cp "$PANEL_CERT_DIR/fullchain.pem" "$LETS_DIR/fullchain.pem"
            cp "$PANEL_CERT_DIR/privkey.pem" "$LETS_DIR/privkey.pem"
            chmod 644 "$LETS_DIR/fullchain.pem"
            chmod 600 "$LETS_DIR/privkey.pem"
            COPIED=$((COPIED + 1))
            NEED_COPY=$((NEED_COPY + 1))
        else
            log_msg "${RED}  ❌ $DOMAIN: no certs found in $PANEL_CERT_DIR${NC}"
            log_msg "${YELLOW}     Will need certbot to generate new certs${NC}"
        fi
    done

    log_msg "${GREEN}✅ SSL certs: $COPIED domains checked, $NEED_COPY copied${NC}"
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 3: Set XRAY_SUBSCRIPTION_URL_PREFIX in .env
# ═══════════════════════════════════════════════════════════════════════════════
set_subscription_url_prefix() {
    log_msg "${CYAN}🔗 Setting XRAY_SUBSCRIPTION_URL_PREFIX...${NC}"

    if [ ! -f "$PANEL_ENV" ]; then
        log_msg "${RED}❌ Panel .env not found at $PANEL_ENV${NC}"
        return 1
    fi

    # Extract sub domain from panel_separate.conf (second server_name, typically)
    local SUB_DOMAIN=""
    local ADMIN_DOMAIN=""
    local SUB_PORT=""

    if [ -f "$DOMAIN_SEP_CONF" ]; then
        # Get all domains
        local ALL_DOMAINS
        ALL_DOMAINS=$(grep -oP 'server_name\s+\K[^;]+' "$DOMAIN_SEP_CONF" 2>/dev/null | tr -d ' ' | sort -u)

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
        PANEL_SSL=$(grep -oP 'UVICORN_SSL_CERTFILE="\K[^"]+' "$PANEL_ENV" 2>/dev/null)
        if [ -n "$PANEL_SSL" ]; then
            # Panel has SSL - extract domain from cert path
            local CERT_DOMAIN
            CERT_DOMAIN=$(echo "$PANEL_SSL" | grep -oP '/certs/\K[^/]+')
            if [ -n "$CERT_DOMAIN" ]; then
                local PANEL_PORT
                PANEL_PORT=$(grep -oP 'UVICORN_PORT=\K[0-9]+' "$PANEL_ENV" 2>/dev/null)
                [ -z "$PANEL_PORT" ] && PANEL_PORT="7431"
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
        PANEL_PORT=$(grep -oP 'UVICORN_PORT=\K[0-9]+' "$PANEL_ENV" 2>/dev/null)
        [ -z "$PANEL_PORT" ] && PANEL_PORT="7431"
        SUB_URL="https://$SERVER_IP:$PANEL_PORT"
        log_msg "${YELLOW}⚠️  Using server IP as fallback${NC}"
    fi

    # Update .env
    if grep -q "^XRAY_SUBSCRIPTION_URL_PREFIX=" "$PANEL_ENV" 2>/dev/null; then
        # Update existing value
        sed -i "s|^XRAY_SUBSCRIPTION_URL_PREFIX=.*|XRAY_SUBSCRIPTION_URL_PREFIX=\"$SUB_URL\"|" "$PANEL_ENV"
        log_msg "${GREEN}✅ Updated XRAY_SUBSCRIPTION_URL_PREFIX=$SUB_URL${NC}"
    elif grep -q "^# *XRAY_SUBSCRIPTION_URL_PREFIX" "$PANEL_ENV" 2>/dev/null; then
        # Uncomment and set
        sed -i "s|^# *XRAY_SUBSCRIPTION_URL_PREFIX.*|XRAY_SUBSCRIPTION_URL_PREFIX=\"$SUB_URL\"|" "$PANEL_ENV"
        log_msg "${GREEN}✅ Enabled XRAY_SUBSCRIPTION_URL_PREFIX=$SUB_URL${NC}"
    else
        # Add new line
        echo "XRAY_SUBSCRIPTION_URL_PREFIX=\"$SUB_URL\"" >> "$PANEL_ENV"
        log_msg "${GREEN}✅ Added XRAY_SUBSCRIPTION_URL_PREFIX=$SUB_URL${NC}"
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 4: Test and start Nginx
# ═══════════════════════════════════════════════════════════════════════════════
test_and_start_nginx() {
    if ! command -v nginx >/dev/null 2>&1; then
        log_msg "${RED}❌ Nginx not installed - skipping${NC}"
        return 1
    fi

    log_msg "${CYAN}🔍 Testing Nginx configuration...${NC}"

    if nginx -t 2>&1; then
        log_msg "${GREEN}✅ Nginx config test passed${NC}"
        systemctl restart nginx 2>/dev/null
        sleep 1
        if systemctl is-active --quiet nginx 2>/dev/null; then
            log_msg "${GREEN}✅ Nginx is running${NC}"
        else
            log_msg "${YELLOW}⚠️  Nginx failed to start - check: journalctl -xeu nginx${NC}"
            return 1
        fi
    else
        log_msg "${RED}❌ Nginx config test failed!${NC}"
        nginx -t 2>&1 | head -5
        return 1
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 5: Restart panel
# ═══════════════════════════════════════════════════════════════════════════════
restart_panel() {
    log_msg "${CYAN}🔄 Restarting panel...${NC}"

    if [ -d "$PANEL_DIR" ] && [ -f "$PANEL_DIR/docker-compose.yml" -o -f "$PANEL_DIR/compose.yml" ]; then
        cd "$PANEL_DIR"
        docker compose restart 2>/dev/null && {
            log_msg "${GREEN}✅ Panel restarted${NC}"
            return 0
        }
    fi

    log_msg "${YELLOW}⚠️  Panel restart failed - try: cd $PANEL_DIR && docker compose restart${NC}"
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════
main() {
    log_msg ""
    log_msg "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    log_msg "${CYAN}║     MRM Post-Restore Auto-Fix (Nginx + SSL + Sub URL)   ║${NC}"
    log_msg "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    log_msg ""

    local STEP=0
    local TOTAL=5
    local FAILED=0

    # Step 1: Ensure Nginx installed
    STEP=$((STEP + 1))
    log_msg "${BLUE}[$STEP/$TOTAL] Ensuring Nginx is installed...${NC}"
    ensure_nginx_installed || FAILED=$((FAILED + 1))
    log_msg ""

    # Step 2: Copy SSL certs
    STEP=$((STEP + 1))
    log_msg "${BLUE}[$STEP/$TOTAL] Copying SSL certificates...${NC}"
    copy_ssl_certs || FAILED=$((FAILED + 1))
    log_msg ""

    # Step 3: Set XRAY_SUBSCRIPTION_URL_PREFIX
    STEP=$((STEP + 1))
    log_msg "${BLUE}[$STEP/$TOTAL] Setting subscription URL prefix...${NC}"
    set_subscription_url_prefix || FAILED=$((FAILED + 1))
    log_msg ""

    # Step 4: Test and start Nginx
    STEP=$((STEP + 1))
    log_msg "${BLUE}[$STEP/$TOTAL] Testing and starting Nginx...${NC}"
    test_and_start_nginx || FAILED=$((FAILED + 1))
    log_msg ""

    # Step 5: Restart panel
    STEP=$((STEP + 1))
    log_msg "${BLUE}[$STEP/$TOTAL] Restarting panel...${NC}"
    restart_panel || FAILED=$((FAILED + 1))
    log_msg ""

    # Summary
    log_msg "${CYAN}══════════════════════════════════════════════════════════${NC}"
    if [ "$FAILED" -eq 0 ]; then
        log_msg "${GREEN}✅ All $TOTAL steps completed successfully!${NC}"
        log_msg "${GREEN}   New users' subscription links should work now.${NC}"
    else
        log_msg "${YELLOW}⚠️  $FAILED/$TOTAL steps had issues - check log: $LOG_FILE${NC}"
    fi
    log_msg "${CYAN}══════════════════════════════════════════════════════════${NC}"
}

main "$@"
