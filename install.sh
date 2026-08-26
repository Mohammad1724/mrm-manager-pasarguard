#!/bin/bash
# MRM Manager Installer

INSTALL_DIR="/opt/mrm-manager"
# Pinned release ref + checksums: files are downloaded from this exact ref and
# verified against checksums.txt (integrity). install.sh itself is bootstrapped
# via the README curl command and therefore cannot self-verify.
REPO_BASE_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard"
REPO_REF="v1.1.2"
MANAGER_REPO_URL="$REPO_BASE_URL/$REPO_REF"
VERSION_REGISTRY_URL="$MANAGER_REPO_URL/versions.conf"
CHECKSUMS_URL="$MANAGER_REPO_URL/checksums.txt"
# MRM-004: bounded downloads, TLS only
CURL_BASE=(curl -fsSL --connect-timeout 10 --max-time 60 --proto '=https' --tlsv1.2)

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# MRM-006: POSIX-safe root check (EUID is undefined under dash)
[ "$(id -u)" -ne 0 ] && { echo -e "${RED}Please run as root${NC}"; exit 1; }

# MRM-003: keep a rollback copy of the current install before overwriting
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "${INSTALL_DIR}.previous" 2>/dev/null
    if cp -a "$INSTALL_DIR" "${INSTALL_DIR}.previous" 2>/dev/null; then
        echo -e "${BLUE}Backed up current install to ${INSTALL_DIR}.previous${NC}"
    fi
else
    mkdir -p "$INSTALL_DIR"
fi

# MRM-001: version is parsed (never sourced) from the pinned versions.conf
MRM_VERSION=""
VERSION_REGISTRY_FILE="$(mktemp)"
if "${CURL_BASE[@]}" -o "$VERSION_REGISTRY_FILE" "$VERSION_REGISTRY_URL" 2>/dev/null; then
    MRM_VERSION="$(grep -E '^MRM_VERSION=' "$VERSION_REGISTRY_FILE" 2>/dev/null | head -1 | cut -d'"' -f2)"
fi
rm -f "$VERSION_REGISTRY_FILE"

# Fallback only if registry fetch failed
if [ -z "$MRM_VERSION" ]; then
    MRM_VERSION="1.1.2"
fi

echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║ MRM Manager Installer v${MRM_VERSION}          ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

# MRM-001: integrity manifest (checksums.txt) is mandatory — abort if absent
CHECKSUMS_FILE="$(mktemp)"
trap 'rm -f "$CHECKSUMS_FILE"' EXIT
if ! "${CURL_BASE[@]}" -o "$CHECKSUMS_FILE" "$CHECKSUMS_URL" 2>/dev/null; then
    echo -e "${RED}✘ Could not download checksums.txt ($CHECKSUMS_URL)${NC}"
    echo -e "${RED}  Aborting to avoid installing unverified files.${NC}"
    exit 1
fi

FAIL_COUNT=0

verify_download() {
    # $1 = installed file path, $2 = repo-relative path (as in checksums.txt)
    local OUT="$1" REL="$2" EXPECTED ACTUAL
    EXPECTED="$(awk -v r="$REL" '$2 == r {print $1}' "$CHECKSUMS_FILE" | head -1)"
    if [ -z "$EXPECTED" ]; then
        echo -e " ${RED}✘${NC} No checksum entry for $REL — rejecting"
        rm -f "$OUT"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi
    ACTUAL="$(sha256sum "$OUT" 2>/dev/null | awk '{print $1}')"
    if [ "$EXPECTED" = "$ACTUAL" ]; then
        return 0
    fi
    echo -e " ${RED}✘${NC} Checksum MISMATCH for $REL (expected ${EXPECTED:0:12}…, got ${ACTUAL:0:12}…)"
    rm -f "$OUT"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return 1
}

echo -e "${BLUE}[1/4] Creating directories...${NC}"
mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/backup"

FILES=(
    "utils.sh" "ui.sh" "ssl.sh" "backup.sh" "domain_separator.sh"
    "theme.sh" "diagnostics.sh" "offline.sh"
    "safe_ops.sh" "monitor.sh" "pg_health.sh" "main.sh" "VERSION" "versions.conf"
)

# Remove deprecated/unused files
rm -f "$INSTALL_DIR/site.sh" "$INSTALL_DIR/port_manager.sh" "$INSTALL_DIR/migrator.sh" "$INSTALL_DIR/mirza.sh" 2>/dev/null

