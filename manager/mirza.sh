#!/bin/bash

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# --- Variables ---
MIRZA_PATH="/var/www/mirzapro"
MIRZA_CONFIG_FILE="$MIRZA_PATH/config.php"
MIRZA_SITE_CONF="/etc/apache2/sites-available/mirzapro.conf"
MIRZA_DB_NAME="mirzapro"
MIRZA_DB_USER="mirza_user"
MIRZA_DB_EXPORT="/root/mirzapro_backup.sql"
MIRZA_REPO_URL="https://github.com/Mmd-Amir/mirza_pro.git"

# --- Logo ---
mirza_logo() {
    clear
    echo -e "${CYAN}"
    cat << EOF
███╗   ███╗██╗██████╗ ███████╗ █████╗     ██████╗ ██████╗  ██████╗
████╗ ████║██║██╔══██╗╚══███╔╝██╔══██╗    ██╔══██╗██╔══██╗██╔═══██╗
██╔████╔██║██║██████╔╝  ███╔╝ ███████║    ██████╔╝██████╔╝██║   ██║
██║╚██╔╝██║██║██╔══██╗ ███╔╝  ██╔══██║    ██╔═══╝ ██╔══██╗██║   ██║
██║ ╚═╝ ██║██║██║  ██║███████╗██║  ██║    ██║     ██║  ██║╚██████╔╝
╚═╝     ╚═╝╚═╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝    ╚═╝     ╚═╝  ╚═╝ ╚═════╝
                    Version 4.0.0 - Ultimate Edition
EOF
    echo -e "${NC}"
}

mirza_pause() {
    read -r -p "Press Enter to continue..."
}

mirza_validate_domain() {
    local DOMAIN="$1"
    local PATTERN='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'

    [ -n "$DOMAIN" ] || return 1
    [ "${#DOMAIN}" -le 253 ] || return 1
    [[ "$DOMAIN" =~ $PATTERN ]]
}

mirza_validate_integer() {
    local VALUE="$1"
    [[ "$VALUE" =~ ^-?[0-9]+$ ]]
}

mirza_validate_positive_integer() {
    local VALUE="$1"
    [[ "$VALUE" =~ ^[0-9]+$ ]] && [ "$VALUE" -gt 0 ]
}

mirza_escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[&|]/\\&/g'
}

mirza_apache_configtest() {
    if command -v apache2ctl >/dev/null 2>&1; then
        apache2ctl configtest >/dev/null 2>&1
    elif command -v apachectl >/dev/null 2>&1; then
        apachectl configtest >/dev/null 2>&1
    else
        return 1
    fi
}

mirza_restart_apache_checked() {
    mirza_apache_configtest || return 1
    systemctl restart apache2 >/dev/null 2>&1
}

mirza_start_db_service() {
    systemctl enable --now mariadb >/dev/null 2>&1 || \
    systemctl enable --now mysql >/dev/null 2>&1 || true
}

mirza_remove_crons() {
    local CURRENT_CRON
    local FILTERED_CRON

    CURRENT_CRON=$(mktemp /tmp/mirza-cron-current.XXXXXX 2>/dev/null) || return 1
    FILTERED_CRON=$(mktemp /tmp/mirza-cron-filtered.XXXXXX 2>/dev/null) || {
        rm -f "$CURRENT_CRON"
        return 1
    }

    if crontab -l 2>/dev/null > "$CURRENT_CRON"; then
        grep -vF "$MIRZA_PATH" "$CURRENT_CRON" > "$FILTERED_CRON" || true
        crontab "$FILTERED_CRON" 2>/dev/null || true
    fi

    rm -f "$CURRENT_CRON" "$FILTERED_CRON"
    return 0
}

mirza_get_config_value() {
    local KEY="$1"
    local FILE="${2:-$MIRZA_CONFIG_FILE}"
    grep -w "\$$KEY" "$FILE" 2>/dev/null | head -n1 | cut -d"'" -f2
}

