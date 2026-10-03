#!/bin/bash
# MRM Manager utils.sh — shared helpers (panel detection, compose, services)

# The palette and every UI helper live in ui.sh; load it first so any module
# that sources utils.sh gets the same look without extra work.
MRM_DIR="${MRM_DIR:-/opt/mrm-manager}"
if ! declare -f ui_header >/dev/null 2>&1; then
    _MRM_UI_CANDIDATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/ui.sh"
    if [ -r "$_MRM_UI_CANDIDATE" ]; then
        # shellcheck source=/dev/null
        source "$_MRM_UI_CANDIDATE"
    elif [ -r "$MRM_DIR/ui.sh" ]; then
        # shellcheck source=/dev/null
        source "$MRM_DIR/ui.sh"
    fi
    unset _MRM_UI_CANDIDATE
fi

CONFIG_FILE="/opt/mrm-manager/panel.conf"
MRM_VERSION_FILE="/opt/mrm-manager/VERSION"
MRM_DEFAULT_VERSION="1.5.9"

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

# "Installed" means a real checkout (directory + .env or compose file). A bare
# /opt/pasarguard left behind by an old install, or created by MRM on a
# node-only server, must never be reported as a stopped panel.
mrm_panel_installed() {
    [ -d "${PANEL_DIR:-}" ] || return 1
    [ -f "${PANEL_ENV:-$PANEL_DIR/.env}" ] && return 0
    get_panel_compose_file >/dev/null 2>&1
}
mrm_node_installed() {
    [ -n "${NODE_DIR:-}" ] && [ -d "$NODE_DIR" ] || return 1
    [ -f "${NODE_ENV:-$NODE_DIR/.env}" ] && return 0
    get_node_compose_file >/dev/null 2>&1
}
# panel | node | none — which service this server is responsible for
mrm_server_role() {
    if mrm_panel_installed; then echo panel
    elif mrm_node_installed; then echo node
    else echo none; fi
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
export THEME_CLASSIC_HTML_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/v$(get_mrm_version)/templates/subscription-classic/index.html"

# Initialize - NON-BLOCKING, no prompt
load_panel_config >/dev/null 2>&1 || apply_panel_config "pasarguard" >/dev/null 2>&1 || true

# pause / invalid_menu_option are provided by ui.sh (ui_pause / ui_invalid).
# Minimal stand-ins keep standalone runs working if ui.sh could not be loaded.
declare -f pause >/dev/null 2>&1 || pause() { echo ""; [ -t 0 ] && read -r -p "  Press Enter to continue… " _; echo ""; }
declare -f ui_error >/dev/null 2>&1 || ui_error() { echo "  ✘ $1" >&2; }
declare -f ui_success >/dev/null 2>&1 || ui_success() { echo "  ✔ $1"; }
declare -f ui_warning >/dev/null 2>&1 || ui_warning() { echo "  ⚠ $1"; }
declare -f ui_info >/dev/null 2>&1 || ui_info() { echo "  ℹ $1"; }
declare -f ui_note >/dev/null 2>&1 || ui_note() { echo "  $1"; }

restart_service() {
    local SERVICE="$1" COMPOSE_FILE=""
    load_panel_config >/dev/null 2>&1 || true
    if [ "$SERVICE" == "panel" ]; then
        [ ! -d "$PANEL_DIR" ] && { ui_error "Panel not found at $PANEL_DIR"; return 1; }
        COMPOSE_FILE="$(get_panel_compose_file 2>/dev/null)"
        [ -z "$COMPOSE_FILE" ] && { ui_error "No compose file found in $PANEL_DIR"; return 1; }
        ui_note "Restarting panel service…"
        # Restart only the panel service — down/up would also stop DB/helpers
        if (cd "$PANEL_DIR" && (docker compose restart panel 2>/dev/null || docker compose restart pasarguard 2>/dev/null || docker-compose restart panel 2>/dev/null || docker-compose restart pasarguard 2>/dev/null || docker compose restart 2>/dev/null || docker-compose restart 2>/dev/null)); then
            return 0
        fi
        ui_error "Panel restart failed"
        return 1
    elif [ "$SERVICE" == "node" ]; then
        # PasarGuard nodes usually run on their own server and connect to the
        # panel over gRPC/rest. This only works when the node docker-compose
        # lives on THIS server — otherwise restart it on the node server.
        ui_note "Only a node running on this server (${NODE_DIR}) can be restarted here."
        [ ! -d "$NODE_DIR" ] && { ui_error "Node not found at $NODE_DIR"; return 1; }
        COMPOSE_FILE="$(get_node_compose_file 2>/dev/null)"
        [ -z "$COMPOSE_FILE" ] && { ui_error "No compose file found in $NODE_DIR"; return 1; }
        ui_note "Restarting node…"
        if (cd "$NODE_DIR" && docker compose restart); then
            return 0
        fi
        ui_error "Node restart failed"
        return 1
    else
        ui_error "Unknown service: $SERVICE"
        return 1
    fi
}
