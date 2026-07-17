#!/bin/bash
# MRM Manager Installer v1.0.2 - Fix prompt + fix hang

INSTALL_DIR="/opt/mrm-manager"
REPO_BASE_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/main"
MANAGER_REPO_URL="$REPO_BASE_URL/manager"
TEMPLATE_REPO_URL="$REPO_BASE_URL/templates/subscription/index.html"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root (sudo)${NC}"
    exit 1
fi

echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║      MRM Manager Installer v1.0.2            ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${BLUE}[1/4] Creating directories...${NC}"
mkdir -p "$INSTALL_DIR"

FILES=(
    "utils.sh" "ui.sh" "ssl.sh" "backup.sh" "domain_separator.sh"
    "theme.sh" "settings.sh" "diagnostics.sh" "offline.sh"
    "safe_ops.sh" "mirza.sh" "monitor.sh" "main.sh" "VERSION"
)
OPT_FILES=("index.html")

get_remote_url() {
    case "$1" in
        index.html) printf '%s\n' "$TEMPLATE_REPO_URL" ;;
        VERSION) printf '%s\n' "$REPO_BASE_URL/VERSION" ;;
        *) printf '%s\n' "$MANAGER_REPO_URL/$1" ;;
    esac
}

install_file() {
    local FILE="$1" TARGET_PATH="$INSTALL_DIR/$FILE"
    mkdir -p "$(dirname "$TARGET_PATH")"
    local URL="$(get_remote_url "$FILE")"
    if curl -s -L -f -o "$TARGET_PATH" "$URL" 2>/dev/null; then
        [[ "$TARGET_PATH" == *.sh ]] && chmod +x "$TARGET_PATH"
        echo -e "  ${GREEN}✔${NC} Downloaded: $FILE"
        return 0
    else
        rm -f "$TARGET_PATH"
        if [[ "$FILE" == "VERSION" ]]; then
            echo "1.0.2" > "$TARGET_PATH"
            echo -e "  ${GREEN}✔${NC} Created: $FILE"
            return 0
        fi
        echo -e "  ${RED}✘${NC} Failed: $FILE"
        return 1
    fi
}

# Silent cleanup
rm -f "$INSTALL_DIR/site.sh" "$INSTALL_DIR/port_manager.sh" "$INSTALL_DIR/migrator.sh" "$INSTALL_DIR/inbound.sh" 2>/dev/null
rm -rf "$INSTALL_DIR/inbound" 2>/dev/null

echo -e "${BLUE}[2/4] Installing core files v1.0.2...${NC}"
for FILE in "${FILES[@]}"; do
    install_file "$FILE" || exit 1
done

echo ""
echo -e "${BLUE}[3/4] Installing optional files...${NC}"
for FILE in "${OPT_FILES[@]}"; do
    URL="$(get_remote_url "$FILE")"
    TARGET="$INSTALL_DIR/$FILE"
    if curl -s -L -f -o "$TARGET" "$URL" 2>/dev/null; then
        echo -e "  ${GREEN}✔${NC} Downloaded: $FILE"
    else
        echo -e "  ${YELLOW}⚠${NC} Skipped: $FILE"
    fi
done

cat > /usr/local/bin/mrm << 'EOF'
#!/bin/bash
if [[ "$1" == "--version" || "$1" == "-v" ]]; then echo "MRM Manager $(cat /opt/mrm-manager/VERSION 2>/dev/null || echo 1.0.2)"; exit 0; fi
[[ "$1" == "doctor" ]] && exec bash /opt/mrm-manager/diagnostics.sh doctor
[[ "$1" == "monitor" ]] && exec bash /opt/mrm-manager/monitor.sh
[[ "$1" == "update" ]] && exec bash -c "$(curl -sL https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/main/install.sh)"
exec bash /opt/mrm-manager/main.sh "$@"
EOF
chmod +x /usr/local/bin/mrm

echo ""
echo -e "${GREEN}✔ MRM Manager v1.0.2 installed${NC}"
echo -e "${CYAN}Type 'mrm' to run${NC}"
echo ""

# FIX 1: Ask with timeout, no hang
read -t 10 -p "Run MRM Manager now? (y/n): " RUN_NOW || RUN_NOW="n"
echo ""
if [[ "$RUN_NOW" =~ ^[Yy]$ ]]; then
    # FIX 2: Run with SKIP_DEPS to avoid apt hang on first run after install
    echo -e "${BLUE}Starting MRM Manager...${NC}"
    MRM_SKIP_DEPS=1 bash "$INSTALL_DIR/main.sh" || bash "$INSTALL_DIR/main.sh"
fi

exit 0