echo -e "${BLUE}[2/4] Installing core files v${MRM_VERSION}...${NC}"
for FILE in "${FILES[@]}"; do
    if [[ "$FILE" == "VERSION" || "$FILE" == "versions.conf" ]]; then
        URL="$MANAGER_REPO_URL/$FILE"
    else
        URL="$MANAGER_REPO_URL/manager/$FILE"
    fi
    if "${CURL_BASE[@]}" -o "$INSTALL_DIR/$FILE" "$URL" 2>/dev/null; then
        if [[ "$FILE" == "VERSION" || "$FILE" == "versions.conf" ]]; then
            REL="$FILE"
        else
            REL="manager/$FILE"
        fi
        if verify_download "$INSTALL_DIR/$FILE" "$REL"; then
            chmod +x "$INSTALL_DIR/$FILE" 2>/dev/null
            echo -e " ${GREEN}✔${NC} Downloaded: $FILE"
        else
            echo -e " ${RED}✘${NC} Rejected: $FILE (bad checksum)"
        fi
    else
        # MRM-001/002: a failed file is only tolerated for the version text
        # files (regenerated locally from known constants); everything else
        # is a hard failure.
        if [ "$FILE" = "VERSION" ]; then
            echo "$MRM_VERSION" > "$INSTALL_DIR/$FILE"
            echo -e " ${GREEN}✔${NC} Created locally: $FILE"
        elif [ "$FILE" = "versions.conf" ]; then
            cat > "$INSTALL_DIR/$FILE" << EOF
MRM_VERSION="$MRM_VERSION"
SSL_VERSION="1.0.3"
BACKUP_VERSION="1.0.5"
THEME_VERSION="1.0.1"
EOF
            echo -e " ${GREEN}✔${NC} Created locally: $FILE"
        else
            echo -e " ${RED}✘${NC} Failed: $FILE"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    fi
done

echo -e "${BLUE}[3/4] Installing backup modules...${NC}"
BACKUP_MODULES=(
    "init.sh" "telegram.sh" "smart_fix.sh" "database.sh"
    "backup_core.sh" "restore_core.sh" "xray.sh" "post_restore.sh" "menu.sh"
)

for MODULE in "${BACKUP_MODULES[@]}"; do
    URL="$MANAGER_REPO_URL/backup/$MODULE"
    if "${CURL_BASE[@]}" -o "$INSTALL_DIR/backup/$MODULE" "$URL" 2>/dev/null; then
        if verify_download "$INSTALL_DIR/backup/$MODULE" "manager/backup/$MODULE"; then
            chmod +x "$INSTALL_DIR/backup/$MODULE" 2>/dev/null
            echo -e " ${GREEN}✔${NC} Downloaded: backup/$MODULE"
        else
            echo -e " ${RED}✘${NC} Rejected: backup/$MODULE (bad checksum)"
        fi
    else
        echo -e " ${RED}✘${NC} Failed: backup/$MODULE"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

# MRM-002: a broken install must never be reported as success
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo ""
    echo -e "${RED}✘ Install FAILED: ${FAIL_COUNT} file(s) missing or corrupt.${NC}"
    echo -e "${YELLOW}  No files were installed from the failed batch (bad files removed).${NC}"
    if [ -d "${INSTALL_DIR}.previous" ]; then
        echo -e "${YELLOW}  Previous version is still intact at ${INSTALL_DIR}.previous${NC}"
        echo -e "${YELLOW}  Restore with: rm -rf $INSTALL_DIR && mv ${INSTALL_DIR}.previous $INSTALL_DIR${NC}"
    fi
    exit 1
fi

echo ""
echo -e "${BLUE}[4/4] Installing optional files...${NC}"
if "${CURL_BASE[@]}" -o "$INSTALL_DIR/index.html" "$MANAGER_REPO_URL/templates/subscription/index.html" 2>/dev/null; then
    if verify_download "$INSTALL_DIR/index.html" "templates/subscription/index.html"; then
        echo -e " ${GREEN}✔${NC} Downloaded: index.html"
    else
        echo -e " ⚠ Skipped: index.html (bad checksum)"
    fi
else
    echo -e " ⚠ Skipped: index.html"
fi

rm -f /usr/local/bin/mrm

# MRM-005: quoted heredoc — the fallback is evaluated at RUNTIME, not install time
cat > /usr/local/bin/mrm << 'EOF'
#!/bin/bash
if [[ "$1" == "--version" || "$1" == "-v" ]]; then
    [ -r /opt/mrm-manager/versions.conf ] && source /opt/mrm-manager/versions.conf
    echo "MRM Manager ${MRM_VERSION:-$(cat /opt/mrm-manager/VERSION 2>/dev/null || echo "1.1.1")}"
    exit 0
fi
exec bash /opt/mrm-manager/main.sh "$@"
EOF
chmod +x /usr/local/bin/mrm

# Installation succeeded — the rollback copy is no longer needed
rm -rf "${INSTALL_DIR}.previous" 2>/dev/null

echo ""
echo -e "${GREEN}✔ MRM Manager v${MRM_VERSION} installed${NC}"
echo -e "${CYAN}Type 'mrm' to run${NC}"
echo ""

# Safe read with fallback for non-interactive environments
if [ -t 0 ]; then
    read -t 10 -p "Run MRM Manager now? (y/n): " RUN_NOW 2>/dev/null || RUN_NOW="n"
else
    RUN_NOW="n"
fi
echo ""
if [[ "$RUN_NOW" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Starting MRM Manager...${NC}"
    exec /usr/local/bin/mrm
else
    echo -e "${CYAN}Run with: mrm${NC}"
fi
exit 0
