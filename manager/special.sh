#!/usr/bin/env bash
# ============================================================================
# MRM SPECIAL MANAGER — In-Panel Special integration
# ============================================================================
# MRM Manager — Maral Rahmani
# Instagram: https://instagram.com/maral.rahmani.7
# Telegram:  https://t.me/MaralRahmani
#
# Installs "MRM Special" (Zomorod-style feature parity):
#   - subscription runtime hook  (mrm-runtime.js → page JS on /raw)
#   - in-panel settings tab     (mrm-special.js + /api/mrm/profile bridge)
#   - profile storage           (per-admin custom variables — survives updates)
#   - theme CSS injection       (primary/secondary via template theme engine)
#   - systemd watchers          (self-healing: dashboard rebuilds/restarts)
#
# Marker convention (copied from zomorod v2 strategy — the dumbest reliable
# one): every injected string wrapped in literal markers so injection is fully
# idempotent and reversible. DO NOT change without bumping SPECIAL_VERSION and
# keeping legacy markers recognized (legacy imports must stay cleanable).
#
# Data layout:   /var/lib/pasarguard/mrm/
# Profile map:   profiles/profiles.json  (admins.json is created by sitecustomize)
# ============================================================================
SPECIAL_VERSION="1.2.2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/utils.sh"
source "$SCRIPT_DIR/domain_separator.sh"

# --- Patched PasarGuard source tree (via detect_active_panel) ---------------
# Panel Docker integration (optional — used only if the PasarGuard panel runs
# in a Docker container) — copied from zomorod installer.
PASARGUARD_CONTAINER="${PASARGUARD_CONTAINER:-}"
DOCKER_BIN="${DOCKER_BIN:-$(command -v docker 2>/dev/null || true)}"
CONTAINERS=("pasarguard" "pasarguard-panel" "pasarguard-panel-1")

# --- Constants ---------------------------------------------------------------
# The PasarGuard source tree root (host-side checkout that matches the running
# container). Falls back to PANEL_DIR from detect_active_panel.
PASARGUARD_ROOT="${PASARGUARD_ROOT:-${PANEL_DIR:-/opt/pasarguard}}"

# Single source of truth for ALL paths and marker names (mrm-admin-subscriptions.py
# has its own identical copy — keep both in sync when changing).
SPECIAL_DIR="/opt/mrm-manager"
PANEL_DIR="${PANEL_DIR:-/opt/pasarguard}"
BACKEND_PY="$SPECIAL_DIR/plugin"
DATA_NS="/var/lib/pasarguard/mrm"
PROFILES_DIR="$DATA_NS/profiles"
LOG_DIR="/var/log/mrm"
API_ROUTE="/api/mrm/profile"
INTEGRATE="$SPECIAL_DIR/plugin/integrate-dashboard.sh"

# Marker names — injected into target HTML files. The FIRST two MUST match the
# literals inside the python bootstrap snippet (they are searched as raw text);
# the third MUST match the literal inside the theme-guard shell snippet.
MARKER_RUNTIME="mrm-runtime-inline"
MARKER_ADMIN="mrm-special-loader"
MARKER_THEME="mrm-pasarguard-theme-guard"
ROUTER_MARKER="mrm-admin-subscriptions"


SUB_TEMPLATE="$DATA_DIR/templates/subscription/index.html"

UNITS=(mrm-integrator.service mrm-integrator.path mrm-integrator.timer mrm-panel-update.service mrm-panel-update.path mrm-template-switch.service mrm-template-switch.path)
UNIT_SRC="$SPECIAL_DIR/plugin"

special_pause() { read -r -p "Press Enter to continue..." _; }

