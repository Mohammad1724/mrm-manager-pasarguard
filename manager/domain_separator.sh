#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi
if ! declare -f mrm_create_restore_point >/dev/null 2>&1 && [ -r /opt/mrm-manager/safe_ops.sh ]; then source /opt/mrm-manager/safe_ops.sh; fi

NGINX_CONF="/etc/nginx/conf.d/panel_separate.conf"
PANEL_CONFLICT_CONF="/etc/nginx/conf.d/panel.conf"

validate_domain_name() {
    local DOMAIN="$1"
    local PATTERN='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'

    [ -n "$DOMAIN" ] || return 1
    [ "${#DOMAIN}" -le 253 ] || return 1
    [[ "$DOMAIN" =~ $PATTERN ]]
}

validate_port_number() {
    local PORT="$1"
    [[ "$PORT" =~ ^[0-9]+$ ]] || return 1
    [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]
}

stop_nginx_checked() {
    systemctl stop nginx >/dev/null 2>&1
}

start_nginx_checked() {
    nginx -t >/dev/null 2>&1 || return 1
    systemctl start nginx >/dev/null 2>&1
}

restart_nginx_checked() {
    nginx -t >/dev/null 2>&1 || return 1
    systemctl restart nginx >/dev/null 2>&1
}

restore_domain_separator_state() {
    local NGINX_BACKUP="$1"
    local CONFLICT_BACKUP="$2"

    rm -f "$NGINX_CONF" 2>/dev/null || true

    if [ -n "$NGINX_BACKUP" ] && [ -f "$NGINX_BACKUP" ]; then
        cp "$NGINX_BACKUP" "$NGINX_CONF" 2>/dev/null || true
    fi

    if [ -n "$CONFLICT_BACKUP" ] && [ -f "$CONFLICT_BACKUP" ]; then
        mv "$CONFLICT_BACKUP" "$PANEL_CONFLICT_CONF" 2>/dev/null || true
    fi
}

install_requirements() {
    echo -e "${BLUE}Checking requirements...${NC}"
    local NEED_INSTALL=false

    if ! command -v nginx &> /dev/null; then
        echo -e "${YELLOW}Nginx not found. Installing...${NC}"
        NEED_INSTALL=true
    fi

    if ! command -v certbot &> /dev/null; then
        echo -e "${YELLOW}Certbot not found. Installing...${NC}"
        NEED_INSTALL=true
    fi

    if [ "$NEED_INSTALL" = true ]; then
        apt update && apt install -y nginx certbot
        echo -e "${GREEN}✔ Requirements installed.${NC}"
    else
        echo -e "${GREEN}✔ Requirements are already installed.${NC}"
    fi

    systemctl enable nginx > /dev/null 2>&1
}

