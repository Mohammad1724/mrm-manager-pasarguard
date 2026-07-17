#!/bin/bash
# MRM Manager Installer v1.0.0
# Versioning: 1.0.0 - Semantic Versioning

INSTALL_DIR="/opt/mrm-manager"
REPO_BASE_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/main"
MANAGER_REPO_URL="$REPO_BASE_URL/manager"
TEMPLATE_REPO_URL="$REPO_BASE_URL/templates/subscription/index.html"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P || pwd -P)"

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
echo -e "${CYAN}║      MRM Manager Installer v1.0.0            ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

mkdir -p "$INSTALL_DIR"

FILES=(
    "utils.sh"
    "ui.sh"
    "ssl.sh"
    "backup.sh"
    "domain_separator.sh"
    "theme.sh"
    "settings.sh"
    "diagnostics.sh"
    "offline.sh"
    "safe_ops.sh"
    "mirza.sh"
    "monitor.sh"
    "main.sh"
    "VERSION"
)

OPT_FILES=(
    "index.html"
)

get_local_source_path() {
    local FILE="$1"
    local CANDIDATES=()
    case "$FILE" in
        index.html)
            CANDIDATES=(
                "$SCRIPT_DIR/index.html"
                "$SCRIPT_DIR/templates/subscription/index.html"
                "./index.html"
                "./templates/subscription/index.html"
            )
            ;;
        *)
            CANDIDATES=(
                "$SCRIPT_DIR/$FILE"
                "$SCRIPT_DIR/manager/$FILE"
                "./$FILE"
                "./manager/$FILE"
            )
            ;;
    esac
    for CANDIDATE in "${CANDIDATES[@]}"; do
        if [ -f "$CANDIDATE" ]; then
            printf '%s\n' "$CANDIDATE"
            return 0
        fi
    done
    return 1
}

get_remote_url() {
    local FILE="$1"
    case "$FILE" in
        index.html) printf '%s\n' "$TEMPLATE_REPO_URL" ;;
        VERSION) printf '%s\n' "$REPO_BASE_URL/VERSION" ;;
        *) printf '%s\n' "$MANAGER_REPO_URL/$FILE" ;;
    esac
}

set_executable_if_needed() {
    [[ "$1" == *.sh ]] && chmod +x "$1"
}

install_file() {
    local FILE="$1" IS_OPTIONAL="$2" TARGET_PATH="$INSTALL_DIR/$FILE"
    mkdir -p "$(dirname "$TARGET_PATH")"
    local SOURCE_PATH="$(get_local_source_path "$FILE" 2>/dev/null || true)"
    if [ -n "$SOURCE_PATH" ] && [ -f "$SOURCE_PATH" ]; then
        cp "$SOURCE_PATH" "$TARGET_PATH"
        set_executable_if_needed "$TARGET_PATH"
        echo -e "  ${GREEN}✔${NC} Installed (Local): $FILE"
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        if [ "$IS_OPTIONAL" == "true" ]; then
            echo -e "  ${YELLOW}⚠${NC} Skipped optional: $FILE"
            return 0
        else
            echo -e "  ${RED}✘${NC} Failed: $FILE (no curl)"
            return 1
        fi
    fi
    local REMOTE_URL="$(get_remote_url "$FILE")"
    if curl -s -L -f -o "$TARGET_PATH" "$REMOTE_URL" 2>/dev/null; then
        set_executable_if_needed "$TARGET_PATH"
        echo -e "  ${GREEN}✔${NC} Downloaded: $FILE"
        return 0
    else
        rm -f "$TARGET_PATH"
        if [ "$IS_OPTIONAL" == "true" ]; then
            echo -e "  ${YELLOW}⚠${NC} Skipped optional: $FILE"
            return 0
        else
            if [[ "$FILE" == "VERSION" || "$FILE" == "monitor.sh" ]]; then
                echo -e "  ${YELLOW}Creating local $FILE${NC}"
                [ "$FILE" == "VERSION" ] && echo "1.0.0" > "$TARGET_PATH" || echo "# placeholder" > "$TARGET_PATH"
                return 0
            fi
            echo -e "  ${RED}✘${NC} Failed: $FILE"
            return 1
        fi
    fi
}

echo -e "${BLUE}[1/4] Creating directories...${NC}"
mkdir -p "$INSTALL_DIR"

echo -e "${BLUE}[2/4] Installing core files v1.0.0...${NC}"
for FILE in "${FILES[@]}"; do
    install_file "$FILE" "false" || { echo -e "${RED}CRITICAL ERROR at $FILE${NC}"; exit 1; }
done

echo -e "${BLUE}[3/4] Installing optional files...${NC}"
for FILE in "${OPT_FILES[@]}"; do
    install_file "$FILE" "true"
done

echo ""
rm -f "$INSTALL_DIR/inbound.sh" 2>/dev/null
rm -rf "$INSTALL_DIR/inbound" 2>/dev/null

[ ! -f "$INSTALL_DIR/VERSION" ] && echo "1.0.0" > "$INSTALL_DIR/VERSION"

cat > /usr/local/bin/mrm << 'EOF'
#!/bin/bash
if [[ "$1" == "--version" || "$1" == "-v" || "$1" == "version" ]]; then
    echo "MRM Manager $(cat /opt/mrm-manager/VERSION 2>/dev/null || echo 1.0.0)"
    if [ -f "/opt/pasarguard/.env" ]; then echo "Panel: Pasarguard"
    elif [ -f "/opt/marzban/.env" ]; then echo "Panel: Marzban"
    elif [ -f "/opt/rebecca/.env" ]; then echo "Panel: Rebecca"
    fi
    exit 0
fi
if [[ "$1" == "doctor" ]]; then exec bash /opt/mrm-manager/diagnostics.sh doctor "${@:2}"; fi
if [[ "$1" == "monitor" ]]; then exec bash /opt/mrm-manager/monitor.sh "${@:2}"; fi
if [[ "$1" == "update" ]]; then
    echo "Updating MRM Manager..."
    bash -c "$(curl -sL https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/main/install.sh)"
    exit 0
fi
exec bash /opt/mrm-manager/main.sh "$@"
EOF
chmod +x /usr/local/bin/mrm

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║        ${GREEN}✔ Installation Complete v1.0.0 ${CYAN}      ║${NC}"
echo -e "${CYAN}╠══════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║${NC}  Version: ${GREEN}1.0.0${NC}                     ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  

╚══════════════════════════════════════════════╝${NC}"
echo ""

read -p "Run MRM Manager now? (y/n): " RUN_NOW
if [[ "$RUN_NOW" =~ ^[Yy]$ ]]; then
    bash "$INSTALL_DIR/main.sh"
fi
