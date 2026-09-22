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

# Check pg_health.sh uses precise DB container match (MRM-083)
if grep -qF '^(pasarguard-)?(postgresql' "$PROJECT_DIR/manager/pg_health.sh" && grep -qF '^(pasarguard-)?(mysql' "$PROJECT_DIR/manager/pg_health.sh"; then
    pass "pg_health.sh uses precise DB container match"
else
    fail "pg_health.sh uses loose grep for DB containers"
fi

# Check pg_health.sh temp-key uses -i not -it (MRM-084)
if grep -q 'docker exec -it' "$PROJECT_DIR/manager/pg_health.sh"; then
    fail "pg_health.sh temp-key still uses -it (fails without TTY)"
else
    pass "pg_health.sh temp-key uses -i (TTY not required)"
fi

# Check pg_health.sh does not mark official defaults as failures (MRM-085)
if grep -qF 'پیشفرض رسمی' "$PROJECT_DIR/manager/pg_health.sh"; then
    pass "pg_health.sh marks undefined JOB_* as official default (not ✘)"
else
    fail "pg_health.sh reports undefined JOB_* as failure"
fi

# Check pg_health.sh handles unreadable cert honestly (MRM-086)
if grep -qF 'نتوانستم سرتیفیکت را بخوانم' "$PROJECT_DIR/manager/pg_health.sh"; then
    pass "pg_health.sh warns on unreadable cert (no false 'public CA')"
else
    fail "pg_health.sh claims 'issued by public CA' on unreadable cert"
fi

# Check diagnostics.sh matches the official panel/node images (MRM-087)
DIAG="$PROJECT_DIR/manager/diagnostics.sh"
if grep -qF '^pasarguard/panel(:|$)' "$DIAG" && grep -qF '^pasarguard/node(:|$)' "$DIAG"; then
    pass "diagnostics.sh matches pasarguard/panel + pasarguard/node images"
else
    fail "diagnostics.sh missing precise image match for panel/node"
fi
if grep -q 'grep -qiE "pasarguard"' "$DIAG" || grep -q 'grep -qiE "pg-node"' "$DIAG"; then
    fail "diagnostics.sh still contains loose pasarguard/pg-node greps (MRM-087)"
else
    pass "diagnostics.sh has no loose pasarguard/pg-node greps"
fi

# Check diagnostics.sh reports 100-idle CPU, not the 'us' field (MRM-088)
if grep -q '100 - \$1' "$DIAG" && grep -q 'id\.\*' "$DIAG" && ! grep -qF 'top -bn1 | grep "Cpu(s)" | awk' "$DIAG"; then
    pass "mrm_check_cpu computes 100-idle (MRM-088)"
else
    fail "mrm_check_cpu still parses the layout-dependent field 2"
fi

# Check diagnostics.sh skips pre_restore_* safety copies (MRM-089)
if grep -q "grep -v '/pre_restore_'" "$DIAG"; then
    pass "mrm_latest_backup_file excludes pre_restore_* safety copies"
else
    fail "mrm_latest_backup_file can pick a pre_restore_* file"
fi

# Check diagnostics.sh anchored + comment-aware panel .env greps (MRM-090)
if grep -qF '^[[:space:]]*CUSTOM_TEMPLATES_DIRECTORY[[:space:]]*=' "$DIAG" && grep -qF 'UVICORN_SSL_CERTFILE|UVICORN_SSL_KEYFILE' "$DIAG" && ! grep -q 'SSL_CERT_FILE' "$DIAG"; then
    pass "theme/ssl checks are anchored and use real panel vars"
else
    fail "theme/ssl checks still use loose grep or SSL_CERT_FILE"
fi

# Behavioral: new grep patterns must NOT match commented lines (MRM-090)
if printf '# CUSTOM_TEMPLATES_DIRECTORY = "/x"\n' | grep -qE "^[[:space:]]*CUSTOM_TEMPLATES_DIRECTORY[[:space:]]*="; then
    fail "commented CUSTOM_TEMPLATES_DIRECTORY still counts as active"
else
    pass "commented CUSTOM_TEMPLATES_DIRECTORY is ignored (behavioral)"
fi

# Check theme.sh is_theme_active is anchored + comment-aware (MRM-091)
if grep -qE 'grep -qE "\^\[\[:space:\]\]\*SUBSCRIPTION_PAGE_TEMPLATE' "$PROJECT_DIR/manager/theme.sh"; then
    pass "theme.sh is_theme_active anchored (MRM-091)"
else
    fail "theme.sh is_theme_active still greps unanchored SUBSCRIPTION_PAGE_TEMPLATE"
fi
if grep -q 'grep -q "SUBSCRIPTION_PAGE_TEMPLATE"' "$PROJECT_DIR/manager/theme.sh"; then
    fail "theme.sh still contains the loose SUBSCRIPTION_PAGE_TEMPLATE grep"
