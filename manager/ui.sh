#!/bin/bash
# MRM Manager ui.sh — shared CLI design system
#
# Every menu, prompt, message, table and report in MRM Manager is rendered
# through the helpers in this file, so the whole tool has ONE visual language:
#
#   ┌─ MRM Manager ─────────────────────────────────────────── v1.5.4 ─┐
#   │ SSL Certificates                                                 │
#   │ Panel: pasarguard · Certs: /var/lib/pasarguard/certs             │
#   └──────────────────────────────────────────────────────────────────┘
#
#     Panel          ● Running
#     Telegram       ○ Not configured
#
#      1  Request new certificate
#      2  Renew expiring certificates
#
#      0  Back
#
#     › Select:
#
# Conventions
#   • glyphs only (no emoji): ● ○ ◐ ✔ ✘ ⚠ ℹ › • ─ │
#   • two-space left padding for every content line (UI_PAD)
#   • colours switch off automatically when stdout is not a terminal or
#     NO_COLOR is set — cron logs and pipes stay clean (MRM_COLOR=always forces)
#   • "0" is always Back/Exit; y/n questions always go through ui_confirm
#   • no forks on the hot path (header/menu redraws stay instant)
#
# This file is idempotent: sourcing it twice is safe.

[ -n "${_MRM_UI_LOADED:-}" ] && return 0 2>/dev/null
_MRM_UI_LOADED=1

# ─── Palette ────────────────────────────────────────────────────────────────
# Two layers:
#   1. Base ANSI attributes (RED, GREEN, …) — kept because modules use them.
#   2. Semantic roles (UI_C_*) — the helpers below only use these.
# On 256-colour terminals the roles come from a named palette, so the UI looks
# the same in Termius, Windows Terminal, iTerm, … regardless of the user's
# 16-colour theme. On 8/16-colour terminals the roles fall back to the base
# attributes ("classic").
#
#   MRM_PALETTE = amber (default) | slate | teal | classic
#   MRM_THEME   = dark (default) | light   (light keeps the terminal's own text colour)
#   MRM_COLORS  = 256 | 16                  (override colour-depth detection)
#   NO_COLOR, MRM_COLOR=never|always        (disable / force colours)
# 256-colour capable? `tput colors` is unreliable over SSH (Termius, PuTTY and
# Windows Terminal often announce TERM=xterm yet render 256 colours), so the
# terminal name / COLORTERM are trusted first. MRM_COLORS=16|256 overrides.
_ui_has_256() {
    case "${MRM_COLORS:-}" in 256) return 0 ;; 16|8) return 1 ;; esac
    case "${COLORTERM:-}" in truecolor|24bit) return 0 ;; esac
    case "${TERM:-}" in
        *256color*|*truecolor*|*direct*|xterm-kitty|alacritty|wezterm*|foot*) return 0 ;;
        dumb|linux|vt*|ansi|cons25|sun*) return 1 ;;
    esac
    [ "$(tput colors 2>/dev/null || echo 0)" -ge 256 ] 2>/dev/null && return 0
    case "${TERM:-}" in xterm*|screen*|tmux*|rxvt*|putty*|st|st-*|konsole*|gnome*|"") return 0 ;; esac
    return 1
}
_UI_256=0
if [ -n "${NO_COLOR:-}" ] || [ "${MRM_COLOR:-auto}" = "never" ] || { [ ! -t 1 ] && [ "${MRM_COLOR:-auto}" != "always" ]; }; then
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; PURPLE=''; ORANGE=''
    WHITE=''; BOLD=''; DIM=''; NC=''
else
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
    CYAN='\033[0;36m'; PURPLE='\033[0;35m'; ORANGE='\033[0;33m'; WHITE='\033[1;37m'
    BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
    _ui_has_256 && _UI_256=1
    # Several clients (Termius, older Windows terminals) ignore the DIM
    # attribute, which made hints/labels indistinguishable from values. On
    # 256-colour terminals use a fixed mid-grey instead.
    [ "$_UI_256" -eq 1 ] && DIM='\033[38;5;245m'
