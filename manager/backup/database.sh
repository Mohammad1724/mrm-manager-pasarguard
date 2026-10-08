#!/bin/bash
# MRM Backup - Database Module v1.5.13
# SQLite/PostgreSQL/MySQL backup and restore
# Includes live-safe export, cold copy, and probe detection

# ==========================================
# DATABASE LAYER - FIXED for PasarGuard v5
# PasarGuard v5 stores SQLite INSIDE the panel
# container (/code/db.sqlite3 by default), so
# host-path checks alone silently miss the DB.
# We ask the panel itself where its DB lives.
# ==========================================

# Find the RUNNING panel container. Prefers the compose project, falls back to
# a precise name/image match (must NOT match node containers like "pasarguard-node").
mrm_panel_container() {
    local COMPOSE_FILE CID
    # FIX: prefer the container running the pasarguard/panel image — `compose ps`
    # order is not guaranteed and may return a DB/helper container first (MRM-045)
    CID="$(docker ps --format '{{.ID}}|{{.Image}}' 2>/dev/null | awk -F'|' '$2 ~ /^pasarguard\/panel(:|$)/ {print $1; exit}')"
    [ -n "$CID" ] && { printf '%s\n' "$CID"; return 0; }
    COMPOSE_FILE="$(get_existing_compose_file panel 2>/dev/null || true)"
    if [ -n "$COMPOSE_FILE" ] && [ -f "$COMPOSE_FILE" ]; then
        CID="$(docker compose -f "$COMPOSE_FILE" ps -q 2>/dev/null | head -1)"
        [ -n "$CID" ] && { printf '%s\n' "$CID"; return 0; }
    fi
    # Fallback: running container whose IMAGE is the panel image, or whose name
    # is exactly "pasarguard" (exclude *-node / node-*).
    docker ps --format '{{.ID}}|{{.Names}}|{{.Image}}' 2>/dev/null \
        | grep -iE "pasarguard/panel:|pasarguard/panel$|pasarguard/panel\b" \
        | head -1 | cut -d'|' -f1
}

# Find the panel container even if it is STOPPED (needed to copy the DB out/in
# while the panel is down). Same precise matching, using `docker ps -a`.
mrm_find_panel_container() {
    local COMPOSE_FILE CID
    # FIX: prefer the pasarguard/panel image first (MRM-045)
    CID="$(docker ps -a --format '{{.ID}}|{{.Image}}' 2>/dev/null | awk -F'|' '$2 ~ /^pasarguard\/panel(:|$)/ {print $1; exit}')"
    [ -n "$CID" ] && { printf '%s\n' "$CID"; return 0; }
    COMPOSE_FILE="$(get_existing_compose_file panel 2>/dev/null || true)"
    if [ -n "$COMPOSE_FILE" ] && [ -f "$COMPOSE_FILE" ]; then
        CID="$(docker compose -f "$COMPOSE_FILE" ps -a -q 2>/dev/null | head -1)"
        [ -n "$CID" ] && { printf '%s\n' "$CID"; return 0; }
    fi
    docker ps -a --format '{{.ID}}|{{.Names}}|{{.Image}}' 2>/dev/null \
        | grep -iE "pasarguard/panel:|pasarguard/panel$|pasarguard/panel\b|(^|\|)pasarguard(\||$)" \
        | grep -viE "node" \
        | head -1 | cut -d'|' -f1
}

# Ask the panel itself. Prints: TYPE|INFO
#   sqlite   -> sqlite|/abs/path/to/db.sqlite3
#   postgres -> postgres|host|port|user|b64pass|db
#   mysql    -> mysql|host|port|user|b64pass|db
#   UNKNOWN  -> UNKNOWN|<raw url>
mrm_probe_database() {
    local CONT="$1"
    [ -z "$CONT" ] && return 1
    docker exec -i "$CONT" python - <<'PY' 2>/dev/null
import os, base64
try:
    from sqlalchemy.engine import make_url
except ImportError:
    try:
        from sqlalchemy import make_url
    except Exception:
        print("UNKNOWN|"); raise SystemExit(0)
try:
    from config import database_settings as s
    url = s.url
except Exception:
    print("UNKNOWN|"); raise SystemExit(0)
try:
    u = make_url(url)
    dr = (u.drivername or "").lower()
    if dr.startswith("sqlite"):
        path = u.database or ""
        if path and path != ":memory:" and not path.startswith("/"):
            path = os.path.abspath(path)
        print("sqlite|" + path)
    elif dr.startswith("postgres"):
        b64 = base64.b64encode((u.password or "").encode()).decode()
        print("postgres|%s|%s|%s|%s|%s" % (u.host or "localhost", u.port or 5432, u.username or "", b64, u.database or ""))
    elif dr.startswith(("mysql", "mariadb")):
        b64 = base64.b64encode((u.password or "").encode()).decode()
        print("mysql|%s|%s|%s|%s|%s" % (u.host or "localhost", u.port or 3306, u.username or "", b64, u.database or ""))
    else:
        print("UNKNOWN|" + url)
except Exception:
    print("UNKNOWN|" + url)
PY
}

