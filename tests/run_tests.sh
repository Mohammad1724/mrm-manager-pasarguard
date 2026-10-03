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
if grep -q 'BACKUP_VERSION:-1\.0\.9' "$PROJECT_DIR/manager/backup/init.sh"; then
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
if grep -qE "grep -v '/pre_restore_'|! -name 'pre_restore_\*'" "$PROJECT_DIR/manager/backup/restore_core.sh"; then
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
if grep -qiF 'generation failed' "$PROJECT_DIR/manager/backup/smart_fix.sh"; then
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
if grep -qF 'official default' "$PROJECT_DIR/manager/pg_health.sh"; then
    pass "pg_health.sh marks undefined JOB_* as official default (not ✘)"
else
    fail "pg_health.sh reports undefined JOB_* as failure"
fi

# Check pg_health.sh handles unreadable cert honestly (MRM-086)
if grep -qF 'Could not read the certificate' "$PROJECT_DIR/manager/pg_health.sh"; then
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
if grep -qE "grep -v '/pre_restore_'|! -name 'pre_restore_\*'" "$DIAG"; then
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
DS_HDR_V=$(grep -oP '^# MRM Manager v\K[0-9.]+' "$DS" 2>/dev/null | head -1 || true)
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
OFF_HDR=$(grep -oP 'OFFLINE / IRAN MODE v\K[0-9.]+' "$OFF" 2>/dev/null | head -1 || true)
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
SO_HDR=$(grep -oP '^# MRM Manager v\K[0-9.]+' "$SO" 2>/dev/null | head -1 || true)
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

# Guard units: optimized event-driven oneshot and 15m self-heal timer
if grep -q 'Type=oneshot' "$PROJECT_DIR/plugin/mrm-integrator.service" && \
   grep -q 'Type=oneshot' "$PROJECT_DIR/manager/special.sh" && \
   grep -q '15min' "$PROJECT_DIR/plugin/mrm-integrator.timer" && \
   grep -q '15min' "$PROJECT_DIR/manager/special.sh"; then
    pass "mrm-integrator guard uses optimized event-driven oneshot and 15m timer"
else
    fail "mrm-integrator optimized guard units missing"
fi

# ─── v1.4.16: user-facing naming — «MRM Classic (قالب کلاسیک)» / «MRM Special (قالب ویژه)» ───

if grep -q 'MRM Classic' "$PROJECT_DIR/plugin/mrm-special.js" && \
   grep -q 'MRM Special' "$PROJECT_DIR/plugin/mrm-special.js" && \
   grep -q 'MRM Classic' "$PROJECT_DIR/manager/theme.sh" && \
   ! grep -q 'نسخه قدیمی تم' "$PROJECT_DIR/plugin/mrm-special.js" && \
   ! grep -q 'Old template' "$PROJECT_DIR/manager/theme.sh" && \
   ! grep -q 'قالب جدید' "$PROJECT_DIR/plugin/mrm-special.js"; then
    pass "template picker uses «MRM Classic (قالب کلاسیک)» / «MRM Special (قالب ویژه)» naming"
else
    fail "template naming not applied (old/new labels still present)"
fi

if grep -q 'Install / Update MRM Classic' "$PROJECT_DIR/manager/theme.sh" && \
   grep -q 'Install / Update MRM Special' "$PROJECT_DIR/manager/theme.sh"; then
    pass "menu provides dedicated install/update options for MRM Classic and MRM Special"
else
    fail "menu missing dedicated template install options"
fi

if grep -q 'Install / Update Templates' "$PROJECT_DIR/manager/theme.sh" && \
   grep -q 'special_install_auto' "$PROJECT_DIR/manager/special.sh" && \
   grep -q -- '--install-quiet' "$PROJECT_DIR/manager/special.sh"; then
    pass "menu provides unified 1-click installer for MRM Special, Classic and panel manager"
else
    fail "menu missing unified 1-click template installer"
fi

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
   grep -qF -- "--tw-translate-y: 0 !important" templates/subscription-src/src/index.css; then
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
   grep -qF 'margin: auto !important' templates/subscription-src/src/index.css &&
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


# ─── v1.4.13: dialog geometry is transform-free and minifier-proof ────────
BLK="$(grep -o 'mrm-connect-dialog{[^}]*}' templates/subscription/index.html | head -1)"
if grep -qF 'height: fit-content !important' templates/subscription-src/src/index.css &&
   grep -qF 'transform: none !important' templates/subscription-src/src/index.css &&
   grep -qF -- '--tw-translate-x: 0 !important' templates/subscription-src/src/index.css &&
   grep -qF -- '--tw-enter-scale: 1 !important' templates/subscription-src/src/index.css &&
   [ -n "$BLK" ] &&
   printf '%s' "$BLK" | grep -qF -- '--tw-translate-x:0' &&
   ! printf '%s' "$BLK" | grep -qF 'translate(-50%'; then
    pass "[177] connect dialog geometry is transform-free and survives CSS minification" || fail "[177] connect dialog geometry is transform-free and survives CSS minification"
else
    fail "[177] connect dialog geometry is transform-free and survives CSS minification"
fi


# ─── v1.4.14: connect button opens manual picker; tokens never leak ───────
if grep -A3 'const handleMainClick' templates/subscription-src/src/components/quick-connect.tsx | grep -q 'setDialogOpen(true)' &&
   ! grep -A3 'const handleMainClick' templates/subscription-src/src/components/quick-connect.tsx | grep -q 'runAutoConnect' &&
   grep -qF "fullmatch(r'__[A-Za-z_]+__'" manager/theme.sh &&
   grep -qF "brand = brand or 'MRM'" manager/theme.sh &&
   grep -qF '__(?:BRAND|BOT|SUP|NEWS)__' manager/theme.sh; then
    pass "[178] connect button opens the manual app picker; theme refresh never leaks raw tokens" || fail "[178] connect button opens the manual app picker; theme refresh never leaks raw tokens"
else
    fail "[178] connect button opens the manual app picker; theme refresh never leaks raw tokens"
fi


# ─── v1.4.15: Zomorod performance & polish parity ─────────────────────────
if grep -qF 'Type=oneshot' plugin/mrm-integrator.service && \
   grep -qF '_ROUTES_CACHE' plugin/mrm_admin_subscriptions.py && \
   grep -qF 'domObserver?.disconnect()' plugin/mrm-runtime.js && \
   grep -qF 'THEME_PRESETS' plugin/mrm-special.js && \
   grep -qF 'UPDATE_DISMISS_PREFIX' plugin/mrm-special.js && \
   grep -qF 'QRCodeSVG' templates/subscription-src/src/components/qr-modal.tsx && \
   grep -qF 'backdrop-filter: none !important' templates/subscription-src/src/index.css && \
   grep -qF 'treasury-qr-dialog' templates/subscription-src/src/index.css; then
    pass "[179] Zomorod parity: oneshot integrator, route cache, theme studio presets, dismissible notice, mobile GPU mode & SVG QR" || fail "[179] Zomorod parity: oneshot integrator, route cache, theme studio presets, dismissible notice, mobile GPU mode & SVG QR"
else
    fail "[179] Zomorod parity: oneshot integrator, route cache, theme studio presets, dismissible notice, mobile GPU mode & SVG QR"
fi

# ─── v1.4.19: isolated template sources & safe bidirectional switching ───
if grep -qF 'theme_get_special_source' manager/theme.sh && \
   grep -qF 'theme_get_classic_source' manager/theme.sh && \
   grep -qF 'subscription-special' install.sh && \
   grep -qF 'SPECIAL_FINAL_FILE' manager/theme.sh && \
   grep -qF 'dep_sp' manager/theme.sh; then
    pass "[180] template sources isolated in subscription-special & subscription-classic to prevent cross-contamination" || fail "[180] template sources isolated in subscription-special & subscription-classic to prevent cross-contamination"
else
    fail "[180] template sources isolated in subscription-special & subscription-classic to prevent cross-contamination"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Group 12: UI consistency (v1.5.0 design system — manager/ui.sh)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "Group 12: UI consistency"