special_find_dashboard_build() {
    # Host dashboard build (the integrator injects the tab here). Falls back to
    # PANEL_DIR from detect_active_panel, then a bounded find like the
    # integrate-dashboard.sh finder so status sees whatever the integrator found.
    local candidate
    for candidate in \
        "${PASARGUARD_ROOT}/dashboard/build" \
        "${PASARGUARD_ROOT}/panel/dashboard/build" \
        "${PANEL_DIR}/dashboard/build"
    do
        if [ -f "${candidate}/index.html" ]; then printf '%s\n' "${candidate}"; return 0; fi
    done
    if [ -n "${PASARGUARD_ROOT:-}" ] && [ -d "${PASARGUARD_ROOT}" ]; then
        candidate="$(find "${PASARGUARD_ROOT}" -maxdepth 5 -type f -path '*/dashboard/build/index.html' -print -quit 2>/dev/null | sed 's#/index.html$##')"
        [ -n "${candidate}" ] && { printf '%s\n' "${candidate}"; return 0; }
    fi
    return 1
}

special_container_id() {
    local cid
    cid="$(docker ps -q --filter "ancestor=pasarguard/panel" 2>/dev/null | head -1)"
    [ -z "${cid}" ] && cid="$(docker ps --format '{{.ID}} {{.Image}}' 2>/dev/null | awk '/pasarguard\/panel/ {print $1; exit}')"
    [ -n "${cid}" ] && printf '%s\n' "${cid}"
}

