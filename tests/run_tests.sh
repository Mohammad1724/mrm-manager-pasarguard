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

# Check that backup.sh sources all modules
MODULES=("init.sh" "telegram.sh" "smart_fix.sh" "database.sh" "backup_core.sh" "restore_core.sh" "xray.sh" "post_restore.sh" "menu.sh")
for mod in "${MODULES[@]}"; do
    if grep -q "source.*$mod" "$PROJECT_DIR/manager/backup.sh"; then
        pass "backup.sh sources $mod"
    else
        fail "backup.sh missing source for $mod"
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