mirza_load_db_credentials() {
    local FILE="${1:-$MIRZA_CONFIG_FILE}"

    [ -f "$FILE" ] || return 1

    DB_NAME=$(mirza_get_config_value "dbname" "$FILE")
    DB_USER=$(mirza_get_config_value "usernamedb" "$FILE")
    DB_PASS=$(mirza_get_config_value "passworddb" "$FILE")

    [ -n "$DB_NAME" ] && [ -n "$DB_USER" ] && [ -n "$DB_PASS" ]
}

mirza_write_config() {
    local TARGET_FILE="$1"
    local DB_PASS="$2"
    local DOMAIN="$3"
    local BOT_TOKEN="$4"
    local ADMIN_ID="$5"
    local BOT_USERNAME="$6"
    local MARZBAN_VAL="$7"

    cat > "$TARGET_FILE" <<EOF
<?php
if(!defined("index")) define("index", true);
\$dbname = '$MIRZA_DB_NAME'; \$usernamedb = '$MIRZA_DB_USER'; \$passworddb = '$DB_PASS';
\$connect = mysqli_connect("localhost", \$usernamedb, \$passworddb, \$dbname);
if (!\$connect) die("Database connection failed!");
mysqli_set_charset(\$connect, "utf8mb4");
try {
    \$pdo = new PDO("mysql:host=localhost;dbname=\$dbname;charset=utf8mb4", \$usernamedb, \$passworddb, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC
    ]);
} catch(Exception \$e) { die("PDO connection error"); }
\$APIKEY = '$BOT_TOKEN'; \$adminnumber = '$ADMIN_ID';
\$domainhosts = 'https://$DOMAIN'; \$usernamebot = '$BOT_USERNAME';
\$new_marzban = $MARZBAN_VAL;
?>
EOF
}

mirza_write_site_conf() {
    local DOMAIN="$1"

    cat > "$MIRZA_SITE_CONF" <<EOF
<VirtualHost *:80>
    ServerName $DOMAIN
    DocumentRoot $MIRZA_PATH
    <Directory $MIRZA_PATH>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF
}

mirza_restore_install_state() {
    local EXISTING_BACKUP="$1"
    local SITE_BACKUP="$2"

    a2dissite mirzapro.conf >/dev/null 2>&1 || true
    a2ensite 000-default.conf >/dev/null 2>&1 || true

    if [ -f "$SITE_BACKUP" ]; then
        cp "$SITE_BACKUP" "$MIRZA_SITE_CONF" 2>/dev/null || true
    else
        rm -f "$MIRZA_SITE_CONF" 2>/dev/null || true
    fi

    if [ -d "$MIRZA_PATH" ]; then
        rm -rf "$MIRZA_PATH" 2>/dev/null || true
    fi

    if [ -d "$EXISTING_BACKUP" ]; then
        mv "$EXISTING_BACKUP" "$MIRZA_PATH" 2>/dev/null || true
    fi

    mirza_restart_apache_checked >/dev/null 2>&1 || systemctl restart apache2 >/dev/null 2>&1 || true
}