else
    pass "theme.sh has no loose SUBSCRIPTION_PAGE_TEMPLATE grep"
fi
if printf '# SUBSCRIPTION_PAGE_TEMPLATE = "x"\n' | grep -qE "^[[:space:]]*SUBSCRIPTION_PAGE_TEMPLATE[[:space:]]*="; then
    fail "commented SUBSCRIPTION_PAGE_TEMPLATE still counts as active"
else
    pass "commented SUBSCRIPTION_PAGE_TEMPLATE is ignored (behavioral)"
fi

# Check theme.sh is_theme_active also requires the template file (MRM-091b)
if grep -q 'DATA_DIR/templates/subscription/index.html' "$PROJECT_DIR/manager/theme.sh"; then
    pass "is_theme_active requires template file existence (MRM-091b)"
else
    fail "is_theme_active can report Active with the template file missing"
fi

# Check domain_separator.sh proxy scheme follows the panel .env (MRM-092)
DS="$PROJECT_DIR/manager/domain_separator.sh"
if grep -q 'UVICORN_SSL_CERTFILE' "$DS" && grep -q '\$PANEL_PROTO://127.0.0.1:\$PANEL_PORT' "$DS"; then
    pass "domain_separator detects panel SSL from .env (MRM-092)"
else
    fail "domain_separator proxy scheme not driven by panel .env"
fi
if grep -q 'proxy_pass https://127.0.0.1' "$DS"; then
    fail "domain_separator still hard-codes https proxy_pass"
else
    pass "domain_separator has no hard-coded https proxy_pass"
fi

# Check domain_separator.sh panel port default comes from .env (MRM-093)
if grep -q 'UVICORN_PORT' "$DS" && grep -qF 'PANEL_PORT_DEF="8000"' "$DS"; then
    pass "domain_separator reads UVICORN_PORT with 8000 fallback (MRM-093)"
else
    fail "domain_separator panel port default still hard-coded"
fi
if grep -qE 'PANEL_PORT=(_DEF=)?"?7431|default: 7431' "$DS"; then
    fail "domain_separator still references hard-coded 7431 port"
else
    pass "domain_separator has no hard-coded 7431 port"
fi

# Check post_restore.sh panel-port fallback uses the official 8000 (MRM-103)
PR="$PROJECT_DIR/manager/backup/post_restore.sh"
if grep -q 'PANEL_PORT="8000"' "$PR" && ! grep -q 'PANEL_PORT="7431"' "$PR"; then
    pass "post_restore.sh panel port fallback = 8000 (MRM-103)"
else
    fail "post_restore.sh still falls back to 7431"
fi

# Check offline.sh mirror lists aligned with official PasarGuard list (MRM-106)
OFF2="$PROJECT_DIR/manager/offline.sh"
if grep -q 'https://mirror.arvancloud.ir/ubuntu' "$OFF2" \
   && grep -q 'https://repo.iut.ac.ir/repo/ubuntu"' "$OFF2" \
   && ! grep -q 'repo/ubuntu/ubuntu' "$OFF2" \
   && ! grep -q 'http://mirror.arvancloud.ir/ubuntu' "$OFF2"; then
    pass "offline.sh mirrors aligned with official list (MRM-106)"
else
    fail "offline.sh mirror lists still differ from official PasarGuard list"
fi

# Check smart_fix.sh nginx repair is scheme-aware (MRM-105)
SF="$PROJECT_DIR/manager/backup/smart_fix.sh"
if grep -q 'MRM-105' "$SF" && grep -q 'UVICORN_SSL_CERTFILE' "$SF" && grep -q 'PANEL_SSL_DETECT' "$SF"; then
    pass "smart_fix.sh converts to https only when panel SSL is on (MRM-105)"
else
    fail "smart_fix.sh still force-converts http proxy without checking panel SSL"
fi

# Check subscription template is Google-fonts-free / self-hosted (MRM-108)
TPL="$PROJECT_DIR/templates/subscription/index.html"
if ! grep -q 'fonts.googleapis.com' "$TPL" && grep -q 'data:font/woff2;base64' "$TPL"; then
    pass "subscription template self-hosts Vazirmatn (no Google Fonts) (MRM-108)"
else
    fail "subscription template still depends on Google Fonts"
fi

# Check README + ssl.sh license mentions match the actual LICENSE file (MRM-107)
LIC_FILE="$PROJECT_DIR/LICENSE"
if grep -q 'GNU GENERAL PUBLIC LICENSE' "$LIC_FILE" 2>/dev/null; then
    LICENSE_IS='GPL'
else
    LICENSE_IS='OTHER'
fi
if [ "$LICENSE_IS" = 'GPL' ]; then
    if grep -q 'License-GPLv3' "$PROJECT_DIR/README.md" \
        && grep -q 'GPL-3.0' "$PROJECT_DIR/README.md" \
        && grep -q 'License: GPL-3.0' "$PROJECT_DIR/manager/ssl.sh" \
        && ! grep -q 'License-MIT' "$PROJECT_DIR/README.md"; then
        pass "README + ssl.sh license aligned with GPL-3.0 LICENSE (MRM-107)"
    else
        fail "README/ssl.sh license mentions do not match LICENSE (MIT leak?)"
    fi
