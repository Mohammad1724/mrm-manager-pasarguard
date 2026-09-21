#!/bin/bash
# MRM Special — PasarGuard panel integration (Settings tab + subscription runtime)
# Part of the MRM Theme module family. Manages the two-layer integration:
#   1) Subscription runtime  → x-mrm-* headers control the subscription page
#   2) "MRM · Special" tab   → in-panel settings editor (GET/PUT /api/settings)
#
# Owned files (safe to remove on uninstall):
#   /var/lib/pasarguard/mrm/                     namespace data (updates, profiles)
#   /etc/systemd/system/mrm-*.{path,service,timer}
#   <dashboard>/statics/mrm-special.js           admin control plane
#   injected markers in template/dashboard HTML  (mrm-runtime-inline,
#                                                mrm-special-loader,
#                                                mrm-pasarguard-theme-guard)

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi
if ! declare -f ui_header >/dev/null 2>&1 && [ -r /opt/mrm-manager/ui.sh ]; then source /opt/mrm-manager/ui.sh; fi
if ! declare -f mrm_create_restore_point >/dev/null 2>&1 && [ -r /opt/mrm-manager/safe_ops.sh ]; then source /opt/mrm-manager/safe_ops.sh; fi
[ -r "/opt/mrm-manager/versions.conf" ] && source /opt/mrm-manager/versions.conf

SPECIAL_VERSION="1.0.0"
MRM_ROOT="${MRM_ROOT:-/opt/mrm-manager}"
PLUGIN_DIR="${MRM_ROOT}/plugin"
DATA_NS="${MRM_DATA_DIR:-/var/lib/pasarguard/mrm}"
INTEGRATE="${PLUGIN_DIR}/integrate-dashboard.sh"
SUB_TEMPLATE="${SUB_TEMPLATE:-/var/lib/pasarguard/templates/subscription/index.html}"
MARKER_RUNTIME="mrm-runtime-inline"
MARKER_ADMIN="mrm-special-loader"
MARKER_THEME="mrm-pasarguard-theme-guard"
ROUTER_MARKER="mrm-admin-subscriptions"
UNITS=(mrm-integrator.service mrm-integrator.path mrm-panel-update.path)

detect_active_panel > /dev/null 2>&1 || true

special_pause() { read -r -p "Press Enter..." _; }

special_ok()   { echo -e " ${GREEN}●${NC} $1"; }
special_miss() { echo -e " ${RED}○${NC} $1"; }

special_find_dashboard_build() {
    local candidate
    for candidate in \
        "${PASARGUARD_ROOT}/dashboard/build" \
        "${PASARGUARD_ROOT}/panel/dashboard/build" \
        "${PANEL_DIR}/dashboard/build"
    do
        if [ -f "${candidate}/index.html" ]; then printf '%s\n' "${candidate}"; return 0; fi
    done
    return 1
}

special_container_id() {
    local cid
    cid="$(docker ps -q --filter "ancestor=pasarguard/panel" 2>/dev/null | head -1)"
    [ -z "${cid}" ] && cid="$(docker ps --format '{{.ID}} {{.Image}}' 2>/dev/null | awk '/pasarguard\/panel/ {print $1; exit}')"
    [ -n "${cid}" ] && printf '%s\n' "${cid}"
}

# ─── Status ─────────────────────────────────────────────────────────────────

special_status() {
    clear
    echo -e "${BLUE}===========================================${NC}"
    echo -e "${YELLOW}   ◆ MRM SPECIAL — Panel Integration v${SPECIAL_VERSION}${NC}"
    echo -e "${BLUE}===========================================${NC}"
    echo "Panel: ${CYAN}${PANEL_DIR:-unknown}${NC}"
    echo "Data:  ${CYAN}${DATA_DIR:-unknown}${NC}"
    echo ""

    if [ -s "${SUB_TEMPLATE}" ]; then
        if grep -q "${MARKER_RUNTIME}" "${SUB_TEMPLATE}" 2>/dev/null; then
            special_ok "Subscription runtime injected (x-mrm-* active)"
        else
            special_miss "Subscription template found but runtime NOT injected"
        fi
    else
        special_miss "Subscription template not installed (Theme Manager → Install first)"
    fi

    local build_dir
    build_dir="$(special_find_dashboard_build || true)"
    if [ -n "${build_dir}" ] && grep -q "${MARKER_ADMIN}" "${build_dir}/index.html" 2>/dev/null; then
        special_ok "Dashboard tab \"MRM · Special\" present (${build_dir})"
    else
        local cid
        cid="$(special_container_id || true)"
        if [ -n "${cid}" ] && docker exec "${cid}" sh -c 'grep -qs "mrm-special-loader" /code/dashboard/build/index.html /app/dashboard/build/index.html 2>/dev/null'; then
            special_ok "Dashboard tab \"MRM · Special\" present (inside container)"
        else
            special_miss "Dashboard tab not injected"
        fi
    fi

    if systemctl is-active --quiet mrm-integrator.service 2>/dev/null; then
        special_ok "Reintegration guard (mrm-integrator.service) active"
    else
        special_miss "Reintegration guard not running (survives panel upgrades without it)"
    fi

    if systemctl is-enabled --quiet mrm-integrator.path 2>/dev/null; then
        special_ok "Dashboard build watcher (mrm-integrator.path) enabled"
    else
        special_miss "Dashboard build watcher not enabled"
    fi

    if systemctl is-enabled --quiet mrm-panel-update.path 2>/dev/null; then
        special_ok "In-panel updater bridge (mrm-panel-update.path) enabled"
    else
        special_miss "In-panel updater bridge not enabled"
    fi

    echo ""
}

