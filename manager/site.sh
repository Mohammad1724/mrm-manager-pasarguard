#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi
if ! declare -f mrm_create_restore_point >/dev/null 2>&1 && [ -r /opt/mrm-manager/safe_ops.sh ]; then source /opt/mrm-manager/safe_ops.sh; fi

WWW_DIR="/var/www/html"

site_invalid_option() {
    echo -e "${RED}Invalid option.${NC}"
    sleep 1
}

clear_www_dir() {
    mkdir -p "$WWW_DIR"
    find "$WWW_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null
}

copy_dir_contents() {
    local SRC_DIR="$1"
    local DST_DIR="$2"

    mkdir -p "$DST_DIR"
    (cd "$SRC_DIR" && tar -cf - .) | (cd "$DST_DIR" && tar -xf -)
}

restore_www_backup() {
    local BACKUP_DIR="$1"

    [ -d "$BACKUP_DIR" ] || return 1
    clear_www_dir
    copy_dir_contents "$BACKUP_DIR" "$WWW_DIR"
}

restart_nginx_checked() {
    if ! nginx -t >/dev/null 2>&1; then
        return 1
    fi

    systemctl restart nginx >/dev/null 2>&1
}

install_nginx_if_needed() {
    # Install required tools
    local NEED_INSTALL=false
    command -v nginx &> /dev/null || NEED_INSTALL=true
    command -v wget &> /dev/null || NEED_INSTALL=true
    command -v unzip &> /dev/null || NEED_INSTALL=true
    
    if [ "$NEED_INSTALL" = true ]; then
        echo -e "${BLUE}Installing Nginx and tools...${NC}"
        apt-get update -qq > /dev/null
        apt-get install -y nginx wget unzip -qq > /dev/null
    fi
    
    systemctl enable nginx > /dev/null 2>&1
    systemctl start nginx > /dev/null 2>&1
}

download_template() {
    local URL="$1"
    local NAME="$2"
    local TMP_DIR
    local TEMPLATE_ZIP
    local EXTRACT_DIR
    local SITE_BACKUP
    local SOURCE_DIR
    local ITEMS
    local FIRST_ITEM

    echo -e "${BLUE}Downloading template: $NAME...${NC}"

    TMP_DIR=$(mktemp -d /tmp/mrm-site.XXXXXX 2>/dev/null)
    if [ -z "$TMP_DIR" ] || [ ! -d "$TMP_DIR" ]; then
        echo -e "${RED}✘ Failed to create temporary workspace!${NC}"
        return 1
    fi

    TEMPLATE_ZIP="$TMP_DIR/template.zip"
    EXTRACT_DIR="$TMP_DIR/extracted"
    SITE_BACKUP="$TMP_DIR/site-backup"
    mkdir -p "$EXTRACT_DIR" "$SITE_BACKUP" "$WWW_DIR"

    # Backup current site
    copy_dir_contents "$WWW_DIR" "$SITE_BACKUP" 2>/dev/null || true

    # Download
    if ! wget -qO "$TEMPLATE_ZIP" "$URL"; then
        echo -e "${RED}✘ Download failed! URL may be invalid.${NC}"
        rm -rf "$TMP_DIR"
        return 1
    fi

    # Check if file is valid zip
    if ! unzip -tqq "$TEMPLATE_ZIP" >/dev/null 2>&1; then
        echo -e "${RED}✘ Downloaded file is not a valid ZIP!${NC}"
        rm -rf "$TMP_DIR"
        return 1
    fi

    if ! unzip -q -o "$TEMPLATE_ZIP" -d "$EXTRACT_DIR" >/dev/null 2>&1; then
        echo -e "${RED}✘ Failed to extract template ZIP!${NC}"
        rm -rf "$TMP_DIR"
        return 1
    fi

    ITEMS=$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 | wc -l)
    FIRST_ITEM=$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 | head -1)
    SOURCE_DIR="$EXTRACT_DIR"

    if [ "$ITEMS" -eq 1 ] && [ -n "$FIRST_ITEM" ] && [ -d "$FIRST_ITEM" ]; then
        SOURCE_DIR="$FIRST_ITEM"
    fi

    clear_www_dir
    if ! copy_dir_contents "$SOURCE_DIR" "$WWW_DIR"; then
        echo -e "${RED}✘ Failed to deploy template files! Restoring previous site...${NC}"
        restore_www_backup "$SITE_BACKUP" >/dev/null 2>&1 || true
        rm -rf "$TMP_DIR"
        return 1
    fi

    # Fix permissions
    chown -R www-data:www-data "$WWW_DIR" 2>/dev/null
    chmod -R 755 "$WWW_DIR"

    echo -e "${GREEN}✔ Template installed successfully!${NC}"
    rm -rf "$TMP_DIR"
    return 0
}

