#!/bin/bash
# MRM Manager utils.sh v1.0.3 - Fix hang on no panel (no prompt)

export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'
export PURPLE='\033[0;35m'
export ORANGE='\033[0;33m'
export NC='\033[0m'

CONFIG_FILE="/opt/mrm-manager/panel.conf"
MRM_VERSION_FILE="/opt/mrm-manager/VERSION"
MRM_DEFAULT_VERSION="1.0.3"

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
    [ -d "/opt/pasarguard" ] && PANELS+=("pasarguard")
    [ -d "/opt/marzban" ] && PANELS+=("marzban")
    [ -d "/opt/rebecca" ] && PANELS+=("rebecca")
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
    COMPOSE_FILE="$(get_panel_compose_file 2>/dev/null)" || return 1
    docker compose -f "$COMPOSE_FILE" ps -q 2>/dev/null | head -1
}

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

# FIXED: Non-interactive version - never prompts on source
load_panel_config() {
    # If config file exists, try to use it
    if [ -f "$CONFIG_FILE" ]; then
        local PANEL_TYPE
        PANEL_TYPE=$(cat "$CONFIG_FILE" 2>/dev/null)
        if apply_panel_config "$PANEL_TYPE"; then
            return 0
        fi
    fi

    # Try auto-detect
    if auto_detect_single_panel; then
        local PANEL_TYPE
        PANEL_TYPE=$(cat "$CONFIG_FILE" 2>/dev/null)
        if apply_panel_config "$PANEL_TYPE"; then
            return 0
        fi
    fi

    # FIX: No prompt on load - default to pasarguard silently
    # Only prompt when user explicitly calls select_panel via settings menu
    # Check if we're in interactive mode and MRM_FIRST_RUN is not set
    if [ -n "$MRM_FIRST_RUN" ] || [ ! -t 0 ]; then
        # Non-interactive or first run after install - default without prompt
        save_panel_config "pasarguard" 2>/dev/null || true
        apply_panel_config "pasarguard"
        return 0
    fi

    # Even in interactive, if no panels installed, default without prompt to avoid hang
    local PANELS
    PANELS=$(get_installed_panels)
    if [ -z "$PANELS" ]; then
        save_panel_config "pasarguard" 2>/dev/null || true
        apply_panel_config "pasarguard"
        return 0
    fi

    # If multiple panels and interactive, then we can prompt (but this is called on source, so avoid)
    # Default to first found
    local FIRST=$(echo "$PANELS" | head -1)
    if [ -n "$FIRST" ]; then
        save_panel_config "$FIRST" 2>/dev/null || true
        apply_panel_config "$FIRST"
        return 0
    fi

    # Final fallback
    save_panel_config "pasarguard" 2>/dev/null || true
    apply_panel_config "pasarguard"
}

detect_active_panel() {
    load_panel_config
    cat "$CONFIG_FILE" 2>/dev/null || echo "pasarguard"
}

change_panel() {
    echo -e "${YELLOW}Current Panel: $(cat "$CONFIG_FILE" 2>/dev/null)${NC}"
    select_panel
}

get_mrm_version() {
    if [ -f "$MRM_VERSION_FILE" ]; then
        cat "$MRM_VERSION_FILE" 2>/dev/null | head -1
    else
        echo "$MRM_DEFAULT_VERSION"
    fi
}

export THEME_HTML_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/main/templates/subscription/index.html"
export MRM_REPO_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/main"

# Initialize - NON-BLOCKING, no prompt
load_panel_config >/dev/null 2>&1 || apply_panel_config "pasarguard" >/dev/null 2>&1 || true

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Error: Please run as root (sudo).${NC}"
        exit 1
    fi
}

install_deps() {
    if [ -n "$MRM_SKIP_DEPS" ] || [ -n "$MRM_FIRST_RUN" ]; then
        return 0
    fi
    local NEED_INSTALL=false
    for CMD in certbot nginx python3 sqlite3 docker jq lsof curl nano socat tar unzip; do
        command -v "$CMD" >/dev/null 2>&1 || NEED_INSTALL=true
    done
    if [ "$NEED_INSTALL" = true ]; then
        if fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
            echo -e "${YELLOW}apt is locked, skipping dependency install${NC}"
            sleep 1
            return 0
        fi
        echo -e "${BLUE}[INFO] Installing dependencies...${NC}"
        timeout 60 apt-get update -qq >/dev/null 2>&1 || echo -e "${YELLOW}apt update timeout, continuing...${NC}"
        timeout 120 apt-get install -y certbot lsof curl nano socat tar python3 nginx unzip jq sqlite3 -qq >/dev/null 2>&1 || true
        if ! command -v docker >/dev/null 2>&1; then
            timeout 120 curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || true
        fi
    fi
}

pause() {
    echo ""
    read -p "Press Enter to continue..."
}

get_panel_cli() {
    local panel=$(cat "$CONFIG_FILE" 2>/dev/null)
    case "$panel" in
        rebecca) echo "rebecca-cli" ;;
        pasarguard) echo "pasarguard-cli" ;;
        marzban) echo "marzban-cli" ;;
        *) echo "marzban-cli" ;;
    esac
}

restart_service() {
    local SERVICE="$1" COMPOSE_FILE=""
    load_panel_config >/dev/null 2>&1 || true
    if [ "$SERVICE" == "panel" ]; then
        [ ! -d "$PANEL_DIR" ] && { echo -e "${RED}Panel not found at $PANEL_DIR${NC}"; return 1; }
        COMPOSE_FILE="$(get_panel_compose_file 2>/dev/null)"
        [ -z "$COMPOSE_FILE" ] && { echo -e "${RED}No compose file found${NC}"; return 1; }
        (cd "$PANEL_DIR" && docker compose down && docker compose up -d) && echo -e "${GREEN}Done.${NC}" || { echo -e "${RED}Failed${NC}"; return 1; }
    elif [ "$SERVICE" == "node" ]; then
        [ ! -d "$NODE_DIR" ] && { echo -e "${RED}Node not found${NC}"; return 1; }
        COMPOSE_FILE="$(get_node_compose_file 2>/dev/null)"
        [ -z "$COMPOSE_FILE" ] && { echo -e "${RED}No compose file${NC}"; return 1; }
        (cd "$NODE_DIR" && docker compose restart) && echo -e "${GREEN}Done.${NC}" || { echo -e "${RED}Failed${NC}"; return 1; }
    fi
}

admin_create() {
    local cli=$(get_panel_cli) cid=$(get_panel_container_id)
    [ -z "$cid" ] && { echo -e "${RED}Panel not running${NC}"; return; }
    echo -e "${CYAN}Creating Admin for $(cat "$CONFIG_FILE" 2>/dev/null)${NC}"
    echo "1) Super Admin (Sudo)"; echo "2) Regular Admin"; read -p "Select: " type
    if [ "$type" == "1" ]; then docker exec -it "$cid" $cli admin create --sudo; else docker exec -it "$cid" $cli admin create; fi
}

admin_reset() {
    local cli=$(get_panel_cli) cid=$(get_panel_container_id)
    [ -z "$cid" ] && { echo -e "${RED}Panel not running${NC}"; return; }
    read -p "Username to reset password: " user
    [ -n "$user" ] && docker exec -it "$cid" $cli admin update --username "$user" --password
}

admin_delete() {
    local cli=$(get_panel_cli) cid=$(get_panel_container_id)
    [ -z "$cid" ] && { echo -e "${RED}Panel not running${NC}"; return; }
    read -p "Username to delete: " user
    [ -n "$user" ] && docker exec -it "$cid" $cli admin delete --username "$user"
}
