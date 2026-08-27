#!/bin/bash
# MRM Manager Test Suite
# Run: bash tests/run_tests.sh
# Exit code: 0 = all pass, 1 = failures

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0
SKIP=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✔ PASS${NC}: $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}✘ FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
skip() { echo -e "  ${YELLOW}⊘ SKIP${NC}: $1"; SKIP=$((SKIP + 1)); }

echo "═══════════════════════════════════════════════════════════"
echo "  MRM Manager Test Suite"
echo "  Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════════════════"
echo ""

# ─── Test Group 1: Syntax Validation ─────────────────────────────────────────
echo "📋 Group 1: Syntax Validation (bash -n)"
echo ""

for f in "$PROJECT_DIR"/manager/*.sh; do
    if bash -n "$f" 2>/dev/null; then
        pass "$(basename "$f")"
    else
        fail "$(basename "$f") - syntax error"
    fi
done

for f in "$PROJECT_DIR"/manager/backup/*.sh; do
    if bash -n "$f" 2>/dev/null; then
        pass "backup/$(basename "$f")"
    else
        fail "backup/$(basename "$f") - syntax error"
    fi
done

echo ""

# ─── Test Group 2: Security Checks ───────────────────────────────────────────
echo "🔒 Group 2: Security Checks"
echo ""

# Check for hardcoded credentials
if grep -rn "17240304" "$PROJECT_DIR/manager/" >/dev/null 2>&1; then
    fail "Hardcoded credential '17240304' found in source"
else
    pass "No hardcoded credentials found"
fi

# Check for curl | bash pattern (should be fixed)
if grep -rn 'bash -c "$(curl' "$PROJECT_DIR/manager/main.sh" >/dev/null 2>&1; then
    fail "Unsafe curl|bash pattern found in main.sh"
else
    pass "No unsafe curl|bash in main.sh"
fi

# Check that update mechanism uses temp file
if grep -q "mktemp" "$PROJECT_DIR/manager/main.sh"; then
    pass "Update mechanism uses temp file"
else
    fail "Update mechanism should use temp file"
fi

echo ""

# ─── Test Group 3: Version Consistency ───────────────────────────────────────
echo "🔢 Group 3: Version Consistency"
echo ""

# Check VERSION file
if [ -f "$PROJECT_DIR/VERSION" ]; then
    VER_FILE=$(cat "$PROJECT_DIR/VERSION" | head -1)
    if [ -n "$VER_FILE" ]; then
        pass "VERSION file exists: $VER_FILE"
    else
        fail "VERSION file is empty"
    fi
else
    fail "VERSION file missing"
fi

# Check versions.conf
if [ -f "$PROJECT_DIR/versions.conf" ]; then
    source "$PROJECT_DIR/versions.conf"
    if [ "${MRM_VERSION:-}" = "$VER_FILE" ]; then
        pass "versions.conf MRM_VERSION matches VERSION file ($MRM_VERSION)"
    else
        fail "Version mismatch: VERSION=$VER_FILE, versions.conf=$MRM_VERSION"
    fi
else
    fail "versions.conf missing"
fi

echo ""

# ─── Test Group 4: File Structure ────────────────────────────────────────────
echo "📁 Group 4: File Structure"
echo ""

REQUIRED_FILES=(
    "install.sh"
    "manager/main.sh"
    "manager/backup.sh"
    "manager/utils.sh"
    "manager/backup/init.sh"
    "manager/backup/database.sh"
    "manager/backup/backup_core.sh"
    "manager/backup/restore_core.sh"
    "manager/backup/telegram.sh"
    "manager/backup/smart_fix.sh"
    "manager/backup/xray.sh"
    "manager/backup/post_restore.sh"
    "manager/backup/menu.sh"
)

for f in "${REQUIRED_FILES[@]}"; do
    if [ -f "$PROJECT_DIR/$f" ]; then
        pass "File exists: $f"
    else
        fail "Missing file: $f"
    fi
done

echo ""

# ─── Test Group 5: Module Integrity ──────────────────────────────────────────
echo "🧩 Group 5: Module Integrity"
echo ""

# Check that backup.sh sources all modules (direct source lines OR the
# fail-fast loop introduced in MRM-043)
MODULES=("init.sh" "telegram.sh" "smart_fix.sh" "database.sh" "backup_core.sh" "restore_core.sh" "xray.sh" "post_restore.sh" "menu.sh")
for mod in "${MODULES[@]}"; do
    if grep -q "source.*$mod" "$PROJECT_DIR/manager/backup.sh" || \
       { grep -q "for MODULE in " "$PROJECT_DIR/manager/backup.sh" && grep -qw "$mod" "$PROJECT_DIR/manager/backup.sh"; }; then
        pass "backup.sh loads $mod"
    else
        fail "backup.sh missing load for $mod"
    fi
done

# Check that post_restore.sh has standalone guard
if grep -q 'BASH_SOURCE\[0\].*==.*\${0}' "$PROJECT_DIR/manager/backup/post_restore.sh"; then
    pass "post_restore.sh has standalone execution guard"
else
    fail "post_restore.sh missing standalone execution guard"
fi

echo ""

# ─── Test Group 6: Idempotency Checks ────────────────────────────────────────
echo "🔄 Group 6: Idempotency Checks"
echo ""

# Check that smart_fix.sh has proxy_ssl_verify guard
if grep -q 'grep -q "proxy_ssl_verify"' "$PROJECT_DIR/manager/backup/smart_fix.sh"; then
    pass "smart_fix.sh has idempotency guard for proxy_ssl_verify"
else
    fail "smart_fix.sh missing idempotency guard"
fi

# Check that restore_core.sh uses BEGIN/COMMIT for DROP SCHEMA
if grep -q "BEGIN.*DROP SCHEMA" "$PROJECT_DIR/manager/backup/restore_core.sh"; then
    pass "restore_core.sh wraps DROP SCHEMA in transaction"
else
    fail "restore_core.sh missing transaction wrapper for DROP SCHEMA"
fi

echo ""

# ─── Test Group 7: High-Severity Security Checks ─────────────────────────────
echo "🔐 Group 7: High-Severity Security Checks"
echo ""

# Check ssl.sh has source guard
if grep -q "_SSL_MODULE_INITIALIZED" "$PROJECT_DIR/manager/ssl.sh"; then
    pass "ssl.sh has readonly source guard"
else
    fail "ssl.sh missing readonly source guard"
fi

# Check no hardcoded credentials in database.sh
if grep -q "17240304" "$PROJECT_DIR/manager/backup/database.sh" 2>/dev/null; then
    fail "database.sh still has hardcoded credential"
else
    pass "database.sh has no hardcoded credentials"
fi

# Check parse_db_credentials uses Python urllib
if grep -q "urllib.parse" "$PROJECT_DIR/manager/backup/init.sh"; then
    pass "parse_db_credentials uses urllib for URL parsing"
else
    fail "parse_db_credentials missing urllib fallback"
fi

# Check PGPASSWORD not exported in database.sh
if grep -q "^export PGPASSWORD" "$PROJECT_DIR/manager/backup/database.sh" 2>/dev/null; then
    fail "database.sh still exports PGPASSWORD"
else
    pass "database.sh uses .pgpass instead of export PGPASSWORD"
fi

# Check offline.sh has backup before destructive rm
if grep -q "THIRD_PARTY_BACKUP" "$PROJECT_DIR/manager/offline.sh"; then
    pass "offline.sh backs up third-party repos before rm"
else
    fail "offline.sh missing third-party repo backup"
fi

echo ""

# ─── Test Group 8: Medium-Severity Checks ────────────────────────────────────
echo "⚙️ Group 8: Medium-Severity Checks"
echo ""

# Check MRM_BACKUP_VERSION fallback
if grep -q 'BACKUP_VERSION:-1\.0\.5' "$PROJECT_DIR/manager/backup/init.sh"; then
    pass "MRM_BACKUP_VERSION fallback matches current version"
else
    fail "MRM_BACKUP_VERSION fallback mismatch"
fi

# Check TEMP_BASE has safety guard
if grep -q '\[\[ -n.*TEMP_BASE' "$PROJECT_DIR/manager/backup/backup_core.sh"; then
    pass "TEMP_BASE has safety guard before rm -rf"
else
    fail "TEMP_BASE missing safety guard"
fi

# Check WORK_DIR trap has safety guard
if grep -q '\[\[ -n.*WORK_DIR' "$PROJECT_DIR/manager/backup/restore_core.sh"; then
    pass "WORK_DIR trap has safety guard"
else
    fail "WORK_DIR trap missing safety guard"
fi

# Check restore_core.sh uses precise PG container match (MRM-060)
if grep -qF "^(pasarguard-)?(postgresql" "$PROJECT_DIR/manager/backup/restore_core.sh"; then
    pass "restore_core.sh uses precise compose-name match for PG container"
else
    fail "restore_core.sh missing precise PG container match"
fi

# Check restore_core.sh uses precise MySQL container match (MRM-060)
if grep -qF "^(pasarguard-)?(mysql" "$PROJECT_DIR/manager/backup/restore_core.sh"; then
    pass "restore_core.sh uses precise compose-name match for MySQL container"
else
    fail "restore_core.sh missing precise MySQL container match"
fi

# Check restore_core.sh aborts psql import on SQL error (MRM-061)
if grep -qF "ON_ERROR_STOP=1" "$PROJECT_DIR/manager/backup/restore_core.sh"; then
    pass "restore_core.sh aborts psql import on error (ON_ERROR_STOP=1)"
else
    fail "restore_core.sh missing ON_ERROR_STOP on psql import"
fi

# Check restore_core.sh excludes pre_restore safety backups from restore list (MRM-062)
if grep -qF "grep -v '/pre_restore_'" "$PROJECT_DIR/manager/backup/restore_core.sh"; then
    pass "restore_core.sh excludes pre_restore_* from restore list"
else
    fail "restore_core.sh still lists pre_restore_* as restorable"
fi

# Check post_restore.sh propagates DB-update failure to main (MRM-063)
if grep -A5 "Could not update the panel DB automatically" "$PROJECT_DIR/manager/backup/post_restore.sh" | grep -qF "return 1"; then
    pass "post_restore.sh propagates subscription DB failure (return 1)"
else
    fail "post_restore.sh swallows subscription DB failure"
fi

# Check post_restore.sh uses precise DB container match (MRM-064)
if grep -qF "^(pasarguard-)?(postgresql" "$PROJECT_DIR/manager/backup/post_restore.sh" && grep -qF "^(pasarguard-)?(mysql" "$PROJECT_DIR/manager/backup/post_restore.sh"; then
    pass "post_restore.sh uses precise DB container match"
else
    fail "post_restore.sh missing precise DB container match"
fi

# Check post_restore.sh keeps domain order for admin/sub (MRM-065)
if grep "ALL_DOMAINS=" "$PROJECT_DIR/manager/backup/post_restore.sh" | grep -q "sort -u"; then
    fail "post_restore.sh still sorts domains (admin/sub order lost)"
else
    pass "post_restore.sh preserves domain order for admin/sub"
fi

# Check post_restore.sh tolerates spaced UVICORN_* format (MRM-066)
if grep -qF 'UVICORN_PORT\s*=\s*\K[0-9]+' "$PROJECT_DIR/manager/backup/post_restore.sh"; then
    pass "post_restore.sh matches spaced UVICORN_PORT format"
else
    fail "post_restore.sh UVICORN_PORT pattern is space-sensitive"
fi

# Check restore_core.sh does not duplicate post-restore log lines via tee (MRM-067)
if grep -qF "main 2>&1 | tee -a" "$PROJECT_DIR/manager/backup/restore_core.sh"; then
    fail "restore_core.sh still uses tee -a (duplicate log lines)"
else
    pass "restore_core.sh calls main without tee -a (no duplicate log)"
fi

# Check menu.sh has no dead ENTRY POINT duplicate (MRM-068)
if grep -q "ENTRY POINT" "$PROJECT_DIR/manager/backup/menu.sh"; then
    fail "menu.sh still contains dead ENTRY POINT block"
else
    pass "menu.sh has no duplicate ENTRY POINT block"
fi

# Check delete_backup validates numeric selection (MRM-069)
if grep -qF 'SEL" =~ ^[0-9]+$' "$PROJECT_DIR/manager/backup/menu.sh" 2>/dev/null || grep -qF 'SEL =~ ^[0-9]+$' "$PROJECT_DIR/manager/backup/menu.sh"; then
    pass "menu.sh validates numeric backup selection"
else
    fail "menu.sh missing numeric selection validation"
fi

# Check do_restore validates numeric selection (MRM-069)
if grep -qF 'SEL" =~ ^[0-9]+$' "$PROJECT_DIR/manager/backup/restore_core.sh" 2>/dev/null || grep -qF 'SEL =~ ^[0-9]+$' "$PROJECT_DIR/manager/backup/restore_core.sh"; then
    pass "restore_core.sh validates numeric backup selection"
else
    fail "restore_core.sh missing numeric selection validation"
fi

# Check pre_restore backups are labelled SAFETY in list (MRM-070)
if grep -qF 'pre_restore_* ]] && TYPE="SAFETY"' "$PROJECT_DIR/manager/backup/menu.sh"; then
    pass "menu.sh labels pre_restore_* as SAFETY"
else
    fail "menu.sh does not label pre_restore_* as SAFETY"
fi

# Check telegram.sh writes TG_CONFIG verbatim via printf (MRM-071)
if grep -qF "printf 'TG_TOKEN=" "$PROJECT_DIR/manager/backup/telegram.sh"; then
    pass "telegram.sh writes config verbatim (no unquoted heredoc)"
else
    fail "telegram.sh uses expansion-prone heredoc for config"
fi

# Check telegram.sh anchors TG_* greps (MRM-072)
if grep -qF 'grep "^TG_TOKEN="' "$PROJECT_DIR/manager/backup/telegram.sh"; then
    pass "telegram.sh anchors TG_TOKEN grep"
else
    fail "telegram.sh TG_TOKEN grep is unanchored"
fi

# Check telegram.sh uses --data-urlencode for messages (MRM-073)
if grep -qF -- '--data-urlencode "text=' "$PROJECT_DIR/manager/backup/telegram.sh"; then
    pass "telegram.sh URL-encodes message text"
else
    fail "telegram.sh sends raw -d text (breaks on & + #)"
fi

# Check telegram.sh supports http(s) proxies (MRM-074)
if grep -qF -- '--proxy" "$PROXY"' "$PROJECT_DIR/manager/backup/telegram.sh"; then
    pass "telegram.sh supports http(s) proxies via --proxy"
else
    fail "telegram.sh silently ignores http(s) proxies"
fi

# Check smart_fix.sh never assumes SSH port 22 (MRM-076)
if grep -qF 'SSH_PORT=22' "$PROJECT_DIR/manager/backup/smart_fix.sh"; then
    fail "smart_fix.sh assumes SSH port 22 (lockout risk)"
else
    pass "smart_fix.sh does not assume SSH port 22"
fi

# Check smart_fix.sh reports nginx fix only on real change (MRM-077)
if grep -qF 'Nginx config left unchanged' "$PROJECT_DIR/manager/backup/smart_fix.sh"; then
    pass "smart_fix.sh reports nginx no-op honestly"
else
    fail "smart_fix.sh claims nginx repaired even when no change"
fi

# Check smart_fix.sh verifies node certs exist before success (MRM-077)
if grep -qF 'generation FAILED' "$PROJECT_DIR/manager/backup/smart_fix.sh"; then
    pass "smart_fix.sh checks openssl output before claiming certs"
else
    fail "smart_fix.sh claims certs generated on openssl failure"
fi

# Check xray.sh has no orphaned documentation comment (MRM-078)
if grep -qF 'Pick which DB file to restore' "$PROJECT_DIR/manager/backup/xray.sh"; then
    fail "xray.sh contains orphaned mrm_pick_db_restore comment"
else
    pass "xray.sh has no orphaned comment"
fi

# Check monitor.sh loads monitor.conf at runtime (MRM-079)
if grep -qF 'source "$MONITOR_CONFIG"' "$PROJECT_DIR/manager/monitor.sh"; then
    pass "monitor.sh reads monitor.conf (was write-only)"
else
    fail "monitor.sh never reads monitor.conf"
fi

# Check monitor.sh honors config cooldown + ENABLED (MRM-079)
if grep -qF 'COOLDOWN_SECONDS:-3600' "$PROJECT_DIR/manager/monitor.sh" && grep -qF 'ENABLED:-true' "$PROJECT_DIR/manager/monitor.sh"; then
    pass "monitor.sh honors COOLDOWN_SECONDS and ENABLED"
else
    fail "monitor.sh hardcodes cooldown / ignores ENABLED"
fi

# Check monitor.sh detects panel via pasarguard/panel image (MRM-080)
if grep -qF '^pasarguard\/panel' "$PROJECT_DIR/manager/monitor.sh"; then
    pass "monitor.sh matches panel image precisely (no false UP)"
else
    fail "monitor.sh uses loose 'grep pasarguard' for panel status"
fi

# Check monitor.sh anchored TG greps + http(s) proxy (MRM-081)
if grep -qF 'grep "^TG_TOKEN="' "$PROJECT_DIR/manager/monitor.sh" && grep -qF -- '--proxy" "$PROXY"' "$PROJECT_DIR/manager/monitor.sh"; then
    pass "monitor.sh telegram copy anchored + http(s) proxy"
else
    fail "monitor.sh telegram copy still has MRM-072/074 class bugs"
fi

# Check monitor.sh retries alert without parse_mode (MRM-082)
if [ "$(grep -cF -- '--data-urlencode "text=$MESSAGE"' "$PROJECT_DIR/manager/monitor.sh")" -ge 2 ]; then
    pass "monitor.sh retries alert without parse_mode"
else
    fail "monitor.sh has no plain-text retry for Markdown 400"
fi

# Check post_restore.sh validates domains
if grep -q "Skipping invalid domain" "$PROJECT_DIR/manager/backup/post_restore.sh"; then
    pass "post_restore.sh validates domain names"
else
    fail "post_restore.sh missing domain validation"
fi

echo ""

# ─── Test Group 9: Install Script ────────────────────────────────────────────
echo "📦 Group 9: Install Script Validation"
echo ""

# Check install.sh syntax
if bash -n "$PROJECT_DIR/install.sh" 2>/dev/null; then
    pass "install.sh syntax valid"
else
    fail "install.sh syntax error"
fi

# Check that install.sh includes backup modules
if grep -q "BACKUP_MODULES" "$PROJECT_DIR/install.sh"; then
    pass "install.sh includes backup modules installation"
else
    fail "install.sh missing backup modules installation"
fi

# Check that install.sh doesn't reference mirza.sh
if grep -q "mirza.sh" "$PROJECT_DIR/install.sh" 2>/dev/null; then
    # Check if it's only in the rm -f cleanup line (acceptable)
    if grep "mirza.sh" "$PROJECT_DIR/install.sh" | grep -q "rm -f"; then
        pass "install.sh properly cleans up deprecated mirza.sh"
    else
        fail "install.sh still references mirza.sh"
    fi
else
    pass "install.sh does not reference deprecated mirza.sh"
fi

echo ""

echo ""

# ─── Test Group 10: Install Manifest Consistency ─────────────────────────────
echo "📋 Group 10: Install Manifest Consistency"
echo ""

# 10.1: every core file listed in install.sh FILES must exist in the repo
MISSING=0
while IFS= read -r F; do
    [ -z "$F" ] && continue
    case "$F" in
        VERSION|versions.conf)
            [ -f "$PROJECT_DIR/$F" ] || { fail "install.sh lists $F but it is missing"; MISSING=1; } ;;
        *)
            [ -f "$PROJECT_DIR/manager/$F" ] || { fail "install.sh lists $F but manager/$F is missing"; MISSING=1; } ;;
    esac
done < <(sed -n '/^FILES=(/,/^)/p' "$PROJECT_DIR/install.sh" | grep -oE '"[^"]+"' | tr -d '"')
[ "$MISSING" -eq 0 ] && pass "install.sh FILES list matches repo"

# 10.2: every backup module listed in install.sh must exist in the repo
MISSING=0
while IFS= read -r F; do
    [ -z "$F" ] && continue
    [ -f "$PROJECT_DIR/manager/backup/$F" ] || { fail "install.sh lists backup/$F but it is missing"; MISSING=1; }
done < <(sed -n '/^BACKUP_MODULES=(/,/^)/p' "$PROJECT_DIR/install.sh" | grep -oE '"[^"]+"' | tr -d '"')
[ "$MISSING" -eq 0 ] && pass "install.sh BACKUP_MODULES list matches repo"

# 10.3: checksums.txt exists and every entry points to a real file
if [ -f "$PROJECT_DIR/checksums.txt" ]; then
    MISSING=0
    while read -r HASH REL; do
        [ -z "$REL" ] && continue
        [ -f "$PROJECT_DIR/$REL" ] || { fail "checksums.txt entry points to missing file: $REL"; MISSING=1; }
    done < "$PROJECT_DIR/checksums.txt"
    [ "$MISSING" -eq 0 ] && pass "checksums.txt entries all exist"
else
    fail "checksums.txt missing from repo"
fi

# 10.4: every file install.sh downloads must be covered by checksums.txt
MISSING=0
while read -r REL; do
    [ -z "$REL" ] && continue
    if ! grep -qE "^[0-9a-f]{64}  $REL$" "$PROJECT_DIR/checksums.txt" 2>/dev/null; then
        fail "no checksum entry for $REL"
        MISSING=1
    fi
done < <({
    sed -n '/^FILES=(/,/^)/p' "$PROJECT_DIR/install.sh" | grep -oE '"[^"]+"' | tr -d '"' | while read -r F; do
        case "$F" in
            VERSION|versions.conf) echo "$F" ;;
            *) echo "manager/$F" ;;
        esac
    done
    sed -n '/^BACKUP_MODULES=(/,/^)/p' "$PROJECT_DIR/install.sh" | grep -oE '"[^"]+"' | tr -d '"' | sed 's#^#manager/backup/#'
    echo "templates/subscription/index.html"
})
[ "$MISSING" -eq 0 ] && pass "all install.sh downloads are covered by checksums.txt"

echo ""

# ─── Test Group 11: Version Fallback Consistency ─────────────────────────────
# MRM-009/MRM-011: the registry (versions.conf) is the single source of truth;
# every hardcoded fallback in the repo must match it, otherwise releases drift.
echo "🔄 Group 11: Version Fallback Consistency"
echo ""

# Load registry (safe: local repo file)
source "$PROJECT_DIR/versions.conf" 2>/dev/null || { fail "versions.conf could not be sourced"; exit 1; }

# 11.1: REPO_REF in install.sh must match VERSION (release ref pinning)
if grep -q "REPO_REF=\"v${MRM_VERSION}\"" "$PROJECT_DIR/install.sh"; then
    pass "install.sh REPO_REF=v${MRM_VERSION} matches VERSION"
else
    fail "install.sh REPO_REF does not match VERSION (${MRM_VERSION})"
fi

# 11.2: install.sh local fallback literals must match the registry
if grep -q "MRM_VERSION=\"${MRM_VERSION}\"" "$PROJECT_DIR/install.sh"; then
    pass "install.sh MRM_VERSION fallback matches registry"
else
    fail "install.sh MRM_VERSION fallback != ${MRM_VERSION}"
fi
if grep -q "SSL_VERSION=\"${SSL_VERSION}\"" "$PROJECT_DIR/install.sh"; then
    pass "install.sh SSL_VERSION fallback matches registry"
else
    fail "install.sh SSL_VERSION fallback != ${SSL_VERSION}"
fi
if grep -q "BACKUP_VERSION=\"${BACKUP_VERSION}\"" "$PROJECT_DIR/install.sh"; then
    pass "install.sh BACKUP_VERSION fallback matches registry"
else
    fail "install.sh BACKUP_VERSION fallback != ${BACKUP_VERSION}"
fi
if grep -q "THEME_VERSION=\"${THEME_VERSION}\"" "$PROJECT_DIR/install.sh"; then
    pass "install.sh THEME_VERSION fallback matches registry"
else
    fail "install.sh THEME_VERSION fallback != ${THEME_VERSION}"
fi

# 11.3: module-level fallbacks must match the registry
if grep -q "MRM_DEFAULT_VERSION=\"${MRM_VERSION}\"" "$PROJECT_DIR/manager/utils.sh"; then
    pass "utils.sh MRM_DEFAULT_VERSION matches registry"
else
    fail "utils.sh MRM_DEFAULT_VERSION != ${MRM_VERSION}"
fi
if grep -q "SSL_VERSION:-${SSL_VERSION}" "$PROJECT_DIR/manager/ssl.sh"; then
    pass "ssl.sh SSL_VERSION fallback matches registry"
else
    fail "ssl.sh SSL_VERSION fallback != ${SSL_VERSION}"
fi
if grep -q "BACKUP_VERSION:-${BACKUP_VERSION}" "$PROJECT_DIR/manager/backup/init.sh"; then
    pass "backup/init.sh BACKUP_VERSION fallback matches registry"
else
    fail "backup/init.sh BACKUP_VERSION fallback != ${BACKUP_VERSION}"
fi
if grep -q "THEME_VERSION:-${THEME_VERSION}" "$PROJECT_DIR/manager/theme.sh"; then
    pass "theme.sh THEME_VERSION fallback matches registry"
else
    fail "theme.sh THEME_VERSION fallback != ${THEME_VERSION}"
fi

# 11.4: monitor.sh must display the version via get_mrm_version (no stale literal)
if grep -q "get_mrm_version" "$PROJECT_DIR/manager/monitor.sh"; then
    pass "monitor.sh uses get_mrm_version for Version display"
else
    fail "monitor.sh still has a stale hardcoded version display"
fi

echo ""

# ─── Summary ─────────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════"
echo "  Test Results"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo -e "  ${GREEN}Passed${NC}: $PASS"
echo -e "  ${RED}Failed${NC}: $FAIL"
echo -e "  ${YELLOW}Skipped${NC}: $SKIP"
echo -e "  Total:  $((PASS + FAIL + SKIP))"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "  ${GREEN}✔ All tests passed!${NC}"
    echo ""
    exit 0
else
    echo -e "  ${RED}✘ Some tests failed.${NC}"
    echo ""
    exit 1
fi