# --- Core Functions ---
install_mirza() {
    local DOMAIN
    local BOT_TOKEN
    local ADMIN_ID
    local BOT_USERNAME
    local IS_NEW
    local MARZBAN_VAL
    local DB_PASS
    local TMP_DIR
    local TMP_CLONE
    local EXISTING_BACKUP
    local SITE_BACKUP

    mirza_logo
    echo -e "${CYAN}Starting Mirza Pro Installation...${NC}\n"
    read -r -p "Domain (bot.example.com): " DOMAIN
    if ! mirza_validate_domain "$DOMAIN"; then
        echo -e "${RED}Invalid domain format.${NC}"
        mirza_pause
        return
    fi

    read -r -p "Bot Token: " BOT_TOKEN
    if [ -z "$BOT_TOKEN" ]; then
        echo -e "${RED}Bot Token is required.${NC}"
        mirza_pause
        return
    fi

    read -r -p "Admin ID: " ADMIN_ID
    if ! mirza_validate_integer "$ADMIN_ID"; then
        echo -e "${RED}Admin ID must be numeric.${NC}"
        mirza_pause
        return
    fi

    read -r -p "Bot Username (no @): " BOT_USERNAME
    BOT_USERNAME="${BOT_USERNAME#@}"
    if [ -z "$BOT_USERNAME" ]; then
        echo -e "${RED}Bot Username is required.${NC}"
        mirza_pause
        return
    fi

    read -r -p "New Marzban v1.0+? (y/n): " IS_NEW
    [[ "$IS_NEW" =~ ^[Yy]$ ]] && MARZBAN_VAL="true" || MARZBAN_VAL="false"

    DB_PASS=$(openssl rand -base64 12 | tr -d '/=+' 2>/dev/null)
    if [ -z "$DB_PASS" ]; then
        echo -e "${RED}Failed to generate database password.${NC}"
        mirza_pause
        return
    fi

    TMP_DIR=$(mktemp -d /tmp/mrm-mirza-install.XXXXXX 2>/dev/null)
    if [ -z "$TMP_DIR" ] || [ ! -d "$TMP_DIR" ]; then
        echo -e "${RED}Failed to create temporary workspace.${NC}"
        mirza_pause
        return
    fi

    TMP_CLONE="$TMP_DIR/mirza_repo"
    EXISTING_BACKUP="$TMP_DIR/existing_mirza"
    SITE_BACKUP="$TMP_DIR/mirzapro.conf.bak"

    echo -e "${YELLOW}Installing Packages...${NC}"
    if ! apt-get update >/dev/null 2>&1 || \
       ! apt-get install -y apache2 mariadb-server git curl php8.2 libapache2-mod-php8.2 php8.2-{mysql,curl,mbstring,xml,zip,gd,bcmath} jq certbot python3-certbot-apache >/dev/null 2>&1; then
        echo -e "${RED}Failed to install required packages.${NC}"
        rm -rf "$TMP_DIR"
        mirza_pause
        return
    fi

    mirza_start_db_service
    if ! mysql -e "CREATE DATABASE IF NOT EXISTS $MIRZA_DB_NAME; GRANT ALL PRIVILEGES ON $MIRZA_DB_NAME.* TO '$MIRZA_DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS'; FLUSH PRIVILEGES;" >/dev/null 2>&1; then
        echo -e "${RED}Failed to prepare MariaDB database/user.${NC}"
        rm -rf "$TMP_DIR"
        mirza_pause
        return
    fi

    if ! git clone "$MIRZA_REPO_URL" "$TMP_CLONE" >/dev/null 2>&1; then
        echo -e "${RED}Failed to clone Mirza Pro repository.${NC}"
        rm -rf "$TMP_DIR"
        mirza_pause
        return
    fi

    if ! mirza_write_config "$TMP_CLONE/config.php" "$DB_PASS" "$DOMAIN" "$BOT_TOKEN" "$ADMIN_ID" "$BOT_USERNAME" "$MARZBAN_VAL"; then
        echo -e "${RED}Failed to generate Mirza config.php.${NC}"
        rm -rf "$TMP_DIR"
        mirza_pause
        return
    fi

    if [ -f "$MIRZA_SITE_CONF" ]; then
        cp "$MIRZA_SITE_CONF" "$SITE_BACKUP" 2>/dev/null || true
    fi

    if [ -d "$MIRZA_PATH" ]; then
        mv "$MIRZA_PATH" "$EXISTING_BACKUP" || {
            echo -e "${RED}Failed to backup existing Mirza installation.${NC}"
            rm -rf "$TMP_DIR"
            mirza_pause
            return
        }
    fi

    mkdir -p "$(dirname "$MIRZA_PATH")"
    if ! mv "$TMP_CLONE" "$MIRZA_PATH"; then
        echo -e "${RED}Failed to deploy Mirza files.${NC}"
        [ -d "$EXISTING_BACKUP" ] && mv "$EXISTING_BACKUP" "$MIRZA_PATH" 2>/dev/null || true
        rm -rf "$TMP_DIR"
        mirza_pause
        return
    fi

    chown -R www-data:www-data "$MIRZA_PATH" >/dev/null 2>&1 || true
    chmod -R 755 "$MIRZA_PATH" >/dev/null 2>&1 || true

    if ! mirza_write_site_conf "$DOMAIN"; then
        echo -e "${RED}Failed to write Apache site configuration.${NC}"
        mirza_restore_install_state "$EXISTING_BACKUP" "$SITE_BACKUP"
        rm -rf "$TMP_DIR"
        mirza_pause
        return
    fi

    if ! a2ensite mirzapro.conf >/dev/null 2>&1 || \
       ! a2dissite 000-default.conf >/dev/null 2>&1 || \
       ! a2enmod rewrite ssl >/dev/null 2>&1; then
        echo -e "${RED}Failed to enable Apache site/modules for Mirza.${NC}"
        mirza_restore_install_state "$EXISTING_BACKUP" "$SITE_BACKUP"
        rm -rf "$TMP_DIR"
        mirza_pause
        return
    fi

    if ! certbot --apache -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email >/dev/null 2>&1; then
        echo -e "${RED}SSL issuance failed. Reverting installation.${NC}"
        mirza_restore_install_state "$EXISTING_BACKUP" "$SITE_BACKUP"
        rm -rf "$TMP_DIR"
        mirza_pause
        return
    fi

    if ! mirza_restart_apache_checked; then
        echo -e "${RED}Apache restart failed after installation. Reverting changes.${NC}"
        mirza_restore_install_state "$EXISTING_BACKUP" "$SITE_BACKUP"
        rm -rf "$TMP_DIR"
        mirza_pause
        return
    fi

    rm -rf "$EXISTING_BACKUP" "$TMP_DIR"
    echo -e "${GREEN}✔ Mirza Pro Installed Successfully!${NC}"
    mirza_pause
}