else
    pass "LICENSE file is not GPL — MRM-107 check skipped (non-GPL license in use)"
fi

# Check domain_separator.sh header version matches VERSION (MRM-094)
DS_HDR_V=$(grep -oP '^# MRM Manager v\K[0-9.]+' "$DS" 2>/dev/null | head -1)
DS_REAL_V=$(cat "$PROJECT_DIR/VERSION" 2>/dev/null | head -1)
if [ -n "$DS_HDR_V" ] && [ "$DS_HDR_V" = "$DS_REAL_V" ]; then
    pass "domain_separator header version = $DS_REAL_V (matches VERSION)"
else
    fail "domain_separator header version [$DS_HDR_V] != VERSION [$DS_REAL_V]"
fi
if grep -q '# MRM Manager v1.0.0' "$DS"; then
    fail "domain_separator header still says v1.0.0"
else
    pass "domain_separator header no longer says v1.0.0"
fi

# Check domain_separator.sh revert uses -s not -f (MRM-095)
if grep -q '\[ -s "\$EDIT_BACKUP" \]' "$DS"; then
    pass "manual-edit revert uses -s (non-empty backup) (MRM-095)"
else
    fail "manual-edit revert still checks -f on mktemp file"
fi

# Check offline.sh feeds "y" FIRST on existing-install path (MRM-096)
OFF="$PROJECT_DIR/manager/offline.sh"
EXIST_BLOCK=$(sed -n '/^    if \[ -d "\/opt\/pasarguard" \]; then/,/^    else$/p' "$OFF" 2>/dev/null)
FIRST_RESP=$(printf '%s\n' "$EXIST_BLOCK" | grep 'RESPONSES+=' | head -1)
if [ -n "$FIRST_RESP" ] && echo "$FIRST_RESP" | grep -q 'RESPONSES+="y\\n"'; then
    pass "offline.sh existing-path answers y BEFORE mirror n's (MRM-096)"
else
    fail "offline.sh existing-path RESPONSES order wrong (missing leading y)"
fi

# Check offline.sh restore removes stale MRM sources.list (MRM-097)
if grep -q 'Managed by MRM' "$OFF" && grep -q 'rm -f /etc/apt/sources.list' "$OFF" \
   && grep -q 'elif \[ -f /etc/apt/sources.list \]' "$OFF"; then
    pass "offline.sh restore cleans stale MRM sources.list (MRM-097)"
else
    fail "offline.sh restore does not remove stale MRM sources.list"
fi

# Check offline.sh apt mirror reader extracts real URLs (MRM-098)
if grep -qF 'https?://[^"[:space:]]+' "$OFF" && ! grep -qF 'awk '\''$1=="deb"' "$OFF"; then
    pass "offline_get_current_apt_mirror extracts http(s) URLs (MRM-098)"
else
    fail "offline_get_current_apt_mirror still uses field-index awk"
fi

# Check offline.sh version literals (MRM-099)
if grep -q 'v1.0.0' "$OFF"; then
    fail "offline.sh still has v1.0.0 literals"
else
    pass "offline.sh has no stale v1.0.0 literals (MRM-099)"
fi
OFF_HDR=$(grep -oP 'OFFLINE / IRAN MODE v\K[0-9.]+' "$OFF" 2>/dev/null | head -1)
OFF_VER=$(cat "$PROJECT_DIR/VERSION" 2>/dev/null | head -1)
if [ -n "$OFF_HDR" ] && [ "$OFF_HDR" = "$OFF_VER" ]; then
    pass "offline.sh header version = $OFF_VER (matches VERSION)"
else
    fail "offline.sh header version [$OFF_HDR] != VERSION [$OFF_VER]"
fi

# Check safe_ops.sh create loop guards against "/" (MRM-100)
SO="$PROJECT_DIR/manager/safe_ops.sh"
if grep -q '\[ "$TARGET" != "/" \] || continue' "$SO"; then
    pass "safe_ops.sh create loop guards "/" (MRM-100)"
else
    fail "safe_ops.sh create loop can cp -a / (missing "/" guard)"
fi

# Check safe_ops.sh restore pre-flights present backups (MRM-101)
if grep -q 'restore point incomplete' "$SO" && grep -q 'if [ ! -e "$RP_DIR/files$TARGET" ]' "$SO"; then
    pass "safe_ops.sh restore pre-flights backups (MRM-101)"
else
    fail "safe_ops.sh restore can delete live file before verifying backup"
fi