fi

# Semantic roles — classic mapping (8/16-colour terminals, or MRM_PALETTE=classic)
UI_C_FRAME="$CYAN"      # box borders and rules
UI_C_TITLE="$BOLD"      # page / section titles, table headers
UI_C_BRAND="$BOLD"      # "MRM Manager" in the header
UI_C_MUTED="$DIM"       # labels, hints, paths, secondary text
UI_C_ACCENT="$CYAN"     # menu numbers, prompt chevron, commands, steps
UI_C_TEXT=''            # values, menu labels, messages ('' = terminal default)
UI_C_OK="$GREEN"
UI_C_WARN="$YELLOW"
UI_C_ERR="$RED"
UI_C_INFO="$BLUE"

MRM_PALETTE="${MRM_PALETTE:-amber}"
if [ "$_UI_256" -eq 1 ] && [ "$MRM_PALETTE" != "classic" ]; then
    # xterm-256 indexes:  frame accent ok  warn err muted title text
    case "$MRM_PALETTE" in
        slate) _UI_P=(240 75  78  214 203 245 255 252) ;;
        teal)  _UI_P=(66  80  114 221 174 245 255 252) ;;
        *)     _UI_P=(238 179 108 215 174 244 254 250) ;;   # amber
    esac
    UI_C_FRAME="\033[38;5;${_UI_P[0]}m"
    UI_C_ACCENT="\033[38;5;${_UI_P[1]}m"; UI_C_INFO="$UI_C_ACCENT"
    UI_C_BRAND="\033[1;38;5;${_UI_P[1]}m"
    UI_C_OK="\033[38;5;${_UI_P[2]}m"
    UI_C_WARN="\033[38;5;${_UI_P[3]}m"
    UI_C_ERR="\033[38;5;${_UI_P[4]}m"
    UI_C_MUTED="\033[38;5;${_UI_P[5]}m"
    UI_C_TITLE="\033[1;38;5;${_UI_P[6]}m"
    UI_C_TEXT="\033[38;5;${_UI_P[7]}m"
    if [ "${MRM_THEME:-dark}" = "light" ]; then UI_C_TEXT=''; UI_C_TITLE="$BOLD"; fi
    # Legacy names follow the palette too, so the few direct uses stay consistent.
    RED="$UI_C_ERR"; GREEN="$UI_C_OK"; YELLOW="$UI_C_WARN"; BLUE="$UI_C_INFO"
    CYAN="$UI_C_ACCENT"; DIM="$UI_C_MUTED"
    unset _UI_P
fi
export RED GREEN YELLOW BLUE CYAN PURPLE ORANGE WHITE BOLD DIM NC

UI_RED="$RED"; UI_GREEN="$GREEN"; UI_YELLOW="$YELLOW"; UI_BLUE="$BLUE"
UI_CYAN="$CYAN"; UI_NC="$NC"; UI_BOLD="$BOLD"; UI_DIM="$DIM"

# ─── Glyphs ─────────────────────────────────────────────────────────────────
UI_G_OK="✔"; UI_G_ERR="✘"; UI_G_WARN="⚠"; UI_G_INFO="ℹ"
UI_G_ON="●"; UI_G_OFF="○"; UI_G_HALF="◐"; UI_G_PROMPT="›"; UI_G_BULLET="•"
UI_H="─"; UI_V="│"; UI_TL="┌"; UI_TR="┐"; UI_BL="└"; UI_BR="┘"

UI_PAD="  "
UI_BRAND="MRM Manager"
UI_MIN_WIDTH=44
UI_MAX_WIDTH=72
UI_KV_WIDTH="${UI_KV_WIDTH:-14}"

# ─── Geometry helpers (fork-free) ───────────────────────────────────────────