update_mirza() {
    local CONFIG_BACKUP

    mirza_logo
    if [ ! -d "$MIRZA_PATH" ]; then
        echo -e "${RED}Error: Mirza is not installed.${NC}"
        mirza_pause
        return
    fi

    if [ ! -f "$MIRZA_CONFIG_FILE" ]; then
        echo -e "${RED}Error: config.php not found.${NC}"
        mirza_pause
        return
    fi

    CONFIG_BACKUP=$(mktemp /tmp/mirza-config.XXXXXX 2>/dev/null)
    if [ -z "$CONFIG_BACKUP" ] || ! cp "$MIRZA_CONFIG_FILE" "$CONFIG_BACKUP"; then
        echo -e "${RED}Failed to create temporary config backup.${NC}"
        mirza_pause
        return
    fi

    if git -C "$MIRZA_PATH" fetch origin >/dev/null 2>&1 && \
       git -C "$MIRZA_PATH" reset --hard origin/main >/dev/null 2>&1; then
        cp "$CONFIG_BACKUP" "$MIRZA_CONFIG_FILE" >/dev/null 2>&1 || true
        chown -R www-data:www-data "$MIRZA_PATH" >/dev/null 2>&1 || true

        if mirza_restart_apache_checked; then
            echo -e "${GREEN}✔ Updated successfully.${NC}"
        else
            echo -e "${YELLOW}⚠ Update completed, but Apache restart failed. Please check Apache manually.${NC}"
        fi
    else
        cp "$CONFIG_BACKUP" "$MIRZA_CONFIG_FILE" >/dev/null 2>&1 || true
        echo -e "${RED}Error: Failed to update Mirza repository.${NC}"
    fi

    rm -f "$CONFIG_BACKUP"
    mirza_pause
}

remove_mirza() {
    local REMOVAL_OK=true

    mirza_logo
    read -r -p "Are you sure you want to DELETE everything? (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        a2dissite mirzapro.conf >/dev/null 2>&1 || true
        a2ensite 000-default.conf >/dev/null 2>&1 || true

        rm -rf "$MIRZA_PATH" || REMOVAL_OK=false
        rm -f "$MIRZA_SITE_CONF" || REMOVAL_OK=false

        mirza_start_db_service
        mysql -e "DROP DATABASE IF EXISTS $MIRZA_DB_NAME; DROP USER IF EXISTS '$MIRZA_DB_USER'@'localhost'; FLUSH PRIVILEGES;" >/dev/null 2>&1 || REMOVAL_OK=false
        mirza_remove_crons || REMOVAL_OK=false

        if mirza_restart_apache_checked; then
            if [ "$REMOVAL_OK" = true ]; then
                echo -e "${GREEN}✔ Mirza removed successfully.${NC}"
            else
                echo -e "${YELLOW}⚠ Mirza was removed with warnings. Please review Apache/MySQL manually.${NC}"
            fi
        else
            echo -e "${RED}Apache restart failed after removal. Please check configuration manually.${NC}"
        fi
    fi
    mirza_pause
}