# Check safe_ops.sh header version matches VERSION (MRM-102)
SO_HDR=$(grep -oP '^# MRM Manager v\K[0-9.]+' "$SO" 2>/dev/null | head -1)
SO_VER=$(cat "$PROJECT_DIR/VERSION" 2>/dev/null | head -1)
if [ -n "$SO_HDR" ] && [ "$SO_HDR" = "$SO_VER" ]; then
    pass "safe_ops.sh header version = $SO_VER (matches VERSION)"
else
    fail "safe_ops.sh header version [$SO_HDR] != VERSION [$SO_VER]"
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

# 10.2b: every plugin module listed in install.sh must exist in the repo
MISSING=0
while IFS= read -r F; do
    [ -z "$F" ] && continue
    [ -f "$PROJECT_DIR/plugin/$F" ] || { fail "install.sh lists plugin/$F but it is missing"; MISSING=1; }
done < <(sed -n '/^PLUGIN_MODULES=(/,/^)/p' "$PROJECT_DIR/install.sh" | grep -oE '"[^"]+"' | tr -d '"')
[ "$MISSING" -eq 0 ] && pass "install.sh PLUGIN_MODULES list matches repo"

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
    sed -n '/^PLUGIN_MODULES=(/,/^)/p' "$PROJECT_DIR/install.sh" | grep -oE '"[^"]+"' | tr -d '"' | sed 's#^#plugin/#'
    echo "templates/subscription/index.html"
})
[ "$MISSING" -eq 0 ] && pass "all install.sh downloads are covered by checksums.txt"

# 10.5: every checksums.txt hash actually matches the file on disk (MRM-104) —
# a stale manifest passes the existence checks above but breaks the
# install-time sha256 verification (install.sh aborts on mismatch).
HASH_BAD=0
while read -r HASH REL; do
    [ -z "$REL" ] && continue
    ACTUAL="$(sha256sum "$PROJECT_DIR/$REL" 2>/dev/null | awk '{print $1}')"
    if [ "$ACTUAL" != "$HASH" ]; then
        fail "checksum mismatch for $REL (stale checksums.txt?)"
        HASH_BAD=1
    fi
done < "$PROJECT_DIR/checksums.txt"
[ "$HASH_BAD" -eq 0 ] && pass "all checksums.txt hashes match actual files"

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

# ─── Test Group 12: Dump Integrity Validation (MRM-108) ─────────────────────
echo "💾 Group 12: Dump Integrity Validation (MRM-108)"
echo ""

# database.sh defines only functions (plus one harmless global), so it can be
# sourced here to test the dump validators directly without docker.
if source "$PROJECT_DIR/manager/backup/database.sh" 2>/dev/null; then
    TMPVAL=$(mktemp -d)

    # PostgreSQL: complete dump must be accepted
    printf 'CREATE TABLE foo(x int);\nCOPY foo FROM stdin;\n1\n\\.\n-- PostgreSQL database dump complete\n' > "$TMPVAL/pg_good.sql"
    if mrm_pg_dump_ok "$TMPVAL/pg_good.sql"; then
        pass "mrm_pg_dump_ok accepts a complete pg_dump"
    else
        fail "mrm_pg_dump_ok rejected a complete pg_dump"
    fi

    # PostgreSQL: truncated dump (no trailer) must be rejected
    printf 'CREATE TABLE foo(x int);\n' > "$TMPVAL/pg_bad.sql"
    if mrm_pg_dump_ok "$TMPVAL/pg_bad.sql"; then
        fail "mrm_pg_dump_ok accepted a truncated dump"
    else
        pass "mrm_pg_dump_ok rejects a truncated dump"
    fi

    # PostgreSQL: empty file must be rejected
    : > "$TMPVAL/pg_empty.sql"
    if mrm_pg_dump_ok "$TMPVAL/pg_empty.sql"; then
        fail "mrm_pg_dump_ok accepted an empty dump"
    else
        pass "mrm_pg_dump_ok rejects an empty dump"
    fi

    # PostgreSQL: complete gzip dump must be accepted
    gzip -c "$TMPVAL/pg_good.sql" > "$TMPVAL/pg_good.sql.gz"
    if mrm_pg_dump_ok "$TMPVAL/pg_good.sql.gz"; then
        pass "mrm_pg_dump_ok accepts a complete .sql.gz dump"
    else
        fail "mrm_pg_dump_ok rejected a complete .sql.gz dump"
    fi

    # PostgreSQL: truncated gzip dump must be rejected
    gzip -c "$TMPVAL/pg_bad.sql" > "$TMPVAL/pg_bad.sql.gz"
    if mrm_pg_dump_ok "$TMPVAL/pg_bad.sql.gz"; then
        fail "mrm_pg_dump_ok accepted a truncated .sql.gz dump"
    else
        pass "mrm_pg_dump_ok rejects a truncated .sql.gz dump"
    fi

    # MySQL: complete dump must be accepted
    printf 'CREATE TABLE foo(x int);\n-- Dump completed on 2026-09-01 12:00:00\n' > "$TMPVAL/my_good.sql"
    if mrm_mysql_dump_ok "$TMPVAL/my_good.sql"; then
        pass "mrm_mysql_dump_ok accepts a complete mysqldump"
    else
        fail "mrm_mysql_dump_ok rejected a complete mysqldump"
    fi

    # MySQL: truncated dump must be rejected
    printf 'CREATE TABLE foo(x int);\n' > "$TMPVAL/my_bad.sql"
    if mrm_mysql_dump_ok "$TMPVAL/my_bad.sql"; then
        fail "mrm_mysql_dump_ok accepted a truncated dump"
    else
        pass "mrm_mysql_dump_ok rejects a truncated dump"
    fi

    rm -rf "$TMPVAL"
