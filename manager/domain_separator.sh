#!/bin/bash
# MRM Manager v1.5.0
# domain_separator.sh — separate panel and subscription domains via nginx

# ─── Shared libraries ────────────────────────────────────────────────────────
MRM_DIR="${MRM_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)}"
[ -r "$MRM_DIR/utils.sh" ] || MRM_DIR="/opt/mrm-manager"
# shellcheck source=/dev/null
if [ -z "$PANEL_DIR" ] || ! declare -f load_panel_config >/dev/null 2>&1; then source "$MRM_DIR/utils.sh"; fi
# shellcheck source=/dev/null
declare -f ui_header >/dev/null 2>&1 || source "$MRM_DIR/ui.sh"
# shellcheck source=/dev/null
if ! declare -f mrm_create_restore_point >/dev/null 2>&1 && [ -r "$MRM_DIR/safe_ops.sh" ]; then source "$MRM_DIR/safe_ops.sh"; fi
# MRM-045: reuse ssl.sh's recovery helpers (stale live cleanup, broken
# profile detection, days-remaining) when they are installed
# shellcheck source=/dev/null
if ! declare -f _stale_live_cleanup >/dev/null 2>&1 && [ -r "$MRM_DIR/ssl.sh" ]; then source "$MRM_DIR/ssl.sh"; fi

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
    ui_note "Checking requirements…"
    local NEED_INSTALL=false

    if ! command -v nginx &> /dev/null; then
        ui_warning "nginx not found — installing"
        NEED_INSTALL=true
    fi

    if ! command -v certbot &> /dev/null; then
        ui_warning "certbot not found — installing"
        NEED_INSTALL=true
    fi

    if [ "$NEED_INSTALL" = true ]; then
        apt update && apt install -y nginx certbot
        ui_success "Requirements installed"
    else
        ui_success "Requirements present (nginx, certbot)"
    fi

    systemctl enable nginx > /dev/null 2>&1
}