setup_domain_separation() {
    local ADMIN_DOM
    local SUB_DOM
    local PORT
    local PANEL_PORT
    local CONFIRM
    local ADMIN_CERT_OK
    local SUB_CERT_OK
    local SUB_CERT_PATH
    local NGINX_BACKUP=""
    local CONFLICT_BACKUP=""

    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      DOMAIN SEPARATOR (Panel & Sub)         ${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""

    install_requirements

    echo ""

    read -p "1. Admin Domain (e.g., admin.site.com): " ADMIN_DOM
    if [ -z "$ADMIN_DOM" ]; then echo -e "${RED}Error: Admin Domain is required!${NC}"; pause; return; fi
    if ! validate_domain_name "$ADMIN_DOM"; then echo -e "${RED}Error: Admin Domain format is invalid!${NC}"; pause; return; fi

    read -p "2. Sub Domain (e.g., sub.site.com): " SUB_DOM
    if [ -z "$SUB_DOM" ]; then echo -e "${RED}Error: Sub Domain is required!${NC}"; pause; return; fi
    if ! validate_domain_name "$SUB_DOM"; then echo -e "${RED}Error: Sub Domain format is invalid!${NC}"; pause; return; fi

    if [ "$ADMIN_DOM" = "$SUB_DOM" ]; then
        echo -e "${RED}Error: Admin Domain and Sub Domain cannot be the same!${NC}"
        pause; return
    fi

    read -p "3. Port to use (default: 2096): " PORT
    [ -z "$PORT" ] && PORT="2096"
    if ! validate_port_number "$PORT"; then
        echo -e "${RED}Error: Port must be a number between 1 and 65535!${NC}"
        pause; return
    fi

    read -p "4. Current Panel Port (default: 7431): " PANEL_PORT
    [ -z "$PANEL_PORT" ] && PANEL_PORT="7431"
    if ! validate_port_number "$PANEL_PORT"; then
        echo -e "${RED}Error: Panel Port must be a number between 1 and 65535!${NC}"
        pause; return
    fi

    # Fix: Prevent loop
    if [ "$PORT" = "$PANEL_PORT" ]; then
        echo -e "${RED}Error: Nginx port ($PORT) cannot be same as Panel port ($PANEL_PORT)!${NC}"
        pause; return
    fi

    echo ""
    echo -e "${BLUE}-------------------------------------${NC}"
    echo -e "Admin: ${CYAN}$ADMIN_DOM${NC}"
    echo -e "Sub:   ${CYAN}$SUB_DOM${NC}"
    echo -e "Port:  ${CYAN}$PORT${NC}"
    echo -e "Panel: ${CYAN}$PANEL_PORT${NC}"
    echo -e "${BLUE}-------------------------------------${NC}"
    read -p "Is this correct? (y/n): " CONFIRM
    if [ "$CONFIRM" != "y" ]; then echo "Cancelled."; pause; return; fi

    echo ""
    echo -e "${BLUE}Stopping Nginx to get SSL...${NC}"
    if ! stop_nginx_checked; then
        echo -e "${RED}✘ Failed to stop Nginx!${NC}"
        pause; return
    fi

    # Get SSL for Admin Domain
    echo -e "${BLUE}Requesting SSL for Admin Domain: $ADMIN_DOM${NC}"
    certbot certonly --standalone --non-interactive --agree-tos --email "admin@$ADMIN_DOM" -d "$ADMIN_DOM"
    ADMIN_CERT_OK=$?

    # Get SSL for Sub Domain (Separate)
    echo -e "${BLUE}Requesting SSL for Sub Domain: $SUB_DOM${NC}"
    certbot certonly --standalone --non-interactive --agree-tos --email "admin@$ADMIN_DOM" -d "$SUB_DOM"
    SUB_CERT_OK=$?

    # Check Admin cert (required)
    if [ $ADMIN_CERT_OK -ne 0 ] || [ ! -d "/etc/letsencrypt/live/$ADMIN_DOM" ]; then
        echo -e "${RED}✘ Failed to get SSL for Admin Domain!${NC}"
        start_nginx_checked >/dev/null 2>&1 || systemctl start nginx >/dev/null 2>&1 || true
        pause; return
    fi

    # Check Sub cert
    SUB_CERT_PATH="/etc/letsencrypt/live/$SUB_DOM"
    if [ $SUB_CERT_OK -ne 0 ] || [ ! -d "$SUB_CERT_PATH" ]; then
        echo -e "${RED}✘ Sub Domain SSL failed. Cannot proceed safely.${NC}"
        start_nginx_checked >/dev/null 2>&1 || systemctl start nginx >/dev/null 2>&1 || true
        pause; return
    fi

    echo -e "${GREEN}✔ SSL Certificates ready.${NC}"

    if declare -f mrm_create_restore_point >/dev/null 2>&1; then
        local RESTORE_POINT_ID
        RESTORE_POINT_ID="$(mrm_create_restore_point "domain-separation" "nginx" "$NGINX_CONF" "$PANEL_CONFLICT_CONF")"
        [ -n "$RESTORE_POINT_ID" ] && echo -e "${BLUE}Restore point created: $RESTORE_POINT_ID${NC}"
    fi

    if [ -f "$NGINX_CONF" ]; then
        NGINX_BACKUP=$(mktemp /tmp/mrm-domain-separator.XXXXXX 2>/dev/null)
        if [ -z "$NGINX_BACKUP" ] || ! cp "$NGINX_CONF" "$NGINX_BACKUP" 2>/dev/null; then
            echo -e "${RED}✘ Failed to backup existing Nginx config!${NC}"
            start_nginx_checked >/dev/null 2>&1 || systemctl start nginx >/dev/null 2>&1 || true
            pause; return
        fi
    fi

    # Cleanup old conflicts (safe backup)
    if [ -f "$PANEL_CONFLICT_CONF" ]; then
        echo -e "${YELLOW}Found conflicting config: panel.conf. Disabling it...${NC}"
        CONFLICT_BACKUP="${PANEL_CONFLICT_CONF}.bak"
        [ -e "$CONFLICT_BACKUP" ] && CONFLICT_BACKUP="${PANEL_CONFLICT_CONF}.bak.$(date +%s)"
        if ! mv "$PANEL_CONFLICT_CONF" "$CONFLICT_BACKUP"; then
            echo -e "${RED}✘ Failed to disable conflicting panel.conf!${NC}"
            start_nginx_checked >/dev/null 2>&1 || systemctl start nginx >/dev/null 2>&1 || true
            [ -n "$NGINX_BACKUP" ] && rm -f "$NGINX_BACKUP"
            pause; return
        fi
    fi

    # Configure Nginx
    echo -e "${BLUE}Writing Nginx configuration...${NC}"

    cat > "$NGINX_CONF" <<EOF
# Admin Domain
server {
    listen $PORT ssl;
    listen [::]:$PORT ssl;
    server_name $ADMIN_DOM;

    ssl_certificate /etc/letsencrypt/live/$ADMIN_DOM/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$ADMIN_DOM/privkey.pem;

    location / {
        # FIXED: Changed to HTTPS to match Pasarguard .env config
        proxy_pass https://127.0.0.1:$PANEL_PORT;
        proxy_ssl_verify off;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}

# Sub Domain
server {
    listen $PORT ssl;
    listen [::]:$PORT ssl;
    server_name $SUB_DOM;

    ssl_certificate ${SUB_CERT_PATH}/fullchain.pem;
    ssl_certificate_key ${SUB_CERT_PATH}/privkey.pem;

    location / {
        # FIXED: Changed to HTTPS to match Pasarguard .env config
        proxy_pass https://127.0.0.1:$PANEL_PORT;
        proxy_ssl_verify off;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

    # Test and apply
    echo -e "${BLUE}Testing Nginx configuration...${NC}"
    if ! nginx -t >/dev/null 2>&1; then
        echo -e "${RED}✘ Nginx Config Error! Reverting...${NC}"
        restore_domain_separator_state "$NGINX_BACKUP" "$CONFLICT_BACKUP"
        start_nginx_checked >/dev/null 2>&1 || systemctl start nginx >/dev/null 2>&1 || true
        rm -f "$NGINX_BACKUP" 2>/dev/null
        pause; return
    fi

    if command -v ufw &> /dev/null; then ufw allow "$PORT"/tcp > /dev/null 2>&1; fi

    if ! restart_nginx_checked; then
        echo -e "${RED}✘ Failed to restart Nginx! Reverting...${NC}"
        restore_domain_separator_state "$NGINX_BACKUP" "$CONFLICT_BACKUP"
        start_nginx_checked >/dev/null 2>&1 || systemctl start nginx >/dev/null 2>&1 || true
        rm -f "$NGINX_BACKUP" 2>/dev/null
        pause; return
    fi

    rm -f "$NGINX_BACKUP" 2>/dev/null

    echo ""
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}      SETUP COMPLETED SUCCESSFULLY    ${NC}"
    echo -e "${GREEN}======================================${NC}"
    echo ""
    echo -e "1. Login Panel: ${CYAN}https://$ADMIN_DOM:$PORT${NC}"
    echo -e "2. Set Subscription URL to: ${CYAN}https://$SUB_DOM:$PORT${NC}"
    echo ""
    pause
}

edit_nginx_config_manually() {
    local EDIT_BACKUP

    if declare -f mrm_create_restore_point >/dev/null 2>&1; then
        local RESTORE_POINT_ID
        RESTORE_POINT_ID="$(mrm_create_restore_point "domain-manual-edit" "nginx" "$NGINX_CONF" "$PANEL_CONFLICT_CONF")"
        [ -n "$RESTORE_POINT_ID" ] && echo -e "${BLUE}Restore point created: $RESTORE_POINT_ID${NC}"
    fi

    EDIT_BACKUP=$(mktemp /tmp/mrm-domain-edit.XXXXXX 2>/dev/null)
    if [ -f "$NGINX_CONF" ] && [ -n "$EDIT_BACKUP" ]; then
        cp "$NGINX_CONF" "$EDIT_BACKUP" 2>/dev/null || true
    fi

    nano "$NGINX_CONF"

    if restart_nginx_checked; then
        echo -e "${GREEN}Done.${NC}"
    else
        echo -e "${RED}Nginx config is invalid or restart failed. Reverting...${NC}"
        if [ -n "$EDIT_BACKUP" ] && [ -f "$EDIT_BACKUP" ]; then
            cp "$EDIT_BACKUP" "$NGINX_CONF" 2>/dev/null || true
            restart_nginx_checked >/dev/null 2>&1 || systemctl start nginx >/dev/null 2>&1 || true
        else
            rm -f "$NGINX_CONF" 2>/dev/null || true
        fi
        pause
    fi

    rm -f "$EDIT_BACKUP" 2>/dev/null
}

domain_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      DOMAIN MANAGER                       ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo "1) Separate Admin & Sub Domains (Wizard)"
        echo "2) Restart Nginx"
        echo "3) Check Nginx Status"
        echo "4) Edit Nginx Config Manually"
        echo "5) Back"
        read -p "Select: " OPT
        case $OPT in
            1) setup_domain_separation ;;
            2)
                if restart_nginx_checked; then
                    echo "Done."
                else
                    echo -e "${RED}Failed to restart Nginx. Check configuration with: nginx -t${NC}"
                fi
                sleep 1
                ;;
            3) systemctl status nginx --no-pager; pause ;;
            4) edit_nginx_config_manually ;;
            5) return ;;
            *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
        esac
    done
}
