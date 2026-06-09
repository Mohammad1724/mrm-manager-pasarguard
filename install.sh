#!/bin/bash

# ==========================================
# MRM Manager Installer v3.2
# ==========================================

INSTALL_DIR="/opt/mrm-manager"
REPO_BASE_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-ssl-pasarguard/main"
MANAGER_REPO_URL="$REPO_BASE_URL/manager"
TEMPLATE_REPO_URL="$REPO_BASE_URL/templates/subscription/index.html"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P || pwd -P)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Check Root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root (sudo)${NC}"
    exit 1
fi

echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║      MRM Manager Installer v3.2              ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

# Create directories
echo -e "${BLUE}[1/4] Creating directories...${NC}"
mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/inbound"

# Core Files List
FILES=(
    "utils.sh"
    "ui.sh"
    "ssl.sh"
    "backup.sh"
    "domain_separator.sh"
    "site.sh"
    "theme.sh"
    "migrator.sh"
    "mirza.sh"
    "main.sh"
)

# Inbound Module Files
INBOUND_FILES=(
    "inbound/main.sh"
    "inbound/lib.sh"
    "inbound/create.sh"
    "inbound/manage.sh"
    "inbound/tools.sh"
)

# Optional files
OPT_FILES=(
    "index.html"
)

get_local_source_path() {
    local FILE="$1"
    local CANDIDATES=()
    local CANDIDATE

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
        index.html)
            printf '%s\n' "$TEMPLATE_REPO_URL"
            ;;
        *)
            printf '%s\n' "$MANAGER_REPO_URL/$FILE"
            ;;
    esac
}

set_executable_if_needed() {
    local TARGET_PATH="$1"

    if [[ "$TARGET_PATH" == *.sh ]]; then
        chmod +x "$TARGET_PATH"
    fi
}

validate_download_prerequisites() {
    local FILE

    for FILE in "${FILES[@]}" "${INBOUND_FILES[@]}"; do
        if ! get_local_source_path "$FILE" >/dev/null 2>&1; then
            if ! command -v curl >/dev/null 2>&1; then
                echo -e "${RED}curl is required for online installation but is not installed.${NC}"
                echo -e "${YELLOW}Install curl or run this installer from a full local repository checkout.${NC}"
                exit 1
            fi
            return 0
        fi
    done
}

install_file() {
    local FILE="$1"
    local IS_OPTIONAL="$2"
    local TARGET_PATH="$INSTALL_DIR/$FILE"
    local DIR
    local SOURCE_PATH
    local REMOTE_URL

    # Create subdirectory if needed
    DIR="$(dirname "$TARGET_PATH")"
    mkdir -p "$DIR"

    # Try Local Install
    SOURCE_PATH="$(get_local_source_path "$FILE" 2>/dev/null || true)"
    if [ -n "$SOURCE_PATH" ] && [ -f "$SOURCE_PATH" ]; then
        cp "$SOURCE_PATH" "$TARGET_PATH"
        set_executable_if_needed "$TARGET_PATH"
        echo -e "  ${GREEN}✔${NC} Installed (Local): $FILE"
        return 0
    fi

    # Try Online Install
    if ! command -v curl >/dev/null 2>&1; then
        if [ "$IS_OPTIONAL" == "true" ]; then
            echo -e "  ${YELLOW}⚠${NC} Skipped optional: $FILE (curl not installed)"
            return 0
        else
            echo -e "  ${RED}✘${NC} Failed: $FILE (curl not installed and no local source found)"
            return 1
        fi
    fi

    REMOTE_URL="$(get_remote_url "$FILE")"
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
            echo -e "  ${RED}✘${NC} Failed: $FILE"
            return 1
        fi
    fi
}

validate_download_prerequisites

# Install Core Files
echo -e "${BLUE}[2/4] Installing core files...${NC}"
for FILE in "${FILES[@]}"; do
    if ! install_file "$FILE" "false"; then
        echo -e "${RED}CRITICAL ERROR: Installation failed at $FILE${NC}"
        exit 1
    fi
done

# Install Inbound Module
echo -e "${BLUE}[3/4] Installing inbound module...${NC}"
for FILE in "${INBOUND_FILES[@]}"; do
    if ! install_file "$FILE" "false"; then
        echo -e "${RED}CRITICAL ERROR: Installation failed at $FILE${NC}"
        exit 1
    fi
done

# Install Optional Files
echo -e "${BLUE}[4/4] Installing optional files...${NC}"
for FILE in "${OPT_FILES[@]}"; do
    install_file "$FILE" "true"
done

# Cleanup old files
echo ""
echo -e "${YELLOW}Cleaning up old files...${NC}"
rm -f "$INSTALL_DIR/inbound.sh" 2>/dev/null && echo -e "  ${GREEN}✔${NC} Removed old inbound.sh"
rm -f "$INSTALL_DIR/node.sh" 2>/dev/null
rm -f "$INSTALL_DIR/port_manager.sh" 2>/dev/null

# Create shortcut command
ln -sf "$INSTALL_DIR/main.sh" /usr/local/bin/mrm
chmod +x /usr/local/bin/mrm

# Summary
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║        ${GREEN}✔ Installation Complete!${CYAN}              ║${NC}"
echo -e "${CYAN}╠══════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║${NC}  Installed files:                            ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}    • Core modules: ${GREEN}${#FILES[@]}${NC}                        ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}    • Inbound module: ${GREEN}${#INBOUND_FILES[@]}${NC} files               ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                              ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${YELLOW}Type 'mrm' to run the manager${NC}              ${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

# Run
read -p "Run MRM Manager now? (y/n): " RUN_NOW
if [[ "$RUN_NOW" =~ ^[Yy]$ ]]; then
    bash "$INSTALL_DIR/main.sh"
fi