# Frame width: follows the terminal, clamped to a readable range.
ui_width() {
    local cols="${COLUMNS:-}"
    if [ -z "$cols" ] || ! [[ "$cols" =~ ^[0-9]+$ ]]; then
        cols="$(tput cols 2>/dev/null || echo 80)"
    fi
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
    [ "$cols" -gt "$UI_MAX_WIDTH" ] && cols="$UI_MAX_WIDTH"
    [ "$cols" -lt "$UI_MIN_WIDTH" ] && cols="$UI_MIN_WIDTH"
    echo "$cols"
}

# ui_repeat STR N  — repeat a (possibly multi-byte) string N times
ui_repeat() {
    local STR="$1" N="${2:-0}" OUT="" i
    [ "$N" -gt 0 ] 2>/dev/null || return 0
    for ((i=0; i<N; i++)); do OUT+="$STR"; done
    printf '%s' "$OUT"
}

# _ui_plain OUTVAR STR  — STR without ANSI codes (both real ESC and literal \033)
_ui_plain() {
    local __pl_s="$2"
    while [[ "$__pl_s" =~ ($'\e'|\\033)\[[0-9\;]*[A-Za-z] ]]; do
        __pl_s="${__pl_s/"${BASH_REMATCH[0]}"/}"
    done
    printf -v "$1" '%s' "$__pl_s"
}
ui_strip_ansi() { local __P; _ui_plain __P "$1"; printf '%s' "$__P"; }

# _ui_w OUTVAR STR  — display width in terminal columns.
# ASCII fast path; otherwise East-Asian-Width aware (CJK/emoji = 2 columns,
# ZWNJ/ZWJ/combining marks = 0) — ${#VAR} counts characters, not columns.
_ui_w() {
    local __w_s; _ui_plain __w_s "$2"
    local LC_ALL=C.UTF-8
    local __w_chars=${#__w_s}
    LC_ALL=C
    local __w_bytes=${#__w_s}
    LC_ALL=C.UTF-8
    if [ "$__w_chars" -eq "$__w_bytes" ]; then
        printf -v "$1" '%s' "$__w_chars"
        return 0
    fi
    local __w_c CODE __w_n=0 __w_i
    for ((__w_i=0; __w_i<__w_chars; __w_i++)); do
        __w_c="${__w_s:$__w_i:1}"
        printf -v CODE '%d' "'${__w_c}" 2>/dev/null || CODE=0
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
            __w_n=$(( __w_n + 2 ))
        elif [ "$CODE" -eq 8204 ] || [ "$CODE" -eq 8205 ] || { [ "$CODE" -ge 768 ] && [ "$CODE" -le 879 ]; }; then
            : # zero-width
        else
            __w_n=$(( __w_n + 1 ))
        fi
    done
    printf -v "$1" '%s' "$__w_n"
}
ui_text_width() { local __W; _ui_w __W "$1"; echo "$__W"; }

# ui_truncate STR MAX  — cut a plain string to MAX columns with an ellipsis
ui_truncate() {
    local STR="$1" MAX="$2" W
    _ui_w W "$STR"
    if [ "$W" -le "$MAX" ]; then
        printf '%s' "$STR"
        return 0
    fi
    local OUT="" i C
    for ((i=0; i<${#STR}; i++)); do
        C="${STR:$i:1}"
        _ui_w W "${OUT}${C}"
        [ "$W" -ge "$MAX" ] && break
        OUT+="$C"
    done
    printf '%s…' "$OUT"
}

# ui_version — MRM version for the header (env → versions.conf → VERSION file)
ui_version() {
    local V="${MRM_VERSION:-}"
    if [ -z "$V" ] && [ -r /opt/mrm-manager/versions.conf ]; then
        V="$(grep -E '^MRM_VERSION=' /opt/mrm-manager/versions.conf 2>/dev/null | head -1 | cut -d'"' -f2)"
    fi
    if [ -z "$V" ] && [ -s /opt/mrm-manager/VERSION ]; then
        V="$(head -1 /opt/mrm-manager/VERSION 2>/dev/null)"
    fi
    echo "${V:-1.5.4}"
}

# ─── Screen & header ────────────────────────────────────────────────────────

ui_clear() { [ -t 1 ] && clear; return 0; }
ui_blank() { echo ""; }

# _ui_box_row TEXT WIDTH [STYLE] — one framed row: │ text···· │
_ui_box_row() {
    local TEXT="$1" WIDTH="$2" STYLE="${3:-}" INNER W PLAIN
    INNER=$(( WIDTH - 4 ))
    _ui_plain PLAIN "$TEXT"
    _ui_w W "$PLAIN"
    if [ "$W" -gt "$INNER" ]; then
        TEXT="$(ui_truncate "$PLAIN" "$INNER")"
        _ui_w W "$TEXT"
    fi
    printf '%b%s%b %b%b%b%s %b%s%b\n' \
        "$UI_C_FRAME" "$UI_V" "$NC" \
        "$STYLE" "$TEXT" "$NC" "$(ui_repeat ' ' $(( INNER - W )))" \
        "$UI_C_FRAME" "$UI_V" "$NC"
}

# ui_header "Page title" ["context line"]
# Clears the screen on a real terminal and draws the branded frame.
ui_header() {
    local TITLE="$1" SUBTITLE="${2:-}" WIDTH FILL
    WIDTH="$(ui_width)"
    local BRAND=" ${UI_BRAND} " VER=" v$(ui_version) "
    FILL=$(( WIDTH - 4 - ${#BRAND} - ${#VER} ))
    [ "$FILL" -lt 1 ] && FILL=1

    ui_clear
    printf '%b%s%s%b%b%s%b%b%s%b%b%s%b%b%s%s%b\n' \
        "$UI_C_FRAME" "$UI_TL" "$UI_H" "$NC" \
        "$UI_C_BRAND" "$BRAND" "$NC" \
        "$UI_C_FRAME" "$(ui_repeat "$UI_H" "$FILL")" "$NC" \
        "$UI_C_MUTED" "$VER" "$NC" \
        "$UI_C_FRAME" "$UI_H" "$UI_TR" "$NC"
    _ui_box_row "$TITLE" "$WIDTH" "$UI_C_TITLE"
    [ -n "$SUBTITLE" ] && _ui_box_row "$SUBTITLE" "$WIDTH" "$UI_C_MUTED"
    printf '%b%s%s%s%b\n' "$UI_C_FRAME" "$UI_BL" "$(ui_repeat "$UI_H" $(( WIDTH - 2 )))" "$UI_BR" "$NC"
    echo ""
}

# ui_divider [width] — dim horizontal rule
ui_divider() {
    local WIDTH="${1:-$(ui_width)}"
    printf '%b%s%b\n' "$UI_C_MUTED" "$(ui_repeat "$UI_H" "$WIDTH")" "$NC"
}

# ui_section "Title" —   ── Title ───────────────
ui_section() {
    local TITLE="$1" WIDTH LEN FILL
    WIDTH="$(ui_width)"
    _ui_w LEN "$TITLE"
    FILL=$(( WIDTH - LEN - 6 ))
    [ "$FILL" -lt 2 ] && FILL=2
    printf '%s%b%s%b %b%s%b %b%s%b\n' \
        "$UI_PAD" "$UI_C_FRAME" "${UI_H}${UI_H}" "$NC" \
        "$UI_C_TITLE" "$TITLE" "$NC" \
        "$UI_C_FRAME" "$(ui_repeat "$UI_H" "$FILL")" "$NC"
}

# ui_kv "Key" "Value" ["hint"] — aligned key/value line (value may contain
# colours); the optional hint is appended in muted colour.
ui_kv() {
    if [ -n "${3:-}" ]; then
        printf '%s%b%-*s%b %b%b%b %b— %s%b\n' "$UI_PAD" "$UI_C_MUTED" "$UI_KV_WIDTH" "$1" "$NC" "$UI_C_TEXT" "$2" "$NC" "$UI_C_MUTED" "$3" "$NC"
    else
        printf '%s%b%-*s%b %b%b%b\n' "$UI_PAD" "$UI_C_MUTED" "$UI_KV_WIDTH" "$1" "$NC" "$UI_C_TEXT" "$2" "$NC"
    fi
}

# ui_state ok|warn|bad|off "text" — coloured status dot + text (no newline)
ui_state() {
    local MODE="$1" TEXT="$2"
    case "$MODE" in
        ok)   printf '%b%s %s%b' "$UI_C_OK"   "$UI_G_ON"   "$TEXT" "$NC" ;;
        warn) printf '%b%s %s%b' "$UI_C_WARN" "$UI_G_HALF" "$TEXT" "$NC" ;;
        bad)  printf '%b%s %s%b' "$UI_C_ERR"  "$UI_G_OFF"  "$TEXT" "$NC" ;;
        *)    printf '%b%s %s%b' "$UI_C_MUTED" "$UI_G_OFF" "$TEXT" "$NC" ;;
    esac
}

# ui_kv_state "Key" ok|warn|bad|off "text" ["extra dim text"]
ui_kv_state() {
    local VAL; VAL="$(ui_state "$2" "$3")"
    [ -n "${4:-}" ] && VAL+=" $(printf '%b— %s%b' "$UI_C_MUTED" "$4" "$NC")"
    ui_kv "$1" "$VAL"
}

# ─── Messages ───────────────────────────────────────────────────────────────

ui_success() { printf '%s%b%s%b %b%b%b\n' "$UI_PAD" "$UI_C_OK"   "$UI_G_OK"   "$NC" "$UI_C_TEXT" "$1" "$NC"; }
ui_error()   { printf '%s%b%s%b %b%b%b\n' "$UI_PAD" "$UI_C_ERR"  "$UI_G_ERR"  "$NC" "$UI_C_TEXT" "$1" "$NC" >&2; }
ui_warning() { printf '%s%b%s%b %b%b%b\n' "$UI_PAD" "$UI_C_WARN" "$UI_G_WARN" "$NC" "$UI_C_TEXT" "$1" "$NC"; }
ui_info()    { printf '%s%b%s%b %b%b%b\n' "$UI_PAD" "$UI_C_INFO" "$UI_G_INFO" "$NC" "$UI_C_TEXT" "$1" "$NC"; }
ui_note()    { printf '%s%b%b%b\n'        "$UI_PAD" "$UI_C_MUTED" "$1" "$NC"; }
ui_text()    { printf '%s%b%b%b\n'        "$UI_PAD" "$UI_C_TEXT" "$1" "$NC"; }
ui_bullet()  { printf '%s%b%s%b %b%b%b\n' "$UI_PAD" "$UI_C_ACCENT" "$UI_G_BULLET" "$NC" "$UI_C_TEXT" "$1" "$NC"; }
# ui_cmd "command" ["comment"] —   $ command   — comment
ui_cmd() {
    if [ -n "${2:-}" ]; then
        printf '%s%b$ %b%s%b   %b— %s%b\n' "$UI_PAD" "$UI_C_MUTED" "$UI_C_ACCENT" "$1" "$NC" "$UI_C_MUTED" "$2" "$NC"
    else
        printf '%s%b$ %b%s%b\n' "$UI_PAD" "$UI_C_MUTED" "$UI_C_ACCENT" "$1" "$NC"
    fi
}

# ui_step N TOTAL "text" —   [2/5] text
ui_step() {
    printf '%s%b[%s/%s]%b %b%s%b\n' "$UI_PAD" "$UI_C_ACCENT" "$1" "$2" "$NC" "$BOLD$UI_C_TEXT" "$3" "$NC"
}

# ui_result ok|warn|info|bad "text" — message with the glyph chosen by status
ui_result() {
    case "$1" in
        ok|0)  ui_success "$2" ;;
        warn)  ui_warning "$2" ;;
        info)  ui_info "$2" ;;
        *)     ui_error "$2" ;;
    esac
}

# ─── Inline tasks ───────────────────────────────────────────────────────────
# ui_task "Renewing example.com"   →   "  › Renewing example.com … " (line stays open)
# ui_task_note "text"              →   closes the line if open, prints an indented note
# ui_task_done ok|warn|bad ["text"]→   "✔ text" on the open line, or a full result line
UI_TASK_OPEN=0
ui_task() {
    printf '%s%b%s%b %b%s%b %b…%b ' "$UI_PAD" "$UI_C_ACCENT" "$UI_G_PROMPT" "$NC" "$UI_C_TEXT" "$1" "$NC" "$UI_C_MUTED" "$NC"
    UI_TASK_OPEN=1
}
ui_task_note() {
    [ "$UI_TASK_OPEN" = 1 ] && echo ""
    UI_TASK_OPEN=0
    printf '%s  %b%s%b\n' "$UI_PAD" "$UI_C_MUTED" "$1" "$NC"
}
ui_task_done() {
    local MODE="$1" TEXT="${2:-}" C G
    case "$MODE" in
        ok|0)  C="$UI_C_OK";   G="$UI_G_OK" ;;
        warn)  C="$UI_C_WARN"; G="$UI_G_WARN" ;;
        *)     C="$UI_C_ERR";  G="$UI_G_ERR" ;;
    esac
    if [ "$UI_TASK_OPEN" = 1 ]; then
        printf '%b%s%b' "$C" "$G" "$NC"
        [ -n "$TEXT" ] && printf ' %b%s%b' "$UI_C_MUTED" "$TEXT" "$NC"
        echo ""
    else
        ui_result "$MODE" "${TEXT:-done}"
    fi
    UI_TASK_OPEN=0
}

