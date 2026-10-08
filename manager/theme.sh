#!/bin/bash
# MRM Manager theme.sh — subscription page templates (MRM Classic / MRM Special)

# ─── Shared libraries ────────────────────────────────────────────────────────
# utils.sh must load whenever its functions are missing — a parent process may
# export PANEL_DIR while bash functions do not cross the process boundary
# (standalone runs from install/update used to hit "command not found").
MRM_DIR="${MRM_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)}"
[ -r "$MRM_DIR/utils.sh" ] || MRM_DIR="/opt/mrm-manager"
if ! declare -f detect_active_panel >/dev/null 2>&1; then
    for _mrm_utils in "$MRM_DIR/utils.sh" /opt/mrm-manager/utils.sh; do
        # shellcheck source=/dev/null
        [ -r "${_mrm_utils}" ] && { source "${_mrm_utils}"; break; }
    done
    unset _mrm_utils
fi
# shellcheck source=/dev/null
if ! declare -f ui_header >/dev/null 2>&1 && [ -r "$MRM_DIR/ui.sh" ]; then source "$MRM_DIR/ui.sh"; fi
# shellcheck source=/dev/null
if ! declare -f mrm_create_restore_point >/dev/null 2>&1 && [ -r "$MRM_DIR/safe_ops.sh" ]; then source "$MRM_DIR/safe_ops.sh"; fi
# shellcheck source=/dev/null
[ -r "$MRM_DIR/versions.conf" ] && source "$MRM_DIR/versions.conf"
THEME_VERSION="${THEME_VERSION:-2.2.1}"

# Make sure the panel is detected and DATA_DIR is set
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
    ver="$(get_mrm_version 2>/dev/null || cat /opt/mrm-manager/VERSION 2>/dev/null || echo "1.5.12")"
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
    ver="$(get_mrm_version 2>/dev/null || cat /opt/mrm-manager/VERSION 2>/dev/null || echo "1.5.12")"
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
        classic) echo "MRM Classic" ;;
        special) echo "MRM Special" ;;
        *) echo "none" ;;
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
            ui_error "Unknown template '$key' (use: classic | special)"; return 1 ;;
    esac
    detect_active_panel > /dev/null

    if [ -z "$target_src" ] || [ ! -s "$target_src" ]; then
        theme_write_template_status failed "$key" "Template source file missing for $key"
        ui_error "Template source file missing for $key"
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
    ui_success "Active template: $(theme_template_display_name "$key") ($rel)"
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
    [ -s "$DEP_S" ] || [ -s "$DEP_SP" ] || [ -s "$DEP_C" ] || { ui_note "No deployed template yet — install it from: mrm › Theme Manager"; return 0; }
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

        # Note: Do not restart panel on update; hot-injection above already updated running files without downtime.
        ui_success "Deployed templates refreshed (brand, news and selection kept)"
        return 0
    fi
    ui_warning "Template refresh failed"
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
            (cd "$PANEL_DIR" && (docker compose restart panel 2>/dev/null || docker compose restart pasarguard 2>/dev/null || docker compose restart 2>/dev/null))
            return $?
        elif command -v docker-compose >/dev/null 2>&1; then
            (cd "$PANEL_DIR" && (docker-compose restart panel 2>/dev/null || docker-compose restart pasarguard 2>/dev/null || docker-compose restart 2>/dev/null))
            return $?
        fi
    fi

    return 1
}