export_db() {
    mirza_logo
    if [ -f "$MIRZA_CONFIG_FILE" ]; then
        echo -e "${YELLOW}Exporting Database...${NC}"

        if ! mirza_load_db_credentials; then
            echo -e "${RED}❌ Could not read database credentials from config.php${NC}"
            mirza_pause
            return
        fi

        if mysqldump -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" > "$MIRZA_DB_EXPORT" 2>/dev/null; then
            echo -e "${GREEN}✔ Database exported successfully!${NC}"
            echo -e "${CYAN}Location: $MIRZA_DB_EXPORT${NC}"
        else
            echo -e "${RED}❌ Export failed! Access denied or MySQL issue.${NC}"
        fi
    else
        echo -e "${RED}Error: Config file not found!${NC}"
    fi
    mirza_pause
}

import_db() {
    local SQL_PATH

    mirza_logo
    echo -e "${CYAN}--- Import Database ---${NC}"
    read -r -p "Enter full path to your .sql file: " SQL_PATH

    if [ -f "$SQL_PATH" ]; then
        if [ -f "$MIRZA_CONFIG_FILE" ]; then
            if ! mirza_load_db_credentials; then
                echo -e "${RED}Error: Failed to read DB credentials from config.php!${NC}"
                mirza_pause
                return
            fi

            echo -e "${YELLOW}Preparing database...${NC}"
            mirza_start_db_service
            if ! mysql -u root -e "CREATE DATABASE IF NOT EXISTS $DB_NAME; GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS'; FLUSH PRIVILEGES;" >/dev/null 2>&1; then
                echo -e "${RED}❌ Failed to prepare database!${NC}"
                mirza_pause
                return
            fi

            echo -e "${YELLOW}Importing data...${NC}"
            if mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$SQL_PATH" 2>/dev/null; then
                echo -e "${GREEN}✔ Database imported successfully!${NC}"
            else
                echo -e "${RED}❌ Import failed!${NC}"
            fi
        else
            echo -e "${RED}Error: config.php not found to get credentials!${NC}"
        fi
    else
        echo -e "${RED}Error: SQL file not found at $SQL_PATH${NC}"
    fi
    mirza_pause
}

configure_backup() {
    local b_interval
    local BACKUP_PHP
    local DIR_PATH
    local FILE_NAME

    mirza_logo
    echo -e "${CYAN}Setting up Telegram Auto-Backup...${NC}"
    read -r -p "Interval in hours (e.g. 12): " b_interval

    if ! mirza_validate_positive_integer "$b_interval"; then
        echo -e "${RED}Invalid interval. Please enter a positive number.${NC}"
        mirza_pause
        return
    fi

    BACKUP_PHP=$(find "$MIRZA_PATH" -name "*backup*.php" 2>/dev/null | head -n 1)
    if [ -n "$BACKUP_PHP" ]; then
        DIR_PATH=$(dirname "$BACKUP_PHP")
        FILE_NAME=$(basename "$BACKUP_PHP")
        mirza_remove_crons >/dev/null 2>&1 || true
        if (crontab -l 2>/dev/null | grep -vF "$MIRZA_PATH"; echo "0 */$b_interval * * * cd $DIR_PATH && /usr/bin/php $FILE_NAME > /dev/null 2>&1") | crontab -; then
            echo -e "${GREEN}✔ Backup scheduled every $b_interval hours.${NC}"
        else
            echo -e "${RED}Failed to schedule backup cron job.${NC}"
        fi
    else
        echo -e "${RED}Backup file not found in repo!${NC}"
    fi
    mirza_pause
}

renew_ssl() {
    mirza_logo
    echo -e "${YELLOW}Renewing SSL Certificates...${NC}"
    if certbot renew --apache >/dev/null 2>&1; then
        if mirza_restart_apache_checked; then
            echo -e "${GREEN}✔ SSL Renew process completed.${NC}"
        else
            echo -e "${YELLOW}⚠ SSL renewed, but Apache restart failed.${NC}"
        fi
    else
        echo -e "${RED}❌ SSL renew failed!${NC}"
    fi
    mirza_pause
}

