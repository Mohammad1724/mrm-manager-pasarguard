#!/usr/bin/env bash
# ============================================================================
# MRM SPECIAL MANAGER — In-Panel Special integration
# ============================================================================
# MRM Manager — Maral Rahmani
# Instagram: https://instagram.com/maral.rahmani.7
# Telegram:  https://t.me/MaralRahmani
#
# Installs "MRM Special" (in-panel integration for the special template):
#   - subscription runtime hook  (mrm-runtime.js → page JS on /raw)
#   - in-panel settings tab     (mrm-special.js + /api/mrm/profile bridge)
#   - profile storage           (per-admin custom variables — survives updates)
#   - theme CSS injection       (primary/secondary via template theme engine)
#   - systemd watchers          (self-healing: dashboard rebuilds/restarts)
#
# Marker convention (the simplest reliable strategy): every injected string is
# wrapped in literal markers so injection is fully idempotent and reversible. DO NOT change without bumping SPECIAL_VERSION and
# keeping legacy markers recognized (legacy imports must stay cleanable).
#
# Data layout:   /var/lib/pasarguard/mrm/
# Profile map:   profiles/profiles.json  (admins.json is created by sitecustomize)
# ============================================================================
SPECIAL_VERSION="1.2.3"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MRM_DIR="${MRM_DIR:-$SCRIPT_DIR}"
[ -r "$MRM_DIR/utils.sh" ] || MRM_DIR="/opt/mrm-manager"
# shellcheck disable=SC1091
source "$MRM_DIR/utils.sh"
# shellcheck disable=SC1091
declare -f ui_header >/dev/null 2>&1 || source "$MRM_DIR/ui.sh"
# shellcheck disable=SC1091
source "$MRM_DIR/domain_separator.sh"

# --- Patched PasarGuard source tree (via detect_active_panel) ---------------
# Panel Docker integration (optional — used only if the PasarGuard panel runs
# in a Docker container).
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

