#!/bin/bash
# MRM Backup - Menu & Entry Point Module
# Backup menu, cron scheduler, list/delete backups, debug

# ==========================================
# OTHER UTILITIES
# ==========================================
setup_cron() {
    clear
    ui_header "BACKUP SCHEDULER - v${BACKUP_VERSION}"
    echo "Current cron status:"
    if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH"; then
        local CURRENT
        CURRENT="$(crontab -l 2>/dev/null | grep "$SCRIPT_PATH")"
        echo -e "${GREEN}Active:${NC} $CURRENT"
    else
        echo -e "${YELLOW}No scheduled backup${NC}"
    fi
    echo ""
    echo "Select backup interval (v${BACKUP_VERSION}):"
    echo "1) Every 6 hours"
    echo "2) Every 12 hours"
    echo "3) Every 24 hours (Daily) [Recommended]"
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
        if [ -n "$CRON_TIME" ]; then
            ui_success "Scheduled v${BACKUP_VERSION} backup enabled: $CRON_TIME"
            log_backup "INFO" "Cron scheduled: $CRON_TIME"
        else
            ui_success "Scheduled backup disabled"
            log_backup "INFO" "Cron disabled"
        fi
    else
        rm -f "$TMP_CRON"
        ui_error "Failed to install crontab"
        log_backup "ERROR" "Failed to install crontab"
        pause
        return 1
    fi
    pause
}

view_backup_logs() {
    clear
    ui_header "BACKUP LOGS - v${BACKUP_VERSION}"
    if [ -f "$BACKUP_LOG" ]; then echo -e "${YELLOW}Last 50 entries:${NC}\n"; tail -n 50 "$BACKUP_LOG"; else ui_warning "No logs found"; fi
    pause
}