else
    fail "could not source manager/backup/database.sh for validation tests"
fi

echo ""

# ─── v1.3.0: dual templates + in-panel picker + professional coexistence ─────

# Classic template ships alongside the Zomorod-style one
if [ -s "$PROJECT_DIR/templates/subscription-classic/index.html" ] && \
   grep -q "__BRAND__" "$PROJECT_DIR/templates/subscription-classic/index.html" && \
   grep -q "اتصال مستقیم\|v2rayng://\|hiddify://" "$PROJECT_DIR/templates/subscription-classic/index.html"; then
    pass "classic template ships with placeholders + Direct Connect"
else
    fail "templates/subscription-classic/index.html missing or incomplete"
fi

# theme.sh: dual-template switcher (env-parameterized + CLI)
if grep -q 'theme_set_template()' "$PROJECT_DIR/manager/theme.sh" && \
   grep -q -- '--set-template' "$PROJECT_DIR/manager/theme.sh" && \
   grep -q 'TPL_REL=' "$PROJECT_DIR/manager/theme.sh" && \
   grep -q 'subscription-classic/index.html' "$PROJECT_DIR/manager/theme.sh"; then
    pass "theme.sh has dual-template switcher (theme_set_template + CLI)"
else
    fail "theme.sh missing theme_set_template / --set-template / TPL_REL"
fi

# Classic download URL is pinned to the installed release tag
if grep -q 'THEME_CLASSIC_HTML_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/v$(get_mrm_version)/templates/subscription-classic/index.html"' "$PROJECT_DIR/manager/utils.sh"; then
    pass "utils.sh THEME_CLASSIC_HTML_URL pinned to release tag"
else
    fail "utils.sh THEME_CLASSIC_HTML_URL missing or unpinned"
fi

# Backend: template state/switch endpoints + host bridge files
if grep -q '@router.get("/api/mrm/template")' "$PROJECT_DIR/plugin/mrm_admin_subscriptions.py" && \
   grep -q '@router.put("/api/mrm/template"' "$PROJECT_DIR/plugin/mrm_admin_subscriptions.py" && \
   grep -q 'TEMPLATE_REQUEST_FILE = DATA_DIR / "template-request.json"' "$PROJECT_DIR/plugin/mrm_admin_subscriptions.py" && \
   grep -q 'class TemplateSwitch' "$PROJECT_DIR/plugin/mrm_admin_subscriptions.py"; then
    pass "backend exposes GET/PUT /api/mrm/template with host bridge"
else
    fail "backend missing /api/mrm/template endpoints"
fi

# Panel tab: template picker card + master switch kept
if grep -q 'z-tpl-apply' "$PROJECT_DIR/plugin/mrm-special.js" && \
   grep -q 'name="z-template"' "$PROJECT_DIR/plugin/mrm-special.js" && \
   grep -q "PUT', body: JSON.stringify({ template:" "$PROJECT_DIR/plugin/mrm-special.js" && \
   grep -q 'z-enabled' "$PROJECT_DIR/plugin/mrm-special.js"; then
    pass "mrm-special.js has in-panel template picker + master switch"
else
    fail "mrm-special.js missing template picker or master switch"
fi

# Professional coexistence: MRM never removes competing products
if ! grep -q 'special_clean_competing' "$PROJECT_DIR/manager/special.sh" && \
   ! grep -q -- '--clean-others' "$PROJECT_DIR/manager/special.sh" && \
   ! grep -q 'zomorod-integrator' "$PROJECT_DIR/manager/theme.sh"; then
    pass "no competitor-removal tooling (professional coexistence)"
else
    fail "special.sh/theme.sh still remove competing integrations"
fi

# Template-switch host bridge units
if [ -f "$PROJECT_DIR/plugin/mrm-template-switch.sh" ] && \
   grep -q 'PathExists=/var/lib/pasarguard/mrm/template-request.json' "$PROJECT_DIR/plugin/mrm-template-switch.path" && \
   grep -q 'ExecStart=/opt/mrm-manager/plugin/mrm-template-switch.sh' "$PROJECT_DIR/plugin/mrm-template-switch.service"; then
    pass "mrm-template-switch host bridge is complete"
