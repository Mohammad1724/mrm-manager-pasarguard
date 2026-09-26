#!/bin/bash
# MRM Backup - Telegram Module
# Send/receive messages, setup bot, test connection

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
    elif [[ "$PROXY" == http://* || "$PROXY" == https://* ]]; then
        # FIX: previously http(s):// proxies produced NO curl args and the
        # request silently went DIRECT (no proxy) — confusing failures in Iran (MRM-074)
        printf '%s\n' "--proxy" "$PROXY"
    fi
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
    # FIX: anchor the keys so comments or similarly-named keys can never
    # shadow the real token/chat/proxy values (MRM-072)
    TK=$(grep "^TG_TOKEN=" "$TG_CONFIG" | cut -d'=' -f2 | tr -d '"')
    CH=$(grep "^TG_CHAT=" "$TG_CONFIG" | cut -d'=' -f2 | tr -d '"')
    PROXY=$(grep "^TG_PROXY=" "$TG_CONFIG" | cut -d'=' -f2 | tr -d '"')
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
        curl -4 -s "${CURL_PROXY_ARGS[@]}" -X POST "https://api.telegram.org/bot$TK/sendMessage" -d chat_id="$CH" --data-urlencode "text=$MESSAGE" > /dev/null
        return $?
    fi
    return 1
}

test_telegram() {
    local TK CH PROXY RESULT
    local -a CURL_PROXY_ARGS=()
    if [ ! -f "$TG_CONFIG" ]; then ui_error "Telegram is not configured"; return 1; fi
    ui_spinner_start "Testing Telegram connection"
    TK=$(grep "^TG_TOKEN=" "$TG_CONFIG" | cut -d'=' -f2 | tr -d '"')
    CH=$(grep "^TG_CHAT=" "$TG_CONFIG" | cut -d'=' -f2 | tr -d '"')
    PROXY=$(grep "^TG_PROXY=" "$TG_CONFIG" | cut -d'=' -f2 | tr -d '"')
    mapfile -t CURL_PROXY_ARGS < <(build_telegram_proxy_args "$PROXY")
    RESULT=$(curl -4 -s "${CURL_PROXY_ARGS[@]}" -X POST "https://api.telegram.org/bot$TK/sendMessage" -d chat_id="$CH" --data-urlencode "text=MRM Backup test - $(date '+%Y-%m-%d %H:%M')" 2>&1)
    ui_spinner_stop
    if echo "$RESULT" | grep -q '"ok":true'; then
        ui_success "Telegram connection successful"
        return 0
    fi
    ui_error "Telegram connection failed"
    ui_note "Response: $(ui_truncate "$RESULT" 200)"
    return 1
}

setup_telegram() {
    ui_header "Telegram Bot Setup" "backups and alerts are delivered to this chat"
    ui_section "How to get the values"
    ui_text "Bot token:  message @BotFather, send /newbot and copy the token"
    ui_text "Chat ID:    message @userinfobot — it replies with your numeric ID"
    echo ""
    local TK CI USE_PROXY PROXY_URL
    ui_ask_secret TK "Bot token"
    if [ -z "$TK" ]; then ui_error "Bot token is required"; ui_pause; return; fi
    ui_ask CI "Chat ID"
    if [ -z "$CI" ]; then ui_error "Chat ID is required"; ui_pause; return; fi
    echo ""
    if ui_confirm "Use a proxy to reach Telegram?"; then
        ui_note "Formats: socks5://127.0.0.1:1080 · socks5://user:pass@host:1080 · http://host:8080"
        ui_ask PROXY_URL "Proxy URL"
    else
        PROXY_URL=""
    fi
    if declare -f mrm_create_restore_point >/dev/null 2>&1; then
        local RESTORE_POINT_ID
        RESTORE_POINT_ID="$(mrm_create_restore_point "telegram-settings" "none" "$TG_CONFIG")"
        [ -n "$RESTORE_POINT_ID" ] && ui_note "Restore point: $RESTORE_POINT_ID"
    fi
    # Values written verbatim — an unquoted heredoc would expand $VAR,
    # backticks and $(...) inside the token/chat/proxy (MRM-071, same class
    # as MRM-005). printf keeps the shared KEY="value" format (monitor.sh reads it).
    printf 'TG_TOKEN="%s"\nTG_CHAT="%s"\nTG_PROXY="%s"\n' "$TK" "$CI" "$PROXY_URL" > "$TG_CONFIG"
    chmod 600 "$TG_CONFIG"
    echo ""
    ui_success "Telegram configured"
    log_backup "INFO" "Telegram bot configured"
    echo ""
    if ui_confirm "Send a test message now?" y; then test_telegram; fi
    ui_pause
}

remove_telegram_settings() {
    ui_header "Remove Telegram Settings"
    if [ ! -f "$TG_CONFIG" ]; then ui_warning "Telegram is not configured"; ui_pause; return; fi
    ui_text "This deletes the saved bot token and chat ID."
    ui_note "Scheduled backups keep running locally."
    echo ""
    if ui_confirm "Remove Telegram settings?"; then
        if declare -f mrm_create_restore_point >/dev/null 2>&1; then
            local RESTORE_POINT_ID
            RESTORE_POINT_ID="$(mrm_create_restore_point "telegram-settings-remove" "none" "$TG_CONFIG")"
            [ -n "$RESTORE_POINT_ID" ] && ui_note "Restore point: $RESTORE_POINT_ID"
        fi
        rm -f "$TG_CONFIG"
        ui_success "Telegram settings removed"
        log_backup "INFO" "Telegram settings removed"
    else
        ui_cancelled
    fi
    ui_pause
}