theme_invalid_option() {
    if declare -f ui_invalid >/dev/null 2>&1; then ui_invalid; else echo "Invalid option"; sleep 1; fi
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

    detect_active_panel > /dev/null
    if [ "$TARGET" = "classic" ]; then
        ui_header "Install / Update MRM Classic" "Data: ${DATA_DIR:-unknown}"
    elif [ "$TARGET" = "special" ]; then
        ui_header "Install / Update MRM Special" "Data: ${DATA_DIR:-unknown}"
    else
        ui_header "Template Installation" "Data: ${DATA_DIR:-unknown}"
    fi

    # Re-resolve download URLs at use time — the exported vars freeze the version
    # seen when utils.sh was sourced (the updater sources utils.sh before
    # installing the new VERSION file → downloads pinned to the previous tag,
    # e.g. v1.3.1 while running v1.4.x).
    THEME_HTML_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/v$(get_mrm_version)/templates/subscription/index.html"
    THEME_CLASSIC_HTML_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/v$(get_mrm_version)/templates/subscription-classic/index.html"

    if ! command -v python3 &> /dev/null; then
        ui_error "python3 is required but not installed"
        pause; return
    fi

    if [ -z "$DATA_DIR" ]; then
        ui_error "DATA_DIR is not set — panel detection failed"
        pause; return
    fi

    TMP_DIR=$(mktemp -d /tmp/mrm-theme.XXXXXX 2>/dev/null)
    if [ -z "$TMP_DIR" ] || [ ! -d "$TMP_DIR" ]; then
        ui_error "Failed to create a temporary workspace"
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
        [ -n "$RESTORE_POINT_ID" ] && ui_note "Restore point: $RESTORE_POINT_ID"
    fi

    mkdir -p "$TEMPLATE_DIR" "$(dirname "$CLASSIC_FILE")"

    ui_kv "MRM Special" "$TEMPLATE_FILE"
    ui_kv "MRM Classic" "$CLASSIC_FILE"
    echo ""

    # 1. Backup old file
    ui_step 1 3 "Preparing sources"
    if [ -s "$TEMPLATE_FILE" ]; then
        cp "$TEMPLATE_FILE" "$OLD_FILE"
        ui_success "Current template backed up (brand and settings are kept)"
    else
        : > "$OLD_FILE"
    fi

    # 2. Source Selection (Hybrid)
    rm -f "$TEMP_DL"
    LOCAL_TEMPLATE="$(theme_get_local_template 2>/dev/null || true)"

    if [ -n "$LOCAL_TEMPLATE" ]; then
        ui_success "MRM Special source: local copy"
        cp "$LOCAL_TEMPLATE" "$TEMP_DL"
    else
        ui_task "Downloading MRM Special from GitHub"
        if curl -sL -f -o "$TEMP_DL" "$THEME_HTML_URL" 2>/dev/null; then
            if grep -q "404: Not Found" "$TEMP_DL" 2>/dev/null; then
                ui_task_done bad "404"
                ui_note "URL: $THEME_HTML_URL"
                rm -rf "$TMP_DIR"
                pause; return
            fi
            ui_task_done ok
        else
            ui_task_done bad
            ui_note "URL: $THEME_HTML_URL"
            rm -rf "$TMP_DIR"
            pause; return
        fi
    fi

    FILE_SIZE=$(stat -c%s "$TEMP_DL" 2>/dev/null || echo "0")
    if [ "$FILE_SIZE" -lt 1000 ]; then
        ui_error "Template file is too small ($FILE_SIZE bytes) — download is broken"
        rm -rf "$TMP_DIR"
        pause; return
    fi

    # 2b. Classic template (both templates always install together)
    rm -f "$CLASSIC_DL"
    CLASSIC_LOCAL="$(theme_get_local_classic_template 2>/dev/null || true)"
    if [ -n "$CLASSIC_LOCAL" ]; then
        cp "$CLASSIC_LOCAL" "$CLASSIC_DL"
        ui_success "MRM Classic source: local copy"
    else
        ui_task "Downloading MRM Classic from GitHub"
        if curl -sL -f -o "$CLASSIC_DL" "$THEME_CLASSIC_HTML_URL" 2>/dev/null && ! grep -q "404: Not Found" "$CLASSIC_DL" 2>/dev/null; then
            ui_task_done ok
        else
            ui_task_done warn "skipped — continuing with MRM Special only"
            rm -f "$CLASSIC_DL"
        fi
    fi

    # 3. Processing
    ui_step 2 3 "Applying brand settings and deploying"

    export OLD_FILE
    export NEW_FILE="$TEMP_DL"
    export FINAL_FILE="$TEMPLATE_FILE"
    export SPECIAL_FINAL_FILE="$DATA_DIR/templates/subscription-special/index.html"
    export CLASSIC_NEW_FILE="$CLASSIC_DL"
    export CLASSIC_FINAL_FILE="$CLASSIC_FILE"
    # Hand the active ui.sh palette to the interactive Python step (same look)
    export MRM_PY_ACCENT MRM_PY_MUTED MRM_PY_OK MRM_PY_ERR MRM_PY_TEXT MRM_PY_TITLE MRM_PY_FRAME MRM_PY_NC
    printf -v MRM_PY_ACCENT '%b' "$UI_C_ACCENT"; printf -v MRM_PY_MUTED '%b' "$UI_C_MUTED"
    printf -v MRM_PY_OK '%b' "$UI_C_OK";         printf -v MRM_PY_ERR '%b' "$UI_C_ERR"
    printf -v MRM_PY_TEXT '%b' "$UI_C_TEXT";     printf -v MRM_PY_TITLE '%b' "$UI_C_TITLE"
    printf -v MRM_PY_FRAME '%b' "$UI_C_FRAME";   printf -v MRM_PY_NC '%b' "$NC"

    cat > "$PY_SCRIPT" << 'PYEOF'
import html
import os
import re
import sys

ACCENT = os.environ.get('MRM_PY_ACCENT', '')
MUTED = os.environ.get('MRM_PY_MUTED', '')
OK = os.environ.get('MRM_PY_OK', '')
ERR = os.environ.get('MRM_PY_ERR', '')
TEXT = os.environ.get('MRM_PY_TEXT', '')
TITLE = os.environ.get('MRM_PY_TITLE', '')
FRAME = os.environ.get('MRM_PY_FRAME', '')
NC = os.environ.get('MRM_PY_NC', '')

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

print(f"\n  {FRAME}──{NC} {TITLE}Theme Settings{NC} {FRAME}{'─' * 50}{NC}")
print(f'  {MUTED}Press Enter to keep the current value shown in brackets.{NC}\n')


def get_input(label, key):
    try:
        val = input(f'  {ACCENT}›{NC} {TEXT}{label}{NC} {MUTED}[{defaults[key]}]{NC}{TEXT}:{NC} ').strip()
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

        # The per-template directories (subscription-special/, subscription-classic/)
        # may not exist yet on a fresh data dir — create them instead of failing.
        os.makedirs(os.path.dirname(final_path) or '.', exist_ok=True)
        with open(final_path, 'w', encoding='utf-8') as f:
            f.write(content)
        print(f'  {OK}✔{NC} {TEXT}Written: {final_path}{NC}')

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

    print(f'\n  {OK}✔{NC} {TEXT}Settings saved successfully.{NC}')
except Exception as e:
    print(f'\n  {ERR}✘{NC} {TEXT}Error processing file: {e}{NC}', file=sys.stderr)
    sys.exit(1)
PYEOF

    python3 "$PY_SCRIPT"
    PY_EXIT_CODE=$?
    rm -f "$PY_SCRIPT"

    if [ $PY_EXIT_CODE -eq 0 ]; then
        if [ "$TARGET" = "classic" ] && [ ! -s "$CLASSIC_FILE" ]; then
            ui_error "MRM Classic file is empty after processing"
            rm -rf "$TMP_DIR"
            pause; return
        elif [ "$TARGET" != "classic" ] && [ ! -s "$TEMPLATE_FILE" ]; then
            ui_error "Template file is empty after processing"
            rm -rf "$TMP_DIR"
            pause; return
        fi

        echo ""
        ui_step 3 3 "Activating and Finalizing Integration"

        # In-panel integration + systemd watchers (unified setup)
        ui_task "Setting up in-panel manager & watchers"
        if [ -x "$MRM_DIR/special.sh" ]; then
            bash "$MRM_DIR/special.sh" --install-quiet >/dev/null 2>&1 || true
            ui_task_done ok
        else
            ui_task_done warn "skipped"
        fi

        local active_choice="special"
        if [ "$TARGET" = "classic" ]; then
            active_choice="classic"
        elif [ "$TARGET" = "special" ]; then
            active_choice="special"
        else
            echo ""
            ui_section "Active Template"
            ui_text "Choose which template should be active right now:"
            echo "  1) MRM Special (قالب ویژه) [Default]"
            echo "  2) MRM Classic (قالب کلاسیک)"
            local choice_raw
            ui_ask "Select template [1-2]" "1" choice_raw
            case "$choice_raw" in
                2) active_choice="classic" ;;
                *) active_choice="special" ;;
            esac
        fi

        ui_note "Activating $(theme_template_display_name "$active_choice") and restarting the panel…"
        if theme_set_template "$active_choice" >/dev/null; then
            echo ""
            ui_box_start ok "Templates installed and configured"
            ui_box_line "Active" "$(theme_template_display_name "$active_choice")"
            ui_box_line "MRM Special" "$TEMPLATE_FILE"
            ui_box_line "MRM Classic" "$CLASSIC_FILE"
            ui_box_line "In-Panel MRM" "Settings › MRM tab"
            ui_box_line "Size" "special $(du -h "$TEMPLATE_FILE" 2>/dev/null | cut -f1 || echo '?') · classic $(du -h "$CLASSIC_FILE" 2>/dev/null | cut -f1 || echo '?')"
            ui_box_end
            ui_note "Switch templates any time in the panel: Settings › MRM or from Theme Manager."
        else
            ui_warning "Template installed, but activation failed — use 'Template on / off' from the menu"
        fi
        rm -rf "$TMP_DIR"
    else
        ui_error "Template processing failed (python step)"
        rm -rf "$TMP_DIR"
    fi
    pause
}