else
    fail "mrm-template-switch.sh/.path/.service incomplete"
fi

# The update bridge must own mrm-panel-update.* (un-hijacked)
if grep -q 'PathExists=/var/lib/pasarguard/mrm/update-request.json' "$PROJECT_DIR/plugin/mrm-panel-update.path" && \
   grep -q 'update-from-panel.sh' "$PROJECT_DIR/plugin/mrm-panel-update.service" && \
   grep -q 'PathExists=/var/lib/pasarguard/mrm/update-request.json' "$PROJECT_DIR/manager/special.sh"; then
    pass "mrm-panel-update.* is the update bridge (not hijacked)"
else
    fail "mrm-panel-update.* units do not match the update bridge"
fi

# Guard units stay canonical (60s reconciliation loop)
if grep -q 'sleep 60' "$PROJECT_DIR/plugin/mrm-integrator.service" && \
   grep -q 'sleep 60' "$PROJECT_DIR/manager/special.sh"; then
    pass "mrm-integrator guard keeps the canonical 60s loop"
else
    fail "mrm-integrator guard loop missing"
fi

# ─── v1.3.1: user-facing naming — «نسخه قدیمی تم» / «MRM Special» ─────────────

if grep -q 'نسخه قدیمی تم' "$PROJECT_DIR/plugin/mrm-special.js" && \
   grep -q 'MRM Special' "$PROJECT_DIR/plugin/mrm-special.js" && \
   grep -q 'Old template' "$PROJECT_DIR/manager/theme.sh" && \
   ! grep -q 'Zomorod-style' "$PROJECT_DIR/manager/theme.sh" && \
   ! grep -q 'Classic MRM' "$PROJECT_DIR/manager/theme.sh" && \
   ! grep -q 'زمرد ویژه' "$PROJECT_DIR/plugin/mrm-special.js"; then
    pass "template picker uses «نسخه قدیمی تم» / «MRM Special» naming"
else
    fail "template naming not applied (classic/zomorod labels still visible)"
fi

if grep -q 'Install / Update Template' "$PROJECT_DIR/manager/theme.sh" && \
   ! grep -q 'theme_choose_template' "$PROJECT_DIR/manager/theme.sh" && \
   grep -q 'Choose the active one (and ON/OFF) in panel' "$PROJECT_DIR/manager/theme.sh"; then
    pass "option 1 is plain install; template selection lives in the panel only"
else
    fail "menu still shows template choice in CLI or names templates in option 1"
fi

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

# ─── v1.4.0: MRM Turquoise identity — فیروزه‌ای/زغالی ─────────────────────────
if grep -qi -- "--treasury-gold: #2db7b2" templates/subscription-src/src/index.css && \
   grep -qi -- "--treasury-emerald: #0b6e6a" templates/subscription-src/src/index.css; then
    pass "[159] turquoise identity tokens in template source" || fail "[159] turquoise identity tokens in template source"
else
    fail "[159] turquoise identity tokens in template source"
fi
if grep -qi -- "#2db7b2" templates/subscription/index.html && \
   grep -qi -- "#59e0d8" templates/subscription/index.html && \
   grep -qi -- "#0b6e6a" templates/subscription/index.html; then
    pass "[160] turquoise identity in built template" || fail "[160] turquoise identity in built template"
else
    fail "[160] turquoise identity in built template"
fi
if grep -q "primary: '#2DB7B2'" plugin/mrm-runtime.js && grep -q "primary: '#2DB7B2'" plugin/mrm-special.js; then
    pass "[161] turquoise default theme colors in runtime + panel" || fail "[161] turquoise default theme colors in runtime + panel"
else
    fail "[161] turquoise default theme colors in runtime + panel"
fi
if python3 -c "
import re,sys,pathlib
pat=re.compile(r'[\U0001F300-\U0001FAFF]')
bad=[]
for root in ('templates/subscription-src/src','plugin'):
    for f in pathlib.Path(root).rglob('*'):
        if f.is_file() and f.suffix in ('.ts','.tsx','.json','.js') and f.name != 'run_tests.sh' and pat.search(f.read_text(errors='ignore')):
            bad.append(str(f))
sys.exit(1 if bad else 0)
" 2>/dev/null; then
    pass "[162] zero emoji in template source + plugin UI" || fail "[162] zero emoji in template source + plugin UI"
else
    fail "[162] zero emoji in template source + plugin UI"
fi

# ─── v1.4.1: standalone-safety — manager scripts define what they call ───────
if grep -q 'special_find_dashboard_build()' "$PROJECT_DIR/manager/special.sh" && \
   grep -q 'special_container_id()' "$PROJECT_DIR/manager/special.sh"; then
    pass "[163] special helper functions are defined (find_dashboard_build, container_id)" || fail "[163] special helper functions are defined (find_dashboard_build, container_id)"
else
    fail "[163] special helper functions are defined (find_dashboard_build, container_id)"
