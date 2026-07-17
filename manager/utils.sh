#!/bin/bash
# MRM Manager v1.0.0

# --- Colors ---
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'
export PURPLE='\033[0;35m'
export ORANGE='\033[0;33m'
export NC='\033[0m'

# --- Config File ---
CONFIG_FILE="/opt/mrm-manager/panel.conf"
MRM_VERSION_FILE="/opt/mrm-manager/VERSION"
MRM_DEFAULT_VERSION="1.0.0"

ensure_mrm_config_dir() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
}

save_panel_config() {
    local PANEL_NAME="$1"
    ensure_mrm_config_dir || return 1
    printf '%s\n' "$PANEL_NAME" > "$CONFIG_FILE"
}

get_installed_panels() {
    local PANELS=()
    # Check with compose validation too, not just dir
    [ -d "/opt/pasarguard" ] && [ -f "/opt/pasarguard/.env" ] && PANELS+=("pasarguard")
    [ -d "/opt/marzban" ] && [ -f "/opt/marzban/.env" ] && PANELS+=("marzban")
    [ -d "/opt/rebecca" ] && [ -f "/opt/rebecca/.env" ] && PANELS+=("rebecca")
    # Fallback to dir only if env missing but compose exists
    [ ${#PANELS[@]} -eq 0 ] && {
        [ -d "/opt/pasarguard" ] && PANELS+=("pasarguard")
        [ -d "/opt/marzban" ] && PANELS+=("marzban")
        [ -d "/opt/rebecca" ] && PANELS+=("rebecca")
    }
    printf '%s\n' "${PANELS[@]}"
}

auto_detect_single_panel() {
    local DETECTED=()
    local PANEL_NAME
    while IFS= read -r PANEL_NAME; do
        [ -n "$PANEL_NAME" ] && DETECTED+=("$PANEL_NAME")
    done < <(get_installed_panels)
    if [ "${#DETECTED[@]}" -eq 1 ]; then
        save_panel_config "${DETECTED[0]}" || return 1
        return 0
    fi
    return 1
}

apply_panel_config() {
    local PANEL_TYPE="$1"
    case "$PANEL_TYPE" in
        pasarguard)
            export PANEL_DIR="/opt/pasarguard"
            export PANEL_ENV="/opt/pasarguard/.env"
            export PANEL_DEF_CERTS="/var/lib/pasarguard/certs"
            export DATA_DIR="/var/lib/pasarguard"
            export NODE_DIR="/opt/pg-node"
            export NODE_ENV="/opt/pg-node/.env"
            export NODE_DEF_CERTS="/var/lib/pg-node/certs"
            return 0
            ;;
        marzban)
            export PANEL_DIR="/opt/marzban"
            export PANEL_ENV="/opt/marzban/.env"
            export PANEL_DEF_CERTS="/var/lib/marzban/certs"
            export DATA_DIR="/var/lib/marzban"
            export NODE_DIR="/opt/marzban-node"
            export NODE_ENV="/opt/marzban-node/.env"
            export NODE_DEF_CERTS="/var/lib/marzban-node/certs"
            return 0
            ;;
        rebecca)
            export PANEL_DIR="/opt/rebecca"
            export PANEL_ENV="/opt/rebecca/.env"
            export PANEL_DEF_CERTS="/var/lib/rebecca/certs"
            export DATA_DIR="/var/lib/rebecca"
            export NODE_DIR="/opt/rebecca-node"
            export NODE_ENV="/opt/rebecca-node/.env"
            export NODE_DEF_CERTS="/var/lib/rebecca-node/certs"
            return 0
            ;;
    esac
    return 1
}

find_compose_file() {
    local BASE_DIR="$1"
    local CANDIDATE
    [ -z "$BASE_DIR" ] && return 1
    for CANDIDATE in \
        "$BASE_DIR/docker-compose.yml" \
        "$BASE_DIR/docker-compose.yaml" \
        "$BASE_DIR/compose.yml" \
        "$BASE_DIR/compose.yaml"
    do
        if [ -f "$CANDIDATE" ]; then
            printf '%s\n' "$CANDIDATE"
            return 0
        fi
    done
    return 1
}

get_panel_compose_file() {
    find_compose_file "$PANEL_DIR"
}

get_node_compose_file() {
    find_compose_file "$NODE_DIR"
}

get_panel_container_id() {
    local COMPOSE_FILE
    load_panel_config >/dev/null 2>&1 || return 1
    COMPOSE_FILE="$(get_panel_compose_file 2>/dev/null)" || return 1
    docker compose -f "$COMPOSE_FILE" ps -q 2>/dev/null | head -1
}

# --- Panel Selection ---
select_panel() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════${NC}"
    echo -e "${CYAN}       SELECT YOUR PANEL TYPE         ${NC}"
    echo -e "${CYAN}══════════════════════════════════════${NC}"
    echo ""
    echo "1) Pasarguard"
    echo "2) Marzban"
    echo "3) Rebecca"
    echo ""
    read -p "Select [1-3]: " PANEL_CHOICE
    case $PANEL_CHOICE in
        1) save_panel_config "pasarguard" ;;
        2) save_panel_config "marzban" ;;
        3) save_panel_config "rebecca" ;;
        *) echo -e "${RED}Invalid selection. Defaulting to Pasarguard.${NC}"; save_panel_config "pasarguard" ;;
    esac
    load_panel_config
    echo -e "${GREEN}✔ Panel set to: $(cat "$CONFIG_FILE" 2>/dev/null)${NC}"
    echo ""
}

