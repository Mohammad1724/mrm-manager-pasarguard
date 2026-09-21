#!/bin/bash
# MRM Manager Theme

# utils.sh must load whenever its functions are missing — a parent process may
# export PANEL_DIR while bash functions do not cross the process boundary
# (standalone runs from install/update used to hit "command not found").
if ! declare -f detect_active_panel >/dev/null 2>&1; then
    for _mrm_utils in /opt/mrm-manager/utils.sh "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/utils.sh"; do
        [ -r "${_mrm_utils}" ] && { source "${_mrm_utils}"; break; }
    done
    unset _mrm_utils
fi
if ! declare -f ui_header >/dev/null 2>&1 && [ -r /opt/mrm-manager/ui.sh ]; then source /opt/mrm-manager/ui.sh; fi
if ! declare -f mrm_create_restore_point >/dev/null 2>&1 && [ -r /opt/mrm-manager/safe_ops.sh ]; then source /opt/mrm-manager/safe_ops.sh; fi
[ -r "/opt/mrm-manager/versions.conf" ] && source /opt/mrm-manager/versions.conf
THEME_VERSION="${THEME_VERSION:-2.2.1}"

# ✅ اطمینان از تشخیص پنل و تنظیم DATA_DIR
detect_active_panel > /dev/null

theme_get_local_template() {
    local CANDIDATE

    for CANDIDATE in \
        "./index.html" \
        "./templates/subscription/index.html" \
        "/opt/mrm-manager/index.html" \
        "/opt/mrm-manager/templates/subscription/index.html"
    do
        if [ -f "$CANDIDATE" ]; then
            printf '%s\n' "$CANDIDATE"
            return 0
        fi
    done

    return 1
}

theme_get_local_classic_template() {
    local CANDIDATE
    for CANDIDATE in \
        "./templates/subscription-classic/index.html" \
        "/opt/mrm-manager/templates/subscription-classic/index.html"
    do
        if [ -f "$CANDIDATE" ]; then
            printf '%s\n' "$CANDIDATE"
            return 0
        fi
    done
    return 1
}

theme_mrm_data_dir() {
    printf '%s\n' "${MRM_DATA_DIR:-/var/lib/pasarguard/mrm}"
}

theme_write_template_status() {
    # $1=state (running|success|failed)  $2=active (classic|special|empty)  $3=message
    local dir
    dir="$(theme_mrm_data_dir)"
    mkdir -p "$dir" 2>/dev/null
    python3 - "$dir/template-status.json" "${1:-}" "${2:-}" "${3:-}" <<'PY'
import json, sys
from datetime import datetime, timezone
from pathlib import Path
p = Path(sys.argv[1]); state = sys.argv[2]; active = sys.argv[3]; message = sys.argv[4]
try:
    old = json.loads(p.read_text(encoding='utf-8'))
except Exception:
    old = {}
now = datetime.now(timezone.utc).isoformat()
payload = {
    'status': state,
    'active': active or old.get('active'),
    'message': message,
    'started_at': old.get('started_at') or now,
    'finished_at': now if state != 'running' else None,
}
tmp = p.with_suffix('.json.tmp')
tmp.write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')
try:
    tmp.chmod(0o600)
except OSError:
    pass
tmp.replace(p)
PY
}

theme_template_display_name() {
    case "$1" in
        classic) echo "نسخه قدیمی تم" ;;
        special) echo "MRM Special" ;;
        *) echo "—" ;;
    esac
}