fi
_out164="$(cd "$PROJECT_DIR" && PANEL_DIR=/nonexistent bash manager/theme.sh --current-template 2>&1 || true)"
if ! printf '%s' "$_out164" | grep -q 'command not found'; then
    pass "[164] theme.sh standalone run has no missing functions" || fail "[164] theme.sh standalone run has no missing functions"
else
    fail "[164] theme.sh standalone run has no missing functions"
fi

# ─── v1.4.1: wizard brand cleanup — no {{ user.username }} accumulation ───────
_out165="$(cd "$PROJECT_DIR" && bash manager/theme.sh --clean-brand 'FarsNet · {{ user.username }} · {{ user.username }}' 2>/dev/null || true)"
if [ "$_out165" = "FarsNet" ]; then
    pass "[165] wizard brand cleanup strips {{ user.username }} title-suffix accumulation" || fail "[165] wizard brand cleanup strips {{ user.username }} title-suffix accumulation"
else
    fail "[165] wizard brand cleanup strips {{ user.username }} title-suffix accumulation"
fi

# ─── v1.4.2: owner detection fallbacks (role.is_owner / is_owner / is_sudo / profile) ─
if grep -qF "is_sudo" plugin/mrm-special.js &&
   grep -qF "flag(apiProfile?.is_owner)" plugin/mrm-special.js &&
   grep -qF "_admin_is_owner" plugin/mrm_admin_subscriptions.py; then
    pass "[166] owner detection fallbacks (is_sudo + profile) wired" || fail "[166] owner detection fallbacks (is_sudo + profile) wired"
else
    fail "[166] owner detection fallbacks (is_sudo + profile) wired"
fi

# ─── v1.4.3: owner detection case/shape tolerance (Owner vs owner, int/string flags) ─
if grep -qF "superadmin" plugin/mrm-special.js &&
   grep -qF "String(v).toLowerCase()" plugin/mrm-special.js &&
   grep -qF "superadmin" plugin/mrm_admin_subscriptions.py; then
    pass "[167] owner detection accepts Title-Case roles + truthy string/int flags" || fail "[167] owner detection accepts Title-Case roles + truthy string/int flags"
else
    fail "[167] owner detection accepts Title-Case roles + truthy string/int flags"
fi

# ─── v1.4.3: in-tab role diagnostics (works without console access) ──────────
if grep -qF "z-debug-open" plugin/mrm-special.js &&
   grep -qF "openRoleDebug" plugin/mrm-special.js; then
    pass "[168] in-tab role diagnostics button wired" || fail "[168] in-tab role diagnostics button wired"
else
    fail "[168] in-tab role diagnostics button wired"
fi

# ─── v1.4.4: namespace "mrm" allowed + username-fallback cannot block saves ────
if grep -qF 'RESERVED_SLUGS = {"api", "info", "raw", "apps", "usage", "admin"}' plugin/mrm_admin_subscriptions.py &&
   grep -qF '        if explicit:' plugin/mrm_admin_subscriptions.py &&
   ! grep -qF '"mrm"}' plugin/mrm_admin_subscriptions.py; then
    pass "[169] namespace slug mrm allowed; reserved words only rejected when explicit" || fail "[169] namespace slug mrm allowed; reserved words only rejected when explicit"
else
    fail "[169] namespace slug mrm allowed; reserved words only rejected when explicit"
fi

# ─── v1.4.5: template-switch un-brick + smart one-tap connect + mobile detect ─
if grep -qF "PathChanged=/var/lib/pasarguard/mrm/template-request.json" manager/special.sh &&
   grep -qF "PathChanged=/var/lib/pasarguard/mrm/update-request.json" manager/special.sh &&
   grep -qF "trap 'rm -f" plugin/mrm-template-switch.sh &&
   grep -qF "tryAutoOpen" templates/subscription-src/src/components/quick-connect.tsx &&
   grep -qF "/android/.test(userAgent)" templates/subscription-src/src/lib/osDetector.ts &&
   grep -qF "translate: none !important" templates/subscription-src/src/index.css; then
    pass "[170] template-switch un-brick (trap + PathChanged) + smart connect + mobile detect" || fail "[170] template-switch un-brick (trap + PathChanged) + smart connect + mobile detect"
else
    fail "[170] template-switch un-brick (trap + PathChanged) + smart connect + mobile detect"
fi

# ─── v1.4.6: one-tap auto install+connect flow (beginner journey) ─────────────
if grep -qF "runAutoConnect" templates/subscription-src/src/components/quick-connect.tsx &&
   grep -qF "cafebazaar.ir" templates/subscription-src/src/components/quick-connect.tsx &&
   grep -qF "waitForReturn" templates/subscription-src/src/components/quick-connect.tsx; then
    for _loc in fa en ru zh; do
        grep -qF '"autoInstallHint"' "templates/subscription-src/src/locales/${_loc}.json" || exit 1
    done
    pass "[171] one-tap auto install+connect flow with store links + 4 locales" || fail "[171] one-tap auto install+connect flow with store links + 4 locales"