mrm_b64dec() { printf '%s' "$1" | base64 -d 2>/dev/null; }

# Sanity check: is this file a valid SQLite database? (magic header)
mrm_is_sqlite_file() {
    [ -s "$1" ] && head -c 16 "$1" 2>/dev/null | grep -q "SQLite format 3"
}

# Parse a sqlite+aiosqlite://... URL and print the DB path.
#   absolute: sqlite+aiosqlite:////var/lib/db.sqlite3 -> /var/lib/db.sqlite3
#   relative: sqlite+aiosqlite:///db.sqlite3          -> db.sqlite3
mrm_sqlite_path_from_url() {
    local URL="$1" SCHEME REST
    SCHEME="${URL%%:*}"         # scheme = everything before the first ':'
    REST="${URL#*://}"          # everything after the first ://
    case "$SCHEME" in
        sqlite*)
            # REST starts with "//"  -> absolute path (drop ONE leading slash)
            # REST starts with "/"   -> relative path  (drop the leading slash)
            printf '%s\n' "${REST#/}"
            return 0
            ;;
    esac
    return 1
}

# Live-safe SQLite export via host sqlite3 CLI (.backup handles concurrent access).
mrm_sqlite_host_backup() {
    local SRC="$1" DEST="$2"
    [ -n "$SRC" ] && [ -f "$SRC" ] || return 1
    if command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 "$SRC" ".backup '$DEST'" 2>/dev/null && mrm_is_sqlite_file "$DEST" && return 0
    fi
    # Fallback: plain copy (fine for rollback-journal SQLite, panel may be running)
    cp -f "$SRC" "$DEST" 2>/dev/null && mrm_is_sqlite_file "$DEST"
}

# Export SQLite safely (live-safe backup API) from inside the panel container
mrm_export_sqlite() {
    local CONT="$1" SRC="$2" DEST="$3"
    # FIX: unique temp name inside the shared container — a concurrent run
    # (cron + manual) would otherwise overwrite the same path (MRM-052)
    local TMP_IN="/tmp/mrm_db_backup.$$.sqlite3"
    log_backup "INFO" "SQLite export: container=$CONT src=$SRC -> $DEST"
    docker exec -i "$CONT" python - "$SRC" "$TMP_IN" <<'PY' 2>/dev/null || return 1
import sqlite3, sys, os
src_path, dst_path = sys.argv[1], sys.argv[2]
if not src_path or not os.path.exists(src_path):
    raise SystemExit("MISSING")
src = sqlite3.connect(src_path)
dst = sqlite3.connect(dst_path)
src.backup(dst)
src.close(); dst.close()
PY
    docker cp "$CONT:$TMP_IN" "$DEST" >/dev/null 2>&1 || return 1
    docker exec "$CONT" rm -f "$TMP_IN" 2>/dev/null || true
    mrm_is_sqlite_file "$DEST" || return 1
    log_backup "SUCCESS" "SQLite exported via container ($(du -h "$DEST" | cut -f1))"
    return 0
}

# Cold-copy SQLite from a STOPPED container (docker cp works while stopped).
mrm_sqlite_cold_export() {
    local CONT="$1" IN_PATH="$2" DEST="$3"
    [ -n "$CONT" ] && [ -n "$IN_PATH" ] || return 1
    docker cp "$CONT:$IN_PATH" "$DEST" >/dev/null 2>&1 && mrm_is_sqlite_file "$DEST"
}

