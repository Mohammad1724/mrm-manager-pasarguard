#!/bin/bash
# MRM Manager utils.sh v1.1.9

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
# FIX: Default version matches current release (was "1.0.3")
MRM_DEFAULT_VERSION="1.1.9"

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
    local CID COMPOSE_FILE
    # FIX: prefer the container running the pasarguard/panel image — compose ps order
    # is not guaranteed and could return a DB/helper container first
    CID="$(docker ps --format '{{.ID}} {{.Image}}' 2>/dev/null | awk '$2 ~ /^pasarguard\/panel(:|$)/ {print $1; exit}')"
    [ -n "$CID" ] && { printf '%s\n' "$CID"; return 0; }
    COMPOSE_FILE="$(get_panel_compose_file 2>/dev/null)" || return 1
    docker compose -f "$COMPOSE_FILE" ps -q 2>/dev/null | head -1
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
    if [ -n "$MRM_FIRST_RUN" ] || [ ! -t 0 ]; then
        save_panel_config "pasarguard" 2>/dev/null || true
        apply_panel_config "pasarguard"
        return 0
    fi

    # Even in interactive, if no panels installed, default without prompt
    local PANELS
    PANELS=$(get_installed_panels)
    if [ -z "$PANELS" ]; then
        save_panel_config "pasarguard" 2>/dev/null || true
        apply_panel_config "pasarguard"
        return 0
    fi

    # If multiple panels and interactive, default to first found
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

get_mrm_version() {
    # FIX: -s (non-empty) instead of -f — an empty VERSION file must not print ""
    if [ -s "$MRM_VERSION_FILE" ]; then
        cat "$MRM_VERSION_FILE" 2>/dev/null | head -1
    else
        echo "$MRM_DEFAULT_VERSION"
    fi
}

# FIX: pin to the installed release tag — mutable "main" could serve untrusted content
export THEME_HTML_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/v$(get_mrm_version)/templates/subscription/index.html"

# Initialize - NON-BLOCKING, no prompt
load_panel_config >/dev/null 2>&1 || apply_panel_config "pasarguard" >/dev/null 2>&1 || true

pause() {
    echo ""
    read -p "Press Enter to continue..."
}

restart_service() {
    local SERVICE="$1" COMPOSE_FILE=""
    load_panel_config >/dev/null 2>&1 || true
    if [ "$SERVICE" == "panel" ]; then
        [ ! -d "$PANEL_DIR" ] && { echo -e "${RED}Panel not found at $PANEL_DIR${NC}"; return 1; }
        COMPOSE_FILE="$(get_panel_compose_file 2>/dev/null)"
        [ -z "$COMPOSE_FILE" ] && { echo -e "${RED}No compose file found${NC}"; return 1; }
        # FIX: restart only the panel service — down/up would also stop DB/helpers
        (cd "$PANEL_DIR" && docker compose restart pasarguard) && echo -e "${GREEN}Done.${NC}" || { echo -e "${RED}Failed${NC}"; return 1; }
    elif [ "$SERVICE" == "node" ]; then
        # PasarGuard nodes usually run on their own server and connect to the
        # panel over gRPC/rest. This only works when the node docker-compose
        # lives on THIS server — otherwise restart it on the node server.
        echo -e "${YELLOW}Note: this restarts the node only if it runs on this server (${NODE_DIR}).${NC}"
        echo -e "${YELLOW}If the node is on another server, restart it there (systemctl/docker).${NC}"
        [ ! -d "$NODE_DIR" ] && { echo -e "${RED}Node not found${NC}"; return 1; }
        COMPOSE_FILE="$(get_node_compose_file 2>/dev/null)"
        [ -z "$COMPOSE_FILE" ] && { echo -e "${RED}No compose file${NC}"; return 1; }
        (cd "$NODE_DIR" && docker compose restart) && echo -e "${GREEN}Done.${NC}" || { echo -e "${RED}Failed${NC}"; return 1; }
    else
        echo -e "${RED}Unknown service: $SERVICE${NC}" >&2
        return 1
    fi
}