activate_theme() {
    detect_active_panel > /dev/null
    ui_header "Activate Template"

    local T_FILE="$DATA_DIR/templates/subscription/index.html"
    if [ ! -s "$T_FILE" ]; then
        ui_error "Template file missing or empty — install it first"
        ui_note "Expected: $T_FILE"
        pause; return
    fi

    if declare -f mrm_create_restore_point >/dev/null 2>&1; then
        local RESTORE_POINT_ID
        RESTORE_POINT_ID="$(mrm_create_restore_point "theme-activate" "panel" "$PANEL_ENV" "$DATA_DIR/templates/subscription")"
        [ -n "$RESTORE_POINT_ID" ] && ui_note "Restore point: $RESTORE_POINT_ID"
    fi

    if ! theme_apply_env; then
        ui_error "Failed to update the panel .env"
        pause; return
    fi

    if theme_restart_panel; then
        ui_success "Template activated"
    else
        ui_warning "Template activated, but the panel restart failed — restart it manually"
    fi
    pause
}

deactivate_theme() {
    detect_active_panel > /dev/null
    ui_header "Deactivate Template"

    if [ -f "$PANEL_ENV" ]; then
        if declare -f mrm_create_restore_point >/dev/null 2>&1; then
            local RESTORE_POINT_ID
            RESTORE_POINT_ID="$(mrm_create_restore_point "theme-deactivate" "panel" "$PANEL_ENV" "$DATA_DIR/templates/subscription")"
            [ -n "$RESTORE_POINT_ID" ] && ui_note "Restore point: $RESTORE_POINT_ID"
        fi

        if ! theme_clear_env; then
            ui_error "Failed to remove the template settings from the panel .env"
            pause; return
        fi
        if theme_restart_panel; then
            ui_success "Template deactivated — the PasarGuard default page is back"
        else
            ui_warning "Template deactivated, but the panel restart failed — restart it manually"
        fi
    else
        ui_warning "Panel .env not found"
    fi
    pause
}

