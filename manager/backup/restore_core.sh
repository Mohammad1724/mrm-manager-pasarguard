#!/bin/bash
# MRM Backup - Restore Core Module
# Main restore logic: extract, safety backup, restore files, restore DB, start services

# ==========================================
# RESTORE v${BACKUP_VERSION}
# ==========================================
do_restore() {
    clear
    ui_header "RESTORE FROM BACKUP - v${BACKUP_VERSION}"
    setup_env
    init_backup_logging

    local FILES=($(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null))
    if [ ${#FILES[@]} -eq 0 ]; then
        ui_error "No backups found in $BACKUP_DIR"
        echo -e "Upload backup manually to $BACKUP_DIR or download from Telegram"
        pause
        return 1
    fi

    echo -e "${YELLOW}Select backup to restore:${NC}\n"
    for i in "${!FILES[@]}"; do
        local SIZE=$(du -h "${FILES[$i]}" | cut -f1)
        local DATE=$(stat -c %y "${FILES[$i]}" | cut -d' ' -f1)
        local TYPE="v${BACKUP_VERSION}"
        [[ "$(basename "${FILES[$i]}")" == *"Full"* ]] && TYPE="FULL-OLD"
        [[ "$(basename "${FILES[$i]}")" == *"Lite"* ]] && TYPE="LITE-OLD"
        [[ "$(basename "${FILES[$i]}")" == *"V1"* ]] && TYPE="v${BACKUP_VERSION}"
        echo "$((i+1))) [$TYPE] $(basename "${FILES[$i]}") [$SIZE] - $DATE"
    done
    echo ""
    read -p "Select (0 to cancel): " SEL
    [ "$SEL" == "0" ] && return
    local SELECTED="${FILES[$((SEL-1))]}"
    if [ -z "$SELECTED" ] || [ ! -f "$SELECTED" ]; then ui_error "Invalid selection"; pause; return 1; fi

    echo ""
    echo -e "${RED}⚠️  WARNING: This will overwrite current panel data!${NC}"
    echo -e "${YELLOW}Selected: $(basename "$SELECTED") ($(du -h "$SELECTED" | cut -f1))${NC}"
    echo -e "${CYAN}Safety backup will be created automatically.${NC}\n"
    read -p "Continue restore? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then echo "Cancelled"; pause; return; fi

    log_backup "INFO" "Starting restore v${BACKUP_VERSION} from: $(basename "$SELECTED")"

    local WORK_DIR="$TEMP_BASE/restore_$(date +%s)"
    mkdir -p "$WORK_DIR"
    
    # Cleanup trap
    trap 'rm -rf "$WORK_DIR"; trap - RETURN' RETURN

    ui_spinner_start "Extracting backup..."
    if ! tar -xzf "$SELECTED" -C "$WORK_DIR" 2>/dev/null; then
        ui_spinner_stop
        ui_error "Failed to extract backup! File may be corrupted."
        rm -rf "$WORK_DIR"
        trap - RETURN
        pause
        return 1
    fi
    ui_spinner_stop

    local ROOT=$(find "$WORK_DIR" -maxdepth 3 -type d -name "MRM_*" | head -1)
    if [ -z "$ROOT" ]; then ROOT=$(find "$WORK_DIR" -maxdepth 2 -type f -name "backup_info.txt" -printf "%h" | head -1); fi
    if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
        # Try to find any directory
        ROOT=$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)
    fi
    if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
        ui_error "Invalid backup structure - no root found"
        log_backup "ERROR" "Invalid backup structure"
        rm -rf "$WORK_DIR"
        trap - RETURN
        pause
        return 1
    fi

    log_backup "INFO" "Restore root: $ROOT"

    # Detect backup type
    local IS_V1=false IS_LITE=false IS_FULL=false
    if [[ "$(basename "$SELECTED")" == *"V1"* ]]; then IS_V1=true
    elif tar -tzf "$SELECTED" 2>/dev/null | grep -q "MRM_V1" || [ -f "$ROOT/backup_info.txt" ] && grep -q "V1" "$ROOT/backup_info.txt" 2>/dev/null; then IS_V1=true
    elif [[ "$(basename "$SELECTED")" == *"Full"* ]]; then IS_FULL=true
    else IS_LITE=true; fi

    # Show info if available
    if [ -f "$ROOT/backup_info.txt" ]; then
        echo -e "\n${CYAN}Backup Info:${NC}"
        cat "$ROOT/backup_info.txt"
        echo ""
    fi

    # =========================================================
    # 0) SAFETY BACKUP FIRST - while everything is STILL RUNNING.
    #    Includes a live export of the current database, so a failed
    #    restore can NEVER destroy the original data.
    # =========================================================
    ui_spinner_start "Creating safety backup (with live database)..."
    local SAFETY_BACKUP="$BACKUP_DIR/pre_restore_$(date +%Y%m%d_%H%M%S).tar.gz"
    local SAFETY_DIR="$TEMP_BASE/safety_$(date +%s)"
    mkdir -p "$SAFETY_DIR"
    local SAFETY_DB_OK=false
    if mrm_backup_database "$SAFETY_DIR" >/dev/null 2>&1; then
        if [ -n "$DB_BACKUP_FILE" ] && [ -f "$DB_BACKUP_FILE" ]; then
            mv -f "$DB_BACKUP_FILE" "$SAFETY_DIR/current_db_backup" 2>/dev/null
            SAFETY_DB_OK=true
            log_backup "INFO" "Safety backup includes live DB: $DB_BACKUP_DESC"
        fi
    else
        log_backup "WARN" "Could not export live DB for safety backup"
    fi
    local SAFETY_ITEMS=()
    [ -d "$PANEL_DIR" ] && SAFETY_ITEMS+=("$PANEL_DIR")
    [ -d "$DATA_DIR" ] && SAFETY_ITEMS+=("$DATA_DIR")
    [ -f "$PANEL_ENV" ] && SAFETY_ITEMS+=("$PANEL_ENV")
    [ -f "$SAFETY_DIR/current_db_backup" ] && SAFETY_ITEMS+=("$SAFETY_DIR/current_db_backup")
    if [ "${#SAFETY_ITEMS[@]}" -gt 0 ]; then
        if tar -czf "$SAFETY_BACKUP" "${SAFETY_ITEMS[@]}" 2>/dev/null; then
            ui_spinner_stop
            if [ "$SAFETY_DB_OK" = true ]; then
                ui_success "Safety backup incl. live DB: $(basename "$SAFETY_BACKUP")"
            else
                ui_warning "Safety backup created WITHOUT database"
            fi
            log_backup "INFO" "Safety backup created: $SAFETY_BACKUP (db=$SAFETY_DB_OK)"
            rm -rf "$SAFETY_DIR"
        else
            ui_spinner_stop
            ui_warning "Safety backup FAILED - keeping raw files for manual recovery:"
            if [ -f "$SAFETY_DIR/current_db_backup" ]; then
                local KEEP_DB="$BACKUP_DIR/pre_restore_db_$(date +%Y%m%d_%H%M%S)$(basename "$DB_BACKUP_FILE")"
                mv -f "$SAFETY_DIR/current_db_backup" "$KEEP_DB" 2>/dev/null
                echo -e "  ${RED}⚠ Raw DB saved: ${YELLOW}$KEEP_DB${NC}"
                log_backup "ERROR" "Safety tar failed; raw DB kept at $KEEP_DB"
            fi
        fi
    else
        ui_spinner_stop
        ui_warning "No existing data for safety backup"
        rm -rf "$SAFETY_DIR"
    fi

    # Stop services. We use `stop` (NOT `down`) so the container and its
    # writable layer are preserved - needed to copy the DB in/out safely.
    ui_spinner_start "Stopping services..."
    local PANEL_COMPOSE_FILE NODE_COMPOSE_FILE
    PANEL_COMPOSE_FILE="$(get_existing_compose_file panel 2>/dev/null || true)"
    NODE_COMPOSE_FILE="$(get_existing_compose_file node 2>/dev/null || true)"
    [ -n "$PANEL_COMPOSE_FILE" ] && run_compose_file "$PANEL_COMPOSE_FILE" stop >/dev/null 2>&1 || true
    [ -n "$NODE_COMPOSE_FILE" ] && run_compose_file "$NODE_COMPOSE_FILE" stop >/dev/null 2>&1 || true
    sleep 2
    ui_spinner_stop
    ui_success "Services stopped"

    # Restore based on type
    if [ "$IS_FULL" = true ]; then
        # FULL LEGACY RESTORE
        log_backup "INFO" "Restoring FULL legacy backup"
        ui_spinner_start "Restoring FULL backup files..."
        mkdir -p "$PANEL_DIR" "$DATA_DIR"
        # Remove old (except we already have safety)
        # For FULL, we restore everything but still exclude heavy files loop
        if [ -d "$ROOT/panel" ]; then cp -a "$ROOT/panel/." "$PANEL_DIR/" 2>/dev/null; fi
        if [ -d "$ROOT/data" ]; then cp -a "$ROOT/data/." "$DATA_DIR/" 2>/dev/null; fi
        if [ -d "$ROOT/node" ]; then
            mkdir -p "$NODE_DIR"
            cp -a "$ROOT/node/." "$NODE_DIR/" 2>/dev/null
        fi
        if [ -d "$ROOT/node-data" ]; then
            mkdir -p "$(dirname "$NODE_DEF_CERTS")"
            cp -a "$ROOT/node-data/." "$(dirname "$NODE_DEF_CERTS")/" 2>/dev/null
        fi
        if [ -d "$ROOT/ssl" ] && [ -n "$(ls -A "$ROOT/ssl" 2>/dev/null)" ]; then
            mkdir -p /etc/letsencrypt
            cp -a "$ROOT/ssl/." /etc/letsencrypt/ 2>/dev/null
        fi
        if [ -d "$ROOT/nginx" ] && [ -n "$(ls -A "$ROOT/nginx" 2>/dev/null)" ]; then
            mkdir -p /etc/nginx
            cp -a "$ROOT/nginx/." /etc/nginx/ 2>/dev/null
        fi
        # Safety net: Ensure node SSL certs exist (FULL restore)
        if [ -n "$NODE_DEF_CERTS" ]; then
            mkdir -p "$NODE_DEF_CERTS" 2>/dev/null
            if [ ! -f "$NODE_DEF_CERTS/ssl_cert.pem" ] || [ ! -f "$NODE_DEF_CERTS/ssl_key.pem" ]; then
                openssl req -x509 -newkey rsa:2048 \
                    -keyout "$NODE_DEF_CERTS/ssl_key.pem" \
                    -out "$NODE_DEF_CERTS/ssl_cert.pem" \
                    -days 3650 -nodes \
                    -subj "/CN=PasarGuard-Node" 2>/dev/null || true
                log_backup "INFO" "Generated self-signed SSL for node (FULL restore)"
            fi
        fi

        chmod -R 755 "$DATA_DIR" 2>/dev/null || true
        chown -R 1000:1000 "$DATA_DIR" 2>/dev/null || true
        ui_spinner_stop
        ui_success "FULL files restored"
    else
        # Restore essentials
        log_backup "INFO" "Restoring v${BACKUP_VERSION} essentials"
        ui_spinner_start "Restoring v${BACKUP_VERSION} essentials..."

        mkdir -p "$PANEL_DIR" "$DATA_DIR"

        # Panel .env
        if [ -f "$ROOT/panel/.env" ]; then
            cp "$ROOT/panel/.env" "$PANEL_ENV" 2>/dev/null
            log_backup "INFO" "Restored panel .env"
        fi

        # Panel compose
        local RESTORED_COMPOSE=false
        for f in "$ROOT/panel/"*.yml "$ROOT/panel/"*.yaml; do
            if [ -f "$f" ]; then
                cp "$f" "$PANEL_DIR/" 2>/dev/null
                RESTORED_COMPOSE=true
            fi
        done

        # Data templates
        if [ -d "$ROOT/data/templates" ]; then
            mkdir -p "$DATA_DIR/templates"
            cp -a "$ROOT/data/templates/." "$DATA_DIR/templates/" 2>/dev/null
            log_backup "INFO" "Restored templates"
        fi

        # Data certs
        if [ -d "$ROOT/data/certs" ]; then
            mkdir -p "$DATA_DIR/certs"
            cp -a "$ROOT/data/certs/." "$DATA_DIR/certs/" 2>/dev/null
            log_backup "INFO" "Restored certs"
        fi

        # xray_config.json if exists
        if [ -f "$ROOT/data/xray_config.json" ]; then
            cp "$ROOT/data/xray_config.json" "$DATA_DIR/" 2>/dev/null
        fi

        # Nginx panel_separate.conf
        if [ -f "$ROOT/nginx/panel_separate.conf" ]; then
            mkdir -p "/etc/nginx/conf.d"
            cp "$ROOT/nginx/panel_separate.conf" "/etc/nginx/conf.d/" 2>/dev/null
        fi

        # Node essentials - certs, .env, compose + xray-core & geo assets
        if [ -d "$ROOT/node" ]; then
            mkdir -p "$NODE_DIR"
            if [ -f "$ROOT/node/.env" ]; then
                cp "$ROOT/node/.env" "$NODE_ENV" 2>/dev/null
            fi
            for f in "$ROOT/node/"*.yml "$ROOT/node/"*.yaml; do
                [ -f "$f" ] && cp "$f" "$NODE_DIR/" 2>/dev/null
            done
            if [ -d "$ROOT/node/certs" ]; then
                mkdir -p "$NODE_DEF_CERTS"
                cp -a "$ROOT/node/certs/." "$NODE_DEF_CERTS/" 2>/dev/null
            fi
            # xray-core + geo assets -> restore works OFFLINE, zero manual steps
            local NODE_DATA_DIR
            NODE_DATA_DIR="$(dirname "$NODE_DEF_CERTS" 2>/dev/null)"
            [ -z "$NODE_DATA_DIR" ] && NODE_DATA_DIR="/var/lib/pg-node"
            if [ -d "$ROOT/node/xray-core" ]; then
                mkdir -p "$NODE_DATA_DIR/xray-core"
                cp -a "$ROOT/node/xray-core/." "$NODE_DATA_DIR/xray-core/" 2>/dev/null
                chmod +x "$NODE_DATA_DIR/xray-core/xray" 2>/dev/null || true
                log_backup "INFO" "Restored node xray-core -> $NODE_DATA_DIR/xray-core"
            fi
            if [ -d "$ROOT/node/assets" ]; then
                mkdir -p "$NODE_DATA_DIR/assets"
                cp -a "$ROOT/node/assets/." "$NODE_DATA_DIR/assets/" 2>/dev/null
                log_backup "INFO" "Restored node assets/geo -> $NODE_DATA_DIR/assets"
            fi
        fi

        # Safety net: Ensure node SSL certs exist (generate if missing from backup)
        if [ -n "$NODE_DEF_CERTS" ]; then
            mkdir -p "$NODE_DEF_CERTS" 2>/dev/null
            if [ ! -f "$NODE_DEF_CERTS/ssl_cert.pem" ] || [ ! -f "$NODE_DEF_CERTS/ssl_key.pem" ]; then
                log_backup "INFO" "Node SSL certs missing - generating self-signed"
                openssl req -x509 -newkey rsa:2048 \
                    -keyout "$NODE_DEF_CERTS/ssl_key.pem" \
                    -out "$NODE_DEF_CERTS/ssl_cert.pem" \
                    -days 3650 -nodes \
                    -subj "/CN=PasarGuard-Node" 2>/dev/null || true
                [ -f "$NODE_DEF_CERTS/ssl_cert.pem" ] && log_backup "SUCCESS" "Node SSL certs generated"
            fi
        fi

        # Fix perms
        chmod -R 755 "$DATA_DIR" 2>/dev/null || true
        chown -R 1000:1000 "$DATA_DIR" 2>/dev/null || true

        ui_spinner_stop
        ui_success "v${BACKUP_VERSION} essentials restored"
    fi

    # NOTE: We deliberately do NOT rewrite .env / apply smart fixes here.
    # fix_env_file + apply_smart_fix used to mangle the panel .env during
    # restore, which caused DB connection errors after restore.
    # Restored files are used as-is from the backup.
    echo -e "${CYAN}✓ Restored files are used as-is (no auto .env rewrite).${NC}"
    echo -e "${YELLOW}If you need firewall fixes, use 'Smart Fix' from the Backup menu.${NC}"
    sleep 1

    # Fix IPs in docker-compose ONLY (safe: touches the compose file, NEVER .env).
    # Needed when restoring on a server with a different IP (e.g. pgadmin
    # "Address not available" because PGADMIN_LISTEN_ADDRESS points to an
    # IP that no longer exists on this host).
    ui_spinner_start "Updating IPs in docker-compose..."
    if fix_docker_compose; then
        ui_spinner_stop
        ui_success "Docker compose IPs updated to current server IP"
    else
        ui_spinner_stop
        ui_warning "Compose IP update skipped (compose not found or IP undetectable)"
    fi

    # =========================================================
    # DATABASE RESTORE - while the panel is STOPPED (no locks, no
    # live-write races, no "database is being accessed by other users").
    # =========================================================
    local DB_RESTORE_PATH=""
    local DB_IS_GZ=false
    local DB_IS_SQLITE=false
    local DB_PICK
    DB_PICK="$(mrm_pick_db_restore "$ROOT")"
    case "$(printf '%s' "$DB_PICK" | cut -d'|' -f1)" in
        sqlite) DB_IS_SQLITE=true ;;
        gz)     DB_IS_GZ=true ;;
    esac
    DB_RESTORE_PATH="$(printf '%s' "$DB_PICK" | cut -d'|' -f2-)"

    if [ -n "$DB_RESTORE_PATH" ]; then
        log_backup "INFO" "Found DB to restore: $DB_RESTORE_PATH (sqlite=$DB_IS_SQLITE gz=$DB_IS_GZ)"

        if [ "$DB_IS_SQLITE" = true ]; then
            # --- SQLite restore (panel stopped -> plain file copy is safe) ---
            ui_spinner_start "Restoring SQLite database..."
            local DB_IMPORTED=false
            local TARGET_SQLITE=""
            # Where does the RESTORED config want the DB? (parse the restored .env)
            local ENV_URL
            ENV_URL="$(grep -m1 '^SQLALCHEMY_DATABASE_URL' "$PANEL_ENV" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            if [ -n "$ENV_URL" ]; then
                TARGET_SQLITE="$(mrm_sqlite_path_from_url "$ENV_URL")"
                log_backup "INFO" "SQLite target from restored .env: $TARGET_SQLITE"
            fi

            # 1) Host-visible absolute path (official installs: /var/lib/pasarguard/db.sqlite3)
            if [ -n "$TARGET_SQLITE" ] && [[ "$TARGET_SQLITE" == /* ]]; then
                local TARGET_DIR D_OWNER
                TARGET_DIR="$(dirname "$TARGET_SQLITE")"
                mkdir -p "$TARGET_DIR" 2>/dev/null
                if [ -d "$TARGET_DIR" ] && cp -f "$DB_RESTORE_PATH" "$TARGET_SQLITE" 2>/dev/null; then
                    # Match ownership of the data dir (panel may run as non-root)
                    D_OWNER="$(stat -c '%u:%g' "$TARGET_DIR" 2>/dev/null)"
                    [ -n "$D_OWNER" ] && chown "$D_OWNER" "$TARGET_SQLITE" 2>/dev/null || true
                    chmod 600 "$TARGET_SQLITE" 2>/dev/null || true
                    DB_IMPORTED=true
                    log_backup "SUCCESS" "SQLite restored to host path: $TARGET_SQLITE"
                fi
            fi

            # 2) In-container DB: copy directly into the (stopped) container filesystem
            if [ "$DB_IMPORTED" = false ]; then
                local PCONT IN_PATH WD
                PCONT="$(mrm_find_panel_container)"
                if [ -n "$PCONT" ]; then
                    if [ -n "$TARGET_SQLITE" ]; then
                        if [[ "$TARGET_SQLITE" == /* ]]; then
                            IN_PATH="$TARGET_SQLITE"
                        else
                            WD="$(docker inspect -f '{{.Config.WorkingDir}}' "$PCONT" 2>/dev/null)"
                            [ -z "$WD" ] && WD="/code"
                            IN_PATH="${WD%/}/$TARGET_SQLITE"
                        fi
                    else
                        IN_PATH="$(mrm_sqlite_path_from_container "$PCONT")"
                    fi
                    if docker cp "$DB_RESTORE_PATH" "$PCONT:$IN_PATH" >/dev/null 2>&1; then
                        DB_IMPORTED=true
                        log_backup "SUCCESS" "SQLite restored into container: $IN_PATH"
                    else
                        log_backup "ERROR" "docker cp to container failed: $IN_PATH"
                    fi
                else
                    log_backup "ERROR" "No panel container found for SQLite restore"
                fi
            fi

            # 3) Last resort: known host paths (older PasarGuard stored DB on volume)
            if [ "$DB_IMPORTED" = false ]; then
                local HOST_CAND
                for HOST_CAND in "$DATA_DIR/db.sqlite3" "$PANEL_DIR/db.sqlite3"; do
                    if cp -f "$DB_RESTORE_PATH" "$HOST_CAND" 2>/dev/null; then
                        DB_IMPORTED=true
                        log_backup "SUCCESS" "SQLite restored to host path: $HOST_CAND"
                        break
                    fi
                done
            fi

            ui_spinner_stop
            if [ "$DB_IMPORTED" = true ]; then
                ui_success "SQLite database restored!"
            else
                ui_error "SQLite import failed - check /var/log/mrm-backup.log"
            fi
        else
            # --- PostgreSQL / MySQL dump restore (panel stopped -> no locks) ---
            local DB_IMPORTED=false
            if grep -qiE "postgresql|postgres" "$PANEL_ENV" 2>/dev/null; then
                ui_spinner_start "Importing PostgreSQL database..."
                # Find the DB container even if stopped; start it if needed
                local DB_CONT
                DB_CONT=$(docker ps --format '{{.Names}}' | grep -iE "postgres|timescale" | head -1)
                if [ -z "$DB_CONT" ]; then
                    DB_CONT=$(docker ps -a --format '{{.Names}}' | grep -iE "postgres|timescale" | head -1)
                    [ -n "$DB_CONT" ] && docker start "$DB_CONT" >/dev/null 2>&1
                fi
                # NEW SERVER FIX: If no postgres container exists at all (brand new server),
                # start it from the restored docker-compose to create it
                if [ -z "$DB_CONT" ] && [ -n "$PANEL_COMPOSE_FILE" ] && [ -f "$PANEL_COMPOSE_FILE" ]; then
                    log_backup "INFO" "No postgres container found - starting from restored compose (new server)"
                    run_compose_file "$PANEL_COMPOSE_FILE" up -d postgres db postgresql >/dev/null 2>&1 || true
                    sleep 3
                    DB_CONT=$(docker ps --format '{{.Names}}' | grep -iE "postgres|timescale" | head -1)
                    if [ -n "$DB_CONT" ]; then
                        log_backup "SUCCESS" "Postgres container created from compose: $DB_CONT"
                    else
                        log_backup "ERROR" "Could not create postgres container from compose"
                    fi
                fi
                # Wait until it accepts connections (max ~30s)
                local TRIES=0
                while [ "$TRIES" -lt 30 ]; do
                    if [ -n "$DB_CONT" ] && docker exec "$DB_CONT" pg_isready -U postgres >/dev/null 2>&1; then break; fi
                    sleep 1; TRIES=$((TRIES+1))
                done
                if [ -n "$DB_CONT" ]; then
                    parse_db_credentials "$PANEL_ENV"
                    [ -z "$DB_USER" ] && DB_USER="pasarguard"
                    [ -z "$DB_NAME" ] && DB_NAME="$DB_USER"

                    local SQL_FILE="$DB_RESTORE_PATH"
                    local TEMP_SQL=""

                    if [ "$DB_IS_GZ" = true ]; then
                        TEMP_SQL="$ROOT/database/db.sql"
                        if gunzip -c "$DB_RESTORE_PATH" > "$TEMP_SQL" 2>/dev/null; then
                            SQL_FILE="$TEMP_SQL"
                        else
                            log_backup "ERROR" "Failed to gunzip DB"
                        fi
                    fi

                    if [ -n "$DB_PASS" ]; then
                        if docker exec -e PGPASSWORD="$DB_PASS" "$DB_CONT" psql -U "$DB_USER" -d "$DB_NAME" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null 2>&1 && \
                           cat "$SQL_FILE" | docker exec -i -e PGPASSWORD="$DB_PASS" "$DB_CONT" psql -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
                            DB_IMPORTED=true
                        fi
                    else
                        if docker exec "$DB_CONT" psql -U "$DB_USER" -d "$DB_NAME" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null 2>&1 && \
                           cat "$SQL_FILE" | docker exec -i "$DB_CONT" psql -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
                            DB_IMPORTED=true
                        fi
                    fi

                    [ "$DB_IS_GZ" = true ] && [ -f "$TEMP_SQL" ] && [ "$TEMP_SQL" != "$DB_RESTORE_PATH" ] && rm -f "$TEMP_SQL"
                else
                    # Try host psql as a fallback
                    if command -v psql >/dev/null 2>&1; then
                        local SQL_FILE2="$DB_RESTORE_PATH"
                        if [ "$DB_IS_GZ" = true ]; then
                            SQL_FILE2="$ROOT/database/db.sql"
                            gunzip -c "$DB_RESTORE_PATH" > "$SQL_FILE2" 2>/dev/null
                        fi
                        parse_db_credentials "$PANEL_ENV"
                        [ -z "$DB_USER" ] && DB_USER="pasarguard"
                        [ -z "$DB_NAME" ] && DB_NAME="$DB_USER"
                        export PGPASSWORD="$DB_PASS"
                        if psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" >/dev/null 2>&1 && \
                           psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -f "$SQL_FILE2" >/dev/null 2>&1; then
                            DB_IMPORTED=true
                        fi
                        unset PGPASSWORD
                        [ "$DB_IS_GZ" = true ] && [ -f "$SQL_FILE2" ] && rm -f "$SQL_FILE2"
                    else
                        log_backup "ERROR" "No DB container or psql found for restore"
                    fi
                fi
                ui_spinner_stop
                if [ "$DB_IMPORTED" = true ]; then ui_success "PostgreSQL database imported successfully!"; log_backup "SUCCESS" "PostgreSQL DB imported"; else ui_error "PostgreSQL database import failed! Check logs"; log_backup "ERROR" "PostgreSQL DB import failed"; fi
            elif grep -qiE "mysql|mariadb" "$PANEL_ENV" 2>/dev/null; then
                ui_spinner_start "Importing MySQL/MariaDB database..."
                local DB_CONT
                DB_CONT=$(docker ps --format '{{.Names}}' | grep -iE "mysql|mariadb" | head -1)
                if [ -z "$DB_CONT" ]; then
                    DB_CONT=$(docker ps -a --format '{{.Names}}' | grep -iE "mysql|mariadb" | head -1)
                    [ -n "$DB_CONT" ] && docker start "$DB_CONT" >/dev/null 2>&1
                fi
                # NEW SERVER FIX: If no mysql container exists at all (brand new server),
                # start it from the restored docker-compose to create it
                if [ -z "$DB_CONT" ] && [ -n "$PANEL_COMPOSE_FILE" ] && [ -f "$PANEL_COMPOSE_FILE" ]; then
                    log_backup "INFO" "No MySQL container found - starting from restored compose (new server)"
                    run_compose_file "$PANEL_COMPOSE_FILE" up -d mysql mariadb db >/dev/null 2>&1 || true
                    sleep 3
                    DB_CONT=$(docker ps --format '{{.Names}}' | grep -iE "mysql|mariadb" | head -1)
                    if [ -n "$DB_CONT" ]; then
                        log_backup "SUCCESS" "MySQL container created from compose: $DB_CONT"
                    fi
                fi
                if [ -n "$DB_CONT" ]; then
                    # Wait for MySQL to be ready (max 30s)
                    local MYSQL_TRIES=0
                    while [ "$MYSQL_TRIES" -lt 30 ]; do
                        if docker exec "$DB_CONT" mysqladmin ping -u root >/dev/null 2>&1; then break; fi
                        sleep 1; MYSQL_TRIES=$((MYSQL_TRIES+1))
                    done
                fi
                if [ -n "$DB_CONT" ]; then
                    parse_db_credentials "$PANEL_ENV"
                    [ -z "$DB_USER" ] && DB_USER="pasarguard"
                    [ -z "$DB_NAME" ] && DB_NAME="$DB_USER"
                    local SQL_FILE="$DB_RESTORE_PATH"
                    local TEMP_SQL=""
                    if [ "$DB_IS_GZ" = true ]; then
                        TEMP_SQL="$ROOT/database/db.sql"
                        gunzip -c "$DB_RESTORE_PATH" > "$TEMP_SQL" 2>/dev/null && SQL_FILE="$TEMP_SQL"
                    fi
                    if docker exec -e MYSQL_PWD="$DB_PASS" "$DB_CONT" mysql -u "$DB_USER" "$DB_NAME" < "$SQL_FILE" 2>/dev/null; then
                        DB_IMPORTED=true
                    fi
                    [ "$DB_IS_GZ" = true ] && [ -f "$TEMP_SQL" ] && [ "$TEMP_SQL" != "$DB_RESTORE_PATH" ] && rm -f "$TEMP_SQL"
                fi
                ui_spinner_stop
                if [ "$DB_IMPORTED" = true ]; then ui_success "MySQL database imported successfully!"; log_backup "SUCCESS" "MySQL DB imported"; else ui_error "MySQL database import failed!"; log_backup "ERROR" "MySQL DB import failed"; fi
            fi
        fi
    else
        log_backup "WARNING" "No database file found in backup to restore"
        ui_warning "No database found in backup - only files restored"
    fi

    # Ensure xray-core binary BEFORE starting services (fixes Error_Node on restore)
    # xray-core is excluded from small backups (MRM_BACKUP_XRAY=0 by default),
    # so on a new server the binary is missing. We must download it BEFORE the
    # node container starts, otherwise the node fails with:
    #   "fork/exec /var/lib/pg-node/xray-core/xray: no such file or directory"
    local XRAY_WAS_DOWNLOADED=false
    local XRAY_BIN_PATH=""
    XRAY_BIN_PATH="$(dirname "${NODE_DEF_CERTS:-/var/lib/pg-node/certs}" 2>/dev/null)"
    [ -z "$XRAY_BIN_PATH" ] && XRAY_BIN_PATH="/var/lib/pg-node"
    XRAY_BIN_PATH="$XRAY_BIN_PATH/xray-core/xray"

    ui_spinner_start "Checking xray-core binary (must exist before node starts)..."
    if [ -x "$XRAY_BIN_PATH" ] && "$XRAY_BIN_PATH" -version >/dev/null 2>&1; then
        ui_spinner_stop
        ui_success "xray-core already present and working"
        log_backup "INFO" "xray-core already present: $XRAY_BIN_PATH"
    else
        ui_spinner_stop
        log_backup "INFO" "xray-core missing at $XRAY_BIN_PATH - downloading before service start"
        ui_spinner_start "Downloading xray-core (needed before node starts)..."
        if mrm_ensure_xray_core; then
            XRAY_WAS_DOWNLOADED=true
            ui_spinner_stop
            ui_success "xray-core downloaded successfully"
            log_backup "SUCCESS" "xray-core downloaded to $XRAY_BIN_PATH"
        else
            ui_spinner_stop
            ui_error "xray-core download FAILED! Node will not work."
            echo -e "    ${YELLOW}Possible causes:${NC}"
            echo -e "    ${YELLOW}- GitHub is blocked on this server (common in Iran)${NC}"
            echo -e "    ${YELLOW}- No internet connection${NC}"
            echo -e "    ${YELLOW}- Try: mrm fix-node${NC}"
            log_backup "ERROR" "xray-core download failed during restore"
        fi
    fi

    # Start services (AFTER the DB is restored AND xray-core is ensured)
    local STARTED_ANY=false START_FAILED=false
    PANEL_COMPOSE_FILE="$(get_existing_compose_file panel 2>/dev/null || true)"
    NODE_COMPOSE_FILE="$(get_existing_compose_file node 2>/dev/null || true)"

    ui_spinner_start "Starting services..."
    if [ -n "$NODE_COMPOSE_FILE" ]; then
        if run_compose_file "$NODE_COMPOSE_FILE" up -d >/dev/null 2>&1; then STARTED_ANY=true; else START_FAILED=true; fi
    fi
    if [ -n "$PANEL_COMPOSE_FILE" ]; then
        if run_compose_file "$PANEL_COMPOSE_FILE" up -d >/dev/null 2>&1; then STARTED_ANY=true; else START_FAILED=true; fi
    fi
    ui_spinner_stop

    if [ "$START_FAILED" = true ]; then ui_error "Failed to start one or more services"; elif [ "$STARTED_ANY" = true ]; then ui_success "Services started"; else ui_warning "No compose services found to start"; fi

    # If xray was freshly downloaded, restart the node container to pick it up
    if [ "$XRAY_WAS_DOWNLOADED" = true ] && [ -n "$NODE_COMPOSE_FILE" ]; then
        ui_spinner_start "Restarting node to apply new xray-core..."
        if run_compose_file "$NODE_COMPOSE_FILE" restart >/dev/null 2>&1; then
            ui_spinner_stop
            ui_success "Node restarted with new xray-core"
            log_backup "INFO" "Node restarted after xray-core download"
        else
            ui_spinner_stop
            ui_warning "Node restart failed - try: docker restart \$(docker ps -a --format '{{.Names}}' | grep -i node | head -1)"
            log_backup "WARNING" "Node restart failed after xray-core download"
        fi
    fi

    # ═══════════════════════════════════════════════════════════════
    # POST-RESTORE AUTO-FIX (Nginx + SSL + Sub URL)
    # Fix common issues after restore:
    #   - Install Nginx if missing
    #   - Copy SSL certs to /etc/letsencrypt/live/
    #   - Set XRAY_SUBSCRIPTION_URL_PREFIX
    #   - Test and start Nginx
    #   - Restart panel with new settings
    # ═══════════════════════════════════════════════════════════════
    if declare -f main >/dev/null 2>&1; then
        echo ""
        echo -e "${CYAN}🔧 Running post-restore auto-fix...${NC}"
        main 2>&1 | tee -a /var/log/mrm-post-restore.log
        echo -e "${GREEN}✔ Post-restore auto-fix completed${NC}"
        log_backup "SUCCESS" "Post-restore auto-fix executed"
    else
        echo -e "${YELLOW}⚠ post_restore module not loaded - skipping auto-fix${NC}"
        log_backup "WARNING" "post_restore module not loaded"
    fi

    # Final cleanup
    rm -rf "$WORK_DIR"
    trap - RETURN

    local NEW_SERVER_IP=$(get_server_ip)
    log_backup "SUCCESS" "Restore v${BACKUP_VERSION} completed from: $(basename "$SELECTED")"

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              ✔ RESTORE v${BACKUP_VERSION} COMPLETED!                     ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC} Server IP: ${CYAN}$NEW_SERVER_IP${NC}"
    echo -e "${GREEN}║${NC} Backup: ${CYAN}$(basename "$SELECTED")${NC}"
    echo -e "${GREEN}║${NC} Type: ${CYAN}v${BACKUP_VERSION}${NC}"
    echo -e "${GREEN}║${NC} Data: ${CYAN}Safe & Complete${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Safety backup: $SAFETY_BACKUP${NC}"
    if [ "$XRAY_WAS_DOWNLOADED" = true ]; then
        echo -e "${YELLOW}Note: xray-core was downloaded during restore (not in backup)${NC}"
    elif [ -x "$XRAY_BIN_PATH" ]; then
        echo -e "${CYAN}Note: xray-core was present or restored from backup${NC}"
    else
        echo -e "${RED}⚠ WARNING: xray-core is MISSING! Run: mrm fix-node${NC}"
    fi
    echo ""
    pause
}

# Xray release asset name for this machine's architecture.
# IMPORTANT: XTLS/Xray-core assets are Xray-linux-64.zip (x86_64) and
# Xray-linux-arm64-v8a.zip (aarch64) - NOT x64/arm64 (those URLs 404!).
