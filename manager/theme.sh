#!/bin/bash

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi
if ! declare -f ui_header >/dev/null 2>&1 && [ -r /opt/mrm-manager/ui.sh ]; then source /opt/mrm-manager/ui.sh; fi
if ! declare -f mrm_create_restore_point >/dev/null 2>&1 && [ -r /opt/mrm-manager/safe_ops.sh ]; then source /opt/mrm-manager/safe_ops.sh; fi

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

theme_apply_env() {
    [ -f "$PANEL_ENV" ] || touch "$PANEL_ENV" 2>/dev/null || return 1
    sed -i '/CUSTOM_TEMPLATES_DIRECTORY/d' "$PANEL_ENV" || return 1
    sed -i '/SUBSCRIPTION_PAGE_TEMPLATE/d' "$PANEL_ENV" || return 1
    echo "CUSTOM_TEMPLATES_DIRECTORY=\"$DATA_DIR/templates/\"" >> "$PANEL_ENV" || return 1
    echo 'SUBSCRIPTION_PAGE_TEMPLATE="subscription/index.html"' >> "$PANEL_ENV" || return 1
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
    TEMPLATE_DIR=$(dirname "$TEMPLATE_FILE")
    OLD_FILE="$TMP_DIR/index_old.html"
    TEMP_DL="$TMP_DIR/index_dl.html"
    PY_SCRIPT="$TMP_DIR/mrm_theme_logic.py"

    if declare -f mrm_create_restore_point >/dev/null 2>&1; then
        local RESTORE_POINT_ID
        RESTORE_POINT_ID="$(mrm_create_restore_point "theme-update" "panel" "$PANEL_ENV" "$DATA_DIR/templates/subscription")"
        [ -n "$RESTORE_POINT_ID" ] && echo -e "${BLUE}Restore point created: $RESTORE_POINT_ID${NC}"
    fi

    mkdir -p "$TEMPLATE_DIR"

    echo -e "${BLUE}Template Path: $TEMPLATE_FILE${NC}"

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

    # 3. Processing
    echo -e "${BLUE}Processing configuration...${NC}"

    export OLD_FILE
    export NEW_FILE="$TEMP_DL"
    export FINAL_FILE="$TEMPLATE_FILE"

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
new_path = os.environ.get('NEW_FILE')
final_path = os.environ.get('FINAL_FILE')

defaults = {
    'brand': 'FarsNetVIP',
    'bot': 'MyBot',
    'sup': 'Support',
    'news': 'خوش آمدید',
}


def clean_handle(value, fallback):
    value = (value or '').strip().lstrip('@')
    value = re.sub(r'[\s"\'"'<>]+', '', value)
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
    with open(new_path, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    content = content.replace('__BRAND__', new_brand)
    content = content.replace('__BOT__', new_bot)
    content = content.replace('__SUP__', new_sup)
    content = content.replace('__NEWS__', new_news)

    with open(final_path, 'w', encoding='utf-8') as f:
        f.write(content)

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

        if ! theme_apply_env; then
            echo -e "${RED}✘ Failed to update panel environment for theme.${NC}"
            rm -rf "$TMP_DIR"
            pause; return
        fi

        echo ""
        echo -e "${CYAN}=== Final Configuration ===${NC}"
        echo -e "Template: $TEMPLATE_FILE"
        echo -e "File Size: $(stat -c%s "$TEMPLATE_FILE") bytes"
        grep -E "CUSTOM_TEMPLATES|SUBSCRIPTION_PAGE" "$PANEL_ENV"
        echo ""

        echo -e "${BLUE}Restarting panel...${NC}"
        if theme_restart_panel; then
            echo -e "${GREEN}✔ Theme Updated & Panel Restarted.${NC}"
        else
            echo -e "${YELLOW}⚠ Theme updated, but panel restart failed. Please restart manually.${NC}"
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

        rm -rf "$DATA_DIR/templates/subscription"
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
    if grep -q "SUBSCRIPTION_PAGE_TEMPLATE" "$PANEL_ENV" 2>/dev/null; then return 0; fi
    return 1
}

theme_menu() {
    while true; do
        clear
        detect_active_panel > /dev/null
        
        echo -e "${BLUE}===========================================${NC}"
        echo -e "${YELLOW}      THEME MANAGER                        ${NC}"
        echo -e "${BLUE}===========================================${NC}"
        echo -e "Panel: ${CYAN}$PANEL_DIR${NC}"
        echo -e "Data:  ${CYAN}$DATA_DIR${NC}"
        if is_theme_active; then 
            echo -e "Status: ${GREEN}● Active${NC}"
        else 
            echo -e "Status: ${RED}● Inactive${NC}"
        fi
        echo ""
        echo "1) Install / Update Theme"
        echo "2) Activate Theme"
        echo "3) Deactivate Theme"
        echo "4) Uninstall Theme"
        echo "0) Back"
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select: " T_OPT
        case $T_OPT in
            1) install_theme_wizard ;;
            2) activate_theme ;;
            3) deactivate_theme ;;
            4) uninstall_theme ;;
            0) return ;;
            *) theme_invalid_option ;;
        esac
    done
}