uninstall_theme() {
    detect_active_panel > /dev/null
    ui_header "Uninstall Template"
    ui_text "Removes the deployed template files and switches the panel back to its default page."
    ui_bullet "$DATA_DIR/templates/subscription"
    ui_bullet "$DATA_DIR/templates/subscription-classic"
    echo ""
    if ui_confirm "Delete the template files?"; then
        if declare -f mrm_create_restore_point >/dev/null 2>&1; then
            local RESTORE_POINT_ID
            RESTORE_POINT_ID="$(mrm_create_restore_point "theme-uninstall" "panel" "$PANEL_ENV" "$DATA_DIR/templates/subscription")"
            [ -n "$RESTORE_POINT_ID" ] && ui_note "Restore point: $RESTORE_POINT_ID"
        fi

        rm -rf "$DATA_DIR/templates/subscription" "$DATA_DIR/templates/subscription-classic"
        rm -f "$(theme_mrm_data_dir)/template-status.json"
        if [ -f "$PANEL_ENV" ]; then
            if ! theme_clear_env; then
                ui_error "Failed to remove the template settings from the panel .env"
                pause; return
            fi
            if theme_restart_panel; then
                ui_success "Template removed and deactivated"
            else
                ui_warning "Template removed, but the panel restart failed — restart it manually"
            fi
        else
            ui_success "Template files removed"
        fi
    else
        ui_cancelled
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
    local cur sp cl
    cur="$(theme_current_template)"
    sp="$DATA_DIR/templates/subscription/index.html"
    cl="$DATA_DIR/templates/subscription-classic/index.html"
    if is_theme_active; then
        ui_kv_state "Template" ok "On" "active: $(theme_template_display_name "$cur")"
    else
        ui_kv_state "Template" off "Off" "PasarGuard default page"
    fi
    if [ -s "$DATA_DIR/templates/subscription-special/index.html" ] || { [ -s "$sp" ] && ! grep -q "guideBanner" "$sp" 2>/dev/null; }; then
        ui_kv_state "MRM Special" ok "Installed"
    else
        ui_kv_state "MRM Special" off "Not installed"
    fi
    if [ -s "$cl" ]; then
        ui_kv_state "MRM Classic" ok "Installed"
    else
        ui_kv_state "MRM Classic" off "Not installed"
    fi
}

