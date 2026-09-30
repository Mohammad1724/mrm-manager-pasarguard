#!/bin/bash
# MRM Backup - Restore Core Module
# Main restore logic: extract, safety backup, restore files, restore DB, start services

# ─── Restore ─────────────────────────────────────────────────────────────────
do_restore() {
    setup_env
    init_backup_logging
    ui_header "Restore from Backup" "$BACKUP_DIR"

    # FIX: exclude pre_restore_* safety backups from the restore list — their
    # tar layout has no MRM root, so selecting one silently restores nothing
    # while reporting success (MRM-062)
    local FILES=()
    mapfile -t FILES < <(find "$BACKUP_DIR" -maxdepth 1 -name '*.tar.gz' ! -name 'pre_restore_*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
    if [ ${#FILES[@]} -eq 0 ]; then
        ui_error "No backups found in $BACKUP_DIR"
        ui_note "Upload an archive to $BACKUP_DIR (or download one from Telegram) and try again."
        ui_pause
        return 1
    fi

    ui_menu_title "Select a backup to restore"
    for i in "${!FILES[@]}"; do
        local SIZE DATE TYPE
        SIZE=$(du -h "${FILES[$i]}" | cut -f1)
        DATE=$(stat -c %y "${FILES[$i]}" | cut -d' ' -f1)
        TYPE="BACKUP"
        [[ "$(basename "${FILES[$i]}")" == *"Full"* ]] && TYPE="FULL-OLD"
        [[ "$(basename "${FILES[$i]}")" == *"Lite"* ]] && TYPE="LITE-OLD"
        ui_menu_item "$((i+1))" "$(basename "${FILES[$i]}")" "$TYPE · $SIZE · $DATE"
    done
    ui_menu_back "Cancel"
    if ls "$BACKUP_DIR"/pre_restore_*.tar.gz >/dev/null 2>&1; then
        ui_note "pre_restore_* safety copies are hidden — they are not restorable."
    fi
    local SEL
    ui_select SEL
    [ "$SEL" == "0" ] && return
    # validate numeric input — otherwise $((SEL-1)) treats non-numeric
    # input as empty var -> -1 -> FILES[-1] wraps to the LAST backup (MRM-069)
    if ! [[ "$SEL" =~ ^[0-9]+$ ]]; then ui_error "Invalid selection"; ui_pause; return 1; fi
    local SELECTED="${FILES[$((SEL-1))]}"
    if [ -z "$SELECTED" ] || [ ! -f "$SELECTED" ]; then ui_error "Invalid selection"; ui_pause; return 1; fi

    echo ""
    ui_warning "Restoring overwrites the current panel data (database, .env, certificates)."
    ui_kv "Archive" "$(basename "$SELECTED") ($(du -h "$SELECTED" | cut -f1))"
    ui_note "A safety backup of the current state is created first."
    echo ""
    if ! ui_confirm "Start the restore?"; then ui_cancelled; ui_pause; return; fi

    log_backup "INFO" "Starting restore v${BACKUP_VERSION} from: $(basename "$SELECTED")"

    local WORK_DIR="$TEMP_BASE/restore_$(date +%s)"
    mkdir -p "$WORK_DIR"
    
    # Cleanup trap with safety guard
    trap '[[ -n "${WORK_DIR:-}" && -d "${WORK_DIR:-}" && "$WORK_DIR" != "/" ]] && rm -rf "$WORK_DIR"; trap - RETURN' RETURN

    ui_spinner_start "Extracting archive"
    if ! tar -xzf "$SELECTED" -C "$WORK_DIR" 2>/dev/null; then
        ui_spinner_stop
        ui_error "Failed to extract the archive — the file may be corrupted"
        rm -rf "$WORK_DIR"
        trap - RETURN
        ui_pause
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
        ui_error "Invalid archive structure — MRM backup root not found"
        log_backup "ERROR" "Invalid backup structure"
        rm -rf "$WORK_DIR"
        trap - RETURN
        ui_pause
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
        ui_section "Archive info"
        sed "s/^/${UI_PAD}/" "$ROOT/backup_info.txt"
        echo ""
    fi

    # =========================================================
    # 0) SAFETY BACKUP FIRST - while everything is STILL RUNNING.
    #    Includes a live export of the current database, so a failed
    #    restore can NEVER destroy the original data.
    # =========================================================
    ui_spinner_start "Creating safety backup of the current state"
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
                ui_success "Safety backup created (with live database): $(basename "$SAFETY_BACKUP")"
            else
                ui_warning "Safety backup created without a database"
            fi
            log_backup "INFO" "Safety backup created: $SAFETY_BACKUP (db=$SAFETY_DB_OK)"
            rm -rf "$SAFETY_DIR"
        else
            ui_spinner_stop
            ui_warning "Safety backup failed — raw files kept for manual recovery:"
            if [ -f "$SAFETY_DIR/current_db_backup" ]; then
                local KEEP_DB="$BACKUP_DIR/pre_restore_db_$(date +%Y%m%d_%H%M%S)$(basename "$DB_BACKUP_FILE")"
                mv -f "$SAFETY_DIR/current_db_backup" "$KEEP_DB" 2>/dev/null
                ui_bullet "Raw database saved: $KEEP_DB"
                log_backup "ERROR" "Safety tar failed; raw DB kept at $KEEP_DB"
            fi
        fi
    else
        ui_spinner_stop
        ui_warning "No existing data to protect — safety backup skipped"
        rm -rf "$SAFETY_DIR"
    fi

    # Stop services. We use `stop` (NOT `down`) so the container and its
    # writable layer are preserved - needed to copy the DB in/out safely.
    ui_spinner_start "Stopping services"
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
        ui_spinner_start "Restoring files (legacy full archive)"
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
        ui_success "Files restored"
    else
        # Restore essentials
        log_backup "INFO" "Restoring v${BACKUP_VERSION} essentials"
        ui_spinner_start "Restoring panel and node files"

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
        ui_success "Panel and node files restored"
    fi

    # NOTE: We deliberately do NOT rewrite .env / apply smart fixes here.
    # fix_env_file + apply_smart_fix used to mangle the panel .env during
    # restore, which caused DB connection errors after restore.
    # Restored files are used as-is from the backup.
    ui_note "Restored files are used as-is (.env is never rewritten). Firewall fixes: Backup menu › Smart fix."

    # Fix IPs in docker-compose ONLY (safe: touches the compose file, NEVER .env).
    # Needed when restoring on a server with a different IP (e.g. pgadmin
    # "Address not available" because PGADMIN_LISTEN_ADDRESS points to an
    # IP that no longer exists on this host).
    ui_spinner_start "Updating IPs in docker-compose"
    if fix_docker_compose; then
        ui_spinner_stop
        ui_success "docker-compose IPs updated to this server"
    else
        ui_spinner_stop
        ui_warning "Compose IP update skipped (no compose file or IP not detectable)"
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
            ui_spinner_start "Restoring SQLite database"
            local DB_IMPORTED=false
            local SQLITE_OK=true
            # FIX (MRM-108): validate the SQLite file (magic header) BEFORE
            # copying it over a possibly-working database — mirrors the
            # PostgreSQL/MySQL dump validation.
            if ! mrm_is_sqlite_file "$DB_RESTORE_PATH"; then
                SQLITE_OK=false
                log_backup "ERROR" "SQLite backup file is not a valid SQLite database - refusing to restore"
                ui_error "SQLite backup file is invalid — database restore skipped"
            fi
            local TARGET_SQLITE=""
            # Where does the RESTORED config want the DB? (parse the restored .env)
            local ENV_URL
            ENV_URL="$(grep -m1 '^SQLALCHEMY_DATABASE_URL' "$PANEL_ENV" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            if [ -n "$ENV_URL" ]; then
                TARGET_SQLITE="$(mrm_sqlite_path_from_url "$ENV_URL")"
                log_backup "INFO" "SQLite target from restored .env: $TARGET_SQLITE"
            fi

            # 1) Host-visible absolute path (official installs: /var/lib/pasarguard/db.sqlite3)
            if [ "$SQLITE_OK" = true ] && [ -n "$TARGET_SQLITE" ] && [[ "$TARGET_SQLITE" == /* ]]; then
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
            if [ "$SQLITE_OK" = true ] && [ "$DB_IMPORTED" = false ]; then
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
            if [ "$SQLITE_OK" = true ] && [ "$DB_IMPORTED" = false ]; then
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
                ui_success "SQLite database restored"
            else
                ui_error "SQLite import failed — see $BACKUP_LOG"
            fi
        else
            # --- PostgreSQL / MySQL dump restore (panel stopped -> no locks) ---
            local DB_IMPORTED=false
            if grep -qiE "postgresql|postgres" "$PANEL_ENV" 2>/dev/null; then
                ui_spinner_start "Importing PostgreSQL database"
                # Find the DB container even if stopped; start it if needed
                local DB_CONT
                # FIX: precise compose-name match first (MRM-060); bare
                # "grep -iE postgres|timescale" can match an unrelated container
                # (postgres_exporter, node-exporter…) and the DROP SCHEMA below
                # would hit the WRONG database (same pattern as MRM-047)
                DB_CONT=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^(pasarguard-)?(postgresql|timescaledb|postgres|timescale)[-_]?[0-9]*$' | head -1)
                [ -z "$DB_CONT" ] && DB_CONT=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE "postgres|timescale" | head -1)
                if [ -z "$DB_CONT" ]; then
                    DB_CONT=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^(pasarguard-)?(postgresql|timescaledb|postgres|timescale)[-_]?[0-9]*$' | head -1)
                    [ -z "$DB_CONT" ] && DB_CONT=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -iE "postgres|timescale" | head -1)
                    [ -n "$DB_CONT" ] && docker start "$DB_CONT" >/dev/null 2>&1
                fi
                # NEW SERVER FIX: If no postgres container exists at all (brand new server),
                # start it from the restored docker-compose to create it
                if [ -z "$DB_CONT" ] && [ -n "$PANEL_COMPOSE_FILE" ] && [ -f "$PANEL_COMPOSE_FILE" ]; then
                    log_backup "INFO" "No postgres container found - starting from restored compose (new server)"
                    # FIX (MRM-109): official TimescaleDB installs name the service
                    # `timescaledb` (only raw PostgreSQL uses `postgresql`) — without
                    # it the DB container was never created on a bare new server.
                    run_compose_file "$PANEL_COMPOSE_FILE" up -d timescaledb postgresql postgres db >/dev/null 2>&1 || true
                    sleep 3
                    DB_CONT=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^(pasarguard-)?(postgresql|timescaledb|postgres|timescale)[-_]?[0-9]*$' | head -1)
                    [ -z "$DB_CONT" ] && DB_CONT=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE "postgres|timescale" | head -1)
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

                    # ── VALIDATE the dump BEFORE touching the live database ────────
                    # A truncated/corrupt dump must NEVER destroy a working database.
                    # (MRM-108: a partial dump restores a schema with no data and no
                    # alembic_version -> panel crash-loops on start.)
                    if ! mrm_pg_dump_ok "$SQL_FILE"; then
                        log_backup "ERROR" "Refusing to restore: dump is empty/truncated (missing pg_dump trailer)"
                        ui_error "Dump file is incomplete - aborting DB restore (live DB left untouched)"
                        DB_IMPORTED=false
                    else
                        local PGPASS_ENV=()
                        [ -n "$DB_PASS" ] && PGPASS_ENV=(-e "PGPASSWORD=$DB_PASS")
                        # FIX (MRM-108): -w on every psql call so it NEVER prompts
                        # for a password. docker exec has no TTY, so a prompt would
                        # hang or fail obscurely; fail loudly instead.
                        local IMPORT_LOG="$TEMP_BASE/pg_import_$$.log"

                        # ── Reset the target database ──────────────────────────────
                        # Preferred: drop & recreate the whole DATABASE. On a fresh DB
                        # the dump re-runs `CREATE EXTENSION timescaledb` exactly the
                        # way pg_dump/pg_restore expect. The old `DROP SCHEMA public
                        # CASCADE` is UNSAFE on TimescaleDB: it drops the extension
                        # and leaves a DB where the re-import can fail mid-way,
                        # silently leaving a schema with no data / no alembic_version.
                        # ── MRM-110: detect a HALF-RESTORED database left by a
                        # previously failed restore (schema objects exist but
                        # alembic_version is empty -> panel crash-loops with
                        # 'type "proxytypes" already exists').
                        local PREV_HAS_SCHEMA PREV_ALEMBIC
                        PREV_HAS_SCHEMA="$(docker exec "${PGPASS_ENV[@]}" "$DB_CONT" psql -w -tA -U "$DB_USER" -d "$DB_NAME" -c "SELECT to_regclass('public.proxytypes') IS NOT NULL;" 2>/dev/null || true)"
                        PREV_ALEMBIC="$(docker exec "${PGPASS_ENV[@]}" "$DB_CONT" psql -w -tA -U "$DB_USER" -d "$DB_NAME" -c "SELECT count(*) FROM alembic_version;" 2>/dev/null || true)"
                        if [ "$PREV_HAS_SCHEMA" = "t" ] && [ "$PREV_ALEMBIC" != "1" ]; then
                            log_backup "WARNING" "Target DB is HALF-RESTORED (schema without alembic_version=$PREV_ALEMBIC) - a previous restore failed mid-import; it will be fully reset now"
                            ui_warning "Found a half-restored database from an earlier failed restore - resetting it completely"
                        fi

                        local DB_DROPPED=false DB_RESET_OK=false DB_READY=true
                        if [[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]]; then
                            # Kill lingering connections to the target DB (the panel
                            # is already stopped; pgbouncer may hold pooled links).
                            docker exec "${PGPASS_ENV[@]}" "$DB_CONT" psql -w -U "$DB_USER" -d postgres -c \
                                "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB_NAME' AND pid <> pg_backend_pid();" >/dev/null 2>&1 || true
                            if docker exec "${PGPASS_ENV[@]}" "$DB_CONT" psql -w -U "$DB_USER" -d postgres -c "DROP DATABASE IF EXISTS \"$DB_NAME\" WITH (FORCE);" >/dev/null 2>&1; then
                                DB_DROPPED=true
                                if docker exec "${PGPASS_ENV[@]}" "$DB_CONT" psql -w -U "$DB_USER" -d postgres -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\";" >/dev/null 2>&1 \
                                   || docker exec "${PGPASS_ENV[@]}" "$DB_CONT" psql -w -U "$DB_USER" -d postgres -c "CREATE DATABASE \"$DB_NAME\";" >/dev/null 2>&1; then
                                    DB_RESET_OK=true
                                    log_backup "INFO" "Recreated database $DB_NAME (clean restore)"
                                fi
                            fi
                        fi
                        if [ "$DB_RESET_OK" = true ]; then
                            :  # fresh database ready for import
                        elif [ "$DB_DROPPED" = true ]; then
                            # Dropped but CREATE DATABASE failed: importing into a
                            # missing database would only produce confusing errors.
                            DB_READY=false
                            log_backup "ERROR" "Dropped $DB_NAME but CREATE DATABASE failed - cannot import"
                            ui_error "Could not recreate database $DB_NAME - restore aborted"
                        else
                            # Fallback: schema reset (DB user lacks CREATEDB or
                            # `postgres` maintenance DB access).
                            log_backup "WARNING" "DROP/CREATE DATABASE unavailable - falling back to schema reset"
                            docker exec "${PGPASS_ENV[@]}" "$DB_CONT" psql -w -U "$DB_USER" -d "$DB_NAME" -c "BEGIN; DROP SCHEMA public CASCADE; CREATE SCHEMA public; COMMIT;" >/dev/null 2>&1 || true
                        fi

                        # ── Import (ON_ERROR_STOP=1 so a mid-file error fails) ─────
                        # MRM-110: the full psql output is kept in
                        # /var/log/mrm-pg-import-<ts>.log so a mid-file failure
                        # can actually be diagnosed afterwards.
                        local DB_BROKEN=false IMPORT_KEEP
                        IMPORT_KEEP="/var/log/mrm-pg-import-$(date +%Y%m%d_%H%M%S).log"
                        if [ "$DB_READY" = true ]; then
                            if docker exec -i "${PGPASS_ENV[@]}" "$DB_CONT" psql -w -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" < "$SQL_FILE" >"$IMPORT_LOG" 2>&1; then
                                # ── VERIFY before declaring success ────────────────
                                # A zero exit code can still leave an incomplete DB; the
                                # panel REQUIRES alembic_version (1 row). settings is
                                # checked as a soft signal (exists in v3+ only).
                                local ALEMBIC_ROWS SETTINGS_ROWS
                                ALEMBIC_ROWS="$(docker exec "${PGPASS_ENV[@]}" "$DB_CONT" psql -w -tA -U "$DB_USER" -d "$DB_NAME" -c "SELECT count(*) FROM alembic_version;" 2>/dev/null)"
                                if [ "$ALEMBIC_ROWS" = "1" ]; then
                                    DB_IMPORTED=true
                                    SETTINGS_ROWS="$(docker exec "${PGPASS_ENV[@]}" "$DB_CONT" psql -w -tA -U "$DB_USER" -d "$DB_NAME" -c "SELECT count(*) FROM settings;" 2>/dev/null)"
                                    if [ -n "$SETTINGS_ROWS" ] && [ "$SETTINGS_ROWS" -ge 1 ] 2>/dev/null; then
                                        log_backup "SUCCESS" "PostgreSQL import verified (alembic_version=1, settings=$SETTINGS_ROWS)"
                                    else
                                        log_backup "WARNING" "alembic_version=1 but settings empty/missing (pre-v3 backup?)"
                                    fi
                                else
                                    cp -f "$IMPORT_LOG" "$IMPORT_KEEP" 2>/dev/null || true
                                    log_backup "ERROR" "Import finished but alembic_version='$ALEMBIC_ROWS' (expected 1) - DB incomplete. Full psql output: $IMPORT_KEEP"
                                    ui_error "Import produced an incomplete database (alembic_version=$ALEMBIC_ROWS, expected 1)"
                                    DB_BROKEN=true
                                fi
                            else
                                cp -f "$IMPORT_LOG" "$IMPORT_KEEP" 2>/dev/null || true
                                log_backup "ERROR" "PostgreSQL import failed (ON_ERROR_STOP). Full psql output: $IMPORT_KEEP. Last output lines:"
                                tail -n 15 "$IMPORT_LOG" 2>/dev/null | while IFS= read -r L; do log_backup "ERROR" "  $L"; done
                                DB_BROKEN=true
                            fi
                        fi

                        # ── MRM-110: NEVER leave a half-restored DB behind ──────
                        # If the import failed/incomplete, roll the database back
                        # to the pre-restore safety copy so the server keeps
                        # working instead of crash-looping on 'type already exists'.
                        if [ "$DB_BROKEN" = true ] && [ -n "${SAFETY_BACKUP:-}" ] && [ -f "$SAFETY_BACKUP" ]; then
                            ui_warning "Import failed — rolling back to the pre-restore database…"
                            if mrm_rollback_db_from_safety "$SAFETY_BACKUP" "$DB_CONT" "$DB_USER" "$DB_PASS" "$DB_NAME"; then
                                ui_warning "Pre-restore database restored — the panel will run with the OLD data (restore was aborted safely)"
                                log_backup "WARNING" "Restore aborted safely: DB rolled back to pre-restore state"
                            else
                                ui_error "Automatic rollback failed — fix manually with: mrm repair-db (see $IMPORT_KEEP and $BACKUP_LOG)"
                                log_backup "ERROR" "Automatic rollback to the safety DB failed"
                            fi
                        fi
                        unset DB_BROKEN

                        # ── NEW-SERVER FIX (MRM-109): sync the role password ──
                        # The dump contains NO role passwords. On a new server the
                        # database keeps the NEW install's password while the
                        # restored .env sends the OLD one -> the panel crash-loops
                        # with "password authentication failed" after restore.
                        # Align the role with the restored .env while the DB
                        # container is still up and reachable via its socket.
                        if mrm_sync_pg_role_password "$DB_CONT" "$DB_USER" "$DB_PASS"; then
                            log_backup "SUCCESS" "DB credentials match the restored .env"
                        else
                            ui_warning "DB password could not be synced - if the panel fails with 'password authentication failed', fix it from Backup menu › Smart fix or set the role password manually"
                        fi

                        [ -n "$IMPORT_LOG" ] && [ -f "$IMPORT_LOG" ] && rm -f "$IMPORT_LOG"
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
                        if ! mrm_pg_dump_ok "$SQL_FILE2"; then
                            log_backup "ERROR" "Refusing to restore: dump is empty/truncated (missing pg_dump trailer)"
                            ui_error "Dump file is incomplete - aborting DB restore (live DB left untouched)"
                        else
                            parse_db_credentials "$PANEL_ENV"
                            [ -z "$DB_USER" ] && DB_USER="pasarguard"
                            [ -z "$DB_NAME" ] && DB_NAME="$DB_USER"
                            export PGPASSWORD="$DB_PASS"
                            if psql -w -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -c "BEGIN; DROP SCHEMA public CASCADE; CREATE SCHEMA public; COMMIT;" >/dev/null 2>&1 && \
                               psql -w -h 127.0.0.1 -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" -f "$SQL_FILE2" >/dev/null 2>&1; then
                                DB_IMPORTED=true
                            fi
                            unset PGPASSWORD
                        fi
                        [ "$DB_IS_GZ" = true ] && [ -f "$SQL_FILE2" ] && rm -f "$SQL_FILE2"
                    else
                        log_backup "ERROR" "No DB container or psql found for restore"
                    fi
                fi
                ui_spinner_stop
                if [ "$DB_IMPORTED" = true ]; then ui_success "PostgreSQL database imported successfully!"; log_backup "SUCCESS" "PostgreSQL DB imported"; else ui_error "PostgreSQL database import failed! Check logs"; log_backup "ERROR" "PostgreSQL DB import failed"; fi
            elif grep -qiE "mysql|mariadb" "$PANEL_ENV" 2>/dev/null; then
                ui_spinner_start "Importing MySQL/MariaDB database"
                local DB_CONT
                # FIX: precise compose-name match first (MRM-060), loose grep
                # only as fallback — avoids picking an unrelated mysql container
                DB_CONT=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^(pasarguard-)?(mysql|mariadb)[-_]?[0-9]*$' | head -1)
                [ -z "$DB_CONT" ] && DB_CONT=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE "mysql|mariadb" | head -1)
                if [ -z "$DB_CONT" ]; then
                    DB_CONT=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^(pasarguard-)?(mysql|mariadb)[-_]?[0-9]*$' | head -1)
                    [ -z "$DB_CONT" ] && DB_CONT=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -iE "mysql|mariadb" | head -1)
                    [ -n "$DB_CONT" ] && docker start "$DB_CONT" >/dev/null 2>&1
                fi
                # NEW SERVER FIX: If no mysql container exists at all (brand new server),
                # start it from the restored docker-compose to create it
                if [ -z "$DB_CONT" ] && [ -n "$PANEL_COMPOSE_FILE" ] && [ -f "$PANEL_COMPOSE_FILE" ]; then
                    log_backup "INFO" "No MySQL container found - starting from restored compose (new server)"
                    run_compose_file "$PANEL_COMPOSE_FILE" up -d mysql mariadb db >/dev/null 2>&1 || true
                    sleep 3
                    DB_CONT=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^(pasarguard-)?(mysql|mariadb)[-_]?[0-9]*$' | head -1)
                    [ -z "$DB_CONT" ] && DB_CONT=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE "mysql|mariadb" | head -1)
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
                    # FIX (MRM-108): validate the dump before importing — a
                    # truncated mysqldump would silently produce a half-restored DB.
                    if ! mrm_mysql_dump_ok "$SQL_FILE"; then
                        log_backup "ERROR" "Refusing to restore: MySQL dump is empty/truncated (missing 'Dump completed' trailer)"
                        ui_error "Dump file is incomplete - aborting DB restore (live DB left untouched)"
                    else
                        if docker exec -e MYSQL_PWD="$DB_PASS" "$DB_CONT" mysql -u "$DB_USER" "$DB_NAME" < "$SQL_FILE" 2>/dev/null; then
                            DB_IMPORTED=true
                        fi
                    fi
                    # NEW-SERVER FIX (MRM-109): the dump has no role passwords —
                    # align the MySQL user password with the restored .env.
                    local MYSQL_ROOT_PASS
                    MYSQL_ROOT_PASS="$(grep -m1 '^MYSQL_ROOT_PASSWORD' "$PANEL_ENV" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")"
                    mrm_sync_mysql_user_password "$DB_CONT" "$DB_USER" "$DB_PASS" "$MYSQL_ROOT_PASS" || \
                        ui_warning "MySQL password could not be synced - the panel may fail to authenticate"
                    [ "$DB_IS_GZ" = true ] && [ -f "$TEMP_SQL" ] && [ "$TEMP_SQL" != "$DB_RESTORE_PATH" ] && rm -f "$TEMP_SQL"
                fi
                ui_spinner_stop
                if [ "$DB_IMPORTED" = true ]; then ui_success "MySQL database imported successfully!"; log_backup "SUCCESS" "MySQL DB imported"; else ui_error "MySQL database import failed!"; log_backup "ERROR" "MySQL DB import failed"; fi
            fi
        fi
    else
        log_backup "WARNING" "No database file found in backup to restore"
        ui_warning "No database in this archive — only files were restored"
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

    ui_spinner_start "Checking xray-core binary"
    if [ -x "$XRAY_BIN_PATH" ] && "$XRAY_BIN_PATH" -version >/dev/null 2>&1; then
        ui_spinner_stop
        ui_success "xray-core present and working"
        log_backup "INFO" "xray-core already present: $XRAY_BIN_PATH"
    else
        ui_spinner_stop
        log_backup "INFO" "xray-core missing at $XRAY_BIN_PATH - downloading before service start"
        ui_spinner_start "Downloading xray-core"
        if mrm_ensure_xray_core; then
            XRAY_WAS_DOWNLOADED=true
            ui_spinner_stop
            ui_success "xray-core downloaded"
            log_backup "SUCCESS" "xray-core downloaded to $XRAY_BIN_PATH"
        else
            ui_spinner_stop
            ui_error "xray-core download failed — the node will not start"
            ui_bullet "GitHub may be blocked on this server (common in Iran)"
            ui_bullet "Check the internet connection"
            ui_bullet "Retry later with: mrm fix-node"
            log_backup "ERROR" "xray-core download failed during restore"
        fi
    fi

    # Start services (AFTER the DB is restored AND xray-core is ensured)
    local STARTED_ANY=false START_FAILED=false
    PANEL_COMPOSE_FILE="$(get_existing_compose_file panel 2>/dev/null || true)"
    NODE_COMPOSE_FILE="$(get_existing_compose_file node 2>/dev/null || true)"

    ui_spinner_start "Starting services"
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
        ui_spinner_start "Restarting node with the new xray-core"
        if run_compose_file "$NODE_COMPOSE_FILE" restart >/dev/null 2>&1; then
            ui_spinner_stop
            ui_success "Node restarted"
            log_backup "INFO" "Node restarted after xray-core download"
        else
            ui_spinner_stop
            ui_warning "Node restart failed — restart it manually with docker restart <node-container>"
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
        ui_section "Post-restore auto-fix"
        # main() already appends to /var/log/mrm-post-restore.log via
        # log_msg; the old `tee -a` duplicated every line (MRM-067)
        main 2>&1
        ui_success "Post-restore auto-fix completed"
        log_backup "SUCCESS" "Post-restore auto-fix executed"
    else
        ui_warning "post_restore module not loaded — auto-fix skipped"
        log_backup "WARNING" "post_restore module not loaded"
    fi

    # Final cleanup
    rm -rf "$WORK_DIR"
    trap - RETURN

    # ── FINAL VERIFICATION: does the panel actually answer? ──
    # "Services started" only means containers exist. The restore is only
    # successful when the panel process responds on its port (MRM-109).
    local PANEL_UP=false PANEL_HEALTH_PORT
    PANEL_HEALTH_PORT="$(grep -m1 '^UVICORN_PORT' "$PANEL_ENV" 2>/dev/null | cut -d'=' -f2- | tr -d "\"'" | tr -d '[:space:]')"
    case "$PANEL_HEALTH_PORT" in ''|*[!0-9]*) PANEL_HEALTH_PORT=8000 ;; esac
    ui_spinner_start "Waiting for the panel to answer"
    local HEALTH_TRIES=0
    while [ "$HEALTH_TRIES" -lt 30 ]; do
        if curl -sk -o /dev/null -m 3 "https://127.0.0.1:$PANEL_HEALTH_PORT/health" || \
           curl -s -o /dev/null -m 3 "http://127.0.0.1:$PANEL_HEALTH_PORT/health"; then
            PANEL_UP=true
            break
        fi
        sleep 2
        HEALTH_TRIES=$((HEALTH_TRIES + 1))
    done
    ui_spinner_stop
    if [ "$PANEL_UP" = true ]; then
        ui_success "Panel answers on port $PANEL_HEALTH_PORT (/health OK)"
        log_backup "SUCCESS" "Panel health OK after restore (port $PANEL_HEALTH_PORT)"
    else
        ui_warning "Panel did NOT answer /health on port $PANEL_HEALTH_PORT within 60s"
        ui_bullet "Logs: docker logs \$(docker ps -q -f name=pasarguard) --tail 50"
        ui_bullet "Backup log: tail -n 40 $BACKUP_LOG"
        log_backup "WARNING" "Panel /health not answering after restore (port $PANEL_HEALTH_PORT)"
    fi

    local NEW_SERVER_IP=$(get_server_ip)
    log_backup "SUCCESS" "Restore v${BACKUP_VERSION} completed from: $(basename "$SELECTED")"

    echo ""
    ui_box_start ok "Restore completed"
    ui_box_line "Archive" "$(basename "$SELECTED")"
    ui_box_line "Server IP" "$NEW_SERVER_IP"
    if [ "$PANEL_UP" = true ]; then
        ui_box_line "Panel" "$(ui_state ok "UP (port $PANEL_HEALTH_PORT)")"
    else
        ui_box_line "Panel" "$(ui_state bad "NOT RESPONDING — see $BACKUP_LOG")"
    fi
    [ -n "${SAFETY_BACKUP:-}" ] && ui_box_line "Safety copy" "$(basename "$SAFETY_BACKUP")"
    if [ "$XRAY_WAS_DOWNLOADED" = true ]; then
        ui_box_line "xray-core" "$(ui_state ok "Downloaded") not part of the archive"
    elif [ -x "$XRAY_BIN_PATH" ]; then
        ui_box_line "xray-core" "$(ui_state ok "Present")"
    else
        ui_box_line "xray-core" "$(ui_state bad "Missing") run: mrm fix-node"
    fi
    ui_box_end
    ui_pause
}

# ─── Database-only repair (MRM-110) ──────────────────────────────────────────
# Rescue tool for a server left crash-looping by an earlier failed restore
# (panel logs: DuplicateObjectError: type "proxytypes" already exists /
# "Database migrations failed"). It resets and re-imports ONLY the database
# from an MRM backup archive — files, .env and certs are NOT touched.
do_repair_db() {
    setup_env
    init_backup_logging

    local ARCHIVE="${1:-}"
    if [ -z "$ARCHIVE" ]; then
        ARCHIVE="$(find "$BACKUP_DIR" -maxdepth 1 -name 'MRM-*.tar.gz' ! -name 'pre_restore_*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2- | head -1)"
    fi
    if [ -z "$ARCHIVE" ] || [ ! -f "$ARCHIVE" ]; then
        ui_error "No backup archive found (put the MRM-*.tar.gz into $BACKUP_DIR or pass its path)"
        ui_cmd "mrm repair-db /root/mrm-backups/MRM-2026....tar.gz" "repair from a specific archive"
        ui_pause
        return 1
    fi

    ui_header "Database-only repair" "$(basename "$ARCHIVE")"
    ui_warning "The database will be RESET and re-imported from the archive"
    ui_note "Files, .env and certificates are NOT touched."
    if ! ui_confirm "Repair the database now?"; then ui_cancelled; ui_pause; return; fi

    log_backup "INFO" "repair-db started from: $(basename "$ARCHIVE")"

    local WORK
    WORK="$(mktemp -d /tmp/mrm_repair.XXXXXX)"
    if ! tar -xzf "$ARCHIVE" -C "$WORK" 2>/dev/null; then
        ui_error "Cannot extract the archive"
        rm -rf "$WORK"; ui_pause; return 1
    fi
    local ROOT
    ROOT="$(find "$WORK" -maxdepth 3 -type d -name 'MRM_*' 2>/dev/null | head -1)"
    [ -z "$ROOT" ] && ROOT="$(find "$WORK" -maxdepth 2 -type f -name 'backup_info.txt' -printf '%h' 2>/dev/null | head -1)"
    if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
        ui_error "Invalid archive structure — MRM backup root not found"
        rm -rf "$WORK"; ui_pause; return 1
    fi

    local PICK DB_FILE IS_GZ=false
    PICK="$(mrm_pick_db_restore "$ROOT")"
    case "$(printf '%s' "$PICK" | cut -d'|' -f1)" in
        sqlite) DB_FILE="$(printf '%s' "$PICK" | cut -d'|' -f2-)" ;;
        gz)     DB_FILE="$(printf '%s' "$PICK" | cut -d'|' -f2-)"; IS_GZ=true ;;
        sql)    DB_FILE="$(printf '%s' "$PICK" | cut -d'|' -f2-)" ;;
        *)      ui_error "No database file inside this archive"; rm -rf "$WORK"; ui_pause; return 1 ;;
    esac
    log_backup "INFO" "repair-db: db file=$DB_FILE gz=$IS_GZ"

    # Stop ONLY the panel service (the DB container must keep running)
    local PANEL_COMPOSE_FILE
    PANEL_COMPOSE_FILE="$(get_existing_compose_file panel 2>/dev/null || true)"
    [ -n "$PANEL_COMPOSE_FILE" ] && run_compose_file "$PANEL_COMPOSE_FILE" stop pasarguard >/dev/null 2>&1 || true

    local REPAIR_OK=false
    local SQL="$DB_FILE"
    if [ "$IS_GZ" = true ]; then
        gunzip -c "$DB_FILE" > "$WORK/db.sql" 2>/dev/null && SQL="$WORK/db.sql"
    fi

    if mrm_is_sqlite_file "$DB_FILE" && [ "$IS_GZ" = false ]; then
        # --- SQLite repair: copy the file to the configured location ---
        ui_spinner_start "Restoring SQLite database"
        local TARGET_SQLITE ENV_URL
        ENV_URL="$(grep -m1 '^SQLALCHEMY_DATABASE_URL' "$PANEL_ENV" 2>/dev/null | cut -d'=' -f2- | tr -d "\"'" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -n "$ENV_URL" ] && TARGET_SQLITE="$(mrm_sqlite_path_from_url "$ENV_URL" 2>/dev/null)"
        if [ -n "$TARGET_SQLITE" ] && [[ "$TARGET_SQLITE" == /* ]]; then
            mkdir -p "$(dirname "$TARGET_SQLITE")" 2>/dev/null
            if cp -f "$DB_FILE" "$TARGET_SQLITE" 2>/dev/null; then REPAIR_OK=true; fi
        else
            local HOST_CAND
            for HOST_CAND in "$DATA_DIR/db.sqlite3" "$PANEL_DIR/db.sqlite3"; do
                if cp -f "$DB_FILE" "$HOST_CAND" 2>/dev/null; then REPAIR_OK=true; break; fi
            done
        fi
        ui_spinner_stop
    elif mrm_pg_dump_ok "$SQL"; then
        # --- PostgreSQL/TimescaleDB repair ---
        ui_spinner_start "Re-importing the PostgreSQL database"
        local DB_CONT
        DB_CONT="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^(pasarguard-)?(postgresql|timescaledb|postgres|timescale)[-_]?[0-9]*$' | head -1)"
        [ -z "$DB_CONT" ] && DB_CONT="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE "postgres|timescale" | head -1)"
        if [ -z "$DB_CONT" ] && [ -n "$PANEL_COMPOSE_FILE" ]; then
            run_compose_file "$PANEL_COMPOSE_FILE" up -d timescaledb postgresql postgres db >/dev/null 2>&1 || true
            sleep 3
            DB_CONT="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE "timescale|postgres" | head -1)"
        fi
        if [ -z "$DB_CONT" ]; then
            ui_spinner_stop
            ui_error "No PostgreSQL container found"
        else
            local TRIES=0
            while [ "$TRIES" -lt 30 ]; do
                docker exec "$DB_CONT" pg_isready -U postgres >/dev/null 2>&1 && break
                sleep 1; TRIES=$((TRIES+1))
            done
            parse_db_credentials "$PANEL_ENV"
            [ -z "$DB_USER" ] && DB_USER="pasarguard"
            [ -z "$DB_NAME" ] && DB_NAME="$DB_USER"
            local DB_PASS_R
            DB_PASS_R="$(grep -m1 '^DB_PASSWORD' "$PANEL_ENV" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")"
            [ -z "$DB_PASS_R" ] && DB_PASS_R="$DB_PASS"

            docker exec -e PGPASSWORD="$DB_PASS_R" "$DB_CONT" psql -w -U "$DB_USER" -d postgres -c \
                "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB_NAME' AND pid <> pg_backend_pid();" >/dev/null 2>&1 || true
            local IMPORT_KEEP="/var/log/mrm-pg-import-$(date +%Y%m%d_%H%M%S).log"
            if docker exec -e PGPASSWORD="$DB_PASS_R" "$DB_CONT" psql -w -U "$DB_USER" -d postgres -c "DROP DATABASE IF EXISTS \"$DB_NAME\" WITH (FORCE);" >/dev/null 2>&1 \
               && docker exec -e PGPASSWORD="$DB_PASS_R" "$DB_CONT" psql -w -U "$DB_USER" -d postgres -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\";" >/dev/null 2>&1 \
               && docker exec -i -e PGPASSWORD="$DB_PASS_R" "$DB_CONT" psql -w -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" < "$SQL" > "$IMPORT_KEEP" 2>&1; then
                local ROWS
                ROWS="$(docker exec -e PGPASSWORD="$DB_PASS_R" "$DB_CONT" psql -w -tA -U "$DB_USER" -d "$DB_NAME" -c "SELECT count(*) FROM alembic_version;" 2>/dev/null)"
                if [ "$ROWS" = "1" ]; then
                    REPAIR_OK=true
                    ui_success "Database re-imported and verified (alembic_version=1)"
                    mrm_sync_pg_role_password "$DB_CONT" "$DB_USER" "$DB_PASS_R" || true
                else
                    ui_error "Import incomplete (alembic_version=$ROWS) — full log: $IMPORT_KEEP"
                    log_backup "ERROR" "repair-db import incomplete"
                fi
            else
                ui_error "Import failed — full psql output: $IMPORT_KEEP (send this file if you ask for help)"
                log_backup "ERROR" "repair-db import failed; log: $IMPORT_KEEP"
            fi
        fi
        ui_spinner_stop
    elif mrm_mysql_dump_ok "$SQL"; then
        # --- MySQL/MariaDB repair ---
        ui_spinner_start "Re-importing the MySQL database"
        local DB_CONT
        DB_CONT="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^(pasarguard-)?(mysql|mariadb)[-_]?[0-9]*$' | head -1)"
        [ -z "$DB_CONT" ] && DB_CONT="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE "mysql|mariadb" | head -1)"
        if [ -n "$DB_CONT" ]; then
            parse_db_credentials "$PANEL_ENV"
            [ -z "$DB_USER" ] && DB_USER="pasarguard"
            [ -z "$DB_NAME" ] && DB_NAME="$DB_USER"
            local MYSQL_ROOT_PASS
            MYSQL_ROOT_PASS="$(grep -m1 '^MYSQL_ROOT_PASSWORD' "$PANEL_ENV" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")"
            if docker exec -e MYSQL_PWD="${MYSQL_ROOT_PASS:-$DB_PASS}" "$DB_CONT" mysql -uroot -e "DROP DATABASE IF EXISTS \`$DB_NAME\`; CREATE DATABASE \`$DB_NAME\`;" 2>/dev/null \
               && docker exec -i -e MYSQL_PWD="${MYSQL_ROOT_PASS:-$DB_PASS}" "$DB_CONT" mysql -uroot "$DB_NAME" < "$SQL" 2>/dev/null; then
                REPAIR_OK=true
                mrm_sync_mysql_user_password "$DB_CONT" "$DB_USER" "$DB_PASS" "$MYSQL_ROOT_PASS" || true
            fi
        fi
        ui_spinner_stop
    else
        ui_error "Database file failed validation (missing dump trailer) — archive may be truncated"
    fi

    rm -rf "$WORK"

    # Start the panel again and wait for /health
    [ -n "$PANEL_COMPOSE_FILE" ] && run_compose_file "$PANEL_COMPOSE_FILE" up -d >/dev/null 2>&1 || true
    local PANEL_UP=false HEALTH_PORT TRIES=0
    HEALTH_PORT="$(grep -m1 '^UVICORN_PORT' "$PANEL_ENV" 2>/dev/null | cut -d'=' -f2- | tr -d "\"'" | tr -d '[:space:]')"
    case "$HEALTH_PORT" in ''|*[!0-9]*) HEALTH_PORT=8000 ;; esac
    if [ "$REPAIR_OK" = true ]; then
        ui_spinner_start "Waiting for the panel to answer"
        while [ "$TRIES" -lt 30 ]; do
            if curl -sk -o /dev/null -m 3 "https://127.0.0.1:$HEALTH_PORT/health" || \
               curl -s -o /dev/null -m 3 "http://127.0.0.1:$HEALTH_PORT/health"; then
                PANEL_UP=true; break
            fi
            sleep 2; TRIES=$((TRIES+1))
        done
        ui_spinner_stop
    fi

    echo ""
    if [ "$REPAIR_OK" = true ] && [ "$PANEL_UP" = true ]; then
        ui_box_start ok "Database repaired — panel is UP (port $HEALTH_PORT)"
        log_backup "SUCCESS" "repair-db completed successfully"
    elif [ "$REPAIR_OK" = true ]; then
        ui_box_start bad "Database imported but panel did not answer /health"
        ui_box_line "Log" "$BACKUP_LOG"
        ui_box_end
        log_backup "WARNING" "repair-db imported the DB but the panel did not come up"
    else
        ui_box_start bad "Database repair failed"
        ui_box_line "Log" "$BACKUP_LOG"
        ui_box_end
        log_backup "ERROR" "repair-db failed"
    fi
    ui_pause
}

# Xray release asset name for this machine's architecture.
# IMPORTANT: XTLS/Xray-core assets are Xray-linux-64.zip (x86_64) and
# Xray-linux-arm64-v8a.zip (aarch64) - NOT x64/arm64 (those URLs 404!).
