#!/bin/bash
# MRM Backup — menu module (schedule, list/delete, logs, size analyzer)

# ─── Utilities ───────────────────────────────────────────────────────────────
setup_cron() {
    ui_header "Backup Schedule"
    if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH"; then
        local CURRENT
        CURRENT="$(crontab -l 2>/dev/null | grep "$SCRIPT_PATH" | awk '{print $1" "$2" "$3" "$4" "$5}')"
        ui_kv_state "Schedule" ok "Active" "$CURRENT"
    else
        ui_kv_state "Schedule" off "No scheduled backup"
    fi
    echo ""
    ui_menu_item 1 "Every 6 hours"
    ui_menu_item 2 "Every 12 hours"
    ui_menu_item 3 "Every 24 hours" "daily · recommended"
    ui_menu_item 4 "Every week" "Sunday 00:00"
    ui_menu_item 5 "Disable scheduled backup"
    ui_menu_back "Cancel"
    local c
    ui_select c
    local CRON_TIME=""
    case $c in
        1) CRON_TIME="0 */6 * * *" ;;
        2) CRON_TIME="0 */12 * * *" ;;
        3) CRON_TIME="0 0 * * *" ;;
        4) CRON_TIME="0 0 * * 0" ;;
        5) CRON_TIME="" ;;
        0) return ;;
        *) ui_invalid; return ;;
    esac
    # Build the new crontab in a temp file. The old pipe-based version broke
    # on servers with no existing crontab: `crontab -l` fails there, and under
    # `set -e` (leaked by sourced post_restore.sh) the subshell aborted before
    # the new line was written, leaving an empty crontab behind.
    local TMP_CRON
    TMP_CRON="$(mktemp)"
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | grep -v "/opt/mrm-manager/main.sh auto" | grep -v "/opt/mrm-manager/backup.sh auto" > "$TMP_CRON" || true
    if [ -n "$CRON_TIME" ]; then
        echo "$CRON_TIME /bin/bash $SCRIPT_PATH auto >> $BACKUP_LOG 2>&1" >> "$TMP_CRON"
    fi
    if crontab "$TMP_CRON"; then
        rm -f "$TMP_CRON"
        echo ""
        if [ -n "$CRON_TIME" ]; then
            ui_success "Scheduled backup enabled: $CRON_TIME"
            log_backup "INFO" "Cron scheduled: $CRON_TIME"
        else
            ui_success "Scheduled backup disabled"
            log_backup "INFO" "Cron disabled"
        fi
    else
        rm -f "$TMP_CRON"
        ui_error "Failed to install crontab"
        log_backup "ERROR" "Failed to install crontab"
        ui_pause
        return 1
    fi
    ui_pause
}

view_backup_logs() {
    ui_header "Backup Logs" "$BACKUP_LOG · last 50 entries"
    if [ -s "$BACKUP_LOG" ]; then
        tail -n 50 "$BACKUP_LOG"
    else
        ui_warning "No log entries yet"
    fi
    ui_pause
}