else
    fail "[171] one-tap auto install+connect flow with store links + 4 locales"
fi

# ─── v1.4.7: store official app (panel Applications) drives the one-tap button ─
if grep -qF "officialTarget" templates/subscription-src/src/components/quick-connect.tsx &&
   grep -qF "useApps" templates/subscription-src/src/components/quick-connect.tsx &&
   grep -qF "import_url" templates/subscription-src/src/components/quick-connect.tsx; then
    for _loc in fa en ru zh; do
        grep -qF '"official"' "templates/subscription-src/src/locales/${_loc}.json" || exit 1
    done
    pass "[172] store official app from panel Applications drives the connect button" || fail "[172] store official app from panel Applications drives the connect button"
else
    fail "[172] store official app from panel Applications drives the connect button"
fi

# ─── v1.4.8: app import profile name = user's name (not the brand) ──────────
if grep -qF 'encode_title(username or profile["store_name"])' plugin/mrm_admin_subscriptions.py &&
   grep -qF 'db_admin, sub_username = await _validate_namespace' plugin/mrm_admin_subscriptions.py &&
   grep -qF 'db_admin, sub_username = await _admin_for_token' plugin/mrm_admin_subscriptions.py &&
   grep -qF 'userInfo?.username' templates/subscription-src/src/components/quick-connect.tsx &&
   grep -qF 'buildDeepLink(subscriptionUrl, connectName)' templates/subscription-src/src/components/quick-connect.tsx &&
   grep -qF 'b64url(`${u}#${n}`)' templates/subscription-src/src/components/quick-connect.tsx &&
   grep -qF 'b64Prefixes' templates/subscription-src/src/components/quick-connect.tsx; then
    pass "[173] app import profile-title and deep-link name follow the user's name" || fail "[173] app import profile-title and deep-link name follow the user's name"
else
    fail "[173] app import profile-title and deep-link name follow the user's name"
fi

# ─── v1.4.10: connect dialog viewport-safe + touch linux stays mobile ─────────
if grep -qF 'width: min(26rem, calc(100vw - 2rem))' templates/subscription-src/src/index.css &&
   grep -qF 'translate(-50%, -50%)' templates/subscription-src/src/index.css &&
   grep -qF '.mrm-app-row { flex-wrap: wrap; min-width: 0; }' templates/subscription-src/src/index.css &&
   grep -qF 'isTouchDevice && window.innerWidth <= 1024' templates/subscription-src/src/lib/osDetector.ts; then
    pass "[174] connect dialog fits mobile viewports + touch linux stays on mobile tabs" || fail "[174] connect dialog fits mobile viewports + touch linux stays on mobile tabs"
else
    fail "[174] connect dialog fits mobile viewports + touch linux stays on mobile tabs"
fi

# ─── v1.4.11: no foreign brand leftovers + versioned footer + no-cache ───────
if ! grep -rqF 'ganj' templates/subscription-src/src &&
   grep -qF 'Powered by' templates/subscription-src/src/components/layout/footer.tsx &&
   grep -qF '<span className="font-semibold text-primary">MRM</span>' templates/subscription-src/src/components/layout/footer.tsx &&
   grep -qE 'v1\.[0-9]+\.[0-9]+' templates/subscription-src/src/components/layout/footer.tsx &&
   grep -qF '__BRAND__' templates/subscription-src/src/App.tsx &&
   grep -qF 'no-cache, no-store, must-revalidate' plugin/mrm_admin_subscriptions.py; then
    pass "[175] MRM-branded versioned footer, zero ganj leftovers, no-cache headers" || fail "[175] MRM-branded versioned footer, zero ganj leftovers, no-cache headers"
else
    fail "[175] MRM-branded versioned footer, zero ganj leftovers, no-cache headers"
fi

# ─── v1.4.12: mrm update redeploys the deployed templates (brand/news kept) ─
if grep -qF 'theme_redeploy' manager/theme.sh &&
   grep -qF -- '--redeploy)' manager/theme.sh &&
   grep -qF 'theme-settings.json' manager/theme.sh &&
   grep -qF 'startsWith\("__"\)' manager/theme.sh &&
   grep -qF 'https://t\.me/([A-Za-z0-9_]' manager/theme.sh &&
   grep -qF 'subscription-classic/index.html' install.sh &&
   grep -qF -- '--redeploy' install.sh; then
    pass "[176] update redeploys the deployed subscription templates in place" || fail "[176] update redeploys the deployed subscription templates in place"
else
    fail "[176] update redeploys the deployed subscription templates in place"
fi

if [ "$FAIL" -eq 0 ]; then
    echo -e "  ${GREEN}✔ All tests passed!${NC}"
    echo ""
    exit 0
else
    echo -e "  ${RED}✘ Some tests failed.${NC}"
    echo ""
    exit 1
fi