# ─── Menus ──────────────────────────────────────────────────────────────────

# ui_menu_item N "Label" ["hint"]
ui_menu_item() {
    if [ -n "${3:-}" ]; then
        printf '%s%b%2s%b  %b%s%b %b— %s%b\n' "$UI_PAD" "$UI_C_ACCENT$BOLD" "$1" "$NC" "$UI_C_TEXT" "$2" "$NC" "$UI_C_MUTED" "$3" "$NC"
    else
        printf '%s%b%2s%b  %b%s%b\n' "$UI_PAD" "$UI_C_ACCENT$BOLD" "$1" "$NC" "$UI_C_TEXT" "$2" "$NC"
    fi
}

# ui_menu_back ["Exit"] — the standard "0  Back" line (brings its own spacing)
ui_menu_back() {
    echo ""
    printf '%s%b%2s%b  %b%s%b\n' "$UI_PAD" "$BOLD$UI_C_TEXT" "0" "$NC" "$UI_C_MUTED" "${1:-Back}" "$NC"
    echo ""
}

# ui_menu_title "Group" — dim label above a group of items
ui_menu_title() { printf '%s%b%s%b\n' "$UI_PAD" "$UI_C_MUTED" "$1" "$NC"; }

# ─── Prompts ────────────────────────────────────────────────────────────────