list_backups() {
    ui_header "Available Backups" "$BACKUP_DIR"
    local FILES=()
    while IFS= read -r F; do [ -n "$F" ] && FILES+=("$F"); done < <(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null)
    if [ ${#FILES[@]} -eq 0 ]; then ui_warning "No backups found"; ui_pause; return; fi
    ui_table_header "%-3s  %-8s  %-38s  %-7s  %s" "ID" "Type" "Filename" "Size" "Date"
    for i in "${!FILES[@]}"; do
        local NAME SIZE DATE TYPE
        NAME=$(basename "${FILES[$i]}")
        SIZE=$(du -h "${FILES[$i]}" | cut -f1)
        DATE=$(stat -c %y "${FILES[$i]}" | cut -d' ' -f1)
        TYPE="BACKUP"
        [[ "$NAME" == *"Full"* ]] && TYPE="FULL-OLD"
        [[ "$NAME" == *"Lite"* ]] && TYPE="LITE-OLD"
        [[ "$NAME" == *"V1"* ]] && TYPE="BACKUP"
        # pre_restore_* safety backups are not restorable (MRM-062);
        # label them as SAFETY so they are not mistaken for regular backups (MRM-070)
        [[ "$NAME" == pre_restore_* ]] && TYPE="SAFETY"
        ui_table_row "$((i+1))" "$TYPE" "$(ui_truncate "$NAME" 38)" "$SIZE" "$DATE"
    done
    echo ""
    ui_kv "Total" "${#FILES[@]} backup(s)"
    ui_kv "Location" "$BACKUP_DIR"
    ui_note "Regular backups are ready to send to Telegram; SAFETY copies are restore checkpoints."
    ui_pause
}

delete_backup() {
    ui_header "Delete Backup" "$BACKUP_DIR"
    local FILES=()
    while IFS= read -r F; do [ -n "$F" ] && FILES+=("$F"); done < <(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null)
    if [ ${#FILES[@]} -eq 0 ]; then ui_warning "No backups found"; ui_pause; return; fi
    for i in "${!FILES[@]}"; do
        ui_menu_item "$((i+1))" "$(basename "${FILES[$i]}")" "$(du -h "${FILES[$i]}" | cut -f1)"
    done
    ui_menu_back "Cancel"
    local SEL
    ui_select SEL
    [ "$SEL" == "0" ] && return
    # validate numeric input — otherwise $((SEL-1)) treats non-numeric
    # input as empty var -> -1 -> FILES[-1] wraps to the LAST backup (MRM-069)
    if ! [[ "$SEL" =~ ^[0-9]+$ ]]; then ui_error "Invalid selection"; ui_pause; return; fi
    local SELECTED="${FILES[$((SEL-1))]}"
    if [ -z "$SELECTED" ]; then ui_error "Invalid selection"; ui_pause; return; fi
    echo ""
    if ui_confirm "Delete $(basename "$SELECTED")?"; then
        rm -f "$SELECTED"
        ui_success "Backup deleted"
        log_backup "INFO" "Deleted backup: $(basename "$SELECTED")"
    else
        ui_cancelled
    fi
    ui_pause
}

debug_backup_size() {
    ui_header "Backup Size Analyzer" "what makes the archive large"
    setup_env
    ui_section "Panel directory · $PANEL_DIR"
    if [ -d "$PANEL_DIR" ]; then
        ui_kv "Total" "$(du -sh "$PANEL_DIR" 2>/dev/null | cut -f1)"
        du -sh "$PANEL_DIR"/* 2>/dev/null | sort -rh | head -n 20 | sed "s/^/${UI_PAD}/"
        if [ -d "$PANEL_DIR/backup" ]; then
            echo ""
            ui_warning "A backup folder lives inside the panel directory (backup-inside-backup loop):"
            du -sh "$PANEL_DIR/backup"/* 2>/dev/null | head -n 20 | sed "s/^/${UI_PAD}/"
        fi
    else
        ui_note "Not found"
    fi
    echo ""
    ui_section "Data directory · $DATA_DIR"
    if [ -d "$DATA_DIR" ]; then
        ui_kv "Total" "$(du -sh "$DATA_DIR" 2>/dev/null | cut -f1)"
        du -sh "$DATA_DIR"/* 2>/dev/null | sort -rh | head -n 20 | sed "s/^/${UI_PAD}/"
    else
        ui_note "Not found"
    fi
    echo ""
    ui_section "Node directories"
    if [ -d "$NODE_DIR" ]; then
        ui_kv "$NODE_DIR" "$(du -sh "$NODE_DIR" 2>/dev/null | cut -f1)"
        du -sh "$NODE_DIR"/* 2>/dev/null | sort -rh | head -n 20 | sed "s/^/${UI_PAD}/"
    fi
    local NODE_DATA_DIR
    NODE_DATA_DIR="$(dirname "$NODE_DEF_CERTS")"
    if [ -d "$NODE_DATA_DIR" ]; then
        ui_kv "$NODE_DATA_DIR" "$(du -sh "$NODE_DATA_DIR" 2>/dev/null | cut -f1)"
        du -sh "$NODE_DATA_DIR"/* 2>/dev/null | sort -rh | head -n 30 | sed "s/^/${UI_PAD}/"
        [ -d "$NODE_DATA_DIR/assets" ] && ui_warning "assets/ is heavy (geoip.dat / geosite.dat) — excluded from backups"
        [ -d "$NODE_DATA_DIR/xray-core" ] && ui_warning "xray-core/ is heavy (xray binary) — excluded from backups"
    fi
    [ ! -d "$NODE_DIR" ] && [ ! -d "$NODE_DATA_DIR" ] && ui_note "No node on this server"
    echo ""
    ui_section "Other"
    ui_kv "/etc/letsencrypt" "$(du -sh /etc/letsencrypt 2>/dev/null | cut -f1 || echo "not found")"
    ui_kv "/etc/nginx" "$(du -sh /etc/nginx 2>/dev/null | cut -f1 || echo "not found")"
    echo ""
    ui_note "Excluded from archives: assets/*, xray-core/*, backup/*, geoip.dat, geosite.dat, xray binary."
    ui_pause
}

# ─── Main menu ───────────────────────────────────────────────────────────────
backup_menu() {
    init_backup_logging
    local opt
    while true; do
        setup_env
        ui_header "Backup & Restore" "$BACKUP_DIR"
        local BACKUP_COUNT LAST_FILE
        BACKUP_COUNT=$(ls "$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l)
        LAST_FILE=$(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | grep -v '/pre_restore_' | head -1)
        if [ -n "$LAST_FILE" ]; then
            ui_kv_state "Last backup" ok "$(date -r "$LAST_FILE" '+%Y-%m-%d %H:%M' 2>/dev/null)" "$(basename "$LAST_FILE") · $(du -h "$LAST_FILE" | cut -f1)"
        else
            ui_kv_state "Last backup" bad "None yet"
        fi
        ui_kv "Archives" "$BACKUP_COUNT"
        if [ -f "$TG_CONFIG" ]; then ui_kv_state "Telegram" ok "Configured"; else ui_kv_state "Telegram" off "Not configured"; fi
        if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH"; then
            ui_kv_state "Schedule" ok "Active" "$(crontab -l 2>/dev/null | grep "$SCRIPT_PATH" | awk '{print $1" "$2" "$3" "$4" "$5}' | head -1)"
        else
            ui_kv_state "Schedule" off "Not scheduled"
        fi
        echo ""
        ui_menu_title "Backups"
        ui_menu_item 1 "Create backup now"
        ui_menu_item 2 "Restore from backup"
        ui_menu_item 3 "List backups"
        ui_menu_item 4 "Delete a backup"
        ui_menu_item 5 "Backup schedule" "cron"
        echo ""
        ui_menu_title "Telegram"
        ui_menu_item 6 "Set up Telegram bot"
        ui_menu_item 7 "Send test message"
        ui_menu_item 8 "Remove Telegram settings"
        echo ""
        ui_menu_title "Maintenance"
        ui_menu_item 9 "Run smart fix" "permissions, paths, xray-core"
        ui_menu_item 10 "View logs"
        ui_menu_item 11 "Analyze backup size"
        ui_menu_back
        ui_select opt
        case $opt in
            1) do_backup "manual" ;;
            2) do_restore ;;
            3) list_backups ;;
            4) delete_backup ;;
            5) setup_cron ;;
            6) setup_telegram ;;
            7) test_telegram; ui_pause ;;
            8) remove_telegram_settings ;;
            9) ui_header "Smart Fix" "firewall · .env · compose IPs · node certificate · nginx"; apply_smart_fix; ui_pause ;;
            10) view_backup_logs ;;
            11) debug_backup_size ;;
            0) return ;;
            *) ui_invalid ;;
        esac
    done
}