special_pause() { ui_pause; }

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
Description=Resource-bounded MRM reconciliation for PasarGuard
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/mrm-manager/plugin/integrate-dashboard.sh
TimeoutStartSec=90s
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
OnBootSec=45s
OnUnitInactiveSec=15min
AccuracySec=1min
RandomizedDelaySec=2min
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
PathChanged=/var/lib/pasarguard/mrm/update-request.json
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
PathChanged=/var/lib/pasarguard/mrm/template-request.json
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
    systemctl enable --now mrm-integrator.timer mrm-integrator.path \
        mrm-panel-update.path mrm-template-switch.path >/dev/null 2>&1
    systemctl start mrm-integrator.service >/dev/null 2>&1 || true
    ui_success "systemd watchers installed (self-healing, update and template bridges)"
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
    ui_section "Requirements"
    if ! command -v python3 >/dev/null 2>&1; then
        ui_error "python3 not found"; special_pause; exit 1
    fi
    [ -s "$SUB_TEMPLATE" ] || {
        ui_error "Template not found: $SUB_TEMPLATE"
        ui_note "Install it first: Theme Manager › Install / Update MRM Special"
        special_pause; exit 1
    }
    detect_active_panel || true
    [ -n "$PANEL_DIR" ] && [ -d "$PANEL_DIR" ] || {
        ui_error "PasarGuard source directory not found (PANEL_DIR='$PANEL_DIR')"; special_pause; exit 1
    }
    if [ ! -f "$INTEGRATE" ]; then
        ui_error "integrate-dashboard.sh not found: $INTEGRATE"; special_pause; exit 1
    fi
    mkdir -p "$DATA_NS" "$PROFILES_DIR" "$LOG_DIR"
    ui_success "python3, template, source tree and data directories are ready"
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
    ui_header "Install / Update MRM Special" "In-panel settings tab and subscription runtime"
    detect_active_panel >/dev/null 2>&1
    special_check_requirements

    # 1) data namespace + default profiles map
    ui_step 1 4 "Data namespace"
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
    ui_success "$PROFILES_DIR/profiles.json ready"

    # 2) backend bridge (python dir — downloaded as PLUGIN module)
    ui_step 2 4 "Backend bridge"
    mkdir -p "$BACKEND_PY"
    if [ ! -f "$BACKEND_PY/sitecustomize.py" ] || [ ! -f "$BACKEND_PY/mrm_admin_subscriptions.py" ]; then
        ui_error "Plugin sources missing under $BACKEND_PY"; special_pause; exit 1
    fi
    chmod 644 "$BACKEND_PY"/*.py
    ui_success "Bridge ready at $API_ROUTE"

    # 3) inject (idempotent) — self-contained, no python bootstrap needed
    ui_step 3 4 "Template and dashboard integration"
    if [ ! -f "$INTEGRATE" ]; then
        ui_error "integrate-dashboard.sh missing — cannot continue"; special_pause; exit 1
    fi
    MRM_ROOT="$SPECIAL_DIR" PASARGUARD_ROOT="${PANEL_DIR:-/opt/pasarguard}" bash "$INTEGRATE"

    # 4) systemd self-healing watchers
    ui_step 4 4 "Watchers"
    special_install_units

    # 5) summary
    echo ""
    ui_box_start ok "MRM Special v$SPECIAL_VERSION is active"
    ui_box_line "Panel" "Settings › MRM tab (on/off switch lives there)"
    ui_box_line "Storage" "$PROFILES_DIR (survives updates)"
    ui_box_line "Logs" "$LOG_DIR"
    ui_box_end
    special_pause
}

special_uninstall() {
    ui_header "Uninstall MRM Special"
    ui_text "Removes the template and dashboard hooks, the backend bridge and the systemd watchers."
    ui_text "Saved profiles in $DATA_NS/profiles are kept unless you choose to delete them."
    echo ""
    ui_confirm_word "REMOVE" "This removes MRM Special from the panel." || { ui_cancelled; special_pause; return; }
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
    if ui_confirm "Also delete the saved profiles in $DATA_NS?"; then
        rm -rf "$DATA_NS"
    fi
    ui_success "MRM Special removed"
    special_pause
}

special_status() {
    ui_header "MRM Special Status" "integration v$SPECIAL_VERSION"
    # template
    if grep -q "$MARKER_RUNTIME" "$SUB_TEMPLATE" 2>/dev/null; then
        ui_kv_state "Runtime" ok "Installed" "template runtime"
    else
        ui_kv_state "Runtime" bad "Missing" "template runtime"
    fi
    # dashboard (host build first, then the panel container build)
    local bd cid
    bd="$(special_find_dashboard_build || true)"
    if [ -n "$bd" ] && grep -q "$MARKER_ADMIN" "$bd/index.html" 2>/dev/null; then
        ui_kv_state "Dashboard tab" ok "Installed"
    else
        cid="$(special_container_id || true)"
        if [ -n "$cid" ] && docker exec "$cid" sh -c "grep -qs \"${MARKER_ADMIN}\" /code/dashboard/build/index.html /app/dashboard/build/index.html /opt/pasarguard/dashboard/build/index.html" 2>/dev/null; then
            ui_kv_state "Dashboard tab" ok "Installed" "container"
        else
            ui_kv_state "Dashboard tab" bad "Missing"
        fi
    fi
    # backend
    if [ -f "$BACKEND_PY/sitecustomize.py" ] && [ -f "$BACKEND_PY/mrm_admin_subscriptions.py" ]; then
        ui_kv_state "Backend bridge" ok "Installed" "$API_ROUTE"
    else
        ui_kv_state "Backend bridge" bad "Missing"
    fi
    # units
    if systemctl is-active --quiet mrm-panel-update.path 2>/dev/null; then
        ui_kv_state "Watchers" ok "Running"
    else
        ui_kv_state "Watchers" bad "Stopped"
    fi
    # data
    if [ -s "$PROFILES_DIR/profiles.json" ]; then
        local n
        n=$(python3 -c "import json;print(len(json.load(open('$PROFILES_DIR/profiles.json')).get('admins',{})))" 2>/dev/null || echo 0)
        ui_kv_state "Profiles" ok "$n admin(s)" "$DATA_NS"
    else
        ui_kv_state "Profiles" off "none"
    fi
    # active template (both can be installed; one is live)
    local _cur _lbl
    _cur="$(bash "$MRM_DIR/theme.sh" --current-template 2>/dev/null || echo none)"
    case "$_cur" in
        classic) _lbl="MRM Classic" ;;
        special) _lbl="MRM Special" ;;
        *) _lbl="none" ;;
    esac
    ui_kv "Template" "$_lbl" "select in the panel: Settings › MRM"
    # other products — informational only (never removed)
    if special_competing_present; then
        ui_kv_state "Other products" warn "Another integration present" "left untouched"
    else
        ui_kv_state "Other products" ok "None detected"
    fi
    echo ""
    ui_section "Paths"
    ui_kv "Template" "$SUB_TEMPLATE"
    ui_kv "Data" "$DATA_NS"
    ui_kv "Logs" "$LOG_DIR" "integrate.log, panel-update.log"
    echo ""
    special_pause
}

special_reintegrate() {
    ui_header "Repair Integration" "re-runs the idempotent integrator"
    if [ ! -f "$INTEGRATE" ]; then
        ui_error "integrate-dashboard.sh missing: $INTEGRATE"; special_pause; return 1
    fi
    MRM_ROOT="$SPECIAL_DIR" PASARGUARD_ROOT="${PANEL_DIR:-/opt/pasarguard}" bash "$INTEGRATE"
    echo ""
    special_pause
}

special_backup() {
    ui_header "Backup MRM Special Data"
    local out
    out="/root/mrm-special-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    ui_task "Archiving $DATA_NS"
    if tar -czf "$out" -C /var/lib pasarguard/mrm 2>/dev/null; then
        ui_task_done ok
        ui_kv "Archive" "$out"
    else
        ui_task_done bad
        rm -f "$out"
    fi
    special_pause
}

special_install_auto() {
    detect_active_panel >/dev/null 2>&1 || true
    mkdir -p "$DATA_NS" "$PROFILES_DIR" "$LOG_DIR" "$BACKEND_PY" 2>/dev/null || true

    # 1) data namespace + default profiles map
    if [ ! -s "$PROFILES_DIR/profiles.json" ]; then
        cat > "$PROFILES_DIR/profiles.json" <<'JSONEOF'
{
  "version": 1,
  "admins": {}
}
JSONEOF
    fi
    chmod 644 "$PROFILES_DIR/profiles.json" 2>/dev/null || true
    chown -R nobody:nogroup "$DATA_NS" 2>/dev/null || true

    # 2) backend bridge
    if [ -f "$BACKEND_PY/sitecustomize.py" ] && [ -f "$BACKEND_PY/mrm_admin_subscriptions.py" ]; then
        chmod 644 "$BACKEND_PY"/*.py 2>/dev/null || true
    fi

    # 3) inject (idempotent)
    if [ -f "$INTEGRATE" ]; then
        MRM_ROOT="$SPECIAL_DIR" PASARGUARD_ROOT="${PANEL_DIR:-/opt/pasarguard}" bash "$INTEGRATE" >/dev/null 2>&1 || true
    fi

    # 4) systemd self-healing watchers
    special_install_units >/dev/null 2>&1 || true
    return 0
}

special_menu() {
    local S_OPT
    while true; do
        ui_header "MRM Special" "In-panel settings tab · integration v$SPECIAL_VERSION"
        ui_text "Branding, support chip, theme colors, announcements, languages and the on/off switch —"
        ui_text "all managed from the panel: Settings › MRM."
        echo ""
        ui_menu_item 1 "Install / Update"
        ui_menu_item 2 "Status"
        ui_menu_item 3 "Repair integration" "re-run hooks"
        ui_menu_item 4 "Backup settings data"
        ui_menu_item 5 "Uninstall"
        ui_menu_back
        ui_select S_OPT
        case $S_OPT in
            1) special_install ;;
            2) special_status ;;
            3) special_reintegrate ;;
            4) special_backup ;;
            5) special_uninstall ;;
            0) return ;;
            *) ui_invalid ;;
        esac
    done
}

# --- Non-interactive CLI (used by Theme Manager) -----------------------------
case "${1:-}" in
    --detect-quiet)  special_competing_present && exit 0 || exit 1 ;;
    --reintegrate)   special_reintegrate; exit 0 ;;
    --install-quiet) special_install_auto; exit $? ;;
    --status)        special_status; exit 0 ;;
esac

special_menu