setup_fake_site() {
    local DEFAULT_CONF="/etc/nginx/sites-available/default"
    local DEFAULT_CONF_BACKUP=""
    local SITE_CHANGE_OK=true

    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      FAKE SITE MANAGER                      ${NC}"
    echo -e "${CYAN}=============================================${NC}"

    install_nginx_if_needed

    echo ""
    echo "Select a template to install on Port 80:"
    echo ""
    echo -e "${BLUE}--- Professional Templates ---${NC}"
    echo "1) Digital Agency (Modern/Dark)"
    echo "2) Coffee Shop (Elegant)"
    echo "3) Personal Portfolio (Clean)"
    echo "4) Construction Company"
    echo "5) Cryptocurrency Landing Page"
    echo ""
    echo -e "${BLUE}--- Simple HTML (Always Works) ---${NC}"
    echo "6) Simple Gaming Page"
    echo "7) Simple Tech Page"
    echo "8) Simple Business Page"
    echo ""
    echo -e "${BLUE}--- Custom ---${NC}"
    echo "9) Upload Custom Zip (URL)"
    echo "10) Restore Default Nginx"
    echo "11) Back"

    read -p "Select: " T_OPT

    case $T_OPT in
        1) download_template "https://www.free-css.com/assets/files/free-css-templates/download/page296/oxer.zip" "Digital Agency" || SITE_CHANGE_OK=false ;;
        2) download_template "https://www.free-css.com/assets/files/free-css-templates/download/page293/chocolux.zip" "Coffee Shop" || SITE_CHANGE_OK=false ;;
        3) download_template "https://www.free-css.com/assets/files/free-css-templates/download/page294/shapel.zip" "Portfolio" || SITE_CHANGE_OK=false ;;
        4) download_template "https://www.free-css.com/assets/files/free-css-templates/download/page296/constra.zip" "Construction" || SITE_CHANGE_OK=false ;;
        5) download_template "https://www.free-css.com/assets/files/free-css-templates/download/page293/dgital.zip" "Crypto" || SITE_CHANGE_OK=false ;;
        6)
            cat > "$WWW_DIR/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
    <title>Vortex Gaming</title>
    <style>
        body { background: #111; color: #0f0; font-family: monospace; text-align: center; padding-top: 15%; }
        h1 { font-size: 3em; text-shadow: 0 0 10px #0f0; }
    </style>
</head>
<body>
    <h1>VORTEX GAMING</h1>
    <p>System Online | Waiting for connection...</p>
</body>
</html>
HTMLEOF
            echo -e "${GREEN}✔ Gaming page installed.${NC}"
            ;;
        7)
            cat > "$WWW_DIR/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
    <title>Cloud Server</title>
    <style>
        body { background: #f5f5f5; color: #333; font-family: sans-serif; text-align: center; padding-top: 15%; }
        h1 { color: #2196F3; }
        .status { color: #4CAF50; font-weight: bold; }
    </style>
</head>
<body>
    <h1>Cloud Server</h1>
    <p>Status: <span class="status">Online</span></p>
    <p>All systems operational.</p>
</body>
</html>
HTMLEOF
            echo -e "${GREEN}✔ Tech page installed.${NC}"
            ;;
        8)
            cat > "$WWW_DIR/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
    <title>Business Solutions</title>
    <style>
        body { background: #fff; color: #333; font-family: Arial, sans-serif; text-align: center; padding-top: 15%; }
        h1 { color: #1a1a1a; }
        p { color: #666; }
    </style>
</head>
<body>
    <h1>Business Solutions Inc.</h1>
    <p>Professional services for modern enterprises.</p>
    <p>Contact: info@business.local</p>
</body>
</html>
HTMLEOF
            echo -e "${GREEN}✔ Business page installed.${NC}"
            ;;
        9)
            echo ""
            read -p "Enter Zip URL: " ZIP_URL
            if [ -n "$ZIP_URL" ]; then
                download_template "$ZIP_URL" "Custom Template" || SITE_CHANGE_OK=false
            else
                echo -e "${RED}URL cannot be empty.${NC}"
                SITE_CHANGE_OK=false
            fi
            ;;
        10)
            echo '<h1>Welcome to nginx!</h1><p>Server is running.</p>' > "$WWW_DIR/index.html"
            echo -e "${GREEN}✔ Restored default nginx page.${NC}"
            ;;
        11) return ;;
        *)
            site_invalid_option
            return
            ;;
    esac

    if [ "$SITE_CHANGE_OK" != "true" ]; then
        pause
        return
    fi

    if declare -f mrm_create_restore_point >/dev/null 2>&1; then
        local RESTORE_POINT_ID
        RESTORE_POINT_ID="$(mrm_create_restore_point "site-update" "nginx" "$WWW_DIR" "/etc/nginx/sites-available/default")"
        [ -n "$RESTORE_POINT_ID" ] && echo -e "${BLUE}Restore point created: $RESTORE_POINT_ID${NC}"
    fi

    DEFAULT_CONF_BACKUP=$(mktemp /tmp/mrm-nginx-default.XXXXXX 2>/dev/null || true)
    if [ -n "$DEFAULT_CONF_BACKUP" ] && [ -f "$DEFAULT_CONF" ]; then
        cp "$DEFAULT_CONF" "$DEFAULT_CONF_BACKUP"
    fi

    # Ensure Nginx config is correct
    cat > "$DEFAULT_CONF" <<'NGINXEOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root /var/www/html;
    index index.html index.htm;
    server_name _;
    
    location / {
        try_files $uri $uri/ =404;
    }
    
    error_page 404 /404.html;
    location = /404.html {
        internal;
    }
}
NGINXEOF

    # Create 404 page
    cat > "$WWW_DIR/404.html" <<'HTMLEOF'
<!DOCTYPE html>
<html>
<head><title>404 Not Found</title></head>
<body style="text-align:center;padding-top:50px;font-family:sans-serif;">
    <h1>404 Not Found</h1>
    <hr>
    <p>nginx</p>
</body>
</html>
HTMLEOF

    if ! restart_nginx_checked; then
        echo -e "${RED}✘ Nginx config test/restart failed! Reverting site config...${NC}"
        if [ -n "$DEFAULT_CONF_BACKUP" ] && [ -f "$DEFAULT_CONF_BACKUP" ]; then
            cp "$DEFAULT_CONF_BACKUP" "$DEFAULT_CONF"
            restart_nginx_checked >/dev/null 2>&1 || systemctl start nginx >/dev/null 2>&1 || true
        fi
        rm -f "$DEFAULT_CONF_BACKUP"
        pause
        return
    fi

    rm -f "$DEFAULT_CONF_BACKUP"

    echo ""
    echo -e "${YELLOW}Tip: Set Fallback Port to 80 in your Inbound settings.${NC}"
    pause
}

