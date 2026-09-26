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

theme_get_special_source() {
    # Returns the pristine source for MRM Special template (must NOT be Classic)
    local candidate
    for candidate in \
        "/opt/mrm-manager/index.html" \
        "/opt/mrm-manager/templates/subscription-special/index.html" \
        "$DATA_DIR/templates/.special.pristine.html" \
        "$DATA_DIR/templates/subscription-special/index.html" \
        "./templates/subscription/index.html" \
        "/opt/mrm-manager/templates/subscription/index.html"
    do
        if [ -s "$candidate" ] && ! grep -q "guideBanner" "$candidate" 2>/dev/null; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    if [ -s "$DATA_DIR/templates/subscription/index.html" ] && ! grep -q "guideBanner" "$DATA_DIR/templates/subscription/index.html" 2>/dev/null; then
        printf '%s\n' "$DATA_DIR/templates/subscription/index.html"
        return 0
    fi
    # Network fallback if none found
    local dl_dst="$DATA_DIR/templates/.special.pristine.html"
    mkdir -p "$(dirname "$dl_dst")" 2>/dev/null || true
    local ver
    ver="$(get_mrm_version 2>/dev/null || cat /opt/mrm-manager/VERSION 2>/dev/null || echo "1.4.23")"
    local dl_url="https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/v${ver}/templates/subscription/index.html"
    if curl -sL -f -o "$dl_dst" "$dl_url" 2>/dev/null && [ -s "$dl_dst" ] && ! grep -q "guideBanner" "$dl_dst" 2>/dev/null; then
        printf '%s\n' "$dl_dst"
        return 0
    fi
    return 1
}

theme_get_classic_source() {
    # Returns the pristine source for MRM Classic template (MUST be Classic)
    local candidate
    for candidate in \
        "/opt/mrm-manager/templates/subscription-classic/index.html" \
        "$DATA_DIR/templates/.classic.pristine.html" \
        "$DATA_DIR/templates/subscription-classic/index.html" \
        "./templates/subscription-classic/index.html"
    do
        if [ -s "$candidate" ] && grep -q "guideBanner" "$candidate" 2>/dev/null; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    if [ -s "$DATA_DIR/templates/subscription/index.html" ] && grep -q "guideBanner" "$DATA_DIR/templates/subscription/index.html" 2>/dev/null; then
        printf '%s\n' "$DATA_DIR/templates/subscription/index.html"
        return 0
    fi
    # Network fallback if none found
    local dl_dst="$DATA_DIR/templates/.classic.pristine.html"
    mkdir -p "$(dirname "$dl_dst")" 2>/dev/null || true
    local ver
    ver="$(get_mrm_version 2>/dev/null || cat /opt/mrm-manager/VERSION 2>/dev/null || echo "1.4.23")"
    local dl_url="https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/v${ver}/templates/subscription-classic/index.html"
    if curl -sL -f -o "$dl_dst" "$dl_url" 2>/dev/null && [ -s "$dl_dst" ] && grep -q "guideBanner" "$dl_dst" 2>/dev/null; then
        printf '%s\n' "$dl_dst"
        return 0
    fi
    return 1
}

theme_get_local_template() {
    theme_get_special_source
}

theme_get_local_classic_template() {
    theme_get_classic_source
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
        classic) echo "MRM Classic (قالب کلاسیک)" ;;
        special) echo "MRM Special (قالب ویژه)" ;;
        *) echo "—" ;;
    esac
}