theme_current_template() {
    # Prints: classic | special | none
    local rel="" dir st
    rel="$(grep -E "^[[:space:]]*SUBSCRIPTION_PAGE_TEMPLATE[[:space:]]*=" "$PANEL_ENV" 2>/dev/null | tail -1 | cut -d'"' -f2)"
    case "$rel" in
        subscription-classic/*) echo "classic"; return 0 ;;
        subscription/*) echo "special"; return 0 ;;
    esac
    dir="$(theme_mrm_data_dir)"
    st="$(python3 -c "import json;print(json.load(open('$dir/template-status.json')).get('active') or '')" 2>/dev/null || true)"
    case "$st" in
        classic|special) echo "$st"; return 0 ;;
    esac
    if [ -s "$DATA_DIR/templates/subscription/index.html" ]; then echo "special"; return 0; fi
    if [ -s "$DATA_DIR/templates/subscription-classic/index.html" ]; then echo "classic"; return 0; fi
    echo "none"
}

theme_set_template() {
    # $1 = classic | special  — switch the active subscription template
    local key="${1:-}" rel
    case "$key" in
        classic) rel="subscription-classic/index.html" ;;
        special) rel="subscription/index.html" ;;
        *) echo "unknown template '$key' (use: classic | special)"; return 1 ;;
    esac
    detect_active_panel > /dev/null
    if [ ! -s "$DATA_DIR/templates/$rel" ]; then
        theme_write_template_status failed "$key" "Template file missing: templates/$rel"
        echo "Template file missing: $DATA_DIR/templates/$rel"
        return 1
    fi
    theme_write_template_status running "$key" "Switching subscription template to $key"
    if ! theme_apply_env "$rel"; then
        theme_write_template_status failed "$key" "Failed to update panel environment"
        return 1
    fi
    theme_restart_panel || true
    theme_write_template_status success "$key" "Template switched to $key"
    echo "✔ Active template: $(theme_template_display_name "$key") ($rel)"
    return 0
}

theme_apply_env() {
    local TPL_REL="${1:-subscription/index.html}"
    [ -f "$PANEL_ENV" ] || touch "$PANEL_ENV" 2>/dev/null || return 1
    sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$PANEL_ENV" || return 1
    sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$PANEL_ENV" || return 1
    echo "CUSTOM_TEMPLATES_DIRECTORY=\"$DATA_DIR/templates/\"" >> "$PANEL_ENV" || return 1
    echo "SUBSCRIPTION_PAGE_TEMPLATE=\"$TPL_REL\"" >> "$PANEL_ENV" || return 1
    return 0
}

theme_clear_env() {
    if [ -f "$PANEL_ENV" ]; then
        sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$PANEL_ENV" || return 1
        sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$PANEL_ENV" || return 1
    fi
    return 0
}

theme_restart_panel() {
    detect_active_panel > /dev/null

    if declare -f restart_service >/dev/null 2>&1; then
        restart_service "panel" >/dev/null 2>&1
        return $?
    fi

    if [ -d "$PANEL_DIR" ] && command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        (cd "$PANEL_DIR" && docker compose down && docker compose up -d)
        return $?
    fi

    return 1
}

theme_invalid_option() {
    if declare -f ui_error >/dev/null 2>&1; then
        ui_error "Invalid option"
    else
        echo -e "${RED}Invalid option${NC}"
    fi
    sleep 1
}

# ==========================================
# 1. INSTALL / UPDATE
# ==========================================
install_theme_wizard() {
    local TEMPLATE_FILE
    local TEMPLATE_DIR
    local TMP_DIR
    local OLD_FILE
    local TEMP_DL
    local PY_SCRIPT
    local LOCAL_TEMPLATE
    local FILE_SIZE
    local PY_EXIT_CODE
    local CLASSIC_FILE
    local CLASSIC_DL
    local CLASSIC_LOCAL

    clear
    echo -e "${CYAN}=============================================${NC}"
    echo -e "${YELLOW}      THEME INSTALLATION WIZARD              ${NC}"
    echo -e "${CYAN}=============================================${NC}"

    # ✅ تشخیص مجدد پنل برای اطمینان
    detect_active_panel > /dev/null

    if ! command -v python3 &> /dev/null; then
        echo -e "${RED}Python3 is required but not installed.${NC}"
        pause; return
    fi

    # ✅ بررسی DATA_DIR
    if [ -z "$DATA_DIR" ]; then
        echo -e "${RED}ERROR: DATA_DIR is not set!${NC}"
        pause; return
    fi

    TMP_DIR=$(mktemp -d /tmp/mrm-theme.XXXXXX 2>/dev/null)
    if [ -z "$TMP_DIR" ] || [ ! -d "$TMP_DIR" ]; then
        echo -e "${RED}Failed to create temporary workspace.${NC}"
        pause; return
    fi

    TEMPLATE_FILE="$DATA_DIR/templates/subscription/index.html"
    CLASSIC_FILE="$DATA_DIR/templates/subscription-classic/index.html"
    CLASSIC_DL="$TMP_DIR/classic_dl.html"
    TEMPLATE_DIR=$(dirname "$TEMPLATE_FILE")
    OLD_FILE="$TMP_DIR/index_old.html"
    TEMP_DL="$TMP_DIR/index_dl.html"
    PY_SCRIPT="$TMP_DIR/mrm_theme_logic.py"

    if declare -f mrm_create_restore_point >/dev/null 2>&1; then
        local RESTORE_POINT_ID
        RESTORE_POINT_ID="$(mrm_create_restore_point "theme-update" "panel" "$PANEL_ENV" "$DATA_DIR/templates/subscription")"
        [ -n "$RESTORE_POINT_ID" ] && echo -e "${BLUE}Restore point created: $RESTORE_POINT_ID${NC}"
    fi

    mkdir -p "$TEMPLATE_DIR" "$(dirname "$CLASSIC_FILE")"

    echo -e "${BLUE}Template Path: $TEMPLATE_FILE${NC}"
    echo -e "${BLUE}Old template:   $CLASSIC_FILE${NC}"

    # 1. Backup old file
    if [ -s "$TEMPLATE_FILE" ]; then
        cp "$TEMPLATE_FILE" "$OLD_FILE"
        echo -e "${GREEN}✔ Backup created.${NC}"
    else
        : > "$OLD_FILE"
    fi

    # 2. Source Selection (Hybrid)
    rm -f "$TEMP_DL"
    LOCAL_TEMPLATE="$(theme_get_local_template 2>/dev/null || true)"

    if [ -n "$LOCAL_TEMPLATE" ]; then
        echo -e "${GREEN}✔ Found local theme source. Using it.${NC}"
        cp "$LOCAL_TEMPLATE" "$TEMP_DL"
    else
        echo -e "${BLUE}Downloading from GitHub...${NC}"
        echo -e "${BLUE}URL: $THEME_HTML_URL${NC}"
        
        if curl -sL -f -o "$TEMP_DL" "$THEME_HTML_URL" 2>/dev/null; then
            if grep -q "404: Not Found" "$TEMP_DL" 2>/dev/null; then
                echo -e "${RED}✘ Download failed: 404 Not Found${NC}"
                echo -e "${YELLOW}Please check THEME_HTML_URL in utils.sh${NC}"
                rm -rf "$TMP_DIR"
                pause; return
            fi
            echo -e "${GREEN}✔ Downloaded successfully.${NC}"
        else
            echo -e "${RED}✘ Download failed!${NC}"
            rm -rf "$TMP_DIR"
            pause; return
        fi
    fi

    # ✅ بررسی سایز فایل
    FILE_SIZE=$(stat -c%s "$TEMP_DL" 2>/dev/null || echo "0")
    if [ "$FILE_SIZE" -lt 1000 ]; then
        echo -e "${RED}✘ Downloaded file is too small ($FILE_SIZE bytes). Something went wrong.${NC}"
        cat "$TEMP_DL"
        rm -rf "$TMP_DIR"
        pause; return
    fi
    echo -e "${GREEN}✔ File size OK: $FILE_SIZE bytes${NC}"

    # 2b. Classic template (both templates always install together)
    rm -f "$CLASSIC_DL"
    CLASSIC_LOCAL="$(theme_get_local_classic_template 2>/dev/null || true)"
    if [ -n "$CLASSIC_LOCAL" ]; then
        cp "$CLASSIC_LOCAL" "$CLASSIC_DL"
        echo -e "${GREEN}✔ Found local old-template source. Using it.${NC}"
    else
        echo -e "${BLUE}Downloading old template...${NC}"
        echo -e "${BLUE}URL: $THEME_CLASSIC_HTML_URL${NC}"
        if curl -sL -f -o "$CLASSIC_DL" "$THEME_CLASSIC_HTML_URL" 2>/dev/null && ! grep -q "404: Not Found" "$CLASSIC_DL" 2>/dev/null; then
            echo -e "${GREEN}✔ Old template downloaded.${NC}"
        else
            echo -e "${YELLOW}⚠ Old template download failed — continuing with MRM Special only.${NC}"
            rm -f "$CLASSIC_DL"
        fi
    fi

    # 3. Processing
    echo -e "${BLUE}Processing configuration...${NC}"

    export OLD_FILE
    export NEW_FILE="$TEMP_DL"
    export FINAL_FILE="$TEMPLATE_FILE"
    export CLASSIC_NEW_FILE="$CLASSIC_DL"
    export CLASSIC_FINAL_FILE="$CLASSIC_FILE"

    cat > "$PY_SCRIPT" << 'PYEOF'
import html
import os
import re
import sys

CYAN = '\033[0;36m'
YELLOW = '\033[1;33m'
GREEN = '\033[0;32m'
NC = '\033[0m'

old_path = os.environ.get('OLD_FILE')
pairs = [(os.environ.get('NEW_FILE'), os.environ.get('FINAL_FILE'))]
classic_new = os.environ.get('CLASSIC_NEW_FILE')
classic_final = os.environ.get('CLASSIC_FINAL_FILE')
if classic_new and classic_final and os.path.exists(classic_new):
    pairs.append((classic_new, classic_final))

defaults = {
    'brand': 'FarsNetVIP',
    'bot': 'MyBot',
    'sup': 'Support',
    'news': 'خوش آمدید',
}


def clean_handle(value, fallback):
    value = (value or '').strip().lstrip('@')
    value = re.sub(r"[\s\"'<>]+", "", value)
    return value or fallback


def clean_text(value, fallback):
    value = (value or '').strip()
    return value or fallback


try:
    with open(old_path, 'r', encoding='utf-8', errors='ignore') as f:
        old_content = f.read()

    m_brand = re.search(r'<title>(.*?)</title>', old_content, re.S | re.I)
    if not m_brand:
        m_brand = re.search(r'class=["\'][^"\']*brand[^"\']*["\'][^>]*>(.*?)<', old_content, re.S | re.I)
    if m_brand:
        brand_value = html.unescape(m_brand.group(1).strip())
        if brand_value and '__BRAND__' not in brand_value:
            defaults['brand'] = brand_value

    bot_patterns = [
        r'href=["\']https://t\.me/([^"\']+)["\'][^>]*id=["\']renewBtn["\']',
        r'id=["\']renewBtn["\'][^>]*href=["\']https://t\.me/([^"\']+)["\']',
        r'href=["\']https://t\.me/([^"\']+)["\'][^>]*class=["\'][^"\']*renew-btn',
        r'href=["\']https://t\.me/([^"\']+)["\'][^>]*class=["\'][^"\']*bot-link',
    ]
    for pattern in bot_patterns:
        m_bot = re.search(pattern, old_content, re.I)
        if m_bot:
            bot_value = m_bot.group(1).strip()
            if bot_value and '__BOT__' not in bot_value:
                defaults['bot'] = bot_value
                break

    support_patterns = [
        r'href=["\']https://t\.me/([^"\']+)["\'][^>]*class=["\'][^"\']*support-btn',
        r'class=["\'][^"\']*support-btn[^"\']*["\'][^>]*href=["\']https://t\.me/([^"\']+)["\']',
        r'href=["\']https://t\.me/([^"\']+)["\'][^>]*class=["\'][^"\']*btn-dark',
    ]
    for pattern in support_patterns:
        m_sup = re.search(pattern, old_content, re.I)
        if m_sup:
            sup_value = m_sup.group(1).strip()
            if sup_value and '__SUP__' not in sup_value:
                defaults['sup'] = sup_value
                break

    news_patterns = [
        r'id=["\']announceText["\']>\s*([^<]+?)\s*<',
        r'id=["\']nT["\']>\s*([^<]+?)\s*<',
    ]
    for pattern in news_patterns:
        m_news = re.search(pattern, old_content, re.S | re.I)
        if m_news:
            news_value = html.unescape(m_news.group(1).strip())
            if news_value and '__NEWS__' not in news_value:
                defaults['news'] = news_value
                break

except Exception:
    pass

print(f'\n{CYAN}=== Theme Settings ==={NC}')
print(f'Press {YELLOW}ENTER{NC} to keep the current value [in brackets].\n')


def get_input(label, key):
    try:
        val = input(f'{label} [{defaults[key]}]: ').strip()
        if not val:
            return defaults[key]
        return val
    except EOFError:
        return defaults[key]


new_brand = html.escape(clean_text(get_input('Brand Name', 'brand'), defaults['brand']), quote=False)
new_bot = clean_handle(get_input('Bot Username (No @)', 'bot'), defaults['bot'])
new_sup = clean_handle(get_input('Support ID (No @)', 'sup'), defaults['sup'])
new_news = html.escape(clean_text(get_input('News Text', 'news'), defaults['news']), quote=False)

try:
    for new_path, final_path in pairs:
        with open(new_path, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()

        content = content.replace('__BRAND__', new_brand)
        content = content.replace('__BOT__', new_bot)
        content = content.replace('__SUP__', new_sup)
        content = content.replace('__NEWS__', new_news)

        with open(final_path, 'w', encoding='utf-8') as f:
            f.write(content)
        print(f'{GREEN}✔ Written: {final_path}{NC}')

    print(f'\n{GREEN}✔ Settings saved successfully.{NC}')
except Exception as e:
    print(f'\nError processing file: {e}')
    sys.exit(1)
PYEOF

    python3 "$PY_SCRIPT"
    PY_EXIT_CODE=$?
    rm -f "$PY_SCRIPT"

    if [ $PY_EXIT_CODE -eq 0 ]; then
        if [ ! -s "$TEMPLATE_FILE" ]; then
            echo -e "${RED}✘ Final file is empty!${NC}"
            rm -rf "$TMP_DIR"
            pause; return
        fi

        echo ""
        echo -e "${CYAN}=== Final Configuration ===${NC}"
        echo -e "MRM Special  : $TEMPLATE_FILE ($(stat -c%s "$TEMPLATE_FILE" 2>/dev/null) bytes)"
        echo -e "Old template : $CLASSIC_FILE ($(stat -c%s "$CLASSIC_FILE" 2>/dev/null || echo 0) bytes)"
        echo ""

        echo -e "${BLUE}Activating MRM Special template + restarting panel...${NC}"
        if theme_set_template "special"; then
            echo -e "${GREEN}✔ Template installed & panel restarted.${NC}"
            echo -e "${GREEN}  (select «نسخه قدیمی تم» or «MRM Special» in panel → Settings → MRM)${NC}"
        else
            echo -e "${YELLOW}⚠ Templates installed, but activation failed. Use menu option 2.${NC}"
        fi
        rm -rf "$TMP_DIR"
    else
        echo -e "${RED}✘ Python Script Failed.${NC}"
        rm -rf "$TMP_DIR"
    fi
    pause
}

activate_theme() {
    clear
    detect_active_panel > /dev/null
    
    local T_FILE="$DATA_DIR/templates/subscription/index.html"
    if [ ! -s "$T_FILE" ]; then 
        echo -e "${RED}Theme file missing or empty. Install first.${NC}"
        echo -e "${YELLOW}Expected path: $T_FILE${NC}"
        pause; return
    fi

    if declare -f mrm_create_restore_point >/dev/null 2>&1; then
        local RESTORE_POINT_ID
        RESTORE_POINT_ID="$(mrm_create_restore_point "theme-activate" "panel" "$PANEL_ENV" "$DATA_DIR/templates/subscription")"
        [ -n "$RESTORE_POINT_ID" ] && echo -e "${BLUE}Restore point created: $RESTORE_POINT_ID${NC}"
    fi
    
    if ! theme_apply_env; then
        echo -e "${RED}Failed to update panel environment.${NC}"
        pause; return
    fi

    if theme_restart_panel; then
        echo -e "${GREEN}✔ Theme Activated.${NC}"
    else
        echo -e "${YELLOW}⚠ Theme activated, but panel restart failed. Please restart manually.${NC}"
    fi
    pause
}

deactivate_theme() {
    clear
    detect_active_panel > /dev/null
    
    if [ -f "$PANEL_ENV" ]; then
        if declare -f mrm_create_restore_point >/dev/null 2>&1; then
            local RESTORE_POINT_ID
            RESTORE_POINT_ID="$(mrm_create_restore_point "theme-deactivate" "panel" "$PANEL_ENV" "$DATA_DIR/templates/subscription")"
            [ -n "$RESTORE_POINT_ID" ] && echo -e "${BLUE}Restore point created: $RESTORE_POINT_ID${NC}"
        fi

        if ! theme_clear_env; then
            echo -e "${RED}Failed to clean theme settings from panel environment.${NC}"
            pause; return
        fi
        if theme_restart_panel; then
            echo -e "${GREEN}✔ Theme Deactivated.${NC}"
        else
            echo -e "${YELLOW}⚠ Theme deactivated, but panel restart failed. Please restart manually.${NC}"
        fi
    else
        echo -e "${YELLOW}Panel environment file not found.${NC}"
    fi
    pause
}

uninstall_theme() {
    clear
    detect_active_panel > /dev/null
    
    read -p "Delete theme files? (y/n): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        if declare -f mrm_create_restore_point >/dev/null 2>&1; then
            local RESTORE_POINT_ID
            RESTORE_POINT_ID="$(mrm_create_restore_point "theme-uninstall" "panel" "$PANEL_ENV" "$DATA_DIR/templates/subscription")"
            [ -n "$RESTORE_POINT_ID" ] && echo -e "${BLUE}Restore point created: $RESTORE_POINT_ID${NC}"
        fi

        rm -rf "$DATA_DIR/templates/subscription" "$DATA_DIR/templates/subscription-classic"
        rm -f "$(theme_mrm_data_dir)/template-status.json"
        if [ -f "$PANEL_ENV" ]; then
            if ! theme_clear_env; then
                echo -e "${RED}Failed to clean theme settings from panel environment.${NC}"
                pause; return
            fi
            if theme_restart_panel; then
                echo -e "${GREEN}✔ Theme removed & deactivated.${NC}"
            else
                echo -e "${YELLOW}⚠ Theme removed, but panel restart failed. Please restart manually.${NC}"
            fi
        else
            echo -e "${GREEN}✔ Theme files removed.${NC}"
        fi
    fi
    pause
}

is_theme_active() {
    # FIX: anchor the key and ignore commented lines (MRM-091) — the official
    # panel .env.example ships "SUBSCRIPTION_PAGE_TEMPLATE" commented out, so a
    # plain grep would report Theme "Active" on a default install
    # Also require the template file to exist (MRM-091b) — the env key alone
    # must not show "Active" if the template was removed/lost.
    if grep -qE "^[[:space:]]*SUBSCRIPTION_PAGE_TEMPLATE[[:space:]]*=" "$PANEL_ENV" 2>/dev/null \
        && [ -n "${DATA_DIR:-}" ] && [ -s "$DATA_DIR/templates/subscription/index.html" ]; then
        return 0
    fi
    return 1
}

theme_templates_status() {
    local cur sp cl active_name
    cur="$(theme_current_template)"
    active_name="$(theme_template_display_name "$cur")"
    sp="$DATA_DIR/templates/subscription/index.html"
    cl="$DATA_DIR/templates/subscription-classic/index.html"
    echo -e "Active template : ${CYAN}${active_name}${NC}"
    if [ -s "$sp" ]; then
        echo -e "MRM Special     : ${GREEN}●${NC} Installed"
    else
        echo -e "MRM Special     : ${RED}○${NC} Not installed"
    fi
    if [ -s "$cl" ]; then
        echo -e "Old template    : ${GREEN}●${NC} Installed"
    else
        echo -e "Old template    : ${RED}○${NC} Not installed"
    fi
}

theme_conflicts_label() {
    # Informational only — MRM never removes other products.
    if bash /opt/mrm-manager/special.sh --detect-quiet 2>/dev/null; then
        echo -e "Other           : ${YELLOW}ℹ${NC} zomorod integration also present (we never remove other products)"
    fi
}

theme_toggle() {
    clear
    detect_active_panel > /dev/null
    if is_theme_active; then
        echo -e "Template is currently: ${GREEN}ON${NC} (active: $(theme_template_display_name "$(theme_current_template)"))"
        read -p "Turn it OFF (vanilla PasarGuard page)? (y/n): " C
        [[ "$C" =~ ^[Yy]$ ]] || return
        theme_clear_env && theme_restart_panel && echo -e "${GREEN}✔ Template is now OFF${NC}"
    else
        if [ ! -s "$DATA_DIR/templates/subscription/index.html" ] && [ ! -s "$DATA_DIR/templates/subscription-classic/index.html" ]; then
            echo "Template is not installed yet — use option 1 first."
            read -n 1 -s -r -p "Press any key..."; echo; return
        fi
        echo -e "Template is currently: ${RED}OFF${NC}"
        read -p "Turn it ON? (y/n): " C
        [[ "$C" =~ ^[Yy]$ ]] || return
        local cur
        cur="$(theme_current_template)"
        [ "$cur" = "none" ] && cur="special"
        theme_set_template "$cur" && echo -e "${GREEN}✔ Template is now ON (active: $(theme_template_display_name "$cur"))${NC}"
    fi
    read -n 1 -s -r -p "Press any key..."; echo
}

theme_menu() {
    while true; do
        clear
        detect_active_panel > /dev/null

        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      THEME MANAGER v${THEME_VERSION}               ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo -e "Panel: ${CYAN}$PANEL_DIR${NC}"
        echo -e "Data:  ${CYAN}$DATA_DIR${NC}"
        echo ""
        echo -e "${YELLOW}ℹ Both templates stay installed — one is shown at a time.${NC}"
        echo -e "${YELLOW}  Choose the active one (and ON/OFF) in panel → Settings → MRM.${NC}"
        echo ""
        theme_templates_status
        theme_conflicts_label
        echo ""
        echo "1) 📦 Install / Update Template"
        echo "2) 🔛 Template: ON / OFF"
        echo "3) ◆ MRM Special manager"
        echo "4) 🗑️ Uninstall Template"
        echo "0) Back"
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select: " T_OPT
        case $T_OPT in
            1) install_theme_wizard ;;
            2) theme_toggle ;;
            3) bash /opt/mrm-manager/special.sh || echo "MRM Special could not be started" ;;
            4) uninstall_theme ;;
            0) return ;;
            *) theme_invalid_option ;;
        esac
    done
}

case "${1:-}" in
    --set-template)     shift; theme_set_template "$@"; exit $? ;;
    --current-template) theme_current_template; exit 0 ;;
esac

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    theme_menu
fi