# --- Load Panel Config ---
load_panel_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        auto_detect_single_panel || {
            select_panel
            return
        }
    fi
    local PANEL_TYPE
    PANEL_TYPE=$(cat "$CONFIG_FILE" 2>/dev/null)
    if apply_panel_config "$PANEL_TYPE"; then
        return 0
    fi
    auto_detect_single_panel || {
        select_panel
        return
    }
    PANEL_TYPE=$(cat "$CONFIG_FILE" 2>/dev/null)
    apply_panel_config "$PANEL_TYPE"
}

detect_active_panel() {
    load_panel_config
    cat "$CONFIG_FILE" 2>/dev/null || echo "unknown"
}

change_panel() {
    echo -e "${YELLOW}Current Panel: $(cat "$CONFIG_FILE" 2>/dev/null)${NC}"
    select_panel
}

# --- Version Management (NEW) ---
get_mrm_version() {
    if [ -f "$MRM_VERSION_FILE" ]; then
        cat "$MRM_VERSION_FILE" 2>/dev/null | head -1
    else
        echo "$MRM_DEFAULT_VERSION"
    fi
}

# FIXED: was mrm-ssl-pasarguard, now mrm-manager-pasarguard
export THEME_HTML_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/main/templates/subscription/index.html"
export MRM_REPO_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/main"

# Initialize
load_panel_config

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Error: Please run this script as root (sudo).${NC}"
        exit 1
    fi
}

install_deps() {
    local NEED_INSTALL=false
    local REQUIRED_COMMANDS=(
        certbot nginx python3 sqlite3 docker jq lsof curl nano socat tar unzip
    )
    local CMD
    for CMD in "${REQUIRED_COMMANDS[@]}"; do
        command -v "$CMD" >/dev/null 2>&1 || NEED_INSTALL=true
    done
    if [ "$NEED_INSTALL" = true ]; then
        echo -e "${BLUE}[INFO] Installing dependencies...${NC}"
        apt-get update -qq > /dev/null 2>&1
        apt-get install -y certbot lsof curl nano socat tar python3 nginx unzip jq sqlite3 -qq > /dev/null 2>&1
        if ! command -v docker >/dev/null 2>&1; then
            echo -e "${BLUE}[INFO] Installing Docker...${NC}"
            curl -fsSL https://get.docker.com | sh > /dev/null 2>&1
        fi
    fi
}

pause() {
    echo ""
    read -p "Press Enter to continue..."
}

get_panel_cli() {
    local panel
    panel=$(cat "$CONFIG_FILE" 2>/dev/null)
    case "$panel" in
        rebecca) echo "rebecca-cli" ;;
        pasarguard) echo "pasarguard-cli" ;;
        marzban) echo "marzban-cli" ;;
        *) echo "marzban-cli" ;;
    esac
}

restart_service() {
    local SERVICE="$1"
    local COMPOSE_FILE=""
    load_panel_config
    if [ "$SERVICE" == "panel" ]; then
        echo -e "${BLUE}Restarting Panel ($PANEL_DIR)...${NC}"
        if [ ! -d "$PANEL_DIR" ]; then
            echo -e "${RED}Panel not found at $PANEL_DIR${NC}"
            return 1
        fi
        COMPOSE_FILE="$(get_panel_compose_file 2>/dev/null)"
        if [ -z "$COMPOSE_FILE" ]; then
            echo -e "${RED}No compose file found in $PANEL_DIR${NC}"
            return 1
        fi
        if (cd "$PANEL_DIR" && docker compose down && docker compose up -d); then
            echo -e "${GREEN}Done.${NC}"
            return 0
        else
            echo -e "${RED}Failed to restart panel.${NC}"
            return 1
        fi
    elif [ "$SERVICE" == "node" ]; then
        echo -e "${BLUE}Restarting Node ($NODE_DIR)...${NC}"
        if [ ! -d "$NODE_DIR" ]; then
            echo -e "${RED}Node directory not found at $NODE_DIR${NC}"
            return 1
        fi
        COMPOSE_FILE="$(get_node_compose_file 2>/dev/null)"
        if [ -z "$COMPOSE_FILE" ]; then
            echo -e "${RED}No compose file found in $NODE_DIR${NC}"
            return 1
        fi
        if (cd "$NODE_DIR" && docker compose restart); then
            echo -e "${GREEN}Done.${NC}"
            return 0
        else
            echo -e "${RED}Failed to restart node.${NC}"
            return 1
        fi
    fi
    echo -e "${RED}Unknown service: $SERVICE${NC}"
    return 1
}

admin_create() {
    local cli cid
    cli=$(get_panel_cli)
    cid=$(get_panel_container_id)
    if [ -z "$cid" ]; then
        echo -e "${RED}Panel is not running or compose file was not found!${NC}"
        return
    fi
    echo -e "${CYAN}Creating Admin for $(cat "$CONFIG_FILE" 2>/dev/null)${NC}"
    echo "1) Super Admin (Sudo)"
    echo "2) Regular Admin"
    read -p "Select: " type
    if [ "$type" == "1" ]; then
        docker exec -it "$cid" $cli admin create --sudo
    else
        docker exec -it "$cid" $cli admin create
    fi
}

admin_reset() {
    local cli cid
    cli=$(get_panel_cli)
    cid=$(get_panel_container_id)
    if [ -z "$cid" ]; then
        echo -e "${RED}Panel not running or compose file was not found${NC}"
        return
    fi
    read -p "Username to reset password: " user
    if [ -n "$user" ]; then
        docker exec -it "$cid" $cli admin update --username "$user" --password
    fi
}

admin_delete() {
    local cli cid
    cli=$(get_panel_cli)
    cid=$(get_panel_container_id)
    if [ -z "$cid" ]; then
        echo -e "${RED}Panel not running or compose file was not found${NC}"
        return
    fi
    read -p "Username to delete: " user
    if [ -n "$user" ]; then
        docker exec -it "$cid" $cli admin delete --username "$user"
    fi
}