change_domain() {
    local NEW_DOMAIN
    local CONFIG_BACKUP
    local SITE_BACKUP
    local ESC_NEW_DOMAIN

    mirza_logo
    read -r -p "Enter New Domain: " NEW_DOMAIN
    if ! mirza_validate_domain "$NEW_DOMAIN"; then
        echo -e "${RED}Invalid domain format.${NC}"
        mirza_pause
        return
    fi

    if [ ! -f "$MIRZA_CONFIG_FILE" ] || [ ! -f "$MIRZA_SITE_CONF" ]; then
        echo -e "${RED}Required Mirza configuration files were not found.${NC}"
        mirza_pause
        return
    fi

    CONFIG_BACKUP=$(mktemp /tmp/mirza-config-change.XXXXXX 2>/dev/null)
    SITE_BACKUP=$(mktemp /tmp/mirza-site-change.XXXXXX 2>/dev/null)
    cp "$MIRZA_CONFIG_FILE" "$CONFIG_BACKUP" 2>/dev/null || true
    cp "$MIRZA_SITE_CONF" "$SITE_BACKUP" 2>/dev/null || true

    ESC_NEW_DOMAIN=$(mirza_escape_sed_replacement "$NEW_DOMAIN")

    if ! sed -i "s|\(\\\$domainhosts = 'https://\)[^']*\(';\)|\1${ESC_NEW_DOMAIN}\2|" "$MIRZA_CONFIG_FILE"; then
        echo -e "${RED}Failed to update config.php.${NC}"
        rm -f "$CONFIG_BACKUP" "$SITE_BACKUP"
        mirza_pause
        return
    fi

    if ! sed -i "s|^\([[:space:]]*ServerName[[:space:]]\).*|\1${ESC_NEW_DOMAIN}|" "$MIRZA_SITE_CONF"; then
        cp "$CONFIG_BACKUP" "$MIRZA_CONFIG_FILE" 2>/dev/null || true
        echo -e "${RED}Failed to update Apache site configuration.${NC}"
        rm -f "$CONFIG_BACKUP" "$SITE_BACKUP"
        mirza_pause
        return
    fi

    if ! certbot --apache -d "$NEW_DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email >/dev/null 2>&1; then
        cp "$CONFIG_BACKUP" "$MIRZA_CONFIG_FILE" 2>/dev/null || true
        cp "$SITE_BACKUP" "$MIRZA_SITE_CONF" 2>/dev/null || true
        mirza_restart_apache_checked >/dev/null 2>&1 || true
        echo -e "${RED}SSL issuance failed for the new domain. Changes were reverted.${NC}"
        rm -f "$CONFIG_BACKUP" "$SITE_BACKUP"
        mirza_pause
        return
    fi

    if mirza_restart_apache_checked; then
        echo -e "${GREEN}✔ Domain changed to $NEW_DOMAIN${NC}"
    else
        cp "$CONFIG_BACKUP" "$MIRZA_CONFIG_FILE" 2>/dev/null || true
        cp "$SITE_BACKUP" "$MIRZA_SITE_CONF" 2>/dev/null || true
        mirza_restart_apache_checked >/dev/null 2>&1 || true
        echo -e "${RED}Apache restart failed. Domain change was reverted.${NC}"
    fi

    rm -f "$CONFIG_BACKUP" "$SITE_BACKUP"
    mirza_pause
}

additional_mgmt() {
    local am_choice
    local TOKEN

    mirza_logo
    echo -e "1) View Logs\n2) Service Status\n3) Webhook Info\n0) Back"
    read -r -p "Choice: " am_choice
    case $am_choice in
        1) tail -n 50 /var/log/apache2/error.log | less ;;
        2) systemctl status apache2 mariadb --no-pager ;;
        3)
           TOKEN=$(grep "APIKEY" "$MIRZA_CONFIG_FILE" 2>/dev/null | cut -d"'" -f2)
           if [ -n "$TOKEN" ]; then
               curl -s "https://api.telegram.org/bot$TOKEN/getWebhookInfo" | jq .
           else
               echo -e "${RED}APIKEY not found in config.php${NC}"
           fi
           read -r -p "Press Enter..."
           ;;
        0) return ;;
        *) echo -e "${RED}Invalid Option!${NC}"; sleep 1 ;;
    esac
}