# ─── Install / Repair ───────────────────────────────────────────────────────

special_install_units() {
    local unit
    for unit in "${UNITS[@]}"; do
        if [ ! -f "${PLUGIN_DIR}/${unit}" ]; then
            echo -e "${RED}✘ Missing unit source: ${PLUGIN_DIR}/${unit}${NC}"
            return 1
        fi
        install -m 0644 "${PLUGIN_DIR}/${unit}" "/etc/systemd/system/${unit}"
    done
    systemctl daemon-reload
    systemctl enable --now mrm-integrator.service mrm-integrator.path mrm-panel-update.path >/dev/null 2>&1
    echo -e " ${GREEN}✔${NC} systemd guard, watcher and updater bridge installed"
}

special_install() {
    clear
    echo -e "${BLUE}=== ◆ Install / Repair MRM Special Integration ===${NC}"
    echo ""

    if [ ! -x "${INTEGRATE}" ]; then
        echo -e "${RED}✘ integrate-dashboard.sh not found at ${INTEGRATE}${NC}"
        echo -e "${YELLOW}  Reinstall MRM (mrm update) to fetch plugin files.${NC}"
        special_pause; return
    fi

    # Restore point over everything the integration touches
    if declare -f mrm_create_restore_point >/dev/null 2>&1; then
        local RESTORE_POINT_ID
        RESTORE_POINT_ID="$(mrm_create_restore_point "special-install" "panel" \
            "${SUB_TEMPLATE}" "${DATA_NS}" 2>/dev/null || true)"
        [ -n "${RESTORE_POINT_ID}" ] && echo -e "${GREEN}Restore point:${NC} ${RESTORE_POINT_ID}"
    fi

    mkdir -p "${DATA_NS}"
    chmod 700 "${DATA_NS}" 2>/dev/null

    echo -e "${CYAN}[1/2] Installing systemd units...${NC}"
    special_install_units || { special_pause; return; }

    echo -e "${CYAN}[2/2] Running dashboard integration...${NC}"
    if MRM_ROOT="${MRM_ROOT}" bash "${INTEGRATE}"; then
        echo ""
        echo -e "${GREEN}✔ MRM Special integration is healthy.${NC}"
        echo -e "${YELLOW}Note:${NC} /api/mrm/* routes activate after the next normal panel start"
        echo -e "     (Panel Control → Restart Panel). The Settings tab itself works now."
    else
        echo ""
        echo -e "${YELLOW}⚠ Integration partially applied — the guard will keep retrying automatically.${NC}"
        echo -e "  (PasarGuard container/dashboard may not be built yet.)"
    fi
    special_pause
}

special_reintegrate() {
    clear
    echo -e "${BLUE}=== ◆ Re-run Integration (self-heal) ===${NC}"
    if [ -x "${INTEGRATE}" ]; then
        MRM_ROOT="${MRM_ROOT}" bash "${INTEGRATE}"
    else
        echo -e "${RED}✘ integrate-dashboard.sh missing${NC}"
    fi
    special_pause
}

# ─── Uninstall ──────────────────────────────────────────────────────────────

special_strip_markers() {
    # $1 = html file (host path). Removes every MRM-injected marker block.
    [ -f "$1" ] || return 0
    python3 - "$1" "${MARKER_RUNTIME}" "${MARKER_ADMIN}" "${MARKER_THEME}" <<'PY'
from pathlib import Path
import re, sys
path = Path(sys.argv[1])
m_runtime, m_admin, m_theme = sys.argv[2], sys.argv[3], sys.argv[4]
original = path.read_text(encoding='utf-8')
html = original
html = re.sub(rf'\s*<script id="{re.escape(m_runtime)}">.*?</script>\s*', '\n', html, flags=re.S)
html = re.sub(rf'\s*<script\s+id="{re.escape(m_admin)}"[^>]*>\s*</script>\s*', '\n', html, flags=re.I)
html = re.sub(rf'\s*<script id="{re.escape(m_theme)}">.*?</script>\s*', '\n', html, flags=re.S)
if html != original:
    path.write_text(html, encoding='utf-8')
    print(f'  cleaned: {path}')
PY
}