# MRM-045: make sure a valid LE certificate exists for a domain before
# wiring nginx to it:
#   1) healthy existing cert  -> reuse it (no duplicate ACME order)
#   2) broken profile skeleton-> back up + drop it (same as MRM-043)
#   3) stale live dir         -> back up + remove it (same as MRM-042)
#   4) otherwise issue fresh with the given email
ensure_le_cert() {
    local dom="$1" email="$2"
    local le_full="/etc/letsencrypt/live/$dom/fullchain.pem"

    if [[ -f "$le_full" ]] && declare -f get_cert_days_remaining >/dev/null 2>&1; then
        local days
        days=$(get_cert_days_remaining "$le_full" 2>/dev/null || echo 0)
        if [[ "${days:-0}" -gt 0 ]]; then
            ui_success "Existing certificate for $dom is valid (${days} days) — reusing it"
            return 0
        fi
    fi

    if declare -f _renewal_profile_broken >/dev/null 2>&1 && _renewal_profile_broken "$dom"; then
        local bb
        bb="${SSL_BACKUP_DIR:-/opt/mrm-manager/ssl-backups}/broken-conf-$dom-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$bb" 2>/dev/null && cp -a "/etc/letsencrypt/renewal/$dom.conf" "$bb/" 2>/dev/null
        rm -f "/etc/letsencrypt/renewal/$dom.conf" 2>/dev/null
        ui_note "broken renewal profile backed up: $bb"
    fi

    if declare -f _stale_live_cleanup >/dev/null 2>&1; then
        if ! _stale_live_cleanup "$dom"; then
            ui_error "Could not remove stale certificate data for $dom"
            return 1
        fi
    fi

    certbot certonly --standalone --non-interactive --agree-tos --email "$email" --preferred-challenges http -d "$dom"
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

    ui_header "Domain Separator" "nginx front for a separate dashboard and subscription domain"
    ui_text "The dashboard and the subscription links get their own domains, both served by nginx"
    ui_text "on one port with individual Let's Encrypt certificates."
    echo ""

    if declare -f init_logging >/dev/null 2>&1; then
        init_logging || true
    fi

    install_requirements

    echo ""

    ui_ask ADMIN_DOM "Dashboard domain (e.g. admin.example.com)"
    if [ -z "$ADMIN_DOM" ]; then ui_error "Dashboard domain is required."; pause; return; fi
    if ! validate_domain_name "$ADMIN_DOM"; then ui_error "Invalid domain format: $ADMIN_DOM"; pause; return; fi

    ui_ask SUB_DOM "Subscription domain (e.g. sub.example.com)"
    if [ -z "$SUB_DOM" ]; then ui_error "Subscription domain is required."; pause; return; fi
    if ! validate_domain_name "$SUB_DOM"; then ui_error "Invalid domain format: $SUB_DOM"; pause; return; fi

    if [ "$ADMIN_DOM" = "$SUB_DOM" ]; then
        ui_error "The two domains must be different."
        pause; return
    fi

    ui_ask PORT "Public HTTPS port for nginx" "2096"
    [ -z "$PORT" ] && PORT="2096"
    if ! validate_port_number "$PORT"; then
        ui_error "Port must be a number between 1 and 65535."
        pause; return
    fi

    # FIX (MRM-093): default = the panel's real UVICORN_PORT from .env — the
    # official default is 8000 (config.py:54, .env.example), not the old
    # hard-coded 7431 which pointed the proxy at a dead port. Same approach as
    # post_restore.sh / pg_health.sh.
    local PANEL_PORT_DEF
    PANEL_PORT_DEF="$(grep -oP '^\s*UVICORN_PORT\s*=\s*\K[0-9]+' "$PANEL_ENV" 2>/dev/null | head -1)" || true
    [ -z "$PANEL_PORT_DEF" ] && PANEL_PORT_DEF="8000"
    ui_ask PANEL_PORT "Current panel port (UVICORN_PORT)" "$PANEL_PORT_DEF"
    [ -z "$PANEL_PORT" ] && PANEL_PORT="$PANEL_PORT_DEF"
    if ! validate_port_number "$PANEL_PORT"; then
        ui_error "Panel port must be a number between 1 and 65535."
        pause; return
    fi

    # Prevent a proxy loop
    if [ "$PORT" = "$PANEL_PORT" ]; then
        ui_error "The nginx port ($PORT) must differ from the panel port ($PANEL_PORT)."
        pause; return
    fi

    echo ""
    ui_section "Summary"
    ui_kv "Dashboard" "https://$ADMIN_DOM:$PORT"
    ui_kv "Subscription" "https://$SUB_DOM:$PORT"
    ui_kv "Panel port" "$PANEL_PORT"
    echo ""
    if ! ui_confirm "Apply this configuration?" y; then ui_cancelled; pause; return; fi

    echo ""
    # MRM-045: prefer the email already registered with Let's Encrypt
    local CB_EMAIL
    CB_EMAIL=$(grep -h '^[[:space:]]*email[[:space:]]*=' /etc/letsencrypt/renewal/*.conf 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d ' ')
    if [ -z "$CB_EMAIL" ]; then
        ui_ask CB_EMAIL "Let's Encrypt email" "admin@$ADMIN_DOM"
        [ -z "$CB_EMAIL" ] && CB_EMAIL="admin@$ADMIN_DOM"
    fi

    ui_step 1 4 "Stopping nginx for the HTTP challenge"
    if ! stop_nginx_checked; then
        ui_error "Failed to stop nginx"
        pause; return
    fi

    ui_step 2 4 "Certificates"
    # Certificate for the dashboard domain (reuses a valid existing cert — MRM-045)
    ui_note "Dashboard domain: $ADMIN_DOM"
    ensure_le_cert "$ADMIN_DOM" "$CB_EMAIL"
    ADMIN_CERT_OK=$?

    # Certificate for the subscription domain
    ui_note "Subscription domain: $SUB_DOM"
    ensure_le_cert "$SUB_DOM" "$CB_EMAIL"
    SUB_CERT_OK=$?

    # Check dashboard cert (required)
    if [ $ADMIN_CERT_OK -ne 0 ] || [ ! -d "/etc/letsencrypt/live/$ADMIN_DOM" ]; then
        ui_error "Could not obtain a certificate for $ADMIN_DOM"
        start_nginx_checked >/dev/null 2>&1 || systemctl start nginx >/dev/null 2>&1 || true
        pause; return
    fi

    # Check subscription cert
    SUB_CERT_PATH="/etc/letsencrypt/live/$SUB_DOM"
    if [ $SUB_CERT_OK -ne 0 ] || [ ! -d "$SUB_CERT_PATH" ]; then
        ui_error "Could not obtain a certificate for $SUB_DOM — aborting"
        start_nginx_checked >/dev/null 2>&1 || systemctl start nginx >/dev/null 2>&1 || true
        pause; return
    fi

    ui_success "Certificates ready"

    ui_step 3 4 "Writing nginx configuration"
    if declare -f mrm_create_restore_point >/dev/null 2>&1; then
        local RESTORE_POINT_ID
        RESTORE_POINT_ID="$(mrm_create_restore_point "domain-separation" "nginx" "$NGINX_CONF" "$PANEL_CONFLICT_CONF")"
        [ -n "$RESTORE_POINT_ID" ] && ui_note "Restore point: $RESTORE_POINT_ID"
    fi

    if [ -f "$NGINX_CONF" ]; then
        NGINX_BACKUP=$(mktemp /tmp/mrm-domain-separator.XXXXXX 2>/dev/null)
        if [ -z "$NGINX_BACKUP" ] || ! cp "$NGINX_CONF" "$NGINX_BACKUP" 2>/dev/null; then
            ui_error "Failed to back up the existing nginx config"
            start_nginx_checked >/dev/null 2>&1 || systemctl start nginx >/dev/null 2>&1 || true
            pause; return
        fi
    fi

    # Cleanup old conflicts (safe backup)
    if [ -f "$PANEL_CONFLICT_CONF" ]; then
        ui_warning "Conflicting config panel.conf found — disabling it"
        CONFLICT_BACKUP="${PANEL_CONFLICT_CONF}.bak"
        [ -e "$CONFLICT_BACKUP" ] && CONFLICT_BACKUP="${PANEL_CONFLICT_CONF}.bak.$(date +%s)"
        if ! mv "$PANEL_CONFLICT_CONF" "$CONFLICT_BACKUP"; then
            ui_error "Failed to disable panel.conf"
            start_nginx_checked >/dev/null 2>&1 || systemctl start nginx >/dev/null 2>&1 || true
            [ -n "$NGINX_BACKUP" ] && rm -f "$NGINX_BACKUP"
            pause; return
        fi
    fi

    # FIX (MRM-092): the proxy scheme must follow the panel's real .env — SSL
    # is OFF by default in the official panel (UVICORN_SSL_CERTFILE is commented
    # in .env.example, config.py default None), so the old hard-coded
    # "proxy_pass https://..." + always-on proxy_ssl_verify off produced 502 on
    # default installs. Same detection as post_restore.sh:197.
    local PANEL_PROTO PROXY_SSL_LINE
    if [ -n "$(grep -oP '^\s*UVICORN_SSL_CERTFILE\s*=\s*"?\K[^"]+' "$PANEL_ENV" 2>/dev/null | head -1)" ]; then
        PANEL_PROTO="https"
        PROXY_SSL_LINE="        proxy_ssl_verify off;"
    else
        PANEL_PROTO="http"
        PROXY_SSL_LINE=""
    fi

    cat > "$NGINX_CONF" <<EOF
# Admin Domain
server {
    listen $PORT ssl;
    listen [::]:$PORT ssl;
    server_name $ADMIN_DOM;

    ssl_certificate /etc/letsencrypt/live/$ADMIN_DOM/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$ADMIN_DOM/privkey.pem;

    location / {
        # proxy scheme follows the panel .env (MRM-092)
        proxy_pass $PANEL_PROTO://127.0.0.1:$PANEL_PORT;
$PROXY_SSL_LINE
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
        # proxy scheme follows the panel .env (MRM-092)
        proxy_pass $PANEL_PROTO://127.0.0.1:$PANEL_PORT;
$PROXY_SSL_LINE
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
    ui_step 4 4 "Testing and reloading nginx"
    if ! nginx -t >/dev/null 2>&1; then
        ui_error "nginx configuration test failed — reverting"
        restore_domain_separator_state "$NGINX_BACKUP" "$CONFLICT_BACKUP"
        start_nginx_checked >/dev/null 2>&1 || systemctl start nginx >/dev/null 2>&1 || true
        rm -f "$NGINX_BACKUP" 2>/dev/null
        pause; return
    fi

    if command -v ufw &> /dev/null; then ufw allow "$PORT"/tcp > /dev/null 2>&1; fi

    if ! restart_nginx_checked; then
        ui_error "nginx restart failed — reverting"
        restore_domain_separator_state "$NGINX_BACKUP" "$CONFLICT_BACKUP"
        start_nginx_checked >/dev/null 2>&1 || systemctl start nginx >/dev/null 2>&1 || true
        rm -f "$NGINX_BACKUP" 2>/dev/null
        pause; return
    fi

    rm -f "$NGINX_BACKUP" 2>/dev/null

    echo ""
    ui_box_start ok "Domain separation active"
    ui_box_line "Dashboard" "https://$ADMIN_DOM:$PORT"
    ui_box_line "Subscription" "https://$SUB_DOM:$PORT"
    ui_box_line "nginx config" "$NGINX_CONF"
    ui_box_end
    ui_note "Set the subscription URL prefix in the panel to https://$SUB_DOM:$PORT (Settings › Subscription)."
    pause
}

edit_nginx_config_manually() {
    local EDIT_BACKUP

    if declare -f mrm_create_restore_point >/dev/null 2>&1; then
        local RESTORE_POINT_ID
        RESTORE_POINT_ID="$(mrm_create_restore_point "domain-manual-edit" "nginx" "$NGINX_CONF" "$PANEL_CONFLICT_CONF")"
        [ -n "$RESTORE_POINT_ID" ] && ui_note "Restore point: $RESTORE_POINT_ID"
    fi

    EDIT_BACKUP=$(mktemp /tmp/mrm-domain-edit.XXXXXX 2>/dev/null)
    if [ -f "$NGINX_CONF" ] && [ -n "$EDIT_BACKUP" ]; then
        cp "$NGINX_CONF" "$EDIT_BACKUP" 2>/dev/null || true
    fi

    nano "$NGINX_CONF"

    if restart_nginx_checked; then
        ui_success "nginx reloaded with the edited configuration"
        sleep 1
    else
        ui_error "nginx configuration is invalid or the restart failed — reverting"
        # FIX (MRM-095): use -s (non-empty) — mktemp always creates the file,
        # so -f was always true and an EMPTY backup was copied instead of the
        # clean removal path when the config was newly created and invalid
        if [ -n "$EDIT_BACKUP" ] && [ -s "$EDIT_BACKUP" ]; then
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
    local OPT
    while true; do
        ui_header "Domain Separator"
        if [ -f "$NGINX_CONF" ]; then
            local ADMIN_NOW SUB_NOW
            ADMIN_NOW="$(grep -m1 -oP 'server_name\s+\K[^;]+' "$NGINX_CONF" 2>/dev/null)"
            SUB_NOW="$(grep -oP 'server_name\s+\K[^;]+' "$NGINX_CONF" 2>/dev/null | sed -n 2p)"
            ui_kv_state "Status" ok "Configured" "${ADMIN_NOW:-?} · ${SUB_NOW:-?}"
        else
            ui_kv_state "Status" off "Not configured"
        fi
        if systemctl is-active --quiet nginx 2>/dev/null; then ui_kv_state "Nginx" ok "Running"; else ui_kv_state "Nginx" off "Not running"; fi
        echo ""
        ui_menu_item 1 "Separate dashboard and subscription domains" "wizard"
        ui_menu_item 2 "Restart nginx"
        ui_menu_item 3 "Nginx status"
        ui_menu_item 4 "Edit nginx config" "$NGINX_CONF"
        ui_menu_back
        ui_select OPT
        case $OPT in
            1) setup_domain_separation ;;
            2)
                if restart_nginx_checked; then
                    ui_success "nginx restarted"
                else
                    ui_error "nginx restart failed — check the configuration with: nginx -t"
                fi
                sleep 1
                ;;
            3) echo ""; systemctl status nginx --no-pager; ui_pause ;;
            4) edit_nginx_config_manually ;;
            0) return ;;
            *) ui_invalid ;;
        esac
    done
}


if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    domain_menu
fi