list_backups() {
    clear
    ui_header "AVAILABLE BACKUPS - v${BACKUP_VERSION}"
    local FILES=($(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null))
    if [ ${#FILES[@]} -eq 0 ]; then ui_warning "No backups found"; pause; return; fi
    echo -e "${GREEN}ID │ Type       │ Filename                              │ Size   │ Date${NC}"
    echo "───┼────────────┼─────────────────────────────────────────┼────────┼───────────"
    for i in "${!FILES[@]}"; do
        local NAME=$(basename "${FILES[$i]}")
        local SIZE=$(du -h "${FILES[$i]}" | cut -f1)
        local DATE=$(stat -c %y "${FILES[$i]}" | cut -d' ' -f1)
        local TYPE="v${BACKUP_VERSION}"
        [[ "$NAME" == *"Full"* ]] && TYPE="FULL-OLD"
        [[ "$NAME" == *"Lite"* ]] && TYPE="LITE-OLD"
        [[ "$NAME" == *"V1"* ]] && TYPE="v${BACKUP_VERSION}"
        printf "%-2s │ %-10s │ %-39s │ %-6s │ %s\n" "$((i+1))" "$TYPE" "$NAME" "$SIZE" "$DATE"
    done
    echo ""
    echo -e "Total: ${CYAN}${#FILES[@]}${NC} backups"
    echo -e "Location: ${CYAN}$BACKUP_DIR${NC}"
    echo -e "Version: ${CYAN}$MRM_BACKUP_VERSION${NC}"
    echo ""
    echo -e "${YELLOW}Tip: v${BACKUP_VERSION} backups are ready for Telegram${NC}"
    pause
}

delete_backup() {
    clear
    ui_header "DELETE BACKUP"
    local FILES=($(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null))
    if [ ${#FILES[@]} -eq 0 ]; then ui_warning "No backups found"; pause; return; fi
    echo -e "${YELLOW}Select backup to delete:${NC}\n"
    for i in "${!FILES[@]}"; do
        local SIZE=$(du -h "${FILES[$i]}" | cut -f1)
        echo "$((i+1))) $(basename "${FILES[$i]}") [$SIZE]"
    done
    echo ""
    read -p "Select (0 to cancel): " SEL
    [ "$SEL" == "0" ] && return
    local SELECTED="${FILES[$((SEL-1))]}"
    if [ -z "$SELECTED" ]; then ui_error "Invalid selection"; pause; return; fi
    echo ""
    read -p "Delete $(basename "$SELECTED")? (y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then rm -f "$SELECTED"; ui_success "Backup deleted"; log_backup "INFO" "Deleted backup: $(basename "$SELECTED")"; else echo "Cancelled"; fi
    pause
}

debug_backup_size() {
    clear
    ui_header "BACKUP SIZE ANALYZER - v${BACKUP_VERSION}"
    setup_env
    echo -e "${CYAN}Analyzing current data sizes (find 31MB cause):${NC}\n"
    echo -e "${YELLOW}=== PANEL_DIR ($PANEL_DIR) ===${NC}"
    if [ -d "$PANEL_DIR" ]; then
        echo "Total: $(du -sh "$PANEL_DIR" 2>/dev/null | cut -f1)"
        du -sh "$PANEL_DIR"/* 2>/dev/null | sort -rh | head -n 20
        echo ""
        if [ -d "$PANEL_DIR/backup" ]; then
            echo -e "${RED}FOUND backup folder (LOOP CAUSE):${NC}"
            du -sh "$PANEL_DIR/backup"/* 2>/dev/null | head -n 20
            ls -lh "$PANEL_DIR/backup/" 2>/dev/null | head -n 20
            echo ""
        fi
    else
        echo "Not found"
    fi
    echo -e "${YELLOW}=== DATA_DIR ($DATA_DIR) ===${NC}"
    if [ -d "$DATA_DIR" ]; then
        echo "Total: $(du -sh "$DATA_DIR" 2>/dev/null | cut -f1)"
        du -sh "$DATA_DIR"/* 2>/dev/null | sort -rh | head -n 20
    else
        echo "Not found"
    fi
    echo ""
    echo -e "${YELLOW}=== NODE_DIR ($NODE_DIR) & NODE_DATA ===${NC}"
    if [ -d "$NODE_DIR" ]; then
        echo "NODE_DIR Total: $(du -sh "$NODE_DIR" 2>/dev/null | cut -f1)"
        du -sh "$NODE_DIR"/* 2>/dev/null | sort -rh | head -n 20
        echo ""
    fi
    local NODE_DATA_DIR="$(dirname "$NODE_DEF_CERTS")"
    if [ -d "$NODE_DATA_DIR" ]; then
        echo "NODE_DATA_DIR ($NODE_DATA_DIR) Total: $(du -sh "$NODE_DATA_DIR" 2>/dev/null | cut -f1)"
        du -sh "$NODE_DATA_DIR"/* 2>/dev/null | sort -rh | head -n 30
        echo ""
        if [ -d "$NODE_DATA_DIR/assets" ]; then
            echo -e "${RED}FOUND assets (HEAVY - geoip.dat):${NC}"
            ls -lh "$NODE_DATA_DIR/assets/" 2>/dev/null
            echo ""
        fi
        if [ -d "$NODE_DATA_DIR/xray-core" ]; then
            echo -e "${RED}FOUND xray-core (HEAVY - xray binary):${NC}"
            ls -lh "$NODE_DATA_DIR/xray-core/" 2>/dev/null
            echo ""
        fi
    fi
    echo -e "${YELLOW}=== /etc/letsencrypt ===${NC} $(du -sh /etc/letsencrypt 2>/dev/null | cut -f1 || echo "Not found")"
    echo -e "${YELLOW}=== /etc/nginx ===${NC} $(du -sh /etc/nginx 2>/dev/null | cut -f1 || echo "Not found")"
    echo ""
    echo -e "${GREEN}=== v${BACKUP_VERSION} ===${NC}"
    echo -e "Exclude: assets/*, xray-core/*, backup/*, geoip.dat, geosite.dat, xray binary"
    echo -e "Result: 31MB -> 2-5MB"
    echo ""
    pause
}

# ==========================================
# Main menu
# ==========================================
backup_menu() {
    init_backup_logging
    while true; do
        clear
        ui_header "BACKUP & RESTORE"
        setup_env
        local BACKUP_COUNT=$(ls "$BACKUP_DIR"/*.tar.gz 2>/dev/null | wc -l)
        local TG_STATUS="${RED}Not Configured${NC}"
        [ -f "$TG_CONFIG" ] && TG_STATUS="${GREEN}Configured${NC}"
        local CRON_STATUS="${RED}Disabled${NC}"
        crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH" && CRON_STATUS="${GREEN}Active${NC}"
        local SERVER_IP=$(get_server_ip)
        local LAST_SIZE="None"
        local LAST_FILE=$(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | head -1)
        [ -n "$LAST_FILE" ] && LAST_SIZE=$(du -h "$LAST_FILE" | cut -f1)

        echo -e "Panel: ${CYAN}$(basename "$PANEL_DIR")${NC} | IP: ${CYAN}$SERVER_IP${NC} | Version: ${CYAN}$MRM_BACKUP_VERSION${NC}"
        echo -e "Backups: ${CYAN}$BACKUP_COUNT${NC} | Last: ${CYAN}$LAST_SIZE${NC} | Telegram: $TG_STATUS | Cron: $CRON_STATUS"
        echo ""
        echo "1)  📦 Create Backup"
        echo "2)  📥 Restore from Backup"
        echo "3)  📋 List All Backups"
        echo "4)  🗑️  Delete Backup"
        echo "5)  🧑‍💻 Setup Telegram Bot"
        echo "6)  🧪 Test Telegram"
        echo "7)  ❌ Remove Telegram Settings"
        echo "8)  ⏰ Setup Cron Scheduler"
        echo "9)  🔧 Run Smart Fix Only"
        echo "10) 📋 View Logs"
        echo "11) 🔍 Analyze Size"
        echo ""
        echo "0)  ↩️  Back to Main"
        echo ""
        read -p "Select: " opt
        case $opt in
            1) do_backup "manual" ;;
            2) do_restore ;;
            3) list_backups ;;
            4) delete_backup ;;
            5) setup_telegram ;;
            6) test_telegram; pause ;;
            7) remove_telegram_settings ;;
            8) setup_cron ;;
            9) apply_smart_fix; pause ;;
            10) view_backup_logs ;;
            11) debug_backup_size ;;
            0) return ;;
            *) ui_error "Invalid option"; sleep 1 ;;
        esac
    done
}

# ==========================================
# ENTRY POINT
# ==========================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ "$1" == "auto" ]; then
        do_backup "auto"
    elif [ "$1" == "fix-node" ]; then
        # mrm fix-node [--verbose] : repair xray-core + geo files
        setup_env
        init_backup_logging

        FIX_VERBOSE=false
        [[ "$2" == "--verbose" ]] || [[ "$2" == "-v" ]] && FIX_VERBOSE=true
        export MRM_XRAY_VERBOSE="$FIX_VERBOSE"

        NODE_DATA_DIR="$(dirname "${NODE_DEF_CERTS:-/var/lib/pg-node/certs}" 2>/dev/null)"
        [ -z "$NODE_DATA_DIR" ] && NODE_DATA_DIR="/var/lib/pg-node"

        echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║  🔧 Node xray-core Repair Tool          ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${CYAN}Node data dir:${NC} $NODE_DATA_DIR"
        echo -e "  ${CYAN}Expected path:${NC} $NODE_DATA_DIR/xray-core/xray"
        echo -e "  ${CYAN}System arch:${NC}   $(uname -m)"
        echo -e "  ${CYAN}Verbose:${NC}       $FIX_VERBOSE"
        echo ""

        # Pre-flight checks
        echo -e "${YELLOW}Pre-flight checks:${NC}"
        if command -v curl >/dev/null 2>&1; then
            echo -e "  ${GREEN}✔${NC} curl: $(curl --version | head -1)"
        else
            echo -e "  ${RED}✘${NC} curl: NOT INSTALLED"
        fi
        if command -v unzip >/dev/null 2>&1; then
            echo -e "  ${GREEN}✔${NC} unzip: installed"
        else
            echo -e "  ${RED}✘${NC} unzip: NOT INSTALLED"
        fi
        if [ -x "$NODE_DATA_DIR/xray-core/xray" ]; then
            echo -e "  ${YELLOW}⚠${NC} xray binary exists but may be broken"
        else
            echo -e "  ${RED}✘${NC} xray binary: MISSING"
        fi
        echo ""

        echo -e "${YELLOW}Downloading/repairing xray-core...${NC}"
        if mrm_ensure_xray_core; then
            echo ""
            echo -e "${GREEN}✔ xray-core ready: $NODE_DATA_DIR/xray-core/xray${NC}"
            "$NODE_DATA_DIR/xray-core/xray" -version 2>/dev/null | head -1 && true
            echo ""
            echo -e "${YELLOW}Restarting node container...${NC}"
            NODE_CNAME="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -i node | head -1)"
            if [ -n "$NODE_CNAME" ]; then
                if docker restart "$NODE_CNAME" >/dev/null 2>&1; then
                    echo -e "${GREEN}✔ Node restarted: $NODE_CNAME${NC}"
                else
                    echo -e "${RED}✘ Node restart failed: $NODE_CNAME${NC}"
                fi
            else
                echo -e "${YELLOW}⚠ No node container found (is the node docker-compose running?)${NC}"
            fi
            exit 0
        else
            echo ""
            echo -e "${RED}╔══════════════════════════════════════════╗${NC}"
            echo -e "${RED}║  ✘ REPAIR FAILED                        ║${NC}"
            echo -e "${RED}╚══════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${YELLOW}Try these steps:${NC}"
            echo -e "  1. ${CYAN}mrm fix-node --verbose${NC}  (see detailed errors)"
            echo -e "  2. ${CYAN}apt install -y curl unzip${NC}  (ensure tools exist)"
            echo -e "  3. ${CYAN}curl -v https://github.com 2>&1 | head -5${NC}  (test internet)"
            echo -e "  4. Manual download:"
            echo -e "     ${CYAN}ARCH=$( [ "$(uname -m)" = "aarch64" ] && echo arm64-v8a || echo 64 )${NC}"
            echo -e "     ${CYAN}curl -L "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-\$ARCH.zip" -o /tmp/xray.zip${NC}"
            echo -e "     ${CYAN}unzip -o /tmp/xray.zip -d $NODE_DATA_DIR/xray-core/${NC}"
            echo -e "     ${CYAN}chmod +x $NODE_DATA_DIR/xray-core/xray${NC}"
            echo -e "     ${CYAN}docker restart \$(docker ps -a --format '{{.Names}}' | grep -i node | head -1)${NC}"
            echo ""
            echo -e "${YELLOW}Full log: $BACKUP_LOG${NC}"
            exit 1
        fi
    else
        backup_menu
    fi
fi
