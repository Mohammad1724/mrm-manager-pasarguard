#!/bin/bash
# MRM Manager ui.sh v1.1.4

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

# Approximate terminal display width (East Asian Width): emoji/CJK/Hangul count
# as 2 columns — ${#VAR} counts characters, not terminal columns (MRM-030)
ui_text_width() {
    local STR="$1" C CODE W=0 i
    local LC_ALL=C.UTF-8
    for ((i=0; i<${#STR}; i++)); do
        C="${STR:$i:1}"
        CODE=$(printf '%d' "'${C}" 2>/dev/null || echo 0)
        CODE="${CODE:-0}"
        if { [ "$CODE" -ge 4352 ] && [ "$CODE" -le 4447 ]; } ||
           { [ "$CODE" -ge 9184 ] && [ "$CODE" -le 9215 ]; } ||
           { [ "$CODE" -ge 11904 ] && [ "$CODE" -le 42191 ]; } ||
           { [ "$CODE" -ge 44032 ] && [ "$CODE" -le 55203 ]; } ||
           { [ "$CODE" -ge 63744 ] && [ "$CODE" -le 64255 ]; } ||
           { [ "$CODE" -ge 65072 ] && [ "$CODE" -le 65103 ]; } ||
           { [ "$CODE" -ge 65280 ] && [ "$CODE" -le 65376 ]; } ||
           { [ "$CODE" -ge 65504 ] && [ "$CODE" -le 65510 ]; } ||
           { [ "$CODE" -ge 10128 ] && [ "$CODE" -le 10175 ]; } ||
           { [ "$CODE" -ge 126976 ] && [ "$CODE" -le 130303 ]; } ||
           { [ "$CODE" -ge 131072 ] && [ "$CODE" -le 262141 ]; }
        then
            W=$(( W + 2 ))
        else
            W=$(( W + 1 ))
        fi
    done
    echo "$W"
}

ui_header() {
    local TITLE="$1"
    local WIDTH="${2:-50}"
    local MIN_WIDTH
    local PADDING
    local WIDTH_TITLE
    local i

    WIDTH_TITLE="$(ui_text_width "$TITLE")"
    MIN_WIDTH=$(( WIDTH_TITLE + 6 ))
    [ "$WIDTH" -lt "$MIN_WIDTH" ] && WIDTH="$MIN_WIDTH"
    [ "$WIDTH" -lt 40 ] && WIDTH=40

    # FIX: only clear on a real terminal — avoids polluting logs/pipes in
    # non-TTY runs and avoids aborting set -e callers when clear is missing
    if [ -t 1 ]; then
        clear
    fi

    # Top border
    echo -ne "${UI_CYAN}${UI_TL}"
    for ((i=0; i<WIDTH-2; i++)); do echo -ne "${UI_H}"; done
    echo -e "${UI_TR}${UI_NC}"

    # Title (padded to the display width so the right border stays aligned)
    PADDING=$(( (WIDTH - 2 - WIDTH_TITLE) / 2 ))
    [ "$PADDING" -lt 0 ] && PADDING=0
    echo -ne "${UI_CYAN}${UI_V}${UI_NC}"
    for ((i=0; i<PADDING; i++)); do echo -ne " "; done
    echo -ne "${UI_YELLOW}${UI_BOLD}${TITLE}${UI_NC}"
    for ((i=0; i<WIDTH-2-PADDING-WIDTH_TITLE; i++)); do echo -ne " "; done
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
        # FIX: array elements are locale-independent (${SPIN:$i:1} sliced bytes
        # under LANG=C and printed broken UTF-8)
        local SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local i=0
        while true; do
            echo -ne "\r${UI_CYAN}${SPIN[$i]}${UI_NC} $MESSAGE"
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