_ui_prompt() {
    # $1 label, $2 optional default shown in brackets
    if [ -n "${2:-}" ]; then
        printf '%s%b%s%b %b%s%b %b[%s]%b%b:%b ' "$UI_PAD" "$UI_C_ACCENT$BOLD" "$UI_G_PROMPT" "$NC" "$UI_C_TEXT" "$1" "$NC" "$UI_C_MUTED" "$2" "$NC" "$UI_C_TEXT" "$NC"
    else
        printf '%s%b%s%b %b%s:%b ' "$UI_PAD" "$UI_C_ACCENT$BOLD" "$UI_G_PROMPT" "$NC" "$UI_C_TEXT" "$1" "$NC"
    fi
}

# ui_ask VAR "Label" ["default"] — read a line into VAR (default when empty)
ui_ask() {
    local __VAR="$1" __INPUT
    _ui_prompt "$2" "${3:-}"
    IFS= read -r __INPUT || __INPUT=""
    [ -z "$__INPUT" ] && __INPUT="${3:-}"
    printf -v "$__VAR" '%s' "$__INPUT"
}

# ui_ask_secret VAR "Label" — same, without echo (tokens, passwords)
ui_ask_secret() {
    local __VAR="$1" __INPUT
    _ui_prompt "$2" ""
    IFS= read -r -s __INPUT || __INPUT=""
    echo ""
    printf -v "$__VAR" '%s' "$__INPUT"
}

