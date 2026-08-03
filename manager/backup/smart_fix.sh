#!/bin/bash
# MRM Backup - Smart Fix Module
# Fix docker-compose IPs, env files, nginx config, firewall

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

