#!/bin/bash
# MRM Manager Installer

INSTALL_DIR="/opt/mrm-manager"
REPO_BASE_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/main"
MANAGER_REPO_URL="$REPO_BASE_URL/manager"
VERSION_REGISTRY_URL="$REPO_BASE_URL/versions.conf"

# Version is loaded from versions.conf registry — single source of truth
MRM_VERSION=""
VERSION_REGISTRY_FILE="$(mktemp)"
if curl -fsSL --connect-timeout 10 "$VERSION_REGISTRY_URL" -o "$VERSION_REGISTRY_FILE" 2>/dev/null; then
    source "$VERSION_REGISTRY_FILE"
fi
rm -f "$VERSION_REGISTRY_FILE"

# Fallback only if registry fetch failed
if [ -z "$MRM_VERSION" ]; then
    MRM_VERSION="1.1.0"
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

[ "$EUID" -ne 0 ] && { echo -e "${RED}Please run as root${NC}"; exit 1; }

echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║ MRM Manager Installer v${MRM_VERSION}          ║${NC}"
echo -e "${CYAN}║                                              ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${BLUE}[1/4] Creating directories...${NC}"
mkdir -p "$INSTALL_DIR"

FILES=(
    "utils.sh" "ui.sh" "ssl.sh" "backup.sh" "domain_separator.sh"
    "theme.sh" "diagnostics.sh" "offline.sh"
    "safe_ops.sh" "monitor.sh" "pg_health.sh" "main.sh" "VERSION" "versions.conf"
)

# Remove deprecated/unused files
rm -f "$INSTALL_DIR/site.sh" "$INSTALL_DIR/port_manager.sh" "$INSTALL_DIR/migrator.sh" "$INSTALL_DIR/mirza.sh" 2>/dev/null

echo -e "${BLUE}[2/4] Installing core files v${MRM_VERSION}...${NC}"
for FILE in "${FILES[@]}"; do
    URL="$MANAGER_REPO_URL/$FILE"
    [[ "$FILE" == "VERSION" || "$FILE" == "versions.conf" ]] && URL="$REPO_BASE_URL/$FILE"
    if curl -sL -f -o "$INSTALL_DIR/$FILE" "$URL" 2>/dev/null; then
        chmod +x "$INSTALL_DIR/$FILE" 2>/dev/null
        echo -e " ${GREEN}✔${NC} Downloaded: $FILE"
    else
        if [ "$FILE" = "VERSION" ]; then
            echo "$MRM_VERSION" > "$INSTALL_DIR/$FILE"
            echo -e " ${GREEN}✔${NC} Created: $FILE"
        elif [ "$FILE" = "versions.conf" ]; then
            cat > "$INSTALL_DIR/$FILE" << EOF
MRM_VERSION="$MRM_VERSION"
SSL_VERSION="1.0.3"
BACKUP_VERSION="1.0.5"
THEME_VERSION="1.0.1"
EOF
            echo -e " ${GREEN}✔${NC} Created: $FILE"
        else
            echo -e " ${RED}✘${NC} Failed: $FILE"
        fi
    fi
done

echo -e "${BLUE}[3/4] Installing backup modules...${NC}"
mkdir -p "$INSTALL_DIR/backup"

BACKUP_MODULES=(
    "init.sh" "telegram.sh" "smart_fix.sh" "database.sh"
    "backup_core.sh" "restore_core.sh" "xray.sh" "post_restore.sh" "menu.sh"
)

for MODULE in "${BACKUP_MODULES[@]}"; do
    URL="$MANAGER_REPO_URL/backup/$MODULE"
    if curl -sL -f -o "$INSTALL_DIR/backup/$MODULE" "$URL" 2>/dev/null; then
        chmod +x "$INSTALL_DIR/backup/$MODULE" 2>/dev/null
        echo -e " ${GREEN}✔${NC} Downloaded: backup/$MODULE"
    else
        echo -e " ${RED}✘${NC} Failed: backup/$MODULE"
    fi
done

echo ""
echo -e "${BLUE}[4/4] Installing optional files...${NC}"
curl -sL -f -o "$INSTALL_DIR/index.html" "$REPO_BASE_URL/templates/subscription/index.html" 2>/dev/null && echo -e " ${GREEN}✔${NC} Downloaded: index.html" || echo -e " ⚠ Skipped: index.html"

rm -f /usr/local/bin/mrm

cat > /usr/local/bin/mrm << EOF
#!/bin/bash
if [[ "\$1" == "--version" || "\$1" == "-v" ]]; then
    [ -r /opt/mrm-manager/versions.conf ] && source /opt/mrm-manager/versions.conf
    echo "MRM Manager \${MRM_VERSION:-$(cat /opt/mrm-manager/VERSION 2>/dev/null || echo $MRM_VERSION)}"
    exit 0
fi
exec bash /opt/mrm-manager/main.sh "\$@"
EOF
chmod +x /usr/local/bin/mrm

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