# ui_select VAR — the standard menu prompt
ui_select() { ui_ask "$1" "Select"; }

# ui_confirm "Question?" [y|n] — returns 0 for yes; default answer is "n"
ui_confirm() {
    local Q="$1" DEF="${2:-n}" HINT ANS
    case "$DEF" in
        y|Y) HINT="Y/n"; DEF="y" ;;
        *)   HINT="y/N"; DEF="n" ;;
    esac
    printf '%s%b%s%b %b%s%b %b[%s]%b ' "$UI_PAD" "$UI_C_ACCENT$BOLD" "$UI_G_PROMPT" "$NC" "$UI_C_TEXT" "$Q" "$NC" "$UI_C_MUTED" "$HINT" "$NC"
    IFS= read -r ANS || ANS=""
    [ -z "$ANS" ] && ANS="$DEF"
    [[ "$ANS" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

# ui_confirm_word "WORD" "Question" — destructive actions: the word must be typed
ui_confirm_word() {
    local WORD="$1" ANS
    printf '%s%b%s%b %b%s%b %b(type %s to confirm)%b%b:%b ' "$UI_PAD" "$UI_C_ACCENT$BOLD" "$UI_G_PROMPT" "$NC" "$UI_C_TEXT" "$2" "$NC" "$UI_C_MUTED" "$WORD" "$NC" "$UI_C_TEXT" "$NC"
    IFS= read -r ANS || ANS=""
    [ "$ANS" = "$WORD" ]
}

# ui_pause — "Press Enter to continue…" (skipped when stdin is not a terminal)
ui_pause() {
    echo ""
    [ -t 0 ] || return 0
    printf '%s%bPress Enter to continue…%b' "$UI_PAD" "$UI_C_MUTED" "$NC"
    IFS= read -r _ || true
    echo ""
}

# ui_invalid — standard reaction to an unknown menu choice
ui_invalid() { ui_error "Invalid option"; sleep 1; }

# ui_cancelled — standard "nothing was changed" line
ui_cancelled() { ui_note "Cancelled — nothing was changed."; }

# ─── Tables ─────────────────────────────────────────────────────────────────
#   ui_table_header "%-3s  %-10s  %-40s  %s" "ID" "Type" "Filename" "Date"
#   ui_table_row    "1" "FULL" "backup.tar.gz" "2026-09-26"
_UI_TABLE_FMT=""
ui_table_header() {
    _UI_TABLE_FMT="$1"; shift
    local LINE W
    # shellcheck disable=SC2059
    printf -v LINE "$_UI_TABLE_FMT" "$@"
    _ui_w W "$LINE"
    printf '%s%b%s%b\n' "$UI_PAD" "$UI_C_TITLE" "$LINE" "$NC"
    printf '%s%b%s%b\n' "$UI_PAD" "$UI_C_MUTED" "$(ui_repeat "$UI_H" "$W")" "$NC"
}
ui_table_row() {
    # shellcheck disable=SC2059
    printf "${UI_PAD}${UI_C_TEXT}${_UI_TABLE_FMT}${NC}\n" "$@"
}

# ─── Summary box (end of long operations) ───────────────────────────────────
#   ui_box_start ok "Backup completed"
#   ui_box_line "File" "backup.tar.gz"
#   ui_box_end
_UI_BOX_COLOR=""
ui_box_start() {
    local MODE="$1" TITLE="$2" GLYPH WIDTH LABEL W FILL
    case "$MODE" in
        ok)   _UI_BOX_COLOR="$UI_C_OK";    GLYPH="$UI_G_OK" ;;
        bad)  _UI_BOX_COLOR="$UI_C_ERR";   GLYPH="$UI_G_ERR" ;;
        warn) _UI_BOX_COLOR="$UI_C_WARN";  GLYPH="$UI_G_WARN" ;;
        *)    _UI_BOX_COLOR="$UI_C_FRAME"; GLYPH="$UI_G_INFO" ;;
    esac
    WIDTH="$(ui_width)"
    LABEL=" ${GLYPH} ${TITLE} "
    _ui_w W "$LABEL"
    FILL=$(( WIDTH - 3 - W ))
    [ "$FILL" -lt 1 ] && FILL=1
    echo ""
    printf '%b%s%s%b%b%s%b%b%s%s%b\n' \
        "$_UI_BOX_COLOR" "$UI_TL" "$UI_H" "$NC" \
        "$BOLD$_UI_BOX_COLOR" "$LABEL" "$NC" \
        "$_UI_BOX_COLOR" "$(ui_repeat "$UI_H" "$FILL")" "$UI_TR" "$NC"
}
ui_box_line() {
    local KEY="$1" VALUE="${2:-}" WIDTH TEXT PLAIN W FILL
    WIDTH="$(ui_width)"
    if [ -n "$VALUE" ]; then
        printf -v TEXT '%b%-*s%b %b%b%b' "$UI_C_MUTED" "$UI_KV_WIDTH" "$KEY" "$NC" "$UI_C_TEXT" "$VALUE" "$NC"
    else
        printf -v TEXT '%b%b%b' "$UI_C_TEXT" "$KEY" "$NC"
    fi
    _ui_plain PLAIN "$TEXT"
    _ui_w W "$PLAIN"
    FILL=$(( WIDTH - 4 - W ))
    if [ "$FILL" -lt 0 ] && [ -n "$VALUE" ]; then
        # Long values (paths, file names) are shortened so the box frame stays intact
        local MAXV=$(( WIDTH - 4 - UI_KV_WIDTH - 1 ))
        [ "$MAXV" -lt 8 ] && MAXV=8
        printf -v TEXT '%b%-*s%b %b%b%b' "$UI_C_MUTED" "$UI_KV_WIDTH" "$KEY" "$NC" "$UI_C_TEXT" "$(ui_truncate "$VALUE" "$MAXV")" "$NC"
        _ui_plain PLAIN "$TEXT"
        _ui_w W "$PLAIN"
        FILL=$(( WIDTH - 4 - W ))
    fi
    [ "$FILL" -lt 0 ] && FILL=0
    printf '%b%s%b %b%s %b%s%b\n' "$_UI_BOX_COLOR" "$UI_V" "$NC" "$TEXT" "$(ui_repeat ' ' "$FILL")" "$_UI_BOX_COLOR" "$UI_V" "$NC"
}
ui_box_end() {
    local WIDTH; WIDTH="$(ui_width)"
    printf '%b%s%s%s%b\n' "$_UI_BOX_COLOR" "$UI_BL" "$(ui_repeat "$UI_H" $(( WIDTH - 2 )))" "$UI_BR" "$NC"
    echo ""
}

# ─── Spinner ────────────────────────────────────────────────────────────────

ui_spinner_start() {
    local MESSAGE="${1:-Working…}"
    ui_spinner_stop
    [ -t 1 ] || { printf '%s%s\n' "$UI_PAD" "$MESSAGE"; return 0; }
    (
        local SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local i=0
        while true; do
            printf '\r%s%b%s%b %s' "$UI_PAD" "$UI_C_ACCENT" "${SPIN[$i]}" "$NC" "$MESSAGE"
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
        [ -t 1 ] && printf '\r\033[K'
    fi
    return 0
}

# ─── Compatibility shims ────────────────────────────────────────────────────
# Older call sites use these names; they map onto the standard helpers.
pause() { ui_pause; }
invalid_menu_option() { ui_invalid; }