theme_current_template() {
    # Prints: classic | special | none
    local dir st rel
    dir="$(theme_mrm_data_dir)"
    st="$(python3 -c "import json;print(json.load(open('$dir/template-status.json')).get('active') or '')" 2>/dev/null || true)"
    case "$st" in
        classic|special) echo "$st"; return 0 ;;
    esac

    rel="$(grep -E "^[[:space:]]*SUBSCRIPTION_PAGE_TEMPLATE[[:space:]]*=" "$PANEL_ENV" 2>/dev/null | tail -1 | cut -d'"' -f2)"
    case "$rel" in
        subscription-classic/*) echo "classic"; return 0 ;;
        subscription-special/*) echo "special"; return 0 ;;
    esac

    if [ -s "$DATA_DIR/templates/subscription/index.html" ]; then
        if grep -q "guideBanner" "$DATA_DIR/templates/subscription/index.html" 2>/dev/null; then
            echo "classic"; return 0
        else
            echo "special"; return 0
        fi
    fi
    if [ -s "$DATA_DIR/templates/subscription-classic/index.html" ]; then echo "classic"; return 0; fi
    echo "none"
}

theme_set_template() {
    # $1 = classic | special  — switch the active subscription template
    local key="${1:-}" rel="" target_src=""
    case "$key" in
        classic)
            rel="subscription-classic/index.html"
            target_src="$(theme_get_classic_source 2>/dev/null || true)"
            ;;
        special)
            rel="subscription/index.html"
            target_src="$(theme_get_special_source 2>/dev/null || true)"
            ;;
        *)
            echo "unknown template '$key' (use: classic | special)"; return 1 ;;
    esac
    detect_active_panel > /dev/null

    if [ -z "$target_src" ] || [ ! -s "$target_src" ]; then
        theme_write_template_status failed "$key" "Template source file missing for $key"
        echo "Template source file missing for $key"
        return 1
    fi

    theme_write_template_status running "$key" "Switching subscription template to $key"

    mkdir -p "$DATA_DIR/templates/subscription" "$DATA_DIR/templates/subscription-classic" "$DATA_DIR/templates/subscription-special" 2>/dev/null || true

    # Preserve pristine template copies
    if [ "$key" = "classic" ]; then
        cp -f "$target_src" "$DATA_DIR/templates/.classic.pristine.html" 2>/dev/null || true
    elif [ "$key" = "special" ]; then
        cp -f "$target_src" "$DATA_DIR/templates/.special.pristine.html" 2>/dev/null || true
        cp -f "$target_src" "$DATA_DIR/templates/subscription-special/index.html" 2>/dev/null || true
    fi

    # Deploy to BOTH candidate served paths on the host so whichever path PasarGuard reads is updated
    local served_sub="$DATA_DIR/templates/subscription/index.html"
    local served_classic="$DATA_DIR/templates/subscription-classic/index.html"
    cp -f "$target_src" "$served_sub" 2>/dev/null || true
    cp -f "$target_src" "$served_classic" 2>/dev/null || true

    # Inject runtime into served templates so panel customizations apply dynamically
    local r_js="/opt/mrm-manager/plugin/mrm-runtime.js"
    [ -f "$r_js" ] || r_js="$DATA_DIR/plugin/mrm-runtime.js"
    if [ -f "$r_js" ]; then
        for s_file in "$served_sub" "$served_classic"; do
            if [ -f "$s_file" ]; then
                python3 - "$s_file" "$r_js" "mrm-runtime-inline" <<'PY' 2>/dev/null || true
from pathlib import Path
import re, sys
template_path=Path(sys.argv[1]); runtime_path=Path(sys.argv[2]); marker=sys.argv[3]
if template_path.exists() and runtime_path.exists():
    original=template_path.read_text(encoding="utf-8"); runtime=runtime_path.read_text(encoding="utf-8")
    pattern=re.compile(rf'\s*<script id="{re.escape(marker)}">.*?</script>\s*',re.S)
    html=pattern.sub('',original); block=f'\n<script id="{marker}">\n{runtime}\n</script>\n'
    html=html.replace('</body>',block+'</body>',1) if '</body>' in html else html+block
    if html!=original: template_path.write_text(html,encoding="utf-8")
PY
            fi
        done
    fi

    theme_apply_env "$rel" || true

    # Hot-inject into running Docker container across ALL possible paths (both subscription & subscription-classic)
    if command -v docker >/dev/null 2>&1; then
        for cid in $(docker ps -q 2>/dev/null); do
            local img
            img=$(docker inspect -f "{{.Config.Image}}" "$cid" 2>/dev/null || true)
            case "$img" in
                *pasarguard/panel*)
                    for c_dest in \
                        /code/app/templates/subscription/index.html \
                        /code/app/templates/subscription-classic/index.html \
                        /app/app/templates/subscription/index.html \
                        /app/app/templates/subscription-classic/index.html \
                        /opt/pasarguard/app/templates/subscription/index.html \
                        /opt/pasarguard/app/templates/subscription-classic/index.html
                    do
                        if docker exec "$cid" test -e "$(dirname "$c_dest")" >/dev/null 2>&1; then
                            docker cp "$served_sub" "$cid:$c_dest" >/dev/null 2>&1 || true
                        fi
                    done
                    ;;
            esac
        done
    fi

    theme_restart_panel || true
    theme_write_template_status success "$key" "Template switched to $key"
    echo "✔ Active template: $(theme_template_display_name "$key") ($rel)"
    return 0
}

theme_redeploy() {
    # Non-interactive refresh of the deployed subscription templates — run by
    # install.sh at the end of every 'mrm update'. Replaces the deployed files
    # with the freshly installed sources under /opt/mrm-manager while keeping
    # the owner's brand/bot/sup/news values and the active template selection.
    # No prompts: safe for unattended updates.
    detect_active_panel > /dev/null 2>&1 || true
    local D="${DATA_DIR:-}" SRC_S SRC_C DEP_S DEP_C DEP_SP
    [ -n "$D" ] || return 0
    DEP_S="$D/templates/subscription/index.html"
    DEP_SP="$D/templates/subscription-special/index.html"
    DEP_C="$D/templates/subscription-classic/index.html"
    # Nothing deployed yet (wizard never ran) — nothing to refresh.
    [ -s "$DEP_S" ] || [ -s "$DEP_SP" ] || [ -s "$DEP_C" ] || { echo "• No deployed template yet — run 'mrm' → 1 to install it"; return 0; }
    SRC_S="${MRM_SPECIAL_SRC:-}"
    [ -n "$SRC_S" ] || SRC_S="$(theme_get_special_source 2>/dev/null || true)"
    [ -n "$SRC_S" ] || SRC_S="/opt/mrm-manager/index.html"

    SRC_C="${MRM_CLASSIC_SRC:-}"
    [ -n "$SRC_C" ] || SRC_C="$(theme_get_classic_source 2>/dev/null || true)"
    [ -n "$SRC_C" ] || SRC_C="/opt/mrm-manager/templates/subscription-classic/index.html"

    [ -s "$SRC_S" ] || [ -s "$SRC_C" ] || return 0
    mkdir -p "$D/templates/subscription" "$D/templates/subscription-classic" "$D/templates/subscription-special" 2>/dev/null || true
    if python3 - "$SRC_S" "$SRC_C" "$DEP_S" "$DEP_C" "$D/theme-settings.json" "$DEP_SP" <<'PY'
import json, re, sys
from pathlib import Path

src_s, src_c, dep_s, dep_c, settings, dep_sp = (Path(p) for p in sys.argv[1:7])

def clean_brand(value):
    value = re.sub(r'\{\{.*?\}\}', ' ', value or '')
    value = re.sub(r'\s+', ' ', value).strip()
    return value.rstrip(' ·|•-–—:')

brand = bot = sup = news = ''
try:
    saved = json.loads(settings.read_text(encoding='utf-8'))
    brand = str(saved.get('brand') or '')
    bot = str(saved.get('bot') or '')
    sup = str(saved.get('sup') or '')
    news = str(saved.get('news') or '')
except Exception:
    pass

def scrub(value):
    # Never carry raw template tokens (e.g. a never-rendered '__BRAND__' left
    # over from an unrendered deploy) — treat them as unknown so extraction
    # and fallbacks can heal the file.
    value = (value or '').strip()
    return '' if re.fullmatch(r'__[A-Za-z_]+__', value) else value

brand, bot, sup, news = scrub(brand), scrub(bot), scrub(sup), scrub(news)

if not any((brand, bot, sup, news)):
    # Recover the rendered values from the deployed templates (both markups).
    old_s = dep_s.read_text(encoding='utf-8', errors='ignore') if dep_s.is_file() else ''
    old_c = dep_c.read_text(encoding='utf-8', errors='ignore') if dep_c.is_file() else ''
    old = old_s + '\n' + old_c
    m = re.search(r'<title>(.*?)</title>', old, re.S | re.I)
    if m:
        brand = clean_brand(m.group(1).strip())
    for pat in (
        r'href=["\']https://t\.me/([^"\'\s]+)["\'][^>]*id=["\']renewBtn["\']',
        r'id=["\']renewBtn["\'][^>]*href=["\']https://t\.me/([^"\'\s]+)',
        r'href=["\']https://t\.me/([^"\'\s]+)["\'][^>]*class=["\'][^"\']*renew-btn',
        r'href=["\']https://t\.me/([^"\'\s]+)["\'][^>]*class=["\'][^"\']*bot-link',
    ):
        m = re.search(pat, old, re.I)
        if m:
            bot = m.group(1).strip()
            break
    if not bot:
        handles = [h for h in re.findall(r'https://t\.me/([A-Za-z0-9_]{3,})', old_s)]
        uniq = list(dict.fromkeys(handles))
        if len(uniq) == 1:
            bot = uniq[0]
        elif handles:
            bot = max(set(handles), key=handles.count)
    for pat in (
        r'href=["\']https://t\.me/([^"\'\s]+)["\'][^>]*class=["\'][^"\']*support-btn',
        r'class=["\'][^"\']*support-btn["\'][^>]*href=["\']https://t\.me/([^"\'\s]+)',
        r'href=["\']https://t\.me/([^"\'\s]+)["\'][^>]*class=["\'][^"\']*btn-dark',
    ):
        m = re.search(pat, old, re.I)
        if m:
            sup = m.group(1).strip()
            break
    for pat in (
        r'id=["\']announceText["\']>\s*([^<]+?)\s*<',
        r'id=["\']nT["\']>\s*([^<]+?)\s*<',
        r'const\s+\w+="([^"]*)";return!\w+\.startsWith\("__"\)',
    ):
        m = re.search(pat, old, re.S | re.I)
        if m:
            news = m.group(1).strip()
            break

brand, bot, sup, news = scrub(brand), scrub(bot), scrub(sup), scrub(news)
brand = brand or 'MRM'

def render(src, dst):
    if not src.is_file():
        return False
    content = src.read_text(encoding='utf-8', errors='ignore')
    content = content.replace('__BRAND__', brand).replace('__BOT__', bot)
    content = content.replace('__SUP__', sup).replace('__NEWS__', news)
    content = re.sub(r'__(?:BRAND|BOT|SUP|NEWS)__', '', content)
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_name(dst.name + '.tmp')
    tmp.write_text(content, encoding='utf-8')
    try:
        tmp.chmod(0o644)
    except OSError:
        pass
    tmp.replace(dst)
    return True

render(src_s, dep_sp)
render(src_c, dep_c)

# Persist the values so the next refresh never has to guess again.
try:
    payload = json.dumps({'brand': brand, 'bot': bot, 'sup': sup, 'news': news}, indent=2, ensure_ascii=False) + '\n'
    tmp = settings.with_name(settings.name + '.tmp')
    tmp.write_text(payload, encoding='utf-8')
    try:
        tmp.chmod(0o600)
    except OSError:
        pass
    tmp.replace(settings)
except Exception:
    pass
PY
    then
        local active_tpl
        active_tpl="$(theme_current_template)"
        if [ "$active_tpl" = "classic" ] && [ -s "$DEP_C" ]; then
            cp -f "$DEP_C" "$DEP_S" 2>/dev/null || true
            cp -f "$DEP_C" "$D/templates/subscription-classic/index.html" 2>/dev/null || true
        elif [ -s "$DEP_SP" ]; then
            cp -f "$DEP_SP" "$DEP_S" 2>/dev/null || true
            cp -f "$DEP_SP" "$D/templates/subscription-classic/index.html" 2>/dev/null || true
        fi

        # Hot-inject into running Docker container across all potential paths
        if command -v docker >/dev/null 2>&1; then
            for cid in $(docker ps -q 2>/dev/null); do
                local img
                img=$(docker inspect -f "{{.Config.Image}}" "$cid" 2>/dev/null || true)
                case "$img" in
                    *pasarguard/panel*)
                        for c_dest in \
                            /code/app/templates/subscription/index.html \
                            /code/app/templates/subscription-classic/index.html \
                            /app/app/templates/subscription/index.html \
                            /app/app/templates/subscription-classic/index.html \
                            /opt/pasarguard/app/templates/subscription/index.html \
                            /opt/pasarguard/app/templates/subscription-classic/index.html
                        do
                            if docker exec "$cid" test -e "$(dirname "$c_dest")" >/dev/null 2>&1; then
                                docker cp "$DEP_S" "$cid:$c_dest" >/dev/null 2>&1 || true
                            fi
                        done
                        ;;
                esac
            done
        fi

        theme_restart_panel || true
        echo "✔ Deployed templates refreshed (brand/news kept, selection kept)"
        return 0
    fi
    echo "⚠ Template refresh failed"
    return 1
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

    if [ -d "$PANEL_DIR" ] && command -v docker >/dev/null 2>&1; then
        if docker compose version >/dev/null 2>&1; then
            (cd "$PANEL_DIR" && (docker compose up -d --no-deps pasarguard 2>/dev/null || docker compose restart pasarguard 2>/dev/null || docker compose restart 2>/dev/null))
            return $?
        elif command -v docker-compose >/dev/null 2>&1; then
            (cd "$PANEL_DIR" && (docker-compose up -d --no-deps pasarguard 2>/dev/null || docker-compose restart pasarguard 2>/dev/null || docker-compose restart 2>/dev/null))
            return $?
        fi
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
    local TARGET="${1:-both}"
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
    if [ "$TARGET" = "classic" ]; then
        echo -e "${YELLOW}   INSTALL / UPDATE MRM CLASSIC (قالب کلاسیک)   ${NC}"
    elif [ "$TARGET" = "special" ]; then
        echo -e "${YELLOW}   INSTALL / UPDATE MRM SPECIAL (قالب ویژه)     ${NC}"
    else
        echo -e "${YELLOW}      THEME INSTALLATION WIZARD              ${NC}"
    fi
    echo -e "${CYAN}=============================================${NC}"

    # ✅ تشخیص مجدد پنل برای اطمینان
    detect_active_panel > /dev/null

    # Re-resolve download URLs at use time — the exported vars freeze the version
    # seen when utils.sh was sourced (the updater sources utils.sh before
    # installing the new VERSION file → downloads pinned to the previous tag,
    # e.g. v1.3.1 while running v1.4.x).
    THEME_HTML_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/v$(get_mrm_version)/templates/subscription/index.html"
    THEME_CLASSIC_HTML_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/v$(get_mrm_version)/templates/subscription-classic/index.html"

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
    echo -e "${BLUE}MRM Classic:    $CLASSIC_FILE${NC}"

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
        echo -e "${GREEN}✔ Found local MRM Classic source. Using it.${NC}"
    else
        echo -e "${BLUE}Downloading MRM Classic template...${NC}"
        echo -e "${BLUE}URL: $THEME_CLASSIC_HTML_URL${NC}"
        if curl -sL -f -o "$CLASSIC_DL" "$THEME_CLASSIC_HTML_URL" 2>/dev/null && ! grep -q "404: Not Found" "$CLASSIC_DL" 2>/dev/null; then
            echo -e "${GREEN}✔ MRM Classic template downloaded.${NC}"
        else
            echo -e "${YELLOW}⚠ MRM Classic download failed — continuing with MRM Special only.${NC}"
            rm -f "$CLASSIC_DL"
        fi
    fi

    # 3. Processing
    echo -e "${BLUE}Processing configuration...${NC}"

    export OLD_FILE
    export NEW_FILE="$TEMP_DL"
    export FINAL_FILE="$TEMPLATE_FILE"
    export SPECIAL_FINAL_FILE="$DATA_DIR/templates/subscription-special/index.html"
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
pairs = []
new_file = os.environ.get('NEW_FILE')
final_file = os.environ.get('FINAL_FILE')
special_final = os.environ.get('SPECIAL_FINAL_FILE')
if new_file and final_file and os.path.isfile(new_file):
    pairs.append((new_file, final_file))
if new_file and special_final and os.path.isfile(new_file):
    pairs.append((new_file, special_final))

classic_new = os.environ.get('CLASSIC_NEW_FILE')
classic_final = os.environ.get('CLASSIC_FINAL_FILE')
if classic_new and classic_final and os.path.isfile(classic_new):
    pairs.append((classic_new, classic_final))

if not pairs:
    print('No template source files found to install.')
    sys.exit(1)

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


def clean_brand(value):
    # Title format is "<brand> · {{ user.username }}". Earlier releases stored
    # the whole title as the brand default and appended the suffix again on
    # every run ("FarsNet · {{ user.username }} · {{ user.username }}"). Strip
    # template expressions + trailing separators, however deep the damage.
    value = re.sub(r'\{\{.*?\}\}', ' ', value or '')
    value = re.sub(r'\s+', ' ', value).strip()
    return value.rstrip(' ·|•-–—:')


try:
    with open(old_path, 'r', encoding='utf-8', errors='ignore') as f:
        old_content = f.read()

    m_brand = re.search(r'<title>(.*?)</title>', old_content, re.S | re.I)
    if not m_brand:
        m_brand = re.search(r'class=["\'][^"\']*brand[^"\']*["\'][^>]*>(.*?)<', old_content, re.S | re.I)
    if m_brand:
        brand_value = html.unescape(m_brand.group(1).strip())
        if brand_value and '__BRAND__' not in brand_value:
            brand_value = clean_brand(brand_value)
            if brand_value:
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


new_brand = html.escape(clean_brand(clean_text(get_input('Brand Name', 'brand'), defaults['brand'])), quote=False)
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

    # Persist the entered values for non-interactive template refreshes
    # (theme_redeploy on every 'mrm update').
    try:
        import json as _json, os as _os
        from pathlib import Path as _P
        _d = _P(_os.environ.get('DATA_DIR') or '/var/lib/pasarguard')
        _t = _d / 'theme-settings.json'
        _tmp = _t.with_name(_t.name + '.tmp')
        _tmp.write_text(_json.dumps({'brand': new_brand, 'bot': new_bot, 'sup': new_sup, 'news': new_news}, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
        try:
            _tmp.chmod(0o600)
        except OSError:
            pass
        _tmp.replace(_t)
    except Exception:
        pass

    print(f'\n{GREEN}✔ Settings saved successfully.{NC}')
except Exception as e:
    print(f'\nError processing file: {e}')
    sys.exit(1)
PYEOF

    python3 "$PY_SCRIPT"
    PY_EXIT_CODE=$?
    rm -f "$PY_SCRIPT"

    if [ $PY_EXIT_CODE -eq 0 ]; then
        if [ "$TARGET" = "classic" ] && [ ! -s "$CLASSIC_FILE" ]; then
            echo -e "${RED}✘ MRM Classic file is empty!${NC}"
            rm -rf "$TMP_DIR"
            pause; return
        elif [ "$TARGET" != "classic" ] && [ ! -s "$TEMPLATE_FILE" ]; then
            echo -e "${RED}✘ Template file is empty!${NC}"
            rm -rf "$TMP_DIR"
            pause; return
        fi

        echo ""
        echo -e "${CYAN}=== Final Configuration ===${NC}"
        echo -e "MRM Special  : $TEMPLATE_FILE ($(stat -c%s "$TEMPLATE_FILE" 2>/dev/null) bytes)"
        echo -e "MRM Classic  : $CLASSIC_FILE ($(stat -c%s "$CLASSIC_FILE" 2>/dev/null || echo 0) bytes)"
        echo ""

        local active_choice="special"
        if [ "$TARGET" = "classic" ]; then
            active_choice="classic"
        elif [ "$TARGET" = "special" ]; then
            active_choice="special"
        else
            active_choice="$(theme_current_template)"
            [ "$active_choice" = "none" ] && active_choice="special"
        fi

        echo -e "${BLUE}Activating $(theme_template_display_name "$active_choice") + restarting panel...${NC}"
        if theme_set_template "$active_choice"; then
            echo -e "${GREEN}✔ Template installed & panel restarted.${NC}"
            echo -e "${GREEN}  (Switch anytime in panel → Settings → MRM)${NC}"
        else
            echo -e "${YELLOW}⚠ Template installed, but activation failed.${NC}"
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
    if [ -s "$DATA_DIR/templates/subscription-special/index.html" ] || { [ -s "$sp" ] && ! grep -q "guideBanner" "$sp" 2>/dev/null; }; then
        echo -e "MRM Special     : ${GREEN}●${NC} Installed"
    else
        echo -e "MRM Special     : ${RED}○${NC} Not installed"
    fi
    if [ -s "$cl" ]; then
        echo -e "MRM Classic     : ${GREEN}●${NC} Installed"
    else
        echo -e "MRM Classic     : ${RED}○${NC} Not installed"
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
        echo "1) 📦 Install / Update MRM Classic (قالب کلاسیک)"
        echo "2) ✨ Install / Update MRM Special (قالب ویژه)"
        echo "3) 🔛 Template: ON / OFF"
        echo "4) ◆ MRM Special manager"
        echo "5) 🗑️ Uninstall Template"
        echo "0) Back"
        echo -e "${BLUE}===========================================${NC}"
        read -p "Select: " T_OPT
        case $T_OPT in
            1) install_theme_wizard "classic" ;;
            2) install_theme_wizard "special" ;;
            3) theme_toggle ;;
            4) bash /opt/mrm-manager/special.sh || echo "MRM Special could not be started" ;;
            5) uninstall_theme ;;
            0) return ;;
            *) theme_invalid_option ;;
        esac
    done
}

case "${1:-}" in
    --set-template)     shift; theme_set_template "$@"; exit $? ;;
    --redeploy)         theme_redeploy; exit $? ;;
    --current-template) theme_current_template; exit 0 ;;
    --clean-brand)      shift; python3 -c 'import re,sys; v=re.sub(r"\{\{.*?\}\}"," ",sys.argv[1]); v=re.sub(r"\s+"," ",v).strip(); print(v.rstrip(" ·|•-–—:"))' "${1:-}"; exit $? ;;
esac

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    theme_menu
fi
