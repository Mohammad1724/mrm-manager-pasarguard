#!/bin/bash
# MRM Backup - Backup Core Module
# Main backup logic: export DB, backup files, create archive, send to Telegram

# ==========================================
# Backup v1.1.9
# ==========================================
do_backup() {
    local MODE="${1:-manual}"
    setup_env
    init_backup_logging

    # ui_header clears only on a real TTY — no extra clear here (MRM-054)
    [ "$MODE" != "auto" ] && ui_header "BACKUP v${BACKUP_VERSION}"

    log_backup "INFO" "========== Starting backup $MRM_BACKUP_VERSION mode: $MODE =========="
    log_backup "INFO" "PANEL_DIR: $PANEL_DIR DATA_DIR: $DATA_DIR"

    local TS
    local B_NAME
    local B_PATH
    local ARCHIVE_BASE
    local ARCHIVE_PATH
    local COPY_NUMBER=2

    TS="$(date +%Y%m%d_%H%M%S)"
    B_NAME="MRM_V1_${TS}"
    B_PATH="$TEMP_BASE/$B_NAME"
    ARCHIVE_BASE="MRM-${TS/_/-}"

    # Always clean temp first (avoid leftovers)
    [[ -n "$TEMP_BASE" ]] && rm -rf "$TEMP_BASE" 2>/dev/null
    mkdir -p "$B_PATH/database" "$B_PATH/panel" "$B_PATH/data" "$B_PATH/node"
    mkdir -p "$BACKUP_DIR"

    ARCHIVE_PATH="$BACKUP_DIR/${ARCHIVE_BASE}.tar.gz"
    while [ -e "$ARCHIVE_PATH" ]; do
        ARCHIVE_PATH="$BACKUP_DIR/${ARCHIVE_BASE}-${COPY_NUMBER}.tar.gz"
        COPY_NUMBER=$((COPY_NUMBER + 1))
    done

    # 1. Export Database - Core of backup
    [ "$MODE" != "auto" ] && ui_spinner_start "Exporting database..."
    local DB_SUCCESS=false
    local DB_SIZE="0"
    local DB_RAW_PATH=""

    if mrm_backup_database "$B_PATH/database"; then
        DB_SUCCESS=true
        DB_RAW_PATH="$DB_BACKUP_FILE"
        DB_SIZE=$(du -h "$DB_RAW_PATH" 2>/dev/null | cut -f1)
        log_backup "INFO" "DB exported: $DB_BACKUP_DESC ($DB_SIZE)"
        # Compress SQL dumps (postgres/mysql); sqlite stays raw (already compact)
        if [[ "$DB_RAW_PATH" == *.sql ]]; then
            if gzip -9 -c "$DB_RAW_PATH" > "$B_PATH/database/db.sql.gz"; then
                rm -f "$DB_RAW_PATH"
                DB_BACKUP_FILE="$B_PATH/database/db.sql.gz"
                DB_BACKUP_DESC="$DB_BACKUP_DESC (gzip -9)"
                log_backup "INFO" "DB compressed -> $(du -h "$DB_BACKUP_FILE" | cut -f1)"
            fi
        fi
        [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "Database exported ($DB_SIZE) [$DB_BACKUP_DESC]"
    else
        [ "$MODE" != "auto" ] && ui_spinner_stop && ui_error "Database export FAILED!"
        log_backup "ERROR" "Database export failed - backup will NOT contain the DB"
    fi

    if [ "$DB_SUCCESS" = false ] && [ "$MODE" != "auto" ]; then
        echo ""
        echo -e "${RED}⚠️  WARNING: Database export failed!${NC}"
        echo -e "${YELLOW}Backup will be created WITHOUT database.${NC}"
        echo -e "${YELLOW}You can still restore panel files but users will be lost.${NC}\n"
        read -p "Continue anyway? (y/N): " CONT
        if [[ ! "$CONT" =~ ^[Yy]$ ]]; then
            [[ -n "$TEMP_BASE" ]] && rm -rf "$TEMP_BASE" 2>/dev/null
            return
        fi
    fi

    # 2. Panel Essentials - ONLY what's needed
    [ "$MODE" != "auto" ] && ui_spinner_start "Backing up panel essentials..."
    
    # .env - most important
    if [ -f "$PANEL_ENV" ]; then
        cp "$PANEL_ENV" "$B_PATH/panel/.env" 2>/dev/null
        log_backup "INFO" "Copied PANEL_ENV"
    fi

    # docker-compose.yml - essential
    local PANEL_COMPOSE
    PANEL_COMPOSE="$(get_existing_compose_file panel 2>/dev/null || true)"
    if [ -n "$PANEL_COMPOSE" ] && [ -f "$PANEL_COMPOSE" ]; then
        cp "$PANEL_COMPOSE" "$B_PATH/panel/" 2>/dev/null
        log_backup "INFO" "Copied compose: $PANEL_COMPOSE"
    fi

    # templates - if customized
    if [ -d "$DATA_DIR/templates" ]; then
        mkdir -p "$B_PATH/data/templates"
        cp -a "$DATA_DIR/templates/." "$B_PATH/data/templates/" 2>/dev/null
        log_backup "INFO" "Copied templates"
    fi

    # certs - PasarGuard stores certs here, NOT in /etc/letsencrypt
    if [ -d "$DATA_DIR/certs" ]; then
        mkdir -p "$B_PATH/data/certs"
        cp -a "$DATA_DIR/certs/." "$B_PATH/data/certs/" 2>/dev/null
        log_backup "INFO" "Copied certs: $(du -sh "$DATA_DIR/certs" 2>/dev/null | cut -f1)"
    fi

    # xray_config.json if custom
    if [ -f "$DATA_DIR/xray_config.json" ]; then
        cp "$DATA_DIR/xray_config.json" "$B_PATH/data/" 2>/dev/null
    fi

    [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "Panel essentials backed up"

    # 3. Node Essentials - certs, .env, compose (+ xray-core & geo assets OPTIONAL).
    #    Default (MRM_BACKUP_XRAY unset/0): EXCLUDE xray binary & geo files so the
    #    backup stays small (~3-5MB, Telegram-safe). Restore auto-downloads them.
    #    Set MRM_BACKUP_XRAY=1 to include them for a fully OFFLINE self-contained
    #    restore (bigger backup ~40-50MB - may exceed the 50MB Telegram limit).
    local NODE_DATA_DIR
    NODE_DATA_DIR="$(dirname "$NODE_DEF_CERTS" 2>/dev/null)"
    [ -z "$NODE_DATA_DIR" ] && NODE_DATA_DIR="/var/lib/pg-node"
    if [ -d "$NODE_DIR" ] || [ -d "$NODE_DATA_DIR" ]; then
        [ "$MODE" != "auto" ] && ui_spinner_start "Backing up node essentials..."
        mkdir -p "$B_PATH/node"

        # .env
        if [ -f "$NODE_ENV" ]; then
            cp "$NODE_ENV" "$B_PATH/node/.env" 2>/dev/null
        fi

        # compose
        local NODE_COMPOSE_FILE
        NODE_COMPOSE_FILE="$(get_existing_compose_file node 2>/dev/null || true)"
        if [ -n "$NODE_COMPOSE_FILE" ] && [ -f "$NODE_COMPOSE_FILE" ]; then
            cp "$NODE_COMPOSE_FILE" "$B_PATH/node/" 2>/dev/null
        fi

        # certs
        if [ -d "$NODE_DEF_CERTS" ] && [ -n "$(ls -A "$NODE_DEF_CERTS" 2>/dev/null)" ]; then
            mkdir -p "$B_PATH/node/certs"
            cp -a "$NODE_DEF_CERTS/." "$B_PATH/node/certs/" 2>/dev/null
            log_backup "INFO" "Copied node certs"
        fi

        # xray-core binary + geo assets - only when MRM_BACKUP_XRAY=1 (offline restore)
        if [ "${MRM_BACKUP_XRAY:-0}" = "1" ]; then
            if [ -d "$NODE_DATA_DIR/xray-core" ] && [ -n "$(ls -A "$NODE_DATA_DIR/xray-core" 2>/dev/null)" ]; then
                mkdir -p "$B_PATH/node/xray-core"
                cp -a "$NODE_DATA_DIR/xray-core/." "$B_PATH/node/xray-core/" 2>/dev/null
                log_backup "INFO" "Copied node xray-core ($(du -sh "$NODE_DATA_DIR/xray-core" 2>/dev/null | cut -f1))"
            fi
            if [ -d "$NODE_DATA_DIR/assets" ] && [ -n "$(ls -A "$NODE_DATA_DIR/assets" 2>/dev/null)" ]; then
                mkdir -p "$B_PATH/node/assets"
                cp -a "$NODE_DATA_DIR/assets/." "$B_PATH/node/assets/" 2>/dev/null
                log_backup "INFO" "Copied node assets/geo ($(du -sh "$NODE_DATA_DIR/assets" 2>/dev/null | cut -f1))"
            fi
        else
            log_backup "INFO" "xray-core/geo excluded (MRM_BACKUP_XRAY=0) - restore will auto-download"
        fi

        [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "Node essentials backed up"
    fi

    # 4. Nginx - ONLY panel_separate.conf, NOT full /etc/nginx
    if [ -f "/etc/nginx/conf.d/panel_separate.conf" ]; then
        mkdir -p "$B_PATH/nginx"
        cp "/etc/nginx/conf.d/panel_separate.conf" "$B_PATH/nginx/" 2>/dev/null
        log_backup "INFO" "Copied nginx panel_separate.conf (not full nginx)"
    fi

    # 4b. Let's Encrypt certificates (small ~5KB per domain)
    # Needed so post-restore can copy them to /etc/letsencrypt/live/ for Nginx
    if [ -d "/etc/letsencrypt/live" ]; then
        local LETS_COUNT=$(find /etc/letsencrypt/live -name "fullchain.pem" 2>/dev/null | wc -l)
        if [ "$LETS_COUNT" -gt 0 ] 2>/dev/null; then
            mkdir -p "$B_PATH/letsencrypt"
            for CERT_DIR in /etc/letsencrypt/live/*/; do
                [ -d "$CERT_DIR" ] || continue
                local DOMAIN_NAME=$(basename "$CERT_DIR")
                mkdir -p "$B_PATH/letsencrypt/$DOMAIN_NAME"
                [ -f "$CERT_DIR/fullchain.pem" ] && cp "$CERT_DIR/fullchain.pem" "$B_PATH/letsencrypt/$DOMAIN_NAME/" 2>/dev/null
                [ -f "$CERT_DIR/privkey.pem" ] && cp "$CERT_DIR/privkey.pem" "$B_PATH/letsencrypt/$DOMAIN_NAME/" 2>/dev/null
                [ -f "$CERT_DIR/chain.pem" ] && cp "$CERT_DIR/chain.pem" "$B_PATH/letsencrypt/$DOMAIN_NAME/" 2>/dev/null
            done
            log_backup "INFO" "Copied Let's Encrypt certs for $LETS_COUNT domains (small, ~5KB each)"
        fi
    fi

    # 5. CLEANUP - Remove any heavy files that accidentally slipped in
    # This is the FIX for the 31MB issue you reported
    [ "$MODE" != "auto" ] && ui_spinner_start "Cleaning unnecessary heavy files..."

    # Remove backup loops
    rm -rf "$B_PATH/panel/backup" 2>/dev/null
    rm -rf "$B_PATH/data/backup" 2>/dev/null
    rm -rf "$B_PATH/panel/backups" 2>/dev/null
    rm -rf "$B_PATH/data/backups" 2>/dev/null
    find "$B_PATH" -type f -name "backup.zip" -delete 2>/dev/null
    find "$B_PATH" -type f -name "*.tar.gz" -path "*backup*" -delete 2>/dev/null
    find "$B_PATH" -type f -name "MRM_*.tar.gz" -delete 2>/dev/null

    # Remove Xray heavy files from PANEL/data copies (never needed there).
    # node/xray-core + node/assets are stripped by default (small backup);
    # kept only when MRM_BACKUP_XRAY=1 (offline self-contained restore).
    rm -rf "$B_PATH/node-data" 2>/dev/null
    rm -rf "$B_PATH/data/assets" 2>/dev/null
    rm -rf "$B_PATH/data/xray-core" 2>/dev/null
    rm -rf "$B_PATH/panel/assets" 2>/dev/null
    rm -rf "$B_PATH/panel/xray-core" 2>/dev/null
    find "$B_PATH/data" -type f \( -name "geoip.dat" -o -name "geosite.dat" -o -name "xray" \) -delete 2>/dev/null
    find "$B_PATH/panel" -type f \( -name "geoip.dat" -o -name "geosite.dat" -o -name "xray" \) -delete 2>/dev/null
    if [ "${MRM_BACKUP_XRAY:-0}" != "1" ]; then
        rm -rf "$B_PATH/node/assets" 2>/dev/null
        rm -rf "$B_PATH/node/xray-core" 2>/dev/null
        find "$B_PATH/node" -type f \( -name "geoip.dat" -o -name "geosite.dat" -o -name "xray" \) -delete 2>/dev/null
    fi

    # Remove logs, cache, tmp
    find "$B_PATH" -type f -name "*.log" -delete 2>/dev/null
    find "$B_PATH" -type f -name "*.tmp" -delete 2>/dev/null
    find "$B_PATH" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
    find "$B_PATH" -type d -name ".git" -exec rm -rf {} + 2>/dev/null || true
    find "$B_PATH" -type f -name "*.sqlite-wal" -delete 2>/dev/null
    find "$B_PATH" -type f -name "*.sqlite-shm" -delete 2>/dev/null
    find "$B_PATH" -type f -name "*.sock" -delete 2>/dev/null

    [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "Heavy files cleaned (fixed 31MB issue)"

    # 6. Metadata
    local SERVER_IP=$(get_server_ip)
    local TOTAL_RAW_SIZE=$(du -sh "$B_PATH" 2>/dev/null | cut -f1)
    
    cat > "$B_PATH/backup_info.txt" << EOF
========================================
MRM BACKUP  - $MRM_BACKUP_VERSION
========================================
Backup Date: $(date '+%Y-%m-%d %H:%M:%S')
Hostname: $(hostname)
Server IP: $SERVER_IP
Panel: $(basename "$PANEL_DIR")
Panel Dir: $PANEL_DIR
Data Dir: $DATA_DIR
Node Dir: $NODE_DIR
Database Exported: $DB_SUCCESS
Database Size: $DB_SIZE
Database Type: ${DB_BACKUP_DESC:-N/A}
Raw Size Before Compression: $TOTAL_RAW_SIZE
Version: $MRM_BACKUP_VERSION
Backup profile: v${BACKUP_VERSION}
Changes included in this backup profile:
- Excluded panel/backup/backup.zip recursive loop
- Excluded /etc/letsencrypt full (20MB) -> only data/certs
- Excluded /etc/nginx full (5MB) -> only panel_separate.conf
- Added gzip -9 for DB
- xray binary + geo files EXCLUDED by default -> small backup (~3-5MB)
- Restore auto-downloads xray + geo (needs internet on the target server)
- Set MRM_BACKUP_XRAY=1 to embed them for a fully offline restore (bigger backup)
EOF

    cat > "$B_PATH/file_list.txt" << EOF
=== Files in v${BACKUP_VERSION} Backup ===
$(find "$B_PATH" -type f | sort)
EOF

    cat > "$B_PATH/restore_guide.txt" << EOF
MRM BACKUP v${BACKUP_VERSION} - RESTORE GUIDE
=========================================

Auto Restore (Recommended):
1. mrm -> Backup & Restore -> Restore from Backup
2. Select this file
3. Done! Script will:
   - Stop services
   - Create safety backup
   - Restore .env, compose, certs, templates
   - Fix IPs for new server
   - Restore database (with gunzip if needed)
   - Start services
   - Apply smart fixes

Manual Restore (if needed):
1. Extract: tar -xzf MRM-*.tar.gz -C /tmp/
2. Panel:
   cp /tmp/MRM_V1_*/panel/.env $PANEL_DIR/.env
   cp /tmp/MRM_V1_*/panel/*.yml $PANEL_DIR/
3. Data:
   cp -a /tmp/MRM_V1_*/data/certs/* $DATA_DIR/certs/
   cp -a /tmp/MRM_V1_*/data/templates/* $DATA_DIR/templates/
4. Node (if exists):
   cp /tmp/MRM_V1_*/node/.env $NODE_DIR/.env
   cp -a /tmp/MRM_V1_*/node/certs/* /var/lib/pg-node/certs/
5. Database PostgreSQL:
   DB_CONTAINER=\$(docker ps --format '{{.Names}}' | grep -xE 'pasarguard-(postgresql|timescaledb)-[0-9]+' | head -1)
   [ -z "\$DB_CONTAINER" ] && DB_CONTAINER=\$(docker ps --format '{{.Names}}' | grep -iE "postgres|timescale" | head -1)
   gunzip -c /tmp/MRM_V1_*/database/db.sql.gz | docker exec -i "\$DB_CONTAINER" psql -U "\${DB_USER:-pasarguard}" -d "\${DB_NAME:-pasarguard}"
   (Use DB_USER/DB_NAME from /opt/pasarguard/.env — installs may use non-default names.)
   Or SQLite (PasarGuard v5 keeps it INSIDE the panel container at /code/db.sqlite3):
   PANEL_CONT=\$(docker ps --format '{{.ID}}|{{.Image}}' | awk -F'|' '\$2 ~ /^pasarguard\/panel(:|\$)/ {print \$1; exit}')
   docker cp /tmp/MRM_V1_*/database/db.sqlite3 "\${PANEL_CONT}:/tmp/restore.sqlite3"
   docker exec -i "\${PANEL_CONT}" python -c "
import sqlite3
src=sqlite3.connect('/tmp/restore.sqlite3')
dst=sqlite3.connect('/code/db.sqlite3')
src.backup(dst); dst.close(); src.close()"
6. Restart:
   cd $PANEL_DIR && docker compose up -d

Note: This v${BACKUP_VERSION} backup does NOT contain the node xray binary or
geo files (kept small for Telegram). On restore, MRM re-downloads them
automatically - no manual steps, but the target server needs internet.
(Set MRM_BACKUP_XRAY=1 to embed them for a fully offline restore; backup will
be ~40-50MB and may exceed the 50MB Telegram upload limit.)

EOF

    # 7. Create archive with maximum compression + excludes (double safety)
    [ "$MODE" != "auto" ] && ui_spinner_start "Creating v${BACKUP_VERSION} archive (high compression)..."

    local SIZE_BEFORE=$(du -sb "$B_PATH" | cut -f1)

    # Excludes for tar (extra safety even though we already cleaned)
    local EXCLUDE_ARGS=(
        --exclude='*backup.zip'
        --exclude='*backup/*.zip'
        --exclude='*/backup/*'
        --exclude='*backups/*'
        --exclude='*.log'
        --exclude='*.tmp'
        --exclude='*.pid'
        --exclude='__pycache__'
        --exclude='*.pyc'
        --exclude='.git'
        --exclude='node_modules'
        --exclude='*.sqlite-wal'
        --exclude='*.sqlite-shm'
        --exclude='*.sock'
        --exclude='*MRM_*.tar.gz'
    )
    # Strip xray/geo only when they are excluded from the backup (default).
    if [ "${MRM_BACKUP_XRAY:-0}" != "1" ]; then
        EXCLUDE_ARGS+=(
            --exclude='*/assets/*'
            --exclude='*/xray-core/*'
            --exclude='*geoip.dat'
            --exclude='*geosite.dat'
            --exclude='*geodata*'
            --exclude='*/xray'
            --exclude='*xray-core'
        )
    fi

    if tar -czf "$ARCHIVE_PATH" "${EXCLUDE_ARGS[@]}" -C "$TEMP_BASE" "$B_NAME" 2>/dev/null; then
        local BACKUP_SIZE=$(du -h "$ARCHIVE_PATH" | cut -f1)
        local BACKUP_SIZE_BYTES=$(stat -c%s "$ARCHIVE_PATH" 2>/dev/null || echo "0")
        local SAVED_PERCENT=0
        if [ "$SIZE_BEFORE" -gt 0 ]; then
            SAVED_PERCENT=$((100 - BACKUP_SIZE_BYTES * 100 / SIZE_BEFORE))
        fi
        [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "v${BACKUP_VERSION} archive created ($BACKUP_SIZE, saved ${SAVED_PERCENT}% raw)"
    else
        [ "$MODE" != "auto" ] && ui_spinner_stop && ui_error "Failed to create archive!"
        log_backup "ERROR" "Failed to create tar.gz"
        [[ -n "$TEMP_BASE" ]] && rm -rf "$TEMP_BASE" 2>/dev/null
        return 1
    fi

    # 8. Cleanup temp
    [[ -n "$TEMP_BASE" ]] && rm -rf "$TEMP_BASE" 2>/dev/null

    # 9. Send to Telegram - Now small and fast
    local FINAL_SIZE=$(du -h "$ARCHIVE_PATH" | cut -f1)
    if [ -f "$TG_CONFIG" ]; then
        [ "$MODE" != "auto" ] && ui_spinner_start "Sending v${BACKUP_VERSION} backup to Telegram ($FINAL_SIZE)..."
        if send_to_telegram "$ARCHIVE_PATH"; then
            [ "$MODE" != "auto" ] && ui_spinner_stop && ui_success "v${BACKUP_VERSION} backup sent to Telegram! ($FINAL_SIZE)"
        else
            log_backup "WARNING" "Telegram send failed (mode=$MODE) for $(basename "$ARCHIVE_PATH")"
            [ "$MODE" != "auto" ] && ui_spinner_stop && ui_warning "Telegram send failed - check log. Size: $FINAL_SIZE"
        fi
        # Loud warning when the DB is missing (how the 39KB backups happened)
        if [ "$DB_SUCCESS" = false ]; then
            send_to_telegram "" "⚠️ MRM Backup created WITHOUT DATABASE!
File: $(basename "$ARCHIVE_PATH") ($FINAL_SIZE)
Reason: Database export failed - see /var/log/mrm-backup.log
Check: SQLite lives inside the panel container in PasarGuard v5." >/dev/null 2>&1 || true
            log_backup "ERROR" "Backup has NO DATABASE - sent Telegram warning"
        fi
    fi

    # 10. Rotate old backups - keep last 7
    ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | tail -n +8 | xargs rm -f 2>/dev/null || true

    log_backup "SUCCESS" "v${BACKUP_VERSION} backup completed: $(basename "$ARCHIVE_PATH") ($FINAL_SIZE)"
    log_backup "INFO" "========== Backup v${BACKUP_VERSION} finished =========="

    if [ "$MODE" != "auto" ]; then
        echo ""
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║          ✔ BACKUP v${BACKUP_VERSION} COMPLETED!                ║${NC}"
        echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${GREEN}║${NC} File: ${CYAN}$(basename "$ARCHIVE_PATH")${NC}"
        echo -e "${GREEN}║${NC} Size: ${CYAN}$FINAL_SIZE${NC}"
        echo -e "${GREEN}║${NC} Raw Size: $TOTAL_RAW_SIZE -> Compressed: $FINAL_SIZE"
        if [ "$DB_SUCCESS" = false ]; then
            echo -e "${GREEN}║${NC} Database: ${RED}NOT EXPORTED${NC}"
        else
            echo -e "${GREEN}║${NC} Database: ${GREEN}Exported${NC} ($DB_SIZE) [${DB_BACKUP_DESC}]"
        fi
        if [ "${MRM_BACKUP_XRAY:-0}" = "1" ]; then
            echo -e "${GREEN}║${NC} xray/geo: ${GREEN}included (offline restore)${NC}"
        else
            echo -e "${GREEN}║${NC} xray/geo: ${YELLOW}excluded - auto-download on restore${NC}"
        fi
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
                echo ""
        pause
    fi
}