special_revert_router() {
    # $1 = app/routers/__init__.py (host path)
    [ -f "$1" ] || return 0
    python3 - "$1" "${ROUTER_MARKER}" <<'PY'
from pathlib import Path
import re, sys
path = Path(sys.argv[1]); marker = sys.argv[2]
original = path.read_text(encoding='utf-8'); text = original
text = re.sub(rf'\n?# {re.escape(marker)}-start.*?# {re.escape(marker)}-end\n?', '\n', text, flags=re.S)
text = text.replace(
    'for router in (([mrm_admin_subscriptions.router] if mrm_admin_subscriptions else []) + routers):',
    'for router in routers:')
if text != original:
    path.write_text(text, encoding='utf-8')
    print(f'  cleaned: {path}')
PY
    rm -f "$(dirname "$1")/mrm_admin_subscriptions.py"
}

special_uninstall() {
    clear
    echo -e "${BLUE}=== ◆ Remove MRM Special Integration ===${NC}"
    echo "Removes: Settings tab, subscription runtime hooks, guard units."
    echo "Your theme template itself is kept (use Theme Manager to remove it)."
    echo ""
    read -r -p "Type REMOVE to confirm: " C
    [ "${C}" != "REMOVE" ] && { echo "Cancelled."; special_pause; return; }

    if declare -f mrm_create_restore_point >/dev/null 2>&1; then
        local RESTORE_POINT_ID
        RESTORE_POINT_ID="$(mrm_create_restore_point "special-uninstall" "panel" \
            "${SUB_TEMPLATE}" "${DATA_NS}" 2>/dev/null || true)"
        [ -n "${RESTORE_POINT_ID}" ] && echo -e "${GREEN}Restore point:${NC} ${RESTORE_POINT_ID}"
    fi

    echo -e "${CYAN}[1/4] Stopping systemd units...${NC}"
    systemctl disable --now "${UNITS[@]}" >/dev/null 2>&1
    rm -f /etc/systemd/system/mrm-integrator.service \
          /etc/systemd/system/mrm-integrator.path \
          /etc/systemd/system/mrm-integrator.timer \
          /etc/systemd/system/mrm-panel-update.path \
          /etc/systemd/system/mrm-panel-update.service
    systemctl daemon-reload
    echo -e " ${GREEN}✔${NC} Units removed"

    echo -e "${CYAN}[2/4] Cleaning subscription template hooks...${NC}"
    special_strip_markers "${SUB_TEMPLATE}"

    echo -e "${CYAN}[3/4] Cleaning dashboard tab + backend...${NC}"
    local build_dir cid
    build_dir="$(special_find_dashboard_build || true)"
    if [ -n "${build_dir}" ]; then
        special_strip_markers "${build_dir}/index.html"
        special_strip_markers "${build_dir}/404.html"
        rm -f "${build_dir}/statics/mrm-special.js"
    fi
    for candidate in \
        "${PASARGUARD_ROOT}/app/routers/__init__.py" \
        "${PASARGUARD_ROOT}/panel/app/routers/__init__.py"
    do
        special_revert_router "${candidate}"
    done
    cid="$(special_container_id || true)"
    if [ -n "${cid}" ]; then
        docker exec "${cid}" sh -c 'rm -f /code/dashboard/build/statics/mrm-special.js /app/dashboard/build/statics/mrm-special.js' 2>/dev/null || true
        docker exec "${cid}" sh -c 'rm -f /code/app/routers/mrm_admin_subscriptions.py /app/app/routers/mrm_admin_subscriptions.py' 2>/dev/null || true
        echo -e " ${GREEN}✔${NC} Container leftovers removed (restart panel to unload routes)"
    fi

    echo -e "${CYAN}[4/4] Removing namespace data...${NC}"
    rm -rf "${DATA_NS}"
    echo -e " ${GREEN}✔${NC} Done. Settings tab and runtime are fully detached."
    special_pause
}

special_logs() {
    clear
    echo -e "${BLUE}=== ◆ MRM Special Logs ===${NC}"
    echo ""
    echo "--- integrator (last 40) ---"
    journalctl -u mrm-integrator.service --no-pager -n 40 2>/dev/null || echo "(no logs)"
    echo ""
    echo "--- bootstrap log ---"
    tail -n 40 "${DATA_NS}/bootstrap.log" 2>/dev/null || echo "(no logs yet)"
    echo ""
    special_pause
}

# ─── Menu ───────────────────────────────────────────────────────────────────

special_menu() {
    while true; do
        special_status
        echo "1) 🔌 Install / Repair Integration"
        echo "2) 🔁 Re-run Integration (self-heal now)"
        echo "3) 📜 Logs"
        echo "4) 🗑️  Remove Integration"
        echo ""
        echo "0) ↩️ Back"
        echo -e "${BLUE}===========================================${NC}"
        read -r -p "Select: " S_OPT
        case ${S_OPT} in
            1) special_install ;;
            2) special_reintegrate ;;
            3) special_logs ;;
            4) special_uninstall ;;
            0) return ;;
            *) echo -e "${RED}Invalid option${NC}"; sleep 1 ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    special_menu
fi