theme_conflicts_label() {
    # Informational only — MRM never removes other products.
    if bash "$MRM_DIR/special.sh" --detect-quiet 2>/dev/null; then
        ui_kv_state "Other" warn "Another integration present" "left untouched"
    fi
}

theme_toggle() {
    detect_active_panel > /dev/null
    ui_header "Template On / Off"
    if is_theme_active; then
        ui_kv_state "Template" ok "On" "active: $(theme_template_display_name "$(theme_current_template)")"
        echo ""
        ui_confirm "Turn it off (show the PasarGuard default page)?" || return
        if theme_clear_env && theme_restart_panel; then
            ui_success "Template is now off"
        else
            ui_error "Could not turn the template off"
        fi
    else
        if [ ! -s "$DATA_DIR/templates/subscription/index.html" ] && [ ! -s "$DATA_DIR/templates/subscription-classic/index.html" ]; then
            ui_warning "No template installed yet — install MRM Classic or MRM Special first."
            pause; return
        fi
        ui_kv_state "Template" off "Off"
        echo ""
        ui_confirm "Turn it on?" y || return
        local cur
        cur="$(theme_current_template)"
        [ "$cur" = "none" ] && cur="special"
        if theme_set_template "$cur" >/dev/null; then
            ui_success "Template is now on (active: $(theme_template_display_name "$cur"))"
        else
            ui_error "Could not activate the template"
        fi
    fi
    pause
}

theme_select_active_menu() {
    detect_active_panel > /dev/null
    ui_header "Switch Active Template"
    local cur
    cur="$(theme_current_template)"
    ui_kv_state "Current active" ok "$(theme_template_display_name "$cur")"
    echo ""
    ui_menu_item 1 "MRM Special (قالب ویژه)" "Modern turquoise design with Direct Connect"
    ui_menu_item 2 "MRM Classic (قالب کلاسیک)" "Lightweight classic subscription page"
    ui_menu_back
    local sel
    ui_select sel
    case "$sel" in
        1) theme_set_template "special"; pause ;;
        2) theme_set_template "classic"; pause ;;
        0) return ;;
        *) theme_invalid_option ;;
    esac
}

theme_status_menu() {
    if [ -x "$MRM_DIR/special.sh" ]; then
        bash "$MRM_DIR/special.sh" --status
    else
        ui_header "Theme Status"
        theme_templates_status
        theme_conflicts_label
        pause
    fi
}

theme_menu() {
    local T_OPT
    while true; do
        detect_active_panel > /dev/null
        ui_header "Theme Manager" "Panel: ${PANEL_DIR:-unknown} · Data: ${DATA_DIR:-unknown}"
        theme_templates_status
        theme_conflicts_label
        echo ""
        ui_note "Both templates stay installed; one is shown at a time. Switch in the panel: Settings › MRM."
        echo ""
        ui_menu_item 1 "Install / Update Templates" "MRM Special & MRM Classic + panel integration"
        ui_menu_item 2 "Switch Active Template" "MRM Special ⇄ MRM Classic"
        ui_menu_item 3 "Template on / off" "Master switch"
        ui_menu_item 4 "Status & Diagnostics" "Check files, panel hooks and watchers"
        ui_menu_item 5 "Uninstall templates"
        ui_menu_back
        ui_select T_OPT
        case $T_OPT in
            1) install_theme_wizard "both" ;;
            2) theme_select_active_menu ;;
            3) theme_toggle ;;
            4) theme_status_menu ;;
            5) uninstall_theme ;;
            0) return ;;
            *) theme_invalid_option ;;
        esac
    done
}

case "${1:-}" in
    switch|--set-template) shift; theme_set_template "$@"; exit $? ;;
    redeploy|--redeploy)   theme_redeploy; exit $? ;;
    status|--status)       theme_status_menu; exit 0 ;;
    current|--current-template) theme_current_template; exit 0 ;;
    --clean-brand)         shift; python3 -c 'import re,sys; v=re.sub(r"\{\{.*?\}\}"," ",sys.argv[1]); v=re.sub(r"\s+"," ",v).strip(); print(v.rstrip(" ·|•-–—:"))' "${1:-}"; exit $? ;;
esac

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    theme_menu
fi