# ----------------------------------------------------------------------------
# Templated piped shell scripts (sourced files use ${VAR} which must resolve at
# generation time on the host — DO NOT convert these heredocs to 'quoted' form)
# ----------------------------------------------------------------------------
_generate_units() {
    # Canonical unit set:
    #   mrm-integrator.*      — 60s resource-bounded reconciliation guard
    #   mrm-panel-update.*    — panel→host MRM update bridge (update-from-panel.sh)
    #   mrm-template-switch.* — panel→host template switch bridge
    mkdir -p /etc/systemd/system
    cat > /etc/systemd/system/mrm-integrator.service <<'EOF'
[Unit]
Description=Resource-bounded MRM reconciliation guard for PasarGuard
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash -lc 'set -u; while true; do found=0; if command -v docker >/dev/null 2>&1; then for cid in $(docker ps -q 2>/dev/null); do image=$(docker inspect -f "{{.Config.Image}}" "$cid" 2>/dev/null || true); case "$image" in *pasarguard/panel*) found=1; project=$(docker inspect -f "{{ index .Config.Labels \"com.docker.compose.project\" }}" "$cid" 2>/dev/null || true); [ -n "$project" ] || project=pasarguard; echo "[MRM Guard] reconciling ${cid:0:12} compose-project=$project"; if [ -x /opt/mrm-manager/plugin/integrate-dashboard.sh ]; then PASARGUARD_COMPOSE_PROJECT="$project" /opt/mrm-manager/plugin/integrate-dashboard.sh || true; fi ;; esac; done; fi; if [ "$found" -eq 0 ] && [ -x /opt/mrm-manager/plugin/integrate-dashboard.sh ]; then /opt/mrm-manager/plugin/integrate-dashboard.sh || true; fi; sleep 60; done'
Restart=on-failure
RestartSec=10s
TimeoutStartSec=45s
Nice=10
IOSchedulingClass=idle
CPUAccounting=true
CPUQuota=15%
CPUWeight=10
MemoryAccounting=true
MemoryHigh=128M
MemoryMax=192M
TasksMax=32
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/mrm-integrator.path <<'EOF'
[Unit]
Description=Watch PasarGuard dashboard for MRM reintegration

[Path]
PathChanged=/opt/pasarguard/dashboard/build/index.html
PathChanged=/opt/pasarguard/dashboard/build/404.html
PathChanged=/opt/pasarguard/panel/dashboard/build/index.html
PathChanged=/opt/pasarguard/panel/dashboard/build/404.html
Unit=mrm-integrator.service

[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/mrm-integrator.timer <<'EOF'
[Unit]
Description=Schedule low-impact MRM/PasarGuard reconciliation

[Timer]
OnBootSec=20s
OnUnitInactiveSec=60s
AccuracySec=5s
RandomizedDelaySec=5s
Unit=mrm-integrator.service
Persistent=true

[Install]
WantedBy=timers.target
EOF
    cat > /etc/systemd/system/mrm-panel-update.path <<'EOF'
[Unit]
Description=Watch for MRM panel update requests

[Path]
PathExists=/var/lib/pasarguard/mrm/update-request.json
Unit=mrm-panel-update.service

[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/mrm-panel-update.service <<'EOF'
[Unit]
Description=Apply a MRM update requested from PasarGuard
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/mrm-manager/plugin/update-from-panel.sh
TimeoutStartSec=15min
Nice=5
EOF
    cat > /etc/systemd/system/mrm-template-switch.path <<'EOF'
[Unit]
Description=Watch for MRM template switch requests

[Path]
PathExists=/var/lib/pasarguard/mrm/template-request.json
Unit=mrm-template-switch.service

[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/mrm-template-switch.service <<'EOF'
[Unit]
Description=Apply a subscription-template switch requested from PasarGuard
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/mrm-manager/plugin/mrm-template-switch.sh
TimeoutStartSec=5min
Nice=5
EOF
}

special_install_units() {
    _generate_units
    systemctl daemon-reload
    systemctl enable --now mrm-integrator.service mrm-integrator.timer \
        mrm-panel-update.path mrm-template-switch.path >/dev/null 2>&1
    echo "systemd watchers installed (self-healing + update/template bridges)"
}

special_remove_units() {
    for u in "${UNITS[@]}"; do systemctl disable --now "$u" 2>/dev/null; done
    rm -f /etc/systemd/system/mrm-integrator.{service,path,timer} \
          /etc/systemd/system/mrm-panel-update.{service,path} \
          /etc/systemd/system/mrm-template-switch.{service,path}
    rm -f /usr/local/bin/mrm-integrator /usr/local/bin/mrm-panel-update
    systemctl daemon-reload
}

special_check_requirements() {
    echo "--- Checking Requirements ---"
    if ! command -v python3 >/dev/null 2>&1; then
        echo "python3 not found — aborting"; exit 1
    fi
    [ -s "$SUB_TEMPLATE" ] || {
        echo "Template not found at $SUB_TEMPLATE"
        echo "Install the theme first:  Manager Menu → Theme Manager → 1"
        exit 1
    }
    detect_active_panel || true
    [ -n "$PANEL_DIR" ] && [ -d "$PANEL_DIR" ] || {
        echo "PasarGuard source directory not found (PANEL_DIR='$PANEL_DIR') — aborting"; exit 1
    }
    if [ ! -f "$INTEGRATE" ]; then
        echo "integrate-dashboard.sh not found at $INTEGRATE — aborting"; exit 1
    fi
    mkdir -p "$DATA_NS" "$PROFILES_DIR" "$LOG_DIR"
    echo "OK: python3, template, source tree, data dirs"
    echo ""
}

# --- Injection / stripping (literal-marker based) ----------------------------
# $1=target html file; $2=runtime marker $3=admin marker $4=theme marker
special_strip_markers() {
    [ -n "$1" ] && [ -f "$1" ] || return 0
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
p, m_rt, m_adm, m_thm = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
s = open(p, encoding='utf-8', errors='ignore').read()
o = s
def cut(m, s):
    i = s.find(m)
    if i >= 0:
        j = s.find('</script>', i)
        return s[:i] + s[j+9:] if j >= 0 else s[:i]
    return s
for m in (m_adm, m_rt):
    s = cut(m, s)
i = s.find(m_thm)
if i >= 0:
    j = s.find('</style>', i)
    s = s[:i] + s[j+8:] if j >= 0 else s[:i]
if s != o:
    open(p, 'w', encoding='utf-8').write(s)
    print(f"  stripped markers from {p}")
PY
}

# Container variant of the strip above (used by the competing-integration
# cleaner; runs the same python inside the container).
special_strip_markers_container() {
    local cid="$1" file="$2" m_rt="$3" m_adm="$4" m_thm="$5"
    docker exec -i "$cid" python3 - "$file" "$m_rt" "$m_adm" "$m_thm" <<'PY' 2>/dev/null
import sys
p, m_rt, m_adm, m_thm = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    s = open(p, encoding='utf-8', errors='ignore').read()
except OSError:
    sys.exit(0)
o = s
def cut(m, s):
    i = s.find(m)
    if i >= 0:
        j = s.find('</script>', i)
        return s[:i] + s[j+9:] if j >= 0 else s[:i]
    return s
for m in (m_adm, m_rt):
    s = cut(m, s)
i = s.find(m_thm)
if i >= 0:
    j = s.find('</style>', i)
    s = s[:i] + s[j+8:] if j >= 0 else s[:i]
if s != o:
    open(p, 'w', encoding='utf-8').write(s)
PY
}

# $1=__init__.py  $2=router marker  $3=router py filename
special_revert_router() {
    local file="$1" marker="$2" pyname="$3"
    [ -n "$file" ] && [ -f "$file" ] || return 0
    python3 - "$file" "$marker" <<'PY'
import sys
p, mk = sys.argv[1], sys.argv[2]
s = open(p, encoding='utf-8', errors='ignore').read()
o = s
i = s.find(mk)
while i >= 0:
    j = s.find('\n', i)
    s = s[:i] + s[j+1:] if j >= 0 else s[:i]
    i = s.find(mk)
if s != o:
    open(p, 'w', encoding='utf-8').write(s)
    print(f"  reverted router patch: {p}")
PY
    rm -f "$(dirname "$file")/$pyname"
}

special_competing_present() {
    # Informational only — MRM never removes other products.
    local u
    for u in zomorod-integrator.service zomorod-integrator.path zomorod-panel-update.service zomorod-panel-update.path; do
        [ -f "/etc/systemd/system/$u" ] && return 0
    done
    [ -d /opt/zomorod ] && return 0
    [ -d /var/lib/pasarguard/zomorod ] && return 0
    [ -s "$SUB_TEMPLATE" ] && grep -qs "zomorod-runtime-inline" "$SUB_TEMPLATE" && return 0
    local bd
    bd="$(special_find_dashboard_build || true)"
    [ -n "$bd" ] && grep -qs "zomorod-special-loader" "$bd/index.html" 2>/dev/null && return 0
    return 1
}

# ----------------------------------------------------------------------------
special_install() {
    clear
    echo -e "${CYAN}=== Install MRM Special (in-panel settings) ===${NC}"
    echo ""
    detect_active_panel >/dev/null 2>&1
    special_check_requirements

    # 1) data namespace + default profiles map
    echo "[1/5] data namespace…"
    mkdir -p "$PROFILES_DIR"
    if [ ! -s "$PROFILES_DIR/profiles.json" ]; then
        cat > "$PROFILES_DIR/profiles.json" <<'EOF'
{
  "version": 1,
  "admins": {}
}
EOF
    fi
    chmod 644 "$PROFILES_DIR/profiles.json"
    chown -R nobody:nogroup "$DATA_NS" 2>/dev/null
    echo "  $PROFILES_DIR/profiles.json ready"

    # 2) backend bridge (python dir — downloaded as PLUGIN module)
    echo "[2/5] backend bridge…"
    mkdir -p "$BACKEND_PY"
    if [ ! -f "$BACKEND_PY/sitecustomize.py" ] || [ ! -f "$BACKEND_PY/mrm_admin_subscriptions.py" ]; then
        echo "  ERR: plugin sources missing under $BACKEND_PY"; exit 1
    fi
    chmod 644 "$BACKEND_PY"/*.py
    echo "  bridge ready at $API_ROUTE"

    # 3) inject (idempotent) — self-contained, no python bootstrap needed
    echo "[3/5] template + dashboard integration…"
    if [ ! -f "$INTEGRATE" ]; then
        echo "  ERR: integrate-dashboard.sh missing — cannot continue"; exit 1
    fi
    MRM_ROOT="$SPECIAL_DIR" bash "$INTEGRATE"

    # 4) systemd self-healing watchers
    echo "[4/5] watchers…"
    special_install_units

    # 5) summary
    echo ""
    echo -e "${CYAN}=== Install Complete ===${NC}"
    echo "MRM Special (v$SPECIAL_VERSION) is active."
    echo "Open panel → Settings → MRM tab  (on/off switch lives there)"
    echo "Storage:   $PROFILES_DIR  (profile data — survives updates)"
    echo "Logs:      $LOG_DIR"
    echo ""
    special_pause
}

special_uninstall() {
    clear
    echo -e "${CYAN}=== Uninstall MRM Special ===${NC}"
    echo "Removes: hooks (template+dashboard), backend bridge, watchers."
    echo "Keeps:   $DATA_NS/profiles (your saved settings) until you say otherwise."
    echo ""
    read -r -p "Type REMOVE to confirm: " C
    [ "$C" != "REMOVE" ] && { echo "Cancelled."; special_pause; return; }
    detect_active_panel >/dev/null 2>&1
    special_remove_units
    # strip our markers from template
    special_strip_markers "${SUB_TEMPLATE}" "${MARKER_RUNTIME}" "${MARKER_ADMIN}" "${MARKER_THEME}"
    # strip our markers from dashboard build (host + container)
    local bd cid
    bd="$(special_find_dashboard_build || true)"
    if [ -n "$bd" ]; then
        special_strip_markers "$bd/index.html" "${MARKER_RUNTIME}" "${MARKER_ADMIN}" "${MARKER_THEME}"
        special_strip_markers "$bd/404.html" "${MARKER_RUNTIME}" "${MARKER_ADMIN}" "${MARKER_THEME}"
        rm -f "$bd/statics/mrm-special.js"
    fi
    cid="$(special_container_id || true)"
    if [ -n "$cid" ]; then
        local html
        for html in /code/dashboard/build/index.html /code/dashboard/build/404.html \
                    /app/dashboard/build/index.html /app/dashboard/build/404.html; do
            docker exec "$cid" test -f "$html" 2>/dev/null && \
                special_strip_markers_container "$cid" "$html" "${MARKER_RUNTIME}" "${MARKER_ADMIN}" "${MARKER_THEME}"
        done
        docker exec "$cid" sh -c 'rm -f /code/dashboard/build/statics/mrm-special.js /app/dashboard/build/statics/mrm-special.js' 2>/dev/null
        docker exec "$cid" sh -c 'rm -f /code/app/routers/mrm_admin_subscriptions.py /app/app/routers/mrm_admin_subscriptions.py' 2>/dev/null
    fi
    local candidate
    for candidate in \
        "${PASARGUARD_ROOT}/app/routers/__init__.py" \
        "${PASARGUARD_ROOT}/panel/app/routers/__init__.py" \
        "${PANEL_DIR}/app/routers/__init__.py" \
        "${PANEL_DIR}/panel/app/routers/__init__.py"; do
        [ -f "$candidate" ] && special_revert_router "$candidate" "${ROUTER_MARKER}" "mrm_admin_subscriptions.py"
    done
    # remove backend bridge
    rm -f "$BACKEND_PY/sitecustomize.py" "$BACKEND_PY/mrm_admin_subscriptions.py"
    read -r -p "Also delete saved profiles in $DATA_NS ? (y/n): " P
    [[ "$P" =~ ^[Yy]$ ]] && rm -rf "$DATA_NS"
    echo -e "${GREEN}✔ MRM Special removed.${NC}"
    echo ""
    special_pause
}

special_status() {
    clear
    echo -e "${CYAN}=== MRM Special Status (v$SPECIAL_VERSION) ===${NC}"
    echo ""
    # template
    if grep -q "$MARKER_RUNTIME" "$SUB_TEMPLATE" 2>/dev/null; then
        echo -e "Template runtime:   ${GREEN}● Installed${NC}"
    else
        echo -e "Template runtime:   ${RED}○ Missing${NC}"
    fi
    # dashboard (host build first, then the panel container build)
    local bd cid
    bd="$(special_find_dashboard_build || true)"
    if [ -n "$bd" ] && grep -q "$MARKER_ADMIN" "$bd/index.html" 2>/dev/null; then
        echo -e "Dashboard tab:      ${GREEN}● Installed${NC}"
    else
        cid="$(special_container_id || true)"
        if [ -n "$cid" ] && docker exec "$cid" sh -c "grep -qs \"${MARKER_ADMIN}\" /code/dashboard/build/index.html /app/dashboard/build/index.html /opt/pasarguard/dashboard/build/index.html" 2>/dev/null; then
            echo -e "Dashboard tab:      ${GREEN}● Installed${NC}  (container)"
        else
            echo -e "Dashboard tab:      ${RED}○ Missing${NC}"
        fi
    fi
    # backend
    if [ -f "$BACKEND_PY/sitecustomize.py" ] && [ -f "$BACKEND_PY/mrm_admin_subscriptions.py" ]; then
        echo -e "Backend bridge:     ${GREEN}● Installed${NC}  ($API_ROUTE)"
    else
        echo -e "Backend bridge:     ${RED}○ Missing${NC}"
    fi
    # units
    if systemctl is-active --quiet mrm-panel-update.path 2>/dev/null; then
        echo -e "Watchers:           ${GREEN}● Running${NC}"
    else
        echo -e "Watchers:           ${RED}○ Stopped${NC}"
    fi
    # data
    if [ -s "$PROFILES_DIR/profiles.json" ]; then
        local n
        n=$(python3 -c "import json;print(len(json.load(open('$PROFILES_DIR/profiles.json')).get('admins',{})))" 2>/dev/null || echo 0)
        echo -e "Profiles stored:    ${GREEN}$n admin(s)${NC}  ($DATA_NS)"
    else
        echo -e "Profiles stored:    ${RED}none${NC}"
    fi
    echo ""
    # active template (both can be installed; one is live)
    local _cur _lbl
    _cur="$(bash /opt/mrm-manager/theme.sh --current-template 2>/dev/null || echo none)"
    case "$_cur" in
        classic) _lbl="نسخه قدیمی تم" ;;
        special) _lbl="MRM Special" ;;
        *) _lbl="—" ;;
    esac
    echo -e "Active template:    ${CYAN}${_lbl}${NC}  (select in panel → Settings → MRM)"
    # other products — informational only (never removed)
    if special_competing_present; then
        echo -e "Other products:     ${YELLOW}ℹ zomorod also present${NC} (we never remove other products)"
    else
        echo -e "Other products:     ${GREEN}✓ none detected${NC}"
    fi
    echo ""
    echo "Paths:"
    echo "  Template: $SUB_TEMPLATE"
    echo "  Data:     $DATA_NS"
    echo "  Logs:     $LOG_DIR  (integrate.log, panel-update.log)"
    echo ""
    special_pause
}

special_reintegrate() {
    clear
    echo "Re-running integration (idempotent)…"
    if [ ! -f "$INTEGRATE" ]; then
        echo "  ERR: integrate-dashboard.sh missing at $INTEGRATE"; special_pause; return 1
    fi
    MRM_ROOT="$SPECIAL_DIR" bash "$INTEGRATE"
    special_pause
}

special_backup() {
    clear
    echo "Backing up MRM Special data…"
    local out="/root/mrm-special-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czf "$out" -C /var/lib pasarguard/mrm 2>/dev/null
    echo "Backup written to $out"
    special_pause
}

special_menu() {
    while true; do
        clear
        echo -e "${CYAN}===========================================${NC}"
        echo -e "${CYAN}  MRM SPECIAL — In-Panel Settings (v$SPECIAL_VERSION)${NC}"
        echo -e "${CYAN}===========================================${NC}"
        echo "  Subscription page features + Settings→MRM tab"
        echo "  (store branding, support chip, theme, announcements,"
        echo "   fa/en/ru/zh, hide-telegram, on/off switch)"
        echo ""
        echo "1) Install / Update"
        echo "2) Status"
        echo "3) Re-run integration (repair hooks)"
        echo "4) Backup settings data"
        echo "5) Uninstall"
        echo "0) Back"
        echo -e "${CYAN}===========================================${NC}"
        read -r -p "Select: " S_OPT
        case $S_OPT in
            1) special_install ;;
            2) special_status ;;
            3) special_reintegrate ;;
            4) special_backup ;;
            5) special_uninstall ;;
            0) return ;;
            *) echo -e "${RED}Invalid option${NC}"; sleep 1 ;;
        esac
    done
}

# --- Non-interactive CLI (used by Theme Manager) -----------------------------
case "${1:-}" in
    --detect-quiet)  special_competing_present && exit 0 || exit 1 ;;
    --reintegrate)   special_reintegrate; exit 0 ;;
esac

special_menu