# Try to find the sqlite path inside a (possibly stopped) container using
# docker inspect: WORKDIR + Config.Env SQLALCHEMY_DATABASE_URL.
mrm_sqlite_path_from_container() {
    local CONT="$1" ENV_URL WORKDIR
    ENV_URL="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONT" 2>/dev/null | grep -m1 '^SQLALCHEMY_DATABASE_URL=' | cut -d'=' -f2- | tr -d '"' | tr -d "'")"
    if [ -n "$ENV_URL" ]; then
        local P
        P="$(mrm_sqlite_path_from_url "$ENV_URL" 2>/dev/null)"
        if [ -n "$P" ]; then
            if [[ "$P" == /* ]]; then printf '%s\n' "$P"; return 0; fi
            WORKDIR="$(docker inspect -f '{{.Config.WorkingDir}}' "$CONT" 2>/dev/null)"
            [ -z "$WORKDIR" ] && WORKDIR="/code"
            printf '%s/%s\n' "${WORKDIR%/}" "$P"
            return 0
        fi
    fi
    # Common defaults (docker cp also works on STOPPED containers; errors if missing)
    for CAND in "/code/db.sqlite3" "/var/lib/pasarguard/db.sqlite3" "/app/db.sqlite3"; do
        if docker cp "$CONT:$CAND" /dev/null 2>/dev/null; then printf '%s\n' "$CAND"; return 0; fi
    done
    printf '%s\n' "/code/db.sqlite3"
    return 0
}

# Validate a PostgreSQL plain-text dump. pg_dump ALWAYS ends a successful dump
# with the trailer "-- PostgreSQL database dump complete". A dump missing that
# trailer is truncated/corrupt (pg_dump was killed or errored mid-way) and MUST
# NOT be trusted: restoring it yields a schema with no data and no
# alembic_version, which makes the panel crash-loop on start (MRM-108).
# Accepts a plain .sql file OR a .sql.gz (decompresses on the fly to check).
mrm_pg_dump_ok() {
    local F="$1" TAIL=""
    [ -s "$F" ] || return 1
    if [[ "$F" == *.gz ]]; then
        TAIL="$(gunzip -c "$F" 2>/dev/null | tail -c 1024)"
    else
        TAIL="$(tail -c 1024 "$F" 2>/dev/null)"
    fi
    printf '%s' "$TAIL" | grep -q "PostgreSQL database dump complete"
}

# Validate a MySQL/MariaDB dump: mysqldump ends with "-- Dump completed on ...".
mrm_mysql_dump_ok() {
    local F="$1" TAIL=""
    [ -s "$F" ] || return 1
    if [[ "$F" == *.gz ]]; then
        TAIL="$(gunzip -c "$F" 2>/dev/null | tail -c 1024)"
    else
        TAIL="$(tail -c 1024 "$F" 2>/dev/null)"
    fi
    printf '%s' "$TAIL" | grep -qE "Dump completed on|-- Dump completed"
}

# Export PostgreSQL (try: dedicated postgres container, then host pg_dump).
# Always sets PGPASSWORD (even empty) and passes -w so pg_dump NEVER prompts
# for a password interactively (would hang the menu / cron job).
mrm_export_postgres() {
    local DEST="$1" HOST="$2" PORT="$3" USER="$4" PASS="$5" DBNAME="$6"
    local CONT INNER_PORT ERR_FILE
    # FIX: match official compose service names first (pasarguard-postgresql-1…),
    # not any container whose name merely contains "postgres" (MRM-049)
    CONT=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^(pasarguard-)?(postgresql|timescaledb|postgres|timescale)[-_]?[0-9]*$' | head -1)
    [ -z "$CONT" ] && CONT=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE "postgres|timescale" | head -1)
    if [ -n "$CONT" ]; then
        # FIX: the panel connects through pgbouncer (6432) but inside the postgres
        # container the server itself listens on 5432 — dump the server directly (MRM-046)
        # FIX (MRM-108): dump the container's OWN server via the local unix socket
        # (no -h). A hostname from the panel URL (docker service name, pgbouncer…)
        # may not be reachable from INSIDE the DB container, and guessing 5432 is
        # fragile. The unix socket always hits the right instance.
        INNER_PORT="$PORT"
        [ "$INNER_PORT" = "6432" ] && INNER_PORT=5432
        log_backup "INFO" "pg_dump via container: $CONT ($USER@$DBNAME)"
        ERR_FILE="$(mktemp /tmp/mrm-pgdump.XXXXXX)"
        # MRM-110: --no-owner --no-privileges makes the dump PORTABLE — on a new
        # server roles from the old server (extra owners/grantees) may not exist,
        # which previously aborted the import mid-way and left a half-restored DB
        # (schema present, alembic_version empty -> panel crash-loop).
        # Objects are created by the importing user (= the panel DB user), which
        # is exactly what the panel needs.
        if ! ( docker exec -e PGPASSWORD="$PASS" "$CONT" pg_dump -w --no-owner --no-privileges -U "$USER" -d "$DBNAME" > "$DEST" 2>"$ERR_FILE" \
               && mrm_pg_dump_ok "$DEST" ); then
            # Retry over TCP localhost in case the image has no unix socket
            log_backup "WARNING" "unix-socket pg_dump failed, retrying via 127.0.0.1:$INNER_PORT"
            if ! ( docker exec -e PGPASSWORD="$PASS" "$CONT" pg_dump -w --no-owner --no-privileges -h 127.0.0.1 -p "$INNER_PORT" -U "$USER" -d "$DBNAME" > "$DEST" 2>"$ERR_FILE" \
                   && mrm_pg_dump_ok "$DEST" ); then
                log_backup "ERROR" "pg_dump via container failed: $(tail -n 3 "$ERR_FILE" 2>/dev/null | tr '\n' ' ')"
                # FIX (MRM-108): never leave a partial dump behind — it could be
                # archived as a "valid" DB file and later restored.
                rm -f "$ERR_FILE" "$DEST"
                return 1
            fi
        fi
        rm -f "$ERR_FILE"
        log_backup "SUCCESS" "PostgreSQL dumped via container: $(du -h "$DEST" 2>/dev/null | cut -f1)"
        return 0
    fi
    if command -v pg_dump >/dev/null 2>&1; then
        log_backup "INFO" "pg_dump via host: $HOST:$PORT ($USER/$DBNAME)"
        # SECURITY: Use .pgpass to avoid exposing password in process list
        local PGPASS_FILE
        PGPASS_FILE=$(mktemp /tmp/mrm-pgpass.XXXXXX)
        echo "$HOST:$PORT:$DBNAME:$USER:$PASS" > "$PGPASS_FILE"
        chmod 600 "$PGPASS_FILE"
        if PGPASSFILE="$PGPASS_FILE" pg_dump -w -h "$HOST" -p "$PORT" -U "$USER" -d "$DBNAME" 2>/dev/null > "$DEST" \
           && mrm_pg_dump_ok "$DEST"; then
            rm -f "$PGPASS_FILE"
            return 0
        fi
        rm -f "$PGPASS_FILE" "$DEST"
    fi
    return 1
}

# Export MySQL/MariaDB (try: container mysqldump, then host mysqldump).
# MYSQL_PWD is always set (even empty) so the client never prompts for a password.
mrm_export_mysql() {
    local DEST="$1" HOST="$2" PORT="$3" USER="$4" PASS="$5" DBNAME="$6"
    local CONT
    # FIX: match official compose service names, not any "mysql/mariadb" container (MRM-049)
    CONT=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^(pasarguard-)?(mysql|mariadb)[-_]?[0-9]*$' | head -1)
    [ -z "$CONT" ] && CONT=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE "mysql|mariadb" | head -1)
    if [ -n "$CONT" ]; then
        if docker exec -e MYSQL_PWD="$PASS" "$CONT" mysqldump --connect-timeout=5 -h"$HOST" -P"$PORT" -u"$USER" "$DBNAME" 2>/dev/null > "$DEST" \
           && mrm_mysql_dump_ok "$DEST"; then
            return 0
        fi
        rm -f "$DEST"
    fi
    if command -v mysqldump >/dev/null 2>&1; then
        # SECURITY: Use config file to avoid exposing password in process list
        local MYCNF_FILE
        MYCNF_FILE=$(mktemp /tmp/mrm-myconf.XXXXXX)
        cat > "$MYCNF_FILE" <<MYEOF
[client]
user=$USER
password=$PASS
host=$HOST
port=$PORT
MYEOF
        chmod 600 "$MYCNF_FILE"
        if mysqldump --defaults-file="$MYCNF_FILE" --single-transaction --connect-timeout=5 "$DBNAME" 2>/dev/null > "$DEST" \
           && mrm_mysql_dump_ok "$DEST"; then
            rm -f "$MYCNF_FILE"
            return 0
        fi
        rm -f "$MYCNF_FILE" "$DEST"
    fi
    return 1
}

# Main DB backup entry: mrm_backup_database <dest_dir>
# Sets globals: DB_BACKUP_FILE, DB_BACKUP_DESC. Returns 0 = success.
DB_BACKUP_FILE=""; DB_BACKUP_DESC=""
mrm_backup_database() {
    local DEST_DIR="$1" CONT PROBE TYPE
    DB_BACKUP_FILE=""; DB_BACKUP_DESC=""
    CONT="$(mrm_panel_container)"
    log_backup "INFO" "Panel container: ${CONT:-NOT FOUND}"
    if [ -n "$CONT" ]; then
        PROBE="$(mrm_probe_database "$CONT")"
    fi
    TYPE="$(printf '%s' "$PROBE" | cut -d'|' -f1)"
    log_backup "INFO" "Database probe: ${PROBE:-none}"

    if [ "$TYPE" = "sqlite" ]; then
        local SQLITE_PATH
        SQLITE_PATH="$(printf '%s' "$PROBE" | cut -d'|' -f2-)"
        # 1) Host-visible path (official PasarGuard installs put the DB at
        #    /var/lib/pasarguard/db.sqlite3, which IS on the host volume)
        if [ -n "$SQLITE_PATH" ] && [ -f "$SQLITE_PATH" ]; then
            if mrm_sqlite_host_backup "$SQLITE_PATH" "$DEST_DIR/db.sqlite3"; then
                DB_BACKUP_FILE="$DEST_DIR/db.sqlite3"
                DB_BACKUP_DESC="SQLite ($(du -h "$DB_BACKUP_FILE" | cut -f1))"
                log_backup "SUCCESS" "SQLite exported from host path: $SQLITE_PATH"
                return 0
            fi
        fi
        # 2) Live backup API inside the running container (covers in-container DBs)
        if [ -n "$SQLITE_PATH" ] && [ -n "$CONT" ] && mrm_export_sqlite "$CONT" "$SQLITE_PATH" "$DEST_DIR/db.sqlite3"; then
            DB_BACKUP_FILE="$DEST_DIR/db.sqlite3"
            DB_BACKUP_DESC="SQLite ($(du -h "$DB_BACKUP_FILE" | cut -f1))"
            return 0
        fi
        # 3) Panel stopped? Cold-copy from the container filesystem
        local PCONT
        PCONT="$(mrm_find_panel_container)"
        if [ -n "$PCONT" ]; then
            local IN_PATH
            IN_PATH="$(mrm_sqlite_path_from_container "$PCONT")"
            if mrm_sqlite_cold_export "$PCONT" "$IN_PATH" "$DEST_DIR/db.sqlite3"; then
                DB_BACKUP_FILE="$DEST_DIR/db.sqlite3"
                DB_BACKUP_DESC="SQLite (cold copy $IN_PATH)"
                log_backup "SUCCESS" "SQLite cold-copied from stopped container: $IN_PATH"
                return 0
            fi
        fi
        # 4) Last resort: known host paths (older PasarGuard versions)
        local HOST_CAND
        for HOST_CAND in "$DATA_DIR/db.sqlite3" "$PANEL_DIR/db.sqlite3"; do
            if [ -f "$HOST_CAND" ] && [ -s "$HOST_CAND" ]; then
                cp "$HOST_CAND" "$DEST_DIR/db.sqlite3" 2>/dev/null || continue
                # FIX: validate the copied file before trusting it (MRM-051)
                if ! mrm_is_sqlite_file "$DEST_DIR/db.sqlite3"; then
                    log_backup "WARN" "Copied file is not a valid SQLite db: $HOST_CAND"
                    continue
                fi
                DB_BACKUP_FILE="$DEST_DIR/db.sqlite3"
                DB_BACKUP_DESC="SQLite (host copy)"
                log_backup "SUCCESS" "SQLite exported from host path: $HOST_CAND"
                return 0
            fi
        done
        log_backup "ERROR" "SQLite not found (probe=$SQLITE_PATH, host=$DATA_DIR|$PANEL_DIR)"
        return 1
    elif [ "$TYPE" = "postgres" ]; then
        local PHOST PPORT PUSER PPASS PDB
        PHOST="$(printf '%s' "$PROBE" | cut -d'|' -f2)"
        PPORT="$(printf '%s' "$PROBE" | cut -d'|' -f3)"
        PUSER="$(printf '%s' "$PROBE" | cut -d'|' -f4)"
        PPASS="$(mrm_b64dec "$(printf '%s' "$PROBE" | cut -d'|' -f5)")"
        PDB="$(printf '%s' "$PROBE" | cut -d'|' -f6)"
        if [ -n "$PUSER" ] && [ -n "$PDB" ] && mrm_export_postgres "$DEST_DIR/db.sql" "$PHOST" "$PPORT" "$PUSER" "$PPASS" "$PDB"; then
            DB_BACKUP_FILE="$DEST_DIR/db.sql"; DB_BACKUP_DESC="PostgreSQL"
            return 0
        fi
        # FIX: real .env retry straight to the server port — the old loop
        # iterated a single empty tuple and never retried anything (MRM-047)
        # SECURITY: no hardcoded passwords — only credentials from .env file
        if [ -n "$PANEL_ENV" ] && [ -f "$PANEL_ENV" ]; then
            parse_db_credentials "$PANEL_ENV"
            if [ -n "$DB_USER" ] && [ -n "$DB_NAME" ] && \
               mrm_export_postgres "$DEST_DIR/db.sql" "${DB_HOST:-127.0.0.1}" "5432" "$DB_USER" "$DB_PASS" "$DB_NAME"; then
                DB_BACKUP_FILE="$DEST_DIR/db.sql"; DB_BACKUP_DESC="PostgreSQL (fallback)"
                return 0
            fi
        fi
        log_backup "ERROR" "PostgreSQL export failed ($PDB@$PHOST:$PPORT)"
        return 1
    elif [ "$TYPE" = "mysql" ]; then
        local MHOST MPORT MUSER MPASS MDB
        MHOST="$(printf '%s' "$PROBE" | cut -d'|' -f2)"
        MPORT="$(printf '%s' "$PROBE" | cut -d'|' -f3)"
        MUSER="$(printf '%s' "$PROBE" | cut -d'|' -f4)"
        MPASS="$(mrm_b64dec "$(printf '%s' "$PROBE" | cut -d'|' -f5)")"
        MDB="$(printf '%s' "$PROBE" | cut -d'|' -f6)"
        if [ -n "$MUSER" ] && [ -n "$MDB" ] && mrm_export_mysql "$DEST_DIR/db.sql" "$MHOST" "$MPORT" "$MUSER" "$MPASS" "$MDB"; then
            DB_BACKUP_FILE="$DEST_DIR/db.sql"; DB_BACKUP_DESC="MySQL/MariaDB"
            return 0
        fi
        log_backup "ERROR" "MySQL export failed"
        return 1
    fi

    # Probe failed / unknown -> fall back to old .env grep behavior
    log_backup "WARN" "DB probe failed, falling back to .env detection"
    if grep -qiE "postgresql|postgres" "$PANEL_ENV" 2>/dev/null; then
        parse_db_credentials "$PANEL_ENV"
        if mrm_export_postgres "$DEST_DIR/db.sql" "${DB_HOST:-127.0.0.1}" "5432" "${DB_USER:-pasarguard}" "$DB_PASS" "${DB_NAME:-pasarguard}"; then
            DB_BACKUP_FILE="$DEST_DIR/db.sql"; DB_BACKUP_DESC="PostgreSQL"
            return 0
        fi
        return 1
    fi
    # FIX: MySQL/MariaDB .env fallback (MRM-050) — previously this went straight
    # to sqlite and reported "No database found" for MySQL installs
    if grep -qiE "mysql|mariadb" "$PANEL_ENV" 2>/dev/null; then
        parse_db_credentials "$PANEL_ENV"
        if [ -n "$DB_USER" ] && [ -n "$DB_NAME" ] && \
           mrm_export_mysql "$DEST_DIR/db.sql" "${DB_HOST:-127.0.0.1}" "${DB_PORT:-3306}" "$DB_USER" "$DB_PASS" "$DB_NAME"; then
            DB_BACKUP_FILE="$DEST_DIR/db.sql"; DB_BACKUP_DESC="MySQL/MariaDB"
            return 0
        fi
        return 1
    fi
    # Assume sqlite, try host paths
    local HOST_CAND
    for HOST_CAND in "$DATA_DIR/db.sqlite3" "$PANEL_DIR/db.sqlite3"; do
        if mrm_sqlite_host_backup "$HOST_CAND" "$DEST_DIR/db.sqlite3"; then
            DB_BACKUP_FILE="$DEST_DIR/db.sqlite3"; DB_BACKUP_DESC="SQLite (host copy)"
            return 0
        fi
    done
    log_backup "ERROR" "No database found/exportable"
    return 1
}


mrm_pick_db_restore() {
    local ROOT="$1"
    if [ -f "$ROOT/database/db.sqlite3" ]; then
        printf 'sqlite|%s\n' "$ROOT/database/db.sqlite3"; return 0
    fi
    if [ -f "$ROOT/database/db.sql.gz" ]; then
        printf 'gz|%s\n' "$ROOT/database/db.sql.gz"; return 0
    fi
    if [ -f "$ROOT/database/db.sql" ]; then
        printf 'sql|%s\n' "$ROOT/database/db.sql"; return 0
    fi
    printf 'none|\n'; return 1
}

# ============================================================
# DB ROLE PASSWORD SYNC (MRM-109 — restore on a NEW server)
# pg_dump / mysqldump NEVER contain role passwords. On a new
# server the database was initialized with the NEW install's
# generated password, while the restored .env still sends the
# OLD one. The import itself succeeds (docker exec psql uses the
# container's local socket, which is trust-auth), but afterwards
# the panel connects over TCP/pgbouncer with the OLD password and
# crash-loops on "password authentication failed" -> the panel
# never comes up. Fix: set the role password to EXACTLY what the
# restored .env sends, using the local socket (no password needed
# there). The password itself is never logged.
#
# MRM-111 fix: run as the INSTANCE SUPERUSER (-U POSTGRES_USER
# from the container config). The previous version connected as
# the container OS user (root), and psql then looked for a role
# named "root" -> FATAL: role "root" does not exist -> the sync
# could never succeed. Also creates the role when the restored
# .env names a user this instance has never seen.
# ============================================================
mrm_pg_instance_superuser() {
    local CONT="$1" SU
    [ -n "$CONT" ] || { printf 'postgres\n'; return 0; }
    SU="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONT" 2>/dev/null | grep -m1 '^POSTGRES_USER=' | cut -d'=' -f2- | tr -d '"' | tr -d "'")"
    printf '%s\n' "${SU:-postgres}"
    return 0
}

mrm_sync_pg_role_password() {
    local CONT="$1" DB_USER="$2" DB_PASS="$3"
    [ -n "$CONT" ] && [ -n "$DB_USER" ] || return 1
    [[ "$DB_USER" =~ ^[A-Za-z0-9_]+$ ]] || { log_backup "ERROR" "Refusing to sync: unsafe role name '$DB_USER'"; return 1; }
    local SU
    SU="$(mrm_pg_instance_superuser "$CONT")"
    log_backup "INFO" "Syncing PostgreSQL role password with restored .env (role: $DB_USER, admin: $SU)"
    # IMPORTANT: psql -c does NOT perform :'var' variable substitution
    # (-c must be completely parsable by the server, per psql docs), so the
    # statement MUST go through STDIN for -v interpolation to work.
    # :'usr' / :'pass' are safely quoted by psql itself, which also handles
    # passwords containing quotes/backslashes.
    local EXISTS
    EXISTS="$(docker exec -i "$CONT" psql -w -U "$SU" -d postgres -tA -c "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER';" 2>/dev/null)"
    if [ "$EXISTS" = "1" ]; then
        if ! docker exec -i "$CONT" psql -w -U "$SU" -d postgres -v ON_ERROR_STOP=1 \
             -v usr="$DB_USER" -v pass="$DB_PASS" >/dev/null 2>&1 <<'SQL'
ALTER ROLE :"usr" WITH LOGIN PASSWORD :'pass';
SQL
        then
            log_backup "ERROR" "Could not ALTER ROLE $DB_USER - panel may fail with 'password authentication failed'"
            return 1
        fi
    else
        log_backup "INFO" "Role $DB_USER does not exist on this instance - creating it with the restored .env password"
        if ! docker exec -i "$CONT" psql -w -U "$SU" -d postgres -v ON_ERROR_STOP=1 \
             -v usr="$DB_USER" -v pass="$DB_PASS" >/dev/null 2>&1 <<'SQL'
CREATE ROLE :"usr" WITH LOGIN PASSWORD :'pass';
SQL
        then
            log_backup "ERROR" "Could not CREATE ROLE $DB_USER - panel may fail to connect"
            return 1
        fi
    fi
    # Prove the fix over the real auth path (TCP + password). Best-effort:
    # the server may not listen on 127.0.0.1 inside the container.
    if docker exec -e PGPASSWORD="$DB_PASS" "$CONT" psql -w -h 127.0.0.1 -p 5432 -U "$DB_USER" -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
        log_backup "SUCCESS" "Verified: TCP login with the restored .env password works"
    else
        log_backup "INFO" "Role password ALTER applied (TCP verify skipped - server may not listen on 127.0.0.1:5432 inside the container)"
    fi
    return 0
}

# MySQL/MariaDB counterpart of mrm_sync_pg_role_password (MRM-109).
# ROOT_PASS comes from MYSQL_ROOT_PASSWORD in the restored .env (best effort).
mrm_sync_mysql_user_password() {
    local CONT="$1" DB_USER="$2" DB_PASS="$3" ROOT_PASS="$4"
    [ -n "$CONT" ] && [ -n "$DB_USER" ] || return 1
    log_backup "INFO" "Syncing MySQL user password with restored .env (user: $DB_USER)"
    # Escape for a MySQL string literal (backslash first, then single quote)
    local ESC="${DB_PASS//\\/\\\\}"
    ESC="${ESC//\'/\\\'}"
    if docker exec -e MYSQL_PWD="${ROOT_PASS:-}" "$CONT" mysql -uroot -e \
        "ALTER USER '$DB_USER'@'%' IDENTIFIED BY '$ESC'; FLUSH PRIVILEGES;" >/dev/null 2>&1 \
       || docker exec -e MYSQL_PWD="${ROOT_PASS:-}" "$CONT" mysql -uroot -e \
        "SET PASSWORD FOR '$DB_USER'@'%' = PASSWORD('$ESC'); FLUSH PRIVILEGES;" >/dev/null 2>&1; then
        :
    else
        log_backup "ERROR" "Could not sync MySQL user password - panel may fail to authenticate (check MYSQL_ROOT_PASSWORD in .env)"
        return 1
    fi
    if docker exec -e MYSQL_PWD="$DB_PASS" "$CONT" mysql -h127.0.0.1 -u"$DB_USER" -e "SELECT 1;" >/dev/null 2>&1; then
        log_backup "SUCCESS" "Verified: TCP login with the restored .env password works"
    fi
    return 0
}

# ============================================================
# EXTENSION ENSURE (MRM-111 — the missing piece of TimescaleDB restores)
# pg_dump does NOT dump extension definitions. A database freshly
# created by restore has NO extensions, so importing a dump from a
# TimescaleDB install dies mid-way (ON_ERROR_STOP) on the first
# object referencing timescale internals — leaving the half-restored
# DB that crash-loops the panel ('type "proxytypes" already exists').
# Installing the extensions BEFORE the import fixes the import.
# ============================================================
mrm_pg_ensure_extensions() {
    local CONT="$1" ADMIN="$2" DBNAME="$3" DUMP="$4"
    [ -n "$CONT" ] && [ -n "$ADMIN" ] && [ -n "$DBNAME" ] || return 1
    if [ -n "$DUMP" ] && [ -f "$DUMP" ] && grep -aqiE "timescaledb|_timescaledb_internal|create_hypertable" "$DUMP" 2>/dev/null; then
        log_backup "INFO" "Dump references TimescaleDB objects - installing the extension before the import"
        if ! docker exec -i "$CONT" psql -w -v ON_ERROR_STOP=1 -U "$ADMIN" -d "$DBNAME" -c "CREATE EXTENSION IF NOT EXISTS timescaledb;" >/dev/null 2>&1; then
            log_backup "WARNING" "CREATE EXTENSION timescaledb failed - the import may fail on timescale-dependent objects (is this a TimescaleDB install?)"
        fi
    fi
    # Common companions: best-effort and harmless when unavailable.
    docker exec -i "$CONT" psql -w -U "$ADMIN" -d "$DBNAME" -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;" >/dev/null 2>&1 || true
    return 0
}

# ============================================================
# SAFETY ROLLBACK (MRM-110 — a failed import must never leave a
# half-restored database behind)
# A dump import that dies mid-way (ON_ERROR_STOP) leaves the
# target DB with a schema but NO data / NO alembic_version. The
# panel then crash-loops on every start with:
#   DuplicateObjectError: type "proxytypes" already exists
# This re-imports the PRE-RESTORE database export captured in the
# safety backup (pre_restore_*.tar.gz -> */current_db_backup), so
# the server returns to its working pre-restore state.
# ============================================================
mrm_rollback_db_from_safety() {
    local SAFETY_TAR="$1" DB_CONT="$2" DB_USER="$3" DB_PASS="$4" DB_NAME="$5"
    [ -n "$SAFETY_TAR" ] && [ -f "$SAFETY_TAR" ] || return 1
    local RD SDB
    RD="$(mktemp -d /tmp/mrm_rollback.XXXXXX)" || return 1
    if ! tar -xzf "$SAFETY_TAR" -C "$RD" 2>/dev/null; then
        rm -rf "$RD"; return 1
    fi
    SDB="$(find "$RD" -type f -name 'current_db_backup' 2>/dev/null | head -1)"
    if [ -z "$SDB" ] || [ ! -s "$SDB" ]; then
        rm -rf "$RD"; return 1
    fi
    log_backup "INFO" "Rolling back the database from safety copy: $(basename "$SAFETY_TAR")"

    local ROLL_OK=false
    if mrm_is_sqlite_file "$SDB"; then
        # SQLite: copy the safety file back to the known host locations
        local TGT
        for TGT in "$DATA_DIR/db.sqlite3" "$PANEL_DIR/db.sqlite3"; do
            if [ -n "$TGT" ] && cp -f "$SDB" "$TGT" 2>/dev/null; then
                ROLL_OK=true
                log_backup "SUCCESS" "SQLite rolled back to $TGT"
                break
            fi
        done
    elif mrm_pg_dump_ok "$SDB"; then
        # PostgreSQL: reset the broken DB and re-import the safety dump.
        # MRM-111: admin ops run as the instance superuser; extensions are
        # installed before the re-import (same reason as the main import).
        local RB_ADMIN
        RB_ADMIN="$(mrm_pg_instance_superuser "$DB_CONT")"
        docker exec -i "$DB_CONT" psql -w -U "$RB_ADMIN" -d postgres -c "SELECT 1;" >/dev/null 2>&1 || RB_ADMIN="$DB_USER"
        if [ -n "$DB_CONT" ] && [[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]]; then
            docker exec -e PGPASSWORD="$DB_PASS" "$DB_CONT" psql -w -U "$RB_ADMIN" -d postgres -c \
                "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB_NAME' AND pid <> pg_backend_pid();" >/dev/null 2>&1 || true
            if docker exec -e PGPASSWORD="$DB_PASS" "$DB_CONT" psql -w -U "$RB_ADMIN" -d postgres -c "DROP DATABASE IF EXISTS \"$DB_NAME\" WITH (FORCE);" >/dev/null 2>&1 \
               && docker exec -e PGPASSWORD="$DB_PASS" "$DB_CONT" psql -w -U "$RB_ADMIN" -d postgres -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\";" >/dev/null 2>&1; then
                mrm_sync_pg_role_password "$DB_CONT" "$DB_USER" "$DB_PASS" >/dev/null 2>&1 || true
                mrm_pg_ensure_extensions "$DB_CONT" "$RB_ADMIN" "$DB_NAME" "$SDB"
                if docker exec -i -e PGPASSWORD="$DB_PASS" "$DB_CONT" psql -w -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" < "$SDB" >"$RD/import.log" 2>&1; then
                    local ROWS
                    ROWS="$(docker exec -e PGPASSWORD="$DB_PASS" "$DB_CONT" psql -w -tA -U "$DB_USER" -d "$DB_NAME" -c "SELECT count(*) FROM alembic_version;" 2>/dev/null)"
                    if [ "$ROWS" = "1" ]; then
                        ROLL_OK=true
                    else
                        log_backup "ERROR" "Rollback import incomplete (alembic_version=$ROWS)"
                    fi
                else
                    log_backup "ERROR" "Rollback import failed: $(tail -n 3 "$RD/import.log" 2>/dev/null | tr '\n' ' ')"
                fi
            else
                log_backup "ERROR" "Rollback could not recreate database $DB_NAME"
            fi
        fi
    else
        log_backup "WARNING" "Safety DB is neither a valid SQLite file nor a complete pg dump - cannot roll back"
    fi

    rm -rf "$RD"
    if [ "$ROLL_OK" = true ]; then
        log_backup "SUCCESS" "Database rolled back to the pre-restore safety copy"
        return 0
    fi
    log_backup "ERROR" "Could not roll back to the safety database"
    return 1
}