UI_FILES=$(ls "$PROJECT_DIR"/manager/*.sh "$PROJECT_DIR"/manager/backup/*.sh "$PROJECT_DIR"/install.sh)

# 12.1: every ui_* helper used by a module must exist in ui.sh
UI_USED=$(grep -ohE '\bui_[a-z_]+' $UI_FILES | grep -vE '^ui_[a-z_]*_$' | sort -u)
UI_DEFINED=$(grep -oE '^ui_[a-z_]+\(\)' "$PROJECT_DIR/manager/ui.sh" "$PROJECT_DIR/install.sh" | sed 's/.*://; s/()//' | sort -u)
UI_MISSING=""
for FN in $UI_USED; do
    grep -qxF "$FN" <<< "$UI_DEFINED" || UI_MISSING="$UI_MISSING $FN"
done
if [ -z "$UI_MISSING" ]; then
    pass "every ui_* helper referenced by the modules is defined in ui.sh"
else
    fail "ui_* helpers used but undefined:$UI_MISSING"
fi

# 12.2: no raw colour echo left in interactive modules (all output goes through ui_*)
if grep -lE 'echo -e "\$\{(RED|GREEN|YELLOW|BLUE|CYAN)\}' $UI_FILES >/dev/null 2>&1; then
    fail "raw coloured echo -e still present in: $(grep -lE 'echo -e "\$\{(RED|GREEN|YELLOW|BLUE|CYAN)\}' $UI_FILES | xargs -n1 basename | tr '\n' ' ')"
else
    pass "no raw coloured echo -e left in modules (unified ui_* output)"
fi

# 12.3: no ad-hoc prompts — every read uses ui_ask/ui_select/ui_confirm (stand-ins excluded)
if grep -nE 'read (-r )?-p "' $UI_FILES | grep -vE 'Press Enter to continue' >/dev/null 2>&1; then
    fail "ad-hoc 'read -p' prompts remain: $(grep -lE 'read (-r )?-p "' $UI_FILES | grep -v ui.sh | xargs -n1 basename | tr '\n' ' ')"
else
    pass "no ad-hoc read -p prompts (ui_ask / ui_select / ui_confirm everywhere)"
fi

# 12.4: y/n questions are unified through ui_confirm (no literal (y/n) variants)
if grep -nE '\((y/n|y/N|Y/n)\)' $UI_FILES >/dev/null 2>&1; then
    fail "literal (y/n) prompts remain: $(grep -lE '\((y/n|y/N|Y/n)\)' $UI_FILES | xargs -n1 basename | tr '\n' ' ')"
else
    pass "no literal (y/n) prompt variants — ui_confirm is the single yes/no prompt"
fi

# 12.5: no emoji in CLI menus (Telegram message bodies are exempt — they are chat content)
EMOJI_HITS=$(LC_ALL=C.UTF-8 grep -nP '[\x{1F300}-\x{1FAFF}\x{1F000}-\x{1F2FF}\x{2B50}\x{2705}\x{274C}\x{2728}\x{23F0}\x{267B}\x{2699}\x{2B06}\x{21A9}]' $UI_FILES 2>/dev/null \
    | grep -vE 'send_telegram|MSG=|CAPTION=|^[^:]+:[0-9]+:[^"]*[🖥🌐📊⏰🔧💾🔥🧠🧪✅⚠️🛡️🗓️📦🏷️ℹ️]' || true)
if [ -z "$EMOJI_HITS" ]; then
    pass "no emoji in CLI menus / prompts (unified glyph set)"
else
    fail "emoji still present in CLI text: $(echo "$EMOJI_HITS" | head -3 | tr '\n' ' ')"
fi

# 12.6: no "Press any key" / bare clear + === banners (ui_header / ui_pause only)
if grep -nE 'Press any key|^\s*echo -e? "?\$?\{?[A-Z]*\}?=====' $UI_FILES >/dev/null 2>&1; then
    fail "legacy pause/banner style remains: $(grep -lE 'Press any key|=====' $UI_FILES | xargs -n1 basename | tr '\n' ' ')"
else
    pass "no legacy 'Press any key' pauses or === banners"
fi

# 12.7: no hard-coded version numbers in titles (version comes from versions.conf)
if grep -nE 'ui_header "[^"]*v[0-9]+\.[0-9]+\.[0-9]+' $UI_FILES >/dev/null 2>&1; then
    fail "hard-coded version in a header title: $(grep -lE 'ui_header "[^"]*v[0-9]+\.[0-9]+\.[0-9]+' $UI_FILES | xargs -n1 basename | tr '\n' ' ')"
else
    pass "no hard-coded version numbers in ui_header titles"
fi

# 12.8: ui.sh renders headers/menus without colour when not a TTY (log-safe)
UI_OUT=$(NO_COLOR=1 bash -c 'source "'"$PROJECT_DIR"'/manager/ui.sh"; ui_header "Test" "sub"; ui_menu_item 1 "One" "hint"; ui_kv_state "Panel" ok "Running" "x"' 2>&1)
if printf '%s' "$UI_OUT" | grep -q $'\033\['; then
    fail "ui.sh emits ANSI colours even with NO_COLOR / no TTY"
elif printf '%s' "$UI_OUT" | grep -q '┌─ MRM Manager' && printf '%s' "$UI_OUT" | grep -q '   1  One'; then
    pass "ui.sh renders plain, aligned output when colours are off"
else
    fail "ui.sh plain rendering unexpected: $(printf '%s' "$UI_OUT" | head -2 | tr '\n' ' ')"
fi

# 12.10: a bare /opt/pasarguard directory must not be reported as a stopped panel (node-only servers)
if grep -q '^mrm_panel_installed()' "$PROJECT_DIR/manager/utils.sh" && \
   grep -q 'mrm_panel_installed && PANEL_HERE=1' "$PROJECT_DIR/manager/diagnostics.sh" && \
   grep -q '"Panel" off "Not on this server"' "$PROJECT_DIR/manager/diagnostics.sh"; then
    pass "status panel distinguishes installed / node-only / not installed (no false 'Stopped')"
else
    fail "status panel still treats a bare panel directory as an installed (stopped) panel"
fi

# 12.11: domain split status is nginx-aware (separated + nginx down = warning, not green)
if grep -q '"Domains" warn "Separation configured" "nginx is not running"' "$PROJECT_DIR/manager/diagnostics.sh"; then
    pass "domain separation status reflects nginx state"
else
    fail "domain separation shows green while nginx is down"
fi

# 12.12: muted colour does not rely on DIM alone (Termius & co. ignore it)
if grep -qE "38;5;24[45]m" "$PROJECT_DIR/manager/ui.sh" && grep -qE "38;5;24[45]m" "$PROJECT_DIR/install.sh"; then
    pass "muted text uses a 256-colour grey where available (DIM-only rendering fixed)"
else
    fail "muted text still relies on the DIM attribute only"
fi

# 12.13: named 256-colour palettes with a classic fallback, mirrored by the installer
if grep -q 'MRM_PALETTE="${MRM_PALETTE:-amber}"' "$PROJECT_DIR/manager/ui.sh" && \
   grep -q '^        slate) _UI_P=' "$PROJECT_DIR/manager/ui.sh" && \
   grep -q '^        teal)  _UI_P=' "$PROJECT_DIR/manager/ui.sh" && \
   grep -q '"$MRM_PALETTE" != "classic"' "$PROJECT_DIR/manager/ui.sh" && \
   grep -q '38;5;179m' "$PROJECT_DIR/install.sh"; then
    pass "ui.sh ships amber/slate/teal palettes (classic fallback) and install.sh mirrors the default"
else
    fail "palette system missing or installer palette out of sync with ui.sh"
fi

# 12.14: palette selection is honoured and colours stay off with NO_COLOR
_PAL_OUT=$(cd "$PROJECT_DIR" && TERM=xterm-256color MRM_COLOR=always MRM_PALETTE=slate bash -c 'source manager/ui.sh; printf "%s" "$UI_C_ACCENT"' 2>/dev/null || true)
_PAL_OFF=$(cd "$PROJECT_DIR" && TERM=xterm-256color NO_COLOR=1 MRM_PALETTE=slate bash -c 'source manager/ui.sh; printf "%s%s%s" "$UI_C_ACCENT" "$UI_C_TEXT" "$UI_C_FRAME"' 2>/dev/null || true)
if [ "$_PAL_OUT" = '\033[38;5;75m' ] && [ -z "$_PAL_OFF" ]; then
    pass "MRM_PALETTE is honoured and NO_COLOR disables the palette"
else
    fail "palette selection broken (accent='$_PAL_OUT', no_color='$_PAL_OFF')"
fi

# 12.15: UTF-8 safe box drawing in the installer (tr is byte-based) + shared colour-depth detection
if ! grep -qE "tr ' ' '─'" "$PROJECT_DIR/install.sh" && grep -q '^has_256_colors()' "$PROJECT_DIR/install.sh" && \
   grep -q '^_ui_has_256()' "$PROJECT_DIR/manager/ui.sh" && grep -q '_ui_has_256 && _UI_256=1' "$PROJECT_DIR/manager/ui.sh"; then
    pass "installer draws its header without tr and both installer and ui.sh detect 256 colours the same way"
else
    fail "installer header still uses tr on UTF-8, or colour-depth detection is not shared"
fi

# 12.16: TERM=xterm over SSH (Termius/PuTTY) still gets the 256-colour palette; linux console does not
_T1=$(cd "$PROJECT_DIR" && env -u COLORTERM TERM=xterm MRM_COLOR=always bash -c 'source manager/ui.sh; printf "%s" "$_UI_256"' 2>/dev/null || true)
_T2=$(cd "$PROJECT_DIR" && env -u COLORTERM TERM=linux MRM_COLOR=always bash -c 'source manager/ui.sh; printf "%s" "$_UI_256"' 2>/dev/null || true)
if [ "$_T1" = "1" ] && [ "$_T2" = "0" ]; then
    pass "colour-depth detection: TERM=xterm → 256 colours, TERM=linux → classic"
else
    fail "colour-depth detection wrong (xterm=$_T1, linux=$_T2)"
fi

# 12.9: install.sh mini palette is self-contained (defines YELLOW etc. before use)
if grep -q 'YELLOW=' "$PROJECT_DIR/install.sh" && ! grep -q 'BLUE' "$PROJECT_DIR/install.sh"; then
    pass "install.sh palette is self-contained (YELLOW defined, no undefined BLUE)"
else
    fail "install.sh palette incomplete"
fi


# ═══════════════════════════════════════════════════════════════════════════
# Group 13: v1.5.4 audit fixes
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "Group 13: v1.5.4 audit fixes"
echo ""

# 13.1: ssl.sh discover_all_certificates prints nothing for zero certificates
#       (an empty array used to print one blank line → "1 found · 99999 days")
_T=$(mktemp -d)
mkdir -p "$_T/live" "$_T/pc" "$_T/nc"
sed "s#/etc/letsencrypt/live#$_T/live#g" "$PROJECT_DIR/manager/ssl.sh" > "$_T/ssl_t.sh"
_LINES=$(cd "$PROJECT_DIR/manager" && CONFIG_DIR="$PWD" PANEL_DEF_CERTS="$_T/pc" NODE_DEF_CERTS="$_T/nc" \
    bash -c "source '$_T/ssl_t.sh' >/dev/null 2>&1; discover_all_certificates | wc -l" 2>/dev/null || echo "err")
rm -rf "$_T"
if [ "$_LINES" = "0" ]; then
    pass "ssl.sh: no certificates → discover_all_certificates prints 0 lines"
else
    fail "ssl.sh: discover_all_certificates printed '$_LINES' line(s) with no certificates"
fi

# 13.2: ssl.sh expiry table maps VALID → ok (get_cert_status never returns OK)
if grep -q 'VALID|OK) *mode=ok' "$PROJECT_DIR/manager/ssl.sh" && \
   grep -q 'UNKNOWN) *mode=off' "$PROJECT_DIR/manager/ssl.sh"; then
    pass "ssl.sh: expiry table colours VALID certificates green"
else
    fail "ssl.sh: expiry table still treats VALID as an error state"
fi

# 13.3: ssl.sh honours MRM_DIR / its own directory and requires ui.sh (no partial stand-ins)
if grep -q 'CONFIG_DIR="\$MRM_DIR"' "$PROJECT_DIR/manager/ssl.sh" && \
   ! grep -q 'ui_header()  { echo ""' "$PROJECT_DIR/manager/ssl.sh" && \
   grep -q 'ui.sh not found' "$PROJECT_DIR/manager/ssl.sh"; then
    pass "ssl.sh: resolves CONFIG_DIR from MRM_DIR and fails clearly without ui.sh"
else
    fail "ssl.sh: CONFIG_DIR hard-coded or partial ui_* stand-ins still present"
fi

# 13.4: ssl.sh log_message is silent before init_logging created the log dir
if grep -q '\[ -d "\$SSL_LOG_DIR" \] || return 0' "$PROJECT_DIR/manager/ssl.sh"; then
    pass "ssl.sh: log_message does not error before init_logging"
else
    fail "ssl.sh: log_message writes to a missing log directory"
fi

# 13.5: monitor.sh is role-aware (node-only servers are judged by the node, not a missing panel)
if grep -q '^get_service_role()' "$PROJECT_DIR/manager/monitor.sh" && \
   grep -q '^get_node_status()' "$PROJECT_DIR/manager/monitor.sh" && \
   grep -q 'PANEL_STATUS=$(get_service_status)' "$PROJECT_DIR/manager/monitor.sh" && \
   grep -q '\${SERVICE_LABEL^^} DOWN' "$PROJECT_DIR/manager/monitor.sh" && \
   grep -q '^mrm_server_role()' "$PROJECT_DIR/manager/utils.sh"; then
    pass "monitor.sh: alerts follow the server role (panel / node / none)"
else
    fail "monitor.sh: still alerts PANEL DOWN on servers without a panel"
fi

# 13.6: shared installed-checks live in utils.sh (single definition)
_DEFS=$(grep -l '^mrm_panel_installed()' "$PROJECT_DIR"/manager/*.sh "$PROJECT_DIR"/manager/backup/*.sh 2>/dev/null | wc -l)
if [ "$_DEFS" = "1" ] && grep -q '^mrm_panel_installed()' "$PROJECT_DIR/manager/utils.sh"; then
    pass "mrm_panel_installed / mrm_node_installed defined once, in utils.sh"
else
    fail "mrm_panel_installed defined $_DEFS times (expected once, in utils.sh)"
fi

# 13.7: mrm update verifies the installer against the release checksums.txt
if grep -q 'checksums.txt" -o "\$TMP_SUMS"' "$PROJECT_DIR/manager/main.sh" && \
   grep -q 'sha256sum "\$TMP_SCRIPT"' "$PROJECT_DIR/manager/main.sh" && \
   grep -q 'Installer checksum mismatch' "$PROJECT_DIR/manager/main.sh"; then
    pass "main.sh: mrm update checks the installer SHA-256 against checksums.txt"
else
    fail "main.sh: mrm update runs an installer that is not checksum-verified"
fi

# 13.8: in-panel update check compares MRM release versions (not a foreign repo's commits)
if grep -q 'Mohammad1724/mrm-manager-pasarguard/main/versions.conf' "$PROJECT_DIR/plugin/mrm_admin_subscriptions.py" && \
   ! grep -q 'PEDIHS' "$PROJECT_DIR/plugin/mrm_admin_subscriptions.py" && \
   grep -q 'def _installed_version' "$PROJECT_DIR/plugin/mrm_admin_subscriptions.py" && \
   grep -q '"installed_version"' "$PROJECT_DIR/plugin/mrm_admin_subscriptions.py" && \
   grep -q 'installed_version' "$PROJECT_DIR/plugin/mrm-special.js" && \
   ! grep -q 'latest_commit' "$PROJECT_DIR/plugin/mrm-special.js"; then
    pass "plugin: update check is version-based against the MRM repository"
else
    fail "plugin: update check still points at a foreign repository / commit SHAs"
fi

# 13.9: the installed version is recorded for the panel (installer + self-healing integrator)
if grep -q 'install-state.json' "$PROJECT_DIR/install.sh" && \
   grep -q '^record_installed_version()' "$PROJECT_DIR/plugin/integrate-dashboard.sh" && \
   grep -qE "target'\) or data.get\('target_sha'\)" "$PROJECT_DIR/plugin/update-from-panel.sh"; then
    pass "install-state.json is written by install.sh and integrate-dashboard.sh; bridge accepts versions"
else
    fail "install-state.json is never written, or the host bridge only accepts commit SHAs"
fi

# 13.10: nginx / systemctl are guarded — no raw 'command not found' in menus
_NG=$(grep -c 'command -v nginx' "$PROJECT_DIR/manager/diagnostics.sh" || true)
if [ "${_NG:-0}" -ge 4 ] && grep -q 'command -v nginx' "$PROJECT_DIR/manager/domain_separator.sh"; then
    pass "diagnostics.sh / domain_separator.sh check that nginx exists before calling it"
else
    fail "nginx is called without checking that it is installed (diagnostics: $_NG guards)"
fi

# 13.11: backup log is quiet (no per-menu-open Env line, no Permission denied for non-root)
if ! grep -q '^    log_backup "INFO" "Env: PANEL_DIR' "$PROJECT_DIR/manager/backup/init.sh" && \
   grep -q '2>/dev/null || true' <(grep 'BACKUP_LOG"' "$PROJECT_DIR/manager/backup/init.sh"); then
    pass "backup/init.sh: Env line only at MRM_DEBUG=1, log append never errors"
else
    fail "backup/init.sh: still logs Env on every menu open or errors when the log is not writable"
fi

# 13.12: full doctor report is role-aware (no 'Panel is DOWN' advice where no panel is installed)
if grep -q 'if \[ "\$PANEL_HERE" -eq 1 \] && ! mrm_panel_running; then diag_report_line error "Panel is DOWN' "$PROJECT_DIR/manager/diagnostics.sh" && \
   ! grep -q '! mrm_panel_running && diag_report_line error "ACTION' "$PROJECT_DIR/manager/diagnostics.sh"; then
    pass "diagnostics.sh: full report only recommends restarting a panel that is installed here"
else
    fail "diagnostics.sh: full report still says 'Panel is DOWN' on node-only servers"
fi

# 13.13: pg_health JOB rows use short aligned labels (full key in the hint)
if grep -q 'LABEL="\${KEY#JOB_}"' "$PROJECT_DIR/manager/pg_health.sh" && \
   grep -q 'local UI_KV_WIDTH=30' "$PROJECT_DIR/manager/pg_health.sh"; then
    pass "pg_health.sh: JOB_* rows are aligned (short labels, wide key column)"
else
    fail "pg_health.sh: JOB_* rows still use the raw 30+ character keys as labels"
fi

# ─── Test Group 14: New-Server Restore / DB Password Sync (MRM-109) ─────────
echo "🛢️ Group 14: New-Server Restore — DB credential sync (MRM-109)"
echo ""

# 14.1: database.sh has the PostgreSQL role password sync function
if grep -q "^mrm_sync_pg_role_password()" "$PROJECT_DIR/manager/backup/database.sh"; then
    pass "database.sh defines mrm_sync_pg_role_password"
else
    fail "database.sh missing mrm_sync_pg_role_password"
fi

# 14.2: database.sh has the MySQL user password sync function
if grep -q "^mrm_sync_mysql_user_password()" "$PROJECT_DIR/manager/backup/database.sh"; then
    pass "database.sh defines mrm_sync_mysql_user_password"
else
    fail "database.sh missing mrm_sync_mysql_user_password"
fi

# 14.3: the sync uses STDIN here-docs (psql -c does NOT interpolate :'var')
if grep -A16 "^mrm_sync_pg_role_password()" "$PROJECT_DIR/manager/backup/database.sh" | grep -q "<<'SQL'"; then
    pass "mrm_sync_pg_role_password interpolates :\"usr\"/:'pass' via STDIN (not -c)"
else
    fail "mrm_sync_pg_role_password uses -c (psql does not substitute variables in -c)"
fi

# 14.4: restore_core.sh calls the sync after the PostgreSQL import
if grep -qF 'mrm_sync_pg_role_password "$DB_CONT" "$DB_USER" "$DB_PASS"' "$PROJECT_DIR/manager/backup/restore_core.sh"; then
    pass "restore_core.sh syncs the PG role password after import"
else
    fail "restore_core.sh never syncs the PG role password after import"
fi

# 14.5: restore_core.sh calls the MySQL sync after the MySQL import
if grep -qF 'mrm_sync_mysql_user_password "$DB_CONT" "$DB_USER" "$DB_PASS"' "$PROJECT_DIR/manager/backup/restore_core.sh"; then
    pass "restore_core.sh syncs the MySQL user password after import"
else
    fail "restore_core.sh never syncs the MySQL user password after import"
fi

# 14.6: bare new-server compose up includes the timescaledb service name
if grep -qF "up -d timescaledb postgresql postgres db" "$PROJECT_DIR/manager/backup/restore_core.sh"; then
    pass "restore_core.sh starts timescaledb/postgresql services on a bare new server"
else
    fail "restore_core.sh misses the timescaledb service name on bare new server"
fi

# 14.7: post_restore subscription update goes through STDIN (fixes silent -c failure)
if grep -qF "to_jsonb(:'url_prefix'::text)" "$PROJECT_DIR/manager/backup/post_restore.sh" && \
   grep -qF "<<'SQL'" "$PROJECT_DIR/manager/backup/post_restore.sh"; then
    pass "post_restore.sh runs the subscription UPDATE via STDIN (variables interpolate)"
else
    fail "post_restore.sh still sends :'url_prefix' inside -c (never interpolated)"
fi

# 14.8: restore ends with a real /health verification (panel actually up)
if grep -qF "/health" "$PROJECT_DIR/manager/backup/restore_core.sh" && \
   grep -qF "PANEL_UP" "$PROJECT_DIR/manager/backup/restore_core.sh"; then
    pass "restore_core.sh verifies panel /health before reporting success"
else
    fail "restore_core.sh reports success without checking the panel answers"
fi

# 14.9: FUNCTIONAL — the sync runs as the INSTANCE superuser (MRM-111 fix:
# without -U psql falls back to the container OS user 'root' and always fails)
_RESTORE_TMP=$(mktemp -d)
_RECORD_FILE="$_RESTORE_TMP/record.log"
: >"$_RECORD_FILE"
cat >"$_RESTORE_TMP/docker" <<'STUB'
#!/bin/bash
if [ "$1" = "inspect" ]; then
    echo "POSTGRES_USER=instance_admin"
    exit 0
fi
printf '%s\n' "$*" >>"${_RECORD_FILE:?}"
case "$*" in
    *"SELECT 1 FROM pg_roles"*) echo "1"; exit 0 ;;
    *"ALTER ROLE"*|*"CREATE ROLE"*) exit 0 ;;
    *"SELECT 1"*) echo "1"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$_RESTORE_TMP/docker"
(
    PATH="$_RESTORE_TMP:$PATH"
    export _RECORD_FILE
    export PATH
    # database.sh is a module: the logging helper normally comes from init.sh
    log_backup() { :; }
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/manager/backup/database.sh" >/dev/null 2>&1
    mrm_sync_pg_role_password "fake-db-container" "pasarguard" 'p@ss'"'"'w0rd\X' >/dev/null 2>&1
)
if grep -qF "psql -w -U instance_admin -d postgres -v ON_ERROR_STOP=1 -v usr=pasarguard -v pass=p@ss'w0rd\\X" "$_RECORD_FILE"; then
    pass "mrm_sync_pg_role_password runs as the instance superuser via -U and passes special-char passwords via -v"
else
    fail "mrm_sync_pg_role_password does not run as the instance superuser / unsafe password quoting"
fi
rm -rf "$_RESTORE_TMP"

echo ""

# ─── Test Group 15: Half-restored DB guard / safety rollback (MRM-110) ──────
echo "🛟 Group 15: Failed-import safety rollback (MRM-110)"
echo ""

# 15.1: database.sh defines the rollback function
if grep -q "^mrm_rollback_db_from_safety()" "$PROJECT_DIR/manager/backup/database.sh"; then
    pass "database.sh defines mrm_rollback_db_from_safety"
else
    fail "database.sh missing mrm_rollback_db_from_safety"
fi

# 15.2: restore_core.sh triggers the rollback when the import is broken
if grep -qF 'mrm_rollback_db_from_safety "$SAFETY_BACKUP"' "$PROJECT_DIR/manager/backup/restore_core.sh"; then
    pass "restore_core.sh rolls back to the safety DB after a failed import"
else
    fail "restore_core.sh leaves a half-restored DB behind after a failed import"
fi

# 15.3: dumps are portable (--no-owner --no-privileges) — container + host paths
PGDUMP_FLAGS=$(grep -c -- "--no-owner --no-privileges" "$PROJECT_DIR/manager/backup/database.sh" || true)
if [ "${PGDUMP_FLAGS:-0}" -ge 2 ]; then
    pass "pg_dump runs with --no-owner --no-privileges (portable across servers)"
else
    fail "pg_dump is not portable (missing --no-owner --no-privileges)"
fi

# 15.4: mysqldump is consistent (--single-transaction)
if grep -q -- "--single-transaction" "$PROJECT_DIR/manager/backup/database.sh"; then
    pass "mysqldump runs with --single-transaction"
else
    fail "mysqldump lacks --single-transaction (inconsistent live dumps)"
fi

# 15.5: the full psql import output is persisted for diagnosis
if grep -qF "mrm-pg-import-" "$PROJECT_DIR/manager/backup/restore_core.sh"; then
    pass "full psql import output is kept in /var/log/mrm-pg-import-*.log"
else
    fail "import log is deleted — mid-file failures cannot be diagnosed"
fi

# 15.6: pre-flight detection of a half-restored target DB
if grep -qF "HALF-RESTORED" "$PROJECT_DIR/manager/backup/restore_core.sh"; then
    pass "restore detects a half-restored target DB before importing"
else
    fail "restore does not detect half-restored databases"
fi

# 15.7: repair-db CLI is wired end-to-end
if grep -q "^do_repair_db()" "$PROJECT_DIR/manager/backup/restore_core.sh" && \
   grep -qF "repair-db) do_repair_db" "$PROJECT_DIR/manager/backup.sh" && \
   grep -qF 'repair-db) exec bash "$MRM_DIR/backup.sh" repair-db' "$PROJECT_DIR/manager/main.sh"; then
    pass "mrm repair-db is wired (main.sh -> backup.sh -> do_repair_db)"
else
    fail "mrm repair-db is not fully wired"
fi

# 15.8: FUNCTIONAL — rollback actually re-imports the safety dump (stubbed docker)
_ROLL_TMP=$(mktemp -d)
mkdir -p "$_ROLL_TMP/pkg/tmp/mrm_workspace.abc/safety_1"
cat >"$_ROLL_TMP/pkg/tmp/mrm_workspace.abc/safety_1/current_db_backup" <<'EOF'
--
-- PostgreSQL database dump
--
-- PostgreSQL database dump complete
EOF
tar -czf "$_ROLL_TMP/safety.tar.gz" -C "$_ROLL_TMP/pkg" tmp
cat >"$_ROLL_TMP/docker" <<'STUB'
#!/bin/bash
if [ "$1" = "inspect" ]; then
    echo "POSTGRES_USER=postgres"
    exit 0
fi
case "$*" in
    *"CREATE DATABASE"*) exit 0 ;;
    *"DROP DATABASE"*)   exit 0 ;;
    *"pg_terminate_backend"*) exit 0 ;;
    *"CREATE EXTENSION"*) exit 0 ;;
    *"SELECT count(*) FROM alembic_version"*) echo "1"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$_ROLL_TMP/docker"
(
    PATH="$_ROLL_TMP:$PATH"
    export PATH
    DATA_DIR="/tmp/nonexistent-data"; PANEL_DIR="/tmp/nonexistent-panel"
    log_backup() { :; }
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/manager/backup/database.sh" >/dev/null 2>&1
    mrm_rollback_db_from_safety "$_ROLL_TMP/safety.tar.gz" "db-container" "pasarguard" "pw" "pasarguard" >/dev/null 2>&1
)
if [ $? -eq 0 ]; then
    _RC=0
else
    _RC=1
fi
if [ "$_RC" -eq 0 ]; then
    pass "mrm_rollback_db_from_safety re-imports the safety dump (functional)"
else
    fail "mrm_rollback_db_from_safety failed on a valid safety archive (functional)"
fi
rm -rf "$_ROLL_TMP"

# 15.9: extension ensure exists and is wired before the import (MRM-111)
if grep -q "^mrm_pg_ensure_extensions()" "$PROJECT_DIR/manager/backup/database.sh" && \
   grep -qF 'mrm_pg_ensure_extensions "$DB_CONT" "$PG_ADMIN" "$DB_NAME" "$SQL_FILE"' "$PROJECT_DIR/manager/backup/restore_core.sh"; then
    pass "extensions are installed into the fresh DB before the import (timescaledb)"
else
    fail "fresh DB has no extensions — TimescaleDB dumps die mid-import"
fi

# 15.10: the sync runs as the instance superuser (POSTGRES_USER), not root (MRM-111)
if grep -q "^mrm_pg_instance_superuser()" "$PROJECT_DIR/manager/backup/database.sh" && \
   grep -A24 "^mrm_sync_pg_role_password()" "$PROJECT_DIR/manager/backup/database.sh" | grep -q 'psql -w -U "\$SU"'; then
    pass "mrm_sync_pg_role_password connects as the instance superuser (-U POSTGRES_USER)"
else
    fail "mrm_sync_pg_role_password still connects without -U (fails as role 'root')"
fi

# 15.11: import errors are surfaced on screen (not only in a log file)
if grep -qF "PostgreSQL import failed — last errors:" "$PROJECT_DIR/manager/backup/restore_core.sh"; then
    pass "import errors are printed on screen for immediate diagnosis"
else
    fail "import failures leave no on-screen error text"
fi

echo ""

# ─── Test Group 16: UI contract & design core ────────────────────────────────
# (قرارداد DOM↔runtime و هستهٔ مشترک طراحی — جلوگیری از بازگشت «شکست بی‌صدا»)
echo "📋 Group 16: UI contract & design core"
echo ""

# 16.1: فایل‌های هستهٔ مشترک موجودند
for core in "shared/ui-contract.js" "shared/design-tokens.css" "shared/sync-contract.sh" "shared/sync-tokens.sh"; do
    if [ -f "$PROJECT_DIR/$core" ]; then
        pass "shared core present: $core"
    else
        fail "shared core missing: $core"
    fi
done

# 16.2: قرارداد در runtime تزریق شده و هر دو قالب روی یک نسخه‌اند
if bash "$PROJECT_DIR/shared/sync-contract.sh" --check >/dev/null 2>&1; then
    pass "DOM contract injected into runtime (versions in sync)"
else
    fail "DOM contract drifted — run: bash shared/sync-contract.sh"
fi

# 16.3: هستهٔ طراحی در CSS هر دو قالب همگام است
if bash "$PROJECT_DIR/shared/sync-tokens.sh" --check >/dev/null 2>&1; then
    pass "design core injected into template CSS (versions in sync)"
else
    fail "design core drifted — run: bash shared/sync-tokens.sh"
fi

# 16.4: هر ۱۴ نام قرارداد واقعاً در HTML منتشرشده وجود دارد
#       (اگر runtime به نشانگری وصل باشد که در DOM نیست، تنظیم ادمین بی‌صدا بی‌اثر می‌شود)
SUB_HTML="$PROJECT_DIR/templates/subscription/index.html"
missing=""
for name in brand brand-box nav header-actions support announcement configs config-row config-protocol \
            wireguard quick-connect ping apps section-title; do
    { grep -qF "data-ui=\"$name\"" "$SUB_HTML" || grep -qF "\"data-ui\":\"$name\"" "$SUB_HTML"; } || missing="$missing $name"
done
if [ -z "$missing" ]; then
    pass "all 14 data-ui markers present in published subscription template"
else
    fail "data-ui markers missing from published template:$missing"
fi

# 16.5: جانگهدار __BRAND__ برای مرحلهٔ theme.sh --redeploy حفظ شده
if grep -qF '__BRAND__' "$SUB_HTML"; then
    pass "__BRAND__ deploy placeholder preserved for theme.sh --redeploy"
else
    fail "__BRAND__ placeholder lost — theme.sh --redeploy can no longer brand the page"
fi

# 16.6: و نگهبان runtime که توکن خام را به صفحه نمی‌رساند
if grep -qF 'deTokenizeBrand' "$PROJECT_DIR/plugin/mrm-runtime.js"; then
    pass "runtime de-tokenizes raw __XXX__ placeholders (no raw token on screen)"
else
    fail "runtime lacks the raw-placeholder guard (deTokenizeBrand)"
fi

# 16.7: توکن‌های هستهٔ طراحی واقعاً به خروجی نهایی می‌رسند
if grep -q -- '--tap-min' "$SUB_HTML" && grep -q -- '--fs-micro' "$SUB_HTML"; then
    pass "design tokens (--tap-min, --fs-micro) present in published bundle"
else
    fail "design tokens missing from the built template — CSS layer did not ship"
fi

# 16.8: کف هدف لمس ۴۴px در خروجی وجود دارد
if grep -qF 'min-height:var(--tap-min)' "$SUB_HTML" || grep -qF 'min-height: var(--tap-min)' "$SUB_HTML"; then
    pass "44px touch-target floor present in published CSS"
else
    fail "touch-target floor rule missing from published CSS"
fi

# 16.9: هیچ اندازهٔ متنی زیر ۱۲px در CSS قالب نماند (مقیاس تایپوگرافی)
SMALL=$(grep -oE 'font-size: 0\.[0-6][0-9]*rem' "$PROJECT_DIR/templates/subscription-src/src/index.css" | head -1 || true)
if [ -z "$SMALL" ]; then
    pass "no sub-12px font size left in template CSS (type scale floor)"
else
    fail "sub-12px font size found in template CSS: $SMALL"
fi

# 16.10: کلاس‌های UI مشترک (حداقل هدف لمس) در خروجی هستند
if grep -qF '.ui-tap{' "$SUB_HTML" || grep -qF '.ui-tap {' "$SUB_HTML"; then
    pass "shared touch-target utility (.ui-tap) shipped"
else
    fail "shared .ui-tap utility missing from published bundle"
fi

echo ""

# ─── Test Group 17: accessibility structure guards ───────────────────────────
# (ساختار لندمارک/عنوان/برچسب — جلوگیری از بازگشت ایرادهای ممیزی ساختاری)
echo "📋 Group 17: accessibility structure guards"
echo ""

SRC_DIR="$PROJECT_DIR/templates/subscription-src/src"

# 17.1: صفحه دقیقاً یک لندمارک اصلی دارد و همان مال Layout است
MAIN_COUNT=$(grep -rn "<main" "$SRC_DIR" --include="*.tsx" | wc -l | tr -d ' ')
if [ "$MAIN_COUNT" = "1" ] && grep -q "<main" "$SRC_DIR/components/layout/layout.tsx"; then
    pass "exactly one <main> landmark, owned by layout.tsx"
else
    fail "expected a single <main> in layout.tsx, found $MAIN_COUNT occurrence(s)"
fi

# 17.2: ظرف صفحه لندمارک تودرتو نمی‌سازد
if grep -q "<main" "$SRC_DIR/App.tsx"; then
    fail "App.tsx renders a nested <main> (invalid landmark nesting)"
else
    pass "no nested <main> in page container"
fi

# 17.3: صفحه سرتیتر سطح‌بالا دارد (گیرندهٔ خوانندهٔ صفحه)
H1_COUNT=$(grep -c "<h1" "$SRC_DIR/App.tsx" || true)
if [ "${H1_COUNT:-0}" -ge 1 ]; then
    pass "page declares an <h1> (visually hidden where the design has no title)"
else
    fail "page has no <h1>"
fi

# 17.4: داخل تریگرهای آکاردئون سرتیتر تکراری نیست
#       (AccordionTrigger رادیکس خودش سرتیتر سطح سه می‌سازد)
if grep -q "<h3" "$SRC_DIR/components/AppsList.tsx"; then
    fail "AppsList renders its own <h3> inside Radix AccordionTrigger (duplicate heading)"
else
    pass "no duplicate <h3> inside accordion triggers"
fi

# 17.5: بخش اپلیکیشن‌ها در سطح بخش اعلام می‌شود
if grep -q "<h2" "$SRC_DIR/App.tsx"; then
    pass "apps section announced at section level"
else
    fail "apps section title level inconsistent"
fi

# 17.6: هر <input> برچسب دسترس‌پذیر دارد
INPUTS=$(grep -rn "<input" "$SRC_DIR" --include="*.tsx" | wc -l | tr -d ' ')
LABELLED=$(grep -rn "aria-label\|aria-labelledby" "$SRC_DIR" --include="*.tsx" | wc -l | tr -d ' ')
if [ "$INPUTS" = "0" ] || [ "$LABELLED" -ge "$INPUTS" ]; then
    pass "every <input> carries an accessible label"
else
    fail "unlabelled <input> present ($INPUTS inputs vs $LABELLED labels)"
fi

# 17.7: صفحهٔ اصلی فقط سرتیتر صفحه‌سطح/بخشی دارد، نه سطح عمیق‌تر
if grep -q "<h3" "$SRC_DIR/App.tsx"; then
    fail "App.tsx uses a level-3 heading for a page-level state"
else
    pass "page-level states use page-level headings"
fi

# 17.8: دکمه‌های فقط-آیکونی نام دسترس‌پذیر دارند
if grep -q "sr-only" "$SRC_DIR/components/language-switcher.tsx" && \
   grep -q "sr-only" "$SRC_DIR/components/theme-toggle.tsx"; then
    pass "icon-only toolbar buttons expose accessible names"
else
    fail "icon-only toolbar button without accessible name"
fi

echo ""

# ─── Test Group 18: in-panel settings tab standards ──────────────────────────
# (تب «MRM Special» داخل پنل — معیارهای همان صفحهٔ اشتراک: کف تایپوگرافی،
#  هدف لمس، برچسب دسترس‌پذیر، کنتراست، و نوار ذخیره‌ای که محتوا را نپوشاند)
echo "📋 Group 18: in-panel settings tab standards"
echo ""

SPECIAL="$PROJECT_DIR/plugin/mrm-special.js"

# 18.1: هیچ اندازهٔ فونتی زیر کف مقیاس (۰.۷۵rem = ۱۲px) نمانده
if grep -qE 'font-size:(\.[0-6][0-9]*|0\.[0-6][0-9]*)rem' "$SPECIAL"; then
    fail "in-panel CSS still has sub-12px font sizes"
else
    pass "no sub-12px font size in the in-panel settings CSS"
fi

# 18.2: دکمه‌ها حداقل ارتفاع ۴۴px دارند (حداقل ۵ دکمه)
MINH=$(grep -o 'min-height:44px' "$SPECIAL" | wc -l | tr -d ' ')
if [ "$MINH" -ge 5 ]; then
    pass "in-panel buttons meet the 44px touch floor ($MINH rules)"
else
    fail "in-panel buttons below the touch floor (found $MINH min-height rules)"
fi

# 18.3: کلیدها ناحیهٔ ضربهٔ گسترش‌یافته دارند و کل ردیف کلیک‌پذیر است
if grep -q 'input\[type=checkbox\]::before' "$SPECIAL" && \
   grep -q 'enhanceToggles' "$SPECIAL" && \
   grep -q 'z-row-click' "$SPECIAL"; then
    pass "toggle switches expose an expanded hit area and row-level click"
else
    fail "toggle switches lack expanded hit area or row click"
fi

# 18.4: ورودی‌ها روی دستگاه لمسی به آستانهٔ ۴۴px می‌رسند
if grep -q 'pointer:coarse' "$SPECIAL" && grep -q 'min-height:44px' "$SPECIAL"; then
    pass "in-panel inputs reach the touch floor on coarse pointers"
else
    fail "in-panel inputs do not adapt to touch devices"
fi

# 18.5: فوکوس دیداری برای کاربران کیبورد
if grep -q ':focus-visible' "$SPECIAL"; then
    pass "in-panel controls expose a visible keyboard focus ring"
else
    fail "no visible focus ring in the in-panel tab"
fi

# 18.6: وضعیت‌های پویا اعلام می‌شوند (ذخیره/ظاهر/بروزرسانی)
LIVE=$(grep -o 'role="status" aria-live="polite"' "$SPECIAL" | wc -l | tr -d ' ')
if [ "$LIVE" -ge 3 ]; then
    pass "in-panel save/appearance/update statuses are announced ($LIVE live regions)"
else
    fail "in-panel dynamic statuses are not announced (found $LIVE)"
fi
if grep -q 'role="alert"' "$SPECIAL"; then
    pass "in-panel error state is announced as an alert"
else
    fail "in-panel error state is not announced"
fi

# 18.7: خطا و وضعیت ناموفق کنتراست AA دارند (سرخ کم‌کنتراست ممنوع)
if grep -q '#b91c1c' "$SPECIAL" && grep -q '#f87171' "$SPECIAL"; then
    pass "in-panel error/danger colours meet AA on both themes"
else
    fail "in-panel error colours left at the low-contrast red"
fi

# 18.8: نوار ذخیرهٔ چسبان فضای کافی پایین می‌گذارد تا محتوا پنهان نشود
if grep -q 'calc(2rem + 4.6rem)' "$SPECIAL"; then
    pass "sticky save bar reserves space so no content is occluded"
else
    fail "sticky save bar can occlude the last card"
fi

# 18.9: آیکون‌های تزئینی از درخت دسترس‌پذیری کنار گذاشته شده‌اند
# نکته: زیر set -euo pipefail، grep بی‌خروجی اسکریپت را می‌کشد → || true لازم است
BARE_SVG=$( (grep -o '<svg viewBox=' "$SPECIAL" || true) | wc -l | tr -d ' ')
HIDDEN_SVG=$( (grep -o 'aria-hidden="true" focusable="false" viewBox=' "$SPECIAL" || true) | wc -l | tr -d ' ')
if [ "$BARE_SVG" = "0" ] && [ "$HIDDEN_SVG" -ge 5 ]; then
    pass "in-panel decorative icons are hidden from the accessibility tree ($HIDDEN_SVG)"
else
    fail "in-panel icons leak into the accessibility tree (bare=$BARE_SVG, hidden=$HIDDEN_SVG)"
fi

# 18.10: رابط فارسی است — رشته‌های انگلیسی نمانده
if ! grep -q 'Save MRM Settings' "$SPECIAL" && \
   ! grep -q 'Loading MRM settings' "$SPECIAL" && \
   ! grep -q 'Update now' "$SPECIAL" && \
   ! grep -q 'OWNER ONLY' "$SPECIAL" && \
   ! grep -q 'Copy Prefix' "$SPECIAL"; then
    pass "in-panel strings are Persian (no English leftovers)"
else
    fail "English strings remain in the Persian in-panel tab"
fi

echo ""

# ─── Test Group 19: in-panel tab parity (zomorod) + light-theme contrast ─────
# (همان معیارهای گروه ۱۸ برای قالب پایهٔ زمرد + دو ایراد کنتراست تم روشن که
#  سنجهٔ پس‌زمینهٔ واقعی هر عنصر نشان داد. زمرد ممکن است کنار مخزن نباشد → SKIP)
echo "📋 Group 19: in-panel tab parity (zomorod) + light-theme contrast"
echo ""

ZOMOROD_DIR="${ZOMOROD_DIR:-$PROJECT_DIR/../zomorod-template}"
ZSPECIAL="$ZOMOROD_DIR/plugin/zomorod-special.js"

# 19.1: کنتراست دکمهٔ نوتیس و چیپ نقش در تم روشن (متن سفید روی #0E8F8A فقط ۳.۹۵:۱ بود)
if grep -q 'background:#0F766E;color:white' "$SPECIAL"; then
    pass "MRM notice button reaches AA on light theme (#0F766E, 5.47:1 with white)"
else
    fail "MRM notice button still uses the low-contrast teal background"
fi
if grep -q '\.z-role{color:#0F766E' "$SPECIAL"; then
    pass "MRM role chip reaches AA on light theme (5.10:1 on its own tint)"
else
    fail "MRM role chip still below AA on light theme"
fi

# 19.2: کارت بروزرسانی رشتهٔ انگلیسی نمایش نمی‌دهد (unknown / Up to date)
if ! grep -q ": 'unknown'; }" "$SPECIAL" && ! grep -q "Up to date" "$SPECIAL"; then
    pass "update card shows no English fallback (unknown / Up to date)"
else
    fail "update card still leaks English fallback text"
fi

if [ ! -f "$ZSPECIAL" ]; then
    skip "zomorod plugin not found at $ZSPECIAL — parity checks skipped"
else
    # 19.3: کف تایپوگرافی
    if grep -qE 'font-size:(\.[0-6][0-9]*|0\.[0-6][0-9]*)rem' "$ZSPECIAL"; then
        fail "zomorod in-panel CSS still has sub-12px font sizes"
    else
        pass "zomorod: no sub-12px font size in the in-panel settings CSS"
    fi

    # 19.4: هدف لمس ۴۴px
    ZMINH=$(grep -o 'min-height:44px' "$ZSPECIAL" | wc -l | tr -d ' ')
    if [ "$ZMINH" -ge 5 ]; then
        pass "zomorod: in-panel buttons meet the 44px touch floor ($ZMINH rules)"
    else
        fail "zomorod: in-panel buttons below the touch floor (found $ZMINH)"
    fi

    # 19.5: کلیدها ناحیهٔ ضربه + کل‌ردیف کلیک‌پذیر (شامل بخش PWA که بعد رندر می‌شود)
    ZENH=$(grep -o 'enhanceToggles(' "$ZSPECIAL" | wc -l | tr -d ' ')
    if grep -q 'input\[type=checkbox\]::before' "$ZSPECIAL" && \
       grep -q 'z-row-click' "$ZSPECIAL" && [ "$ZENH" -ge 2 ]; then
        pass "zomorod: toggles expose an expanded hit area, row click and PWA re-run ($ZENH calls)"
    else
        fail "zomorod: toggle hit area / row click / PWA enhancement missing"
    fi

    # 19.6: ورودی لمسی + فوکوس دیداری
    if grep -q 'pointer:coarse' "$ZSPECIAL" && grep -q ':focus-visible' "$ZSPECIAL"; then
        pass "zomorod: touch floor on coarse pointers and a visible focus ring"
    else
        fail "zomorod: missing coarse-pointer floor or focus ring"
    fi

    # 19.7: اعلام وضعیت‌های پویا
    ZLIVE=$(grep -o 'role="status" aria-live="polite"' "$ZSPECIAL" | wc -l | tr -d ' ')
    if [ "$ZLIVE" -ge 3 ] && grep -q 'role="alert"' "$ZSPECIAL"; then
        pass "zomorod: dynamic statuses announced ($ZLIVE live regions + alert)"
    else
        fail "zomorod: dynamic statuses are not announced (found $ZLIVE)"
    fi

    # 19.8: سرخ AA در هر دو تم + فضای نوار چسبان
    if grep -q '#b91c1c' "$ZSPECIAL" && grep -q '#f87171' "$ZSPECIAL" && \
       grep -q 'calc(2rem + 4.6rem)' "$ZSPECIAL"; then
        pass "zomorod: AA error colours on both themes and a non-occluding sticky bar"
    else
        fail "zomorod: error colour or sticky-bar spacing missing"
    fi

    # 19.9: آیکون‌های تزئینی پنهان
    ZBARE=$( (grep -o '<svg viewBox=' "$ZSPECIAL" || true) | wc -l | tr -d ' ')
    ZHID=$( (grep -o 'aria-hidden="true" focusable="false" viewBox=' "$ZSPECIAL" || true) | wc -l | tr -d ' ')
    if [ "$ZBARE" = "0" ] && [ "$ZHID" -ge 5 ]; then
        pass "zomorod: decorative icons hidden from the accessibility tree ($ZHID)"
    else
        fail "zomorod: icons leak into the accessibility tree (bare=$ZBARE, hidden=$ZHID)"
    fi

    # 19.10: رابط فارسی — رشته‌های انگلیسی نمانده
    # جملهٔ بارگذاری فارسی است و رشته‌های انگلیسیِ رابط برنگشته‌اند
    # (نام‌های داخلی کد مثل renderLoading نمایش داده نمی‌شوند و بررسی نمی‌شوند)
    if grep -q 'در حال بارگذاری' "$ZSPECIAL" && \
       ! grep -q '>Save<' "$ZSPECIAL" && \
       ! grep -q 'Delete /sub/' "$ZSPECIAL" && \
       ! grep -q 'Save Zomorod Settings' "$ZSPECIAL" && \
       ! grep -q 'Up to date' "$ZSPECIAL" && \
       ! grep -q ": 'unknown'; }" "$ZSPECIAL"; then
        pass "zomorod: in-panel strings are Persian (no English leftovers)"
    else
        fail "zomorod: English strings remain in the Persian in-panel tab"
    fi

    # 19.11: پیام تأیید حذف فضای نام فارسی شده
    if grep -q 'حذف فضای نام' "$ZSPECIAL"; then
        pass "zomorod: delete-namespace confirm dialog is localized"
    else
        fail "zomorod: delete-namespace confirm dialog is still English"
    fi
fi

echo ""

# ─── Test Group 20: installer UX (fail-early, actionable errors, clear end) ──
# (فاز نصب: نصب‌کننده باید پیش از هر نوشتنی پیش‌بینی کند، خطا را با راه‌حل بگوید،
#  شمارهٔ قدم‌ها با پایان کار هم‌خوان باشد و پایان نصب راهنمای ادامه بدهد)
echo "📋 Group 20: installer UX"
echo ""

INSTALLER="$PROJECT_DIR/install.sh"

# 20.1: سینتکس سالم
if bash -n "$INSTALLER" 2>/dev/null; then
    pass "install.sh: syntax is valid"
else
    fail "install.sh: syntax error"
fi

# 20.2: پیش‌بینی ابزارها و فضای دیسک پیش از هر تغییری
if grep -q 'command -v "\$TOOL"' "$INSTALLER" && \
   grep -q 'Missing required tools' "$INSTALLER" && \
   grep -q 'MRM_MIN_FREE_MB' "$INSTALLER" && \
   grep -q 'Not enough free space' "$INSTALLER"; then
    pass "installer pre-flight checks tools and free space with fixes"
else
    fail "installer has no pre-flight tool/disk checks"
fi

# 20.3: بررسی اتصال با پیام عملیاتی (به‌جای شکست گنگ در دانلود اول)
if grep -q 'Contacting the release host' "$INSTALLER" && \
   grep -q 'cannot reach' "$INSTALLER" && \
   grep -q 'curl -I' "$INSTALLER"; then
    pass "connectivity failure names the cause and the exact test command"
else
    fail "connectivity failure is not actionable"
fi

# 20.4: پیام خطای مانیفست تأکید کند که چیزی نصب نشده
if grep -q 'Nothing was installed — files are only written after their checksum is verified' "$INSTALLER"; then
    pass "manifest failure states that nothing was installed"
else
    fail "manifest failure message is unclear about system state"
fi

# 20.5: شمارهٔ قدم‌ها با پایان کار هم‌خوان است (۵ قدم، آخرین قدم = ادغام در پنل)
if grep -q 'ui_step 5 5 "Panel integration and CLI"' "$INSTALLER" && \
   ! grep -q 'ui_step [0-9] 4 ' "$INSTALLER"; then
    pass "installer ends its step counter exactly when the work ends (5/5)"
else
    fail "installer step counter does not match the work it does"
fi

# 20.6: راهنمای گام بعدی پس از نصب
if grep -q 'Next steps' "$INSTALLER" && \
   grep -q 'Settings → MRM Special' "$INSTALLER" && \
   grep -q 'pasarguard restart' "$INSTALLER"; then
    pass "installer ends with actionable next steps for the panel"
else
    fail "installer gives no next-step guidance"
fi

# 20.7: شمارش معکوس پرسش پایانی روی stderr رسم می‌شود (وگرنه در $() گم می‌شود)
if grep -q 'ask_run_now' "$INSTALLER" && \
   grep -q 'read -t 1 -r ANS' "$INSTALLER" && \
   grep -q 'Run MRM Manager now' "$INSTALLER"; then
    pass "final prompt shows a live countdown instead of a silent default"
else
    fail "final prompt has no visible countdown"
fi

# 20.8: گاردهای قبلی دست‌نخورده مانده‌اند (بازگردانی و مانیفست اجباری)
if grep -q 'Aborting\|nothing was installed' "$INSTALLER" 2>/dev/null; then
    : # either wording is fine; the rollback guard below is the real check
fi
if grep -q '\.previous' "$INSTALLER" && grep -q 'rm -rf \$INSTALL_DIR && mv' "$INSTALLER"; then
    pass "rollback copy and its restore command are still documented"
else
    fail "rollback guidance was lost"
fi

# 20.9: manifest بازتولید شده است — هش واقعی install.sh با checksums.txt می‌خواند
if [ -f "$PROJECT_DIR/checksums.txt" ]; then
    SUM_LINE=$( (grep '  install.sh$' "$PROJECT_DIR/checksums.txt" || true) | head -1 )
    REAL_SUM=$(sha256sum "$INSTALLER" | awk '{print $1}')
    if [ -n "$SUM_LINE" ] && [ "${SUM_LINE%% *}" = "$REAL_SUM" ]; then
        pass "checksums.txt matches the edited install.sh"
    else
        fail "checksums.txt is stale for install.sh (regenerate it)"
    fi
else
    fail "checksums.txt is missing"
fi

echo ""

# ─── Test Group 21: terminal rendering (real width, dumb TERM, NO_COLOR) ─────
# (رابط ترمینال باید با عرض واقعی پنجره بسازد: نه سرریز کند، نه با TERM ناشناخته
#  خطای خام چاپ کند، و NO_COLOR را محترم بشمارد. سنجش با pty واقعی + stty)
echo "📋 Group 21: terminal rendering"
echo ""

UIFILE="$PROJECT_DIR/manager/ui.sh"
PROBE="$SCRIPT_DIR/term_probe.sh"

# 21.1: سازوکارهای لازم در ui.sh وجود دارند
if grep -q 'stty size' "$UIFILE" && grep -q '^ui_wrap()' "$UIFILE" && \
   grep -q '^_ui_cut()' "$UIFILE" && grep -q '_ui_kv_budget' "$UIFILE"; then
    pass "ui.sh measures the real window width and folds long text"
else
    fail "ui.sh lacks width detection or folding helpers"
fi

# 21.2: پاک‌کردن صفحه با TERM ناشناخته خطای خام نمی‌دهد
if grep -q 'clear 2>/dev/null' "$UIFILE" && \
   grep -q "case \"\${TERM:-}\" in ''|dumb|unknown) return 0" "$UIFILE"; then
    pass "screen clearing is silent on dumb/unknown TERM"
else
    fail "clear can emit a raw terminal error"
fi

render_at() { # $1=cols  $2=TERM  $3=extRA env (optional)
    local cols="$1" term="$2" extra="${3:-}"
    command -v script >/dev/null 2>&1 || return 1
    env -i PATH="$PATH" HOME="$HOME" TERM="$term" MRM_DIR="$PROJECT_DIR/manager" $extra \
        script -qec "stty cols $cols rows 24 2>/dev/null; MRM_DIR='$PROJECT_DIR/manager' bash '$PROBE'" /dev/null 2>/dev/null \
        | tr -d '\r'
}

strip_ansi() { sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g'; }

# شمارش ستون مستقل از لوکیل: بایت منهای بایت‌های ادامهٔ UTF-8
# (زیر LC_ALL=C هر نویسهٔ قاب ۳ ستون شمرده می‌شد و آزمون را الکی می‌شکست)
char_count() {
    local bytes cont
    bytes=$(printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' ')
    cont=$(printf '%s' "$1" | LC_ALL=C grep -o $'[\x80-\xBF]' | wc -l | tr -d ' ')
    echo $(( bytes - cont ))
}
max_line_width() { # بیشترین عرض خط (نویسه = ستون برای نویسه‌های این رابط)
    local max=0 plain n
    while IFS= read -r line; do
        plain="$(printf '%s' "$line" | strip_ansi)"
        n="$(char_count "$plain")"
        [ "$n" -gt "$max" ] && max=$n
    done
    echo "$max"
}

if ! command -v script >/dev/null 2>&1; then
    skip "pty tool 'script' not available — terminal width checks skipped"
else
    # 21.3: عرض ۴۰ — هیچ خطی نباید سرریز کند
    OUT40="$(render_at 40 xterm-256color)"
    W40="$(printf '%s\n' "$OUT40" | max_line_width)"
    if [ -n "$OUT40" ] && [ "$W40" -le 40 ]; then
        pass "40-column window: nothing overflows (widest line ${W40})"
    else
        fail "40-column window overflows (widest line ${W40:-?})"
    fi

    # 21.4: عرض ۱۰۰ — قاب به سقف خوانایی (۷۲) محدود می‌ماند
    OUT100="$(render_at 100 xterm-256color)"
    W100="$(printf '%s\n' "$OUT100" | max_line_width)"
    if [ -n "$OUT100" ] && [ "$W100" -le 72 ]; then
        pass "100-column window: frame stays at the readable cap (widest ${W100})"
    else
        fail "wide window exceeds the readability cap (widest ${W100:-?})"
    fi

    # 21.5: TERM ناشناخته/خالی — بدون خطای خام ncurses و بدون سرریز
    OUTUNK="$(render_at 40 unknown)"
    OUTEMP="$(render_at 40 "")"
    if ! printf '%s\n%s\n' "$OUTUNK" "$OUTEMP" | grep -qE "unknown terminal type|tput:|No value for \\\$TERM"; then
        pass "unknown/empty TERM: no raw ncurses error leaks into the UI"
    else
        fail "unknown/empty TERM prints a raw terminal error"
    fi
    WUNK="$(printf '%s\n' "$OUTUNK" | max_line_width)"
    if [ "$WUNK" -le 40 ]; then
        pass "unknown TERM still respects the 40-column window (widest ${WUNK})"
    else
        fail "unknown TERM overflows the window (widest ${WUNK})"
    fi

    # 21.6: NO_COLOR — هیچ کد رنگی در خروجی نباشد
    OUTNC="$(render_at 40 xterm-256color "NO_COLOR=1")"
    if [ -n "$OUTNC" ] && ! printf '%s' "$OUTNC" | grep -q $'\033\[[0-9;]*m'; then
        pass "NO_COLOR=1: output carries no colour codes"
    else
        fail "NO_COLOR=1 still produces colour codes"
    fi
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
