#!/bin/bash
# MRM Manager v1.0.0

# ============================================
# INTERACTIVE UI LIBRARY
# ============================================

# Colors
UI_RED='\033[0;31m'
UI_GREEN='\033[0;32m'
UI_YELLOW='\033[1;33m'
UI_BLUE='\033[0;34m'
UI_CYAN='\033[0;36m'
UI_NC='\033[0m'
UI_BOLD='\033[1m'
UI_DIM='\033[2m'

# Box drawing characters
UI_TL="╔"
UI_TR="╗"
UI_BL="╚"
UI_BR="╝"
UI_H="═"
UI_V="║"

# ============================================
# HEADER & BOX FUNCTIONS
# ============================================

ui_header() {
    local TITLE="$1"
    local WIDTH="${2:-50}"
    local MIN_WIDTH
    local PADDING
    local i

    MIN_WIDTH=$(( ${#TITLE} + 6 ))
    [ "$WIDTH" -lt "$MIN_WIDTH" ] && WIDTH="$MIN_WIDTH"
    [ "$WIDTH" -lt 40 ] && WIDTH=40

    clear

    # Top border
    echo -ne "${UI_CYAN}${UI_TL}"
    for ((i=0; i<WIDTH-2; i++)); do echo -ne "${UI_H}"; done
    echo -e "${UI_TR}${UI_NC}"

    # Title
    PADDING=$(( (WIDTH - 2 - ${#TITLE}) / 2 ))
    [ "$PADDING" -lt 0 ] && PADDING=0
    echo -ne "${UI_CYAN}${UI_V}${UI_NC}"
    for ((i=0; i<PADDING; i++)); do echo -ne " "; done
    echo -ne "${UI_YELLOW}${UI_BOLD}${TITLE}${UI_NC}"
    for ((i=0; i<WIDTH-2-PADDING-${#TITLE}; i++)); do echo -ne " "; done
    echo -e "${UI_CYAN}${UI_V}${UI_NC}"

    # Bottom border
    echo -ne "${UI_CYAN}${UI_BL}"
    for ((i=0; i<WIDTH-2; i++)); do echo -ne "${UI_H}"; done
    echo -e "${UI_BR}${UI_NC}"
    echo ""
}

ui_divider() {
    local WIDTH="${1:-46}"
    local i

    echo -ne "${UI_DIM}"
    for ((i=0; i<WIDTH; i++)); do echo -ne "─"; done
    echo -e "${UI_NC}"
}

ui_section() {
    local TITLE="$1"
    ui_divider 46
    echo -e "${UI_BLUE}${UI_BOLD}${TITLE}${UI_NC}"
    ui_divider 46
}

ui_kv() {
    local KEY="$1"
    local VALUE="$2"
    echo -e "${UI_DIM}${KEY}:${UI_NC} ${UI_CYAN}${VALUE}${UI_NC}"
}

# ============================================
# SPINNER
# ============================================

ui_spinner_start() {
    local MESSAGE="${1:-Loading...}"

    ui_spinner_stop
    (
        local SPIN='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        local i=0
        while true; do
            echo -ne "\r${UI_CYAN}${SPIN:$i:1}${UI_NC} $MESSAGE"
            i=$(( (i + 1) % 10 ))
            sleep 0.1
        done
    ) &
    SPINNER_PID=$!
}

ui_spinner_stop() {
    if [ -n "${SPINNER_PID:-}" ]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        unset SPINNER_PID
        echo -ne "\r\033[K"
    fi
}

ui_success() { echo -e "${UI_GREEN}✔ ${UI_NC}$1"; }
ui_error() { echo -e "${UI_RED}✘ ${UI_NC}$1"; }
ui_warning() { echo -e "${UI_YELLOW}⚠ ${UI_NC}$1"; }
ui_info() { echo -e "${UI_BLUE}ℹ ${UI_NC}$1"; }