toggle_site() {
    if systemctl is-active --quiet nginx; then
        if systemctl stop nginx >/dev/null 2>&1; then
            echo -e "${YELLOW}Nginx Stopped (Port 80 freed).${NC}"
        else
            echo -e "${RED}Failed to stop Nginx.${NC}"
        fi
    else
        if restart_nginx_checked; then
            echo -e "${GREEN}Nginx Started.${NC}"
        else
            echo -e "${RED}Failed to start Nginx. Check configuration with: nginx -t${NC}"
        fi
    fi
    pause
}

edit_site() {
    local TMP_DIR
    local INDEX_BACKUP

    if [ -f "$WWW_DIR/index.html" ]; then
        if declare -f mrm_create_restore_point >/dev/null 2>&1; then
            local RESTORE_POINT_ID
            RESTORE_POINT_ID="$(mrm_create_restore_point "site-edit" "nginx" "$WWW_DIR/index.html")"
            [ -n "$RESTORE_POINT_ID" ] && echo -e "${BLUE}Restore point created: $RESTORE_POINT_ID${NC}"
        fi

        TMP_DIR=$(mktemp -d /tmp/mrm-site-edit.XXXXXX 2>/dev/null)
        INDEX_BACKUP="$TMP_DIR/index.html.bak"
        [ -n "$TMP_DIR" ] && cp "$WWW_DIR/index.html" "$INDEX_BACKUP" 2>/dev/null || true

        nano "$WWW_DIR/index.html"

        if restart_nginx_checked; then
            echo -e "${GREEN}✔ Site updated and Nginx restarted.${NC}"
        else
            echo -e "${RED}✘ Nginx restart failed after editing site.${NC}"
            if [ -f "$INDEX_BACKUP" ]; then
                cp "$INDEX_BACKUP" "$WWW_DIR/index.html"
                restart_nginx_checked >/dev/null 2>&1 || systemctl start nginx >/dev/null 2>&1 || true
                echo -e "${YELLOW}Previous index.html restored.${NC}"
            fi
        fi

        rm -rf "$TMP_DIR" 2>/dev/null
    else
        echo -e "${RED}No index.html found. Install a template first.${NC}"
    fi
    pause
}

site_menu() {
    while true; do
        clear
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      FAKE SITE MANAGER (Nginx)            ${NC}"
        echo -e "${BLUE}===========================================${NC}"

        echo -ne "Status: "
        if systemctl is-active --quiet nginx; then
            echo -e "${GREEN}● Running on Port 80${NC}"
        else
            echo -e "${RED}● Stopped${NC}"
        fi
        echo ""

        echo "1) Install / Change Template"
        echo "2) Start / Stop Nginx"
        echo "3) Edit HTML Manually"
        echo "4) Back"
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select: " OPT
        case $OPT in
            1) setup_fake_site ;;
            2) toggle_site ;;
            3) edit_site ;;
            4) return ;;
            *) site_invalid_option ;;
        esac
    done
}
