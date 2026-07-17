#!/bin/bash
# MRM Manager Installer v1.0.1 - Minimal & Fixed hang

INSTALL_DIR="/opt/mrm-manager"
REPO_BASE_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/main"
MANAGER_REPO_URL="$REPO_BASE_URL/manager"
TEMPLATE_REPO_URL="$REPO_BASE_URL/templates/subscription/index.html"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P || pwd -P)"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root (sudo)${NC}"
    exit 1
fi

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
    local CANDIDATES=(
        "$SCRIPT_DIR/$FILE"
        "$SCRIPT_DIR/manager/$FILE"
        "./$FILE"
        "./manager/$FILE"
    )
    for CANDIDATE in "${CANDIDATES[@]}"; do
        if [ -f "$CANDIDATE" ]; then
            printf '%s\n' "$CANDIDATE"
            return 0
        fi
    done
    return 1
}

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
    local SRC="$(get_local_source_path "$FILE" 2>/dev/null || true)"
    if [ -n "$SRC" ] && [ -f "$SRC" ]; then
        cp "$SRC" "$TARGET_PATH"
        [[ "$TARGET_PATH" == *.sh ]] && chmod +x "$TARGET_PATH"
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then return 1; fi
    local URL="$(get_remote_url "$FILE")"
    if curl -s -L -f -o "$TARGET_PATH" "$URL" 2>/dev/null; then
        [[ "$TARGET_PATH" == *.sh ]] && chmod +x "$TARGET_PATH"
        return 0
    else
        rm -f "$TARGET_PATH"
        if [[ "$FILE" == "VERSION" || "$FILE" == "monitor.sh" ]]; then
            [ "$FILE" == "VERSION" ] && echo "1.0.1" > "$TARGET_PATH"
            return 0
        fi
        return 1
    fi
}

# Silent cleanup of old modules - NO OUTPUT (Fix user request)
rm -f "$INSTALL_DIR/site.sh" "$INSTALL_DIR/port_manager.sh" "$INSTALL_DIR/migrator.sh" "$INSTALL_DIR/inbound.sh" 2>/dev/null
rm -rf "$INSTALL_DIR/inbound" 2>/dev/null

for FILE in "${FILES[@]}"; do
    install_file "$FILE" "false" || {
        echo -e "${RED}Failed: $FILE${NC}"
        exit 1
    }
done

for FILE in "${OPT_FILES[@]}"; do
    install_file "$FILE" "true" || true
done

[ ! -f "$INSTALL_DIR/VERSION" ] && echo "1.0.1" > "$INSTALL_DIR/VERSION"

cat > /usr/local/bin/mrm << 'EOF'
#!/bin/bash
if [[ "$1" == "--version" || "$1" == "-v" || "$1" == "version" ]]; then
    echo "MRM Manager $(cat /opt/mrm-manager/VERSION 2>/dev/null || echo 1.0.1)"
    exit 0
fi
if [[ "$1" == "doctor" ]]; then exec bash /opt/mrm-manager/diagnostics.sh doctor "${@:2}"; fi
if [[ "$1" == "monitor" ]]; then exec bash /opt/mrm-manager/monitor.sh "${@:2}"; fi
if [[ "$1" == "update" ]]; then
    bash -c "$(curl -sL https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/main/install.sh)"
    exit 0
fi
exec bash /opt/mrm-manager/main.sh "$@"
EOF
chmod +x /usr/local/bin/mrm

echo -e "${GREEN}✔ MRM Manager v1.0.1 installed${NC}"
echo -e "${CYAN}Type 'mrm' to run${NC}"
# No prompt, no hang - fix user issue
exit 0