migration_server() {
    mirza_logo
    echo -e "${YELLOW}Immigration (Migration) Guide:${NC}"
    echo -e "1. Export Database on OLD server (Option 4)"
    echo -e "2. Install Mirza on NEW server (Option 1)"
    echo -e "3. Import Database on NEW server (Option 5)"
    echo -e "4. Copy 'data' folder from old to new /var/www/mirzapro/"
    mirza_pause
}

remove_domain() {
    local SITE_BACKUP

    mirza_logo

    SITE_BACKUP=$(mktemp /tmp/mirza-remove-domain.XXXXXX 2>/dev/null)
    cp "$MIRZA_SITE_CONF" "$SITE_BACKUP" 2>/dev/null || true

    a2dissite mirzapro.conf >/dev/null 2>&1 || true
    a2ensite 000-default.conf >/dev/null 2>&1 || true
    rm -f "$MIRZA_SITE_CONF" >/dev/null 2>&1 || true

    if mirza_restart_apache_checked; then
        echo -e "${GREEN}✔ Domain configuration removed.${NC}"
        rm -f "$SITE_BACKUP"
    else
        echo -e "${RED}Apache restart failed. Restoring previous domain configuration...${NC}"
        if [ -f "$SITE_BACKUP" ]; then
            cp "$SITE_BACKUP" "$MIRZA_SITE_CONF" 2>/dev/null || true
            a2ensite mirzapro.conf >/dev/null 2>&1 || true
            a2dissite 000-default.conf >/dev/null 2>&1 || true
            mirza_restart_apache_checked >/dev/null 2>&1 || true
        fi
        rm -f "$SITE_BACKUP"
    fi

    mirza_pause
}

delete_crons() {
    mirza_logo
    if mirza_remove_crons; then
        echo -e "${GREEN}✔ Mirza Cron Jobs deleted.${NC}"
    else
        echo -e "${RED}Failed to clean Mirza Cron Jobs.${NC}"
    fi
    mirza_pause
}

# --- Main Menu Function ---
mirza_menu() {
    local choice

    while true; do
        mirza_logo
        echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
        echo -e "${WHITE}║            MIRZA PRO - MAIN MENU               ║${NC}"
        echo -e "${GREEN}╠════════════════════════════════════════════════╣${NC}"
        echo -e "║                                                ║"
        echo -e "║ 1)  Install Mirza Bot                          ║"
        echo -e "║ 2)  Update Mirza Bot                           ║"
        echo -e "║ 3)  Remove Mirza Bot                           ║"
        echo -e "║ 4)  Export Database                            ║"
        echo -e "║ 5)  Import Database                            ║"
        echo -e "║ 6)  Configure Automated Backup                 ║"
        echo -e "║ 7)  Renew SSL Certificates                     ║"
        echo -e "║ 8)  Change Domain                              ║"
        echo -e "║ 9)  Additional Bot Management                  ║"
        echo -e "║ 10) Immigration (Server Migration)             ║"
        echo -e "║ 11) Remove Domain                              ║"
        echo -e "║ 12) Delete Cron Jobs                           ║"
        echo -e "║ 13) Exit                                       ║"
        echo -e "║                                                ║"
        echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
        read -r -p "❯ Select an option [1-13]: " choice

        case $choice in
            1) install_mirza ;;
            2) update_mirza ;;
            3) remove_mirza ;;
            4) export_db ;;
            5) import_db ;;
            6) configure_backup ;;
            7) renew_ssl ;;
            8) change_domain ;;
            9) additional_mgmt ;;
            10) migration_server ;;
            11) remove_domain ;;
            12) delete_crons ;;
            13) return ;;
            *) echo -e "${RED}Invalid Option!${NC}" && sleep 1 ;;
        esac
    done
}

# --- اجرایی فقط در صورت فراخوانی مستقیم ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    mirza_menu
fi
