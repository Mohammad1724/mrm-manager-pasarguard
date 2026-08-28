#!/bin/bash

# ==========================================
# OFFLINE / IRAN MODE v1.1.23
# Fixed: safe handling of sources.list.d, preserve 3rd party repos
# ==========================================

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi
if ! declare -f ui_header >/dev/null 2>&1 && [ -r /opt/mrm-manager/ui.sh ]; then source /opt/mrm-manager/ui.sh; fi
if ! declare -f mrm_create_restore_point >/dev/null 2>&1 && [ -r /opt/mrm-manager/safe_ops.sh ]; then source /opt/mrm-manager/safe_ops.sh; fi

OFFLINE_BACKUP_ROOT="/opt/mrm-manager/offline-backups"
OFFLINE_UBUNTU_MIRRORS=(
    "https://mirror.arvancloud.ir/ubuntu"
    "http://ir.archive.ubuntu.com/ubuntu"
    "https://repo.iut.ac.ir/repo/ubuntu"
)
OFFLINE_DOCKER_MIRRORS=(
    "https://docker.arvancloud.ir"
    "https://hub.hamdocker.ir"
    "https://docker.iranserver.com"
)
OFFLINE_RECOMMENDED_APT_MIRROR="https://mirror.arvancloud.ir/ubuntu"
OFFLINE_RECOMMENDED_DOCKER_MIRROR="https://docker.arvancloud.ir"
OFFLINE_LOCAL_PANEL_ARCHIVE="/root/pasarguard-standalone.tar.gz"
OFFLINE_LOCAL_NODE_ARCHIVE="/root/pg-node-standalone.tar.gz"

offline_invalid_option() {
    if declare -f invalid_menu_option >/dev/null 2>&1; then
        invalid_menu_option
    else
        ui_error "Invalid option"
        sleep 1
    fi
}

offline_require_ubuntu() {
    local OS_ID=""
    if [ -f /etc/os-release ]; then
        OS_ID=$(awk -F= '/^ID=/{gsub(/"/,"", $2); print $2}' /etc/os-release 2>/dev/null)
    fi
    [ "$OS_ID" = "ubuntu" ]
}

offline_validate_domain() {
    local DOMAIN="$1"
    local PATTERN='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
    [ -n "$DOMAIN" ] || return 1
    [ "${#DOMAIN}" -le 253 ] || return 1
    [[ "$DOMAIN" =~ $PATTERN ]]
}

offline_get_codename() {
    awk -F= '/^VERSION_CODENAME=/{gsub(/"/,"", $2); print $2}' /etc/os-release 2>/dev/null
}

offline_get_current_apt_mirror() {
    local SOURCE_FILE MIRROR="" PASS
    # FIX (MRM-098): extract the first http(s) URL (handles
    # "deb [arch=… signed-by=…] URL" lines and quoted .sources URIs: — the old
    # awk field indexes returned "signed-by=…" or a docker URL). Two passes
    # prefer real Ubuntu archive files over third-party .d files (docker/
    # nginx lists used to be reported as the "current APT mirror").
    for PASS in 1 2; do
        for SOURCE_FILE in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
            [ -f "$SOURCE_FILE" ] || continue
            if [ "$PASS" = 1 ] && ! grep -qiE "ubuntu\.com|archive\.ubuntu|security\.ubuntu|ports\.ubuntu" "$SOURCE_FILE" 2>/dev/null; then
                continue
            fi
            MIRROR="$(grep -oP 'https?://[^"[:space:]]+' "$SOURCE_FILE" 2>/dev/null | head -1)"
            if [ -n "$MIRROR" ]; then
                printf '%s\n' "$MIRROR"
                return 0
            fi
        done
    done
    return 1
}

offline_get_current_docker_mirror() {
    local DAEMON_FILE="/etc/docker/daemon.json"
    [ -f "$DAEMON_FILE" ] || return 1
    python3 - <<'PYEOF' 2>/dev/null
import json
path = "/etc/docker/daemon.json"
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    mirrors = data.get("registry-mirrors") or []
    if mirrors:
        print(mirrors[0])
except Exception:
    pass
PYEOF
}

offline_extract_local_bundle() {
    local ARCHIVE="$1" PREFIX="$2" TMP_DIR
    [ -f "$ARCHIVE" ] || return 1
    TMP_DIR=$(mktemp -d "/tmp/${PREFIX}.XXXXXX" 2>/dev/null) || return 1
    tar -xzf "$ARCHIVE" -C "$TMP_DIR" >/dev/null 2>&1 || {
        rm -rf "$TMP_DIR"
        return 1
    }
    printf '%s\n' "$TMP_DIR"
}

offline_prepare_local_install_mirrors() {
    local CURRENT_APT CURRENT_DOCKER BACKUP_DIR CONFIRM
    CURRENT_APT="$(offline_get_current_apt_mirror 2>/dev/null || true)"
    CURRENT_DOCKER="$(offline_get_current_docker_mirror 2>/dev/null || true)"
    if offline_is_known_apt_mirror "$CURRENT_APT" && offline_is_known_docker_mirror "$CURRENT_DOCKER"; then
        return 0
    fi
    echo -e "${YELLOW}Internal mirrors are not fully configured yet.${NC}"
    echo -e "${CYAN}MRM can apply the recommended Ubuntu and Docker mirrors before installation.${NC}"
    echo ""
    read -r -p "Apply recommended mirrors first? (Y/n): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
        return 0
    fi
    BACKUP_DIR="$(offline_create_backup)"
    [ -n "$BACKUP_DIR" ] || return 1
    offline_apply_apt_mirror "$OFFLINE_RECOMMENDED_APT_MIRROR" "$BACKUP_DIR" || return 1
    offline_apply_docker_mirror "$OFFLINE_RECOMMENDED_DOCKER_MIRROR" "$BACKUP_DIR" || return 1
    return 0
}

offline_is_known_apt_mirror() {
    local CURRENT="$1" M
    for M in "${OFFLINE_UBUNTU_MIRRORS[@]}"; do
        [ "$CURRENT" = "$M" ] && return 0
    done
    return 1
}

offline_is_known_docker_mirror() {
    local CURRENT="$1" M
    for M in "${OFFLINE_DOCKER_MIRRORS[@]}"; do
        [ "$CURRENT" = "$M" ] && return 0
    done
    return 1
}

offline_test_apt_mirror() {
    local MIRROR="$1" CODENAME="$2" HTTP_CODE
    HTTP_CODE=$(curl -L -o /dev/null -s --connect-timeout 5 --max-time 10 -w '%{http_code}' "${MIRROR}/dists/${CODENAME}/Release" 2>/dev/null || echo 000)
    [ "$HTTP_CODE" = "200" ]
}

offline_test_docker_mirror() {
    local MIRROR="$1" HTTP_CODE
    HTTP_CODE=$(curl -L -o /dev/null -s --connect-timeout 5 --max-time 10 -w '%{http_code}' "${MIRROR}/v2/" 2>/dev/null || echo 000)
    [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "401" ]
}

offline_create_backup() {
    local BACKUP_DIR
    mkdir -p "$OFFLINE_BACKUP_ROOT" || return 1
    BACKUP_DIR="$OFFLINE_BACKUP_ROOT/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR/apt/sources.list.d" "$BACKUP_DIR/docker" || return 1
    [ -f /etc/apt/sources.list ] && cp -a /etc/apt/sources.list "$BACKUP_DIR/apt/sources.list" 2>/dev/null || true
    [ -d /etc/apt/sources.list.d ] && cp -a /etc/apt/sources.list.d/. "$BACKUP_DIR/apt/sources.list.d/" 2>/dev/null || true
    if [ -f /etc/docker/daemon.json ]; then
        cp -a /etc/docker/daemon.json "$BACKUP_DIR/docker/daemon.json" 2>/dev/null || true
    else
        touch "$BACKUP_DIR/docker/daemon.json.absent"
    fi
    printf '%s\n' "$BACKUP_DIR"
}

# FIXED: safer restore, check backup exists before rm
offline_restore_backup_dir() {
    local BACKUP_DIR="$1"
    [ -d "$BACKUP_DIR" ] || return 1
    # Safety check: backup must contain at least sources.list or sources.list.d
    if [ ! -f "$BACKUP_DIR/apt/sources.list" ] && [ -z "$(ls -A "$BACKUP_DIR/apt/sources.list.d" 2>/dev/null)" ]; then
        echo -e "${RED}Backup dir is empty or invalid, aborting restore to avoid data loss${NC}"
        return 1
    fi
    mkdir -p /etc/apt/sources.list.d /etc/docker
    if [ -f "$BACKUP_DIR/apt/sources.list" ]; then
        cp "$BACKUP_DIR/apt/sources.list" /etc/apt/sources.list || return 1
    elif [ -f /etc/apt/sources.list ] && grep -q "Managed by MRM" /etc/apt/sources.list 2>/dev/null; then
        # FIX (MRM-097): the backup has no sources.list (e.g. Ubuntu 24.04
        # default layout uses only .d/ubuntu.sources) — remove the stale
        # MRM-managed file so the restored official sources are not shadowed.
        rm -f /etc/apt/sources.list 2>/dev/null || true
    fi
    # SECURITY: Backup third-party repos before destructive rm
    local THIRD_PARTY_BACKUP="/tmp/mrm-third-party-backup-$(date +%s)"
    mkdir -p "$THIRD_PARTY_BACKUP"
    cp -a /etc/apt/sources.list.d/. "$THIRD_PARTY_BACKUP/" 2>/dev/null || true
    rm -rf /etc/apt/sources.list.d/* 2>/dev/null || true
    if [ -d "$BACKUP_DIR/apt/sources.list.d" ]; then
        cp -a "$BACKUP_DIR/apt/sources.list.d/." /etc/apt/sources.list.d/ 2>/dev/null || true
    fi
    if [ -f "$BACKUP_DIR/docker/daemon.json" ]; then
        cp "$BACKUP_DIR/docker/daemon.json" /etc/docker/daemon.json || return 1
    elif [ -f "$BACKUP_DIR/docker/daemon.json.absent" ]; then
        rm -f /etc/docker/daemon.json 2>/dev/null || true
    fi
    apt-get update >/dev/null 2>&1 || true
    if command -v docker >/dev/null 2>&1; then
        systemctl restart docker >/dev/null 2>&1 || true
    fi
    return 0
}

offline_latest_backup_dir() {
    ls -1dt "$OFFLINE_BACKUP_ROOT"/* 2>/dev/null | head -1
}

# FIXED: preserve third-party repos instead of deleting all
offline_apply_apt_mirror() {
    local MIRROR="$1" BACKUP_DIR="$2" CODENAME UPDATE_OK=false
    local TMP_THIRD="/tmp/mrm-third-party-$(date +%s)"
    CODENAME="$(offline_get_codename)"
    [ -n "$CODENAME" ] || return 1
    [ -d "$BACKUP_DIR" ] || {
        echo -e "${RED}No backup dir, aborting for safety${NC}"
        return 1
    }

    mkdir -p /etc/apt/sources.list.d
    mkdir -p "$TMP_THIRD"

    # FIXED: Save third-party repos (docker, nginx, etc) that are NOT ubuntu official
    for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [ -f "$f" ] || continue
        # If file contains docker, nginx, certbot, nodesource, etc and NOT ubuntu archive, it's third-party
        if grep -qiE "docker|nginx|certbot|nodesource|yarn|postgresql|timescale" "$f" 2>/dev/null; then
            cp -a "$f" "$TMP_THIRD/" 2>/dev/null
        elif ! grep -qiE "ubuntu\.com|archive\.ubuntu|security\.ubuntu|ports\.ubuntu" "$f" 2>/dev/null; then
            # File that doesn't contain ubuntu - likely third party
            if grep -qiE "deb " "$f" 2>/dev/null; then
                cp -a "$f" "$TMP_THIRD/" 2>/dev/null
            fi
        fi
    done

    # Now safe to clear only ubuntu-related files, but we keep third-party in tmp
    # Remove only ubuntu official files
    for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [ -f "$f" ] || continue
        if grep -qiE "ubuntu\.com|archive\.ubuntu|security\.ubuntu" "$f" 2>/dev/null; then
            rm -f "$f" 2>/dev/null
        fi
    done
    # If no ubuntu files found in sources.list.d, clear directory only if it was ubuntu-only
    # But to stay safe, if we have ubuntu.com in main sources.list, we will overwrite it

    cat > /etc/apt/sources.list <<EOF
# Managed by MRM Iran/Offline Mode v1.1.23
deb ${MIRROR} ${CODENAME} main restricted universe multiverse
deb ${MIRROR} ${CODENAME}-updates main restricted universe multiverse
deb ${MIRROR} ${CODENAME}-backports main restricted universe multiverse
deb ${MIRROR} ${CODENAME}-security main restricted universe multiverse
EOF

    # Restore third-party repos
    if [ -n "$(ls -A "$TMP_THIRD" 2>/dev/null)" ]; then
        cp -a "$TMP_THIRD"/* /etc/apt/sources.list.d/ 2>/dev/null || true
        echo -e "${GREEN}✔ Third-party repos preserved: $(ls "$TMP_THIRD" | tr '\n' ' ')${NC}"
    fi
    rm -rf "$TMP_THIRD"

    if apt-get update >/dev/null 2>&1; then
        UPDATE_OK=true
    fi

    if [ "$UPDATE_OK" != true ]; then
        echo -e "${RED}apt-get update failed, restoring backup...${NC}"
        offline_restore_backup_dir "$BACKUP_DIR" >/dev/null 2>&1 || true
        return 1
    fi
    return 0
}

offline_apply_docker_mirror() {
    local MIRROR="$1" BACKUP_DIR="$2"
    mkdir -p /etc/docker
    if ! python3 - <<PYEOF
import json
path = "/etc/docker/daemon.json"
mirror = ${MIRROR@Q}
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}
except Exception:
    raise SystemExit(1)
mirrors = data.get("registry-mirrors") or []
if mirror not in mirrors:
    mirrors.append(mirror)
data["registry-mirrors"] = mirrors
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
    then
        offline_restore_backup_dir "$BACKUP_DIR" >/dev/null 2>&1 || true
        return 1
    fi
    if command -v docker >/dev/null 2>&1; then
        if ! systemctl restart docker >/dev/null 2>&1; then
            offline_restore_backup_dir "$BACKUP_DIR" >/dev/null 2>&1 || true
            return 1
        fi
    fi
    return 0
}

offline_show_status() {
    local CODENAME CURRENT_APT CURRENT_DOCKER
    clear
    ui_header "IRAN / OFFLINE MODE v1.1.23"
    if ! offline_require_ubuntu; then
        ui_error "This module currently supports Ubuntu only"
        echo ""
        ui_info "Use Ubuntu servers for safe mirror automation in Phase 2."
        echo ""
        pause
        return
    fi
    CODENAME="$(offline_get_codename)"
    CURRENT_APT="$(offline_get_current_apt_mirror 2>/dev/null || echo Not)"
    CURRENT_DOCKER="$(offline_get_current_docker_mirror 2>/dev/null || echo Not)"
    ui_section "Environment"
    ui_kv "Ubuntu Codename" "${CODENAME:-Unknown}"
    ui_kv "Current APT Mirror" "$CURRENT_APT"
    ui_kv "Current Docker Mirror" "$CURRENT_DOCKER"
    echo ""
    ui_section "Third-Party Repos (Preserved)"
    if [ -d /etc/apt/sources.list.d ]; then
        ls /etc/apt/sources.list.d/ 2>/dev/null | head -n 20
    else
        echo "No sources.list.d"
    fi
    echo ""
    ui_section "Current State"
    if offline_is_known_apt_mirror "$CURRENT_APT"; then
        ui_success "APT is using a known Iran/internal mirror"
    else
        ui_warning "APT is not using a known Iran/internal mirror"
    fi
    if [ "$CURRENT_DOCKER" != "Not" ] && offline_is_known_docker_mirror "$CURRENT_DOCKER"; then
        ui_success "Docker is using a known Iran/internal mirror"
    else
        ui_warning "Docker mirror is not configured to a known Iran/internal mirror"
    fi
    echo ""
    pause
}

offline_test_mirrors() {
    local CODENAME MIRROR
    clear
    ui_header "TEST IRAN MIRRORS"
    if ! offline_require_ubuntu; then
        ui_error "This module currently supports Ubuntu only"
        pause
        return
    fi
    CODENAME="$(offline_get_codename)"
    [ -n "$CODENAME" ] || {
        ui_error "Could not detect Ubuntu codename"
        pause
        return
    }
    ui_section "APT Mirrors"
    for MIRROR in "${OFFLINE_UBUNTU_MIRRORS[@]}"; do
        if offline_test_apt_mirror "$MIRROR" "$CODENAME"; then
            ui_success "$MIRROR"
        else
            ui_warning "$MIRROR"
        fi
    done
    echo ""
    ui_section "Docker Mirrors"
    for MIRROR in "${OFFLINE_DOCKER_MIRRORS[@]}"; do
        if offline_test_docker_mirror "$MIRROR"; then
            ui_success "$MIRROR"
        else
            ui_warning "$MIRROR"
        fi
    done
    echo ""
    pause
}

offline_apply_recommended_apt() {
    local BACKUP_DIR
    clear
    ui_header "APPLY IRAN APT MIRROR v1.1.23"
    if ! offline_require_ubuntu; then
        ui_error "This module currently supports Ubuntu only"
        pause
        return
    fi
    echo -e "${YELLOW}Recommended Ubuntu mirror:${NC} $OFFLINE_RECOMMENDED_APT_MIRROR"
    echo -e "${CYAN}A full backup will be created and 3rd-party repos (docker, etc) will be preserved.${NC}"
    echo ""
    read -r -p "Apply this Ubuntu mirror now? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Cancelled"
        pause
        return
    fi
    BACKUP_DIR="$(offline_create_backup)"
    if [ -z "$BACKUP_DIR" ]; then
        ui_error "Failed to create offline backup"
        pause
        return
    fi
    if offline_apply_apt_mirror "$OFFLINE_RECOMMENDED_APT_MIRROR" "$BACKUP_DIR"; then
        ui_success "Ubuntu APT mirror updated successfully (3rd-party repos preserved)"
        ui_info "Backup saved in: $BACKUP_DIR"
    else
        ui_error "Failed to apply Ubuntu APT mirror. Previous config restored."
    fi
    pause
}

offline_apply_recommended_docker() {
    local BACKUP_DIR
    clear
    ui_header "APPLY IRAN DOCKER MIRROR"
    echo -e "${YELLOW}Recommended Docker mirror:${NC} $OFFLINE_RECOMMENDED_DOCKER_MIRROR"
    echo -e "${CYAN}A full backup will be created first.${NC}"
    echo ""
    read -r -p "Apply this Docker mirror now? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Cancelled"
        pause
        return
    fi
    BACKUP_DIR="$(offline_create_backup)"
    if [ -z "$BACKUP_DIR" ]; then
        ui_error "Failed to create offline backup"
        pause
        return
    fi
    if offline_apply_docker_mirror "$OFFLINE_RECOMMENDED_DOCKER_MIRROR" "$BACKUP_DIR"; then
        ui_success "Docker mirror updated successfully"
        ui_info "Backup saved in: $BACKUP_DIR"
    else
        ui_error "Failed to apply Docker mirror. Previous config restored."
    fi
    pause
}

offline_apply_both_recommended() {
    local BACKUP_DIR
    clear
    ui_header "APPLY IRAN MIRRORS v1.1.23"
    if ! offline_require_ubuntu; then
        ui_error "This module currently supports Ubuntu only"
        pause
        return
    fi
    echo -e "${YELLOW}APT Mirror:${NC} $OFFLINE_RECOMMENDED_APT_MIRROR"
    echo -e "${YELLOW}Docker Mirror:${NC} $OFFLINE_RECOMMENDED_DOCKER_MIRROR"
    echo -e "${CYAN}Backup + preserve 3rd-party repos (docker, nginx).${NC}"
    echo ""
    read -r -p "Apply both recommended mirrors now? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Cancelled"
        pause
        return
    fi
    BACKUP_DIR="$(offline_create_backup)"
    if [ -z "$BACKUP_DIR" ]; then
        ui_error "Failed to create offline backup"
        pause
        return
    fi
    if ! offline_apply_apt_mirror "$OFFLINE_RECOMMENDED_APT_MIRROR" "$BACKUP_DIR"; then
        ui_error "Failed to apply Ubuntu APT mirror. Previous config restored."
        pause
        return
    fi
    if ! offline_apply_docker_mirror "$OFFLINE_RECOMMENDED_DOCKER_MIRROR" "$BACKUP_DIR"; then
        ui_error "Failed to apply Docker mirror. Previous config restored."
        pause
        return
    fi
    ui_success "APT and Docker mirrors updated successfully (3rd-party preserved)"
    ui_info "Backup saved in: $BACKUP_DIR"
    pause
}

offline_check_readiness() {
    local CMD FOUND_ANY=false
    local REQUIRED_COMMANDS=(curl tar unzip python3 jq docker nginx certbot)
    clear
    ui_header "OFFLINE READINESS CHECK"
    if ! offline_require_ubuntu; then
        ui_warning "Ubuntu-only automation is available in this module"
    else
        ui_success "Ubuntu detected: $(offline_get_codename)"
    fi
    echo ""
    ui_section "Mirror Status"
    if offline_is_known_apt_mirror "$(offline_get_current_apt_mirror 2>/dev/null || true)"; then
        ui_success "APT uses an internal/Iran mirror"
    else
        ui_warning "APT is not configured with a known internal/Iran mirror"
    fi
    if offline_is_known_docker_mirror "$(offline_get_current_docker_mirror 2>/dev/null || true)"; then
        ui_success "Docker uses an internal/Iran mirror"
    else
        ui_warning "Docker mirror is not configured with a known internal/Iran mirror"
    fi
    echo ""
    ui_section "Required Commands"
    for CMD in "${REQUIRED_COMMANDS[@]}"; do
        if command -v "$CMD" >/dev/null 2>&1; then
            ui_success "$CMD"
        else
            ui_warning "$CMD"
        fi
    done
    echo ""
    ui_section "Expected Local Bundles"
    if [ -f "$OFFLINE_LOCAL_PANEL_ARCHIVE" ]; then
        ui_success "$OFFLINE_LOCAL_PANEL_ARCHIVE"
        FOUND_ANY=true
    else
        ui_warning "$OFFLINE_LOCAL_PANEL_ARCHIVE (required for local panel install)"
    fi
    if [ -f "$OFFLINE_LOCAL_NODE_ARCHIVE" ]; then
        ui_success "$OFFLINE_LOCAL_NODE_ARCHIVE"
        FOUND_ANY=true
    else
        ui_warning "$OFFLINE_LOCAL_NODE_ARCHIVE (required for local node install)"
    fi
    if [ "$FOUND_ANY" != true ]; then
        ui_warning "Place the required tar.gz files in /root with the exact names shown above"
    fi
    echo ""
    pause
}

offline_restore_latest_backup() {
    local BACKUP_DIR
    clear
    ui_header "RESTORE MIRROR BACKUP"
    BACKUP_DIR="$(offline_latest_backup_dir)"
    if [ -z "$BACKUP_DIR" ] || [ ! -d "$BACKUP_DIR" ]; then
        ui_warning "No offline backup found"
        pause
        return
    fi
    echo -e "${YELLOW}Latest backup:${NC} $BACKUP_DIR"
    ls -R "$BACKUP_DIR" | head -n 40
    echo ""
    read -r -p "Restore this backup now? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Cancelled"
        pause
        return
    fi
    if offline_restore_backup_dir "$BACKUP_DIR"; then
        ui_success "Backup restored successfully"
    else
        ui_error "Failed to restore backup"
    fi
    pause
}

offline_install_panel_local() {
    local WORK_DIR EXTRACTED_ROOT RESPONSES="" SSL_MODE SSL_DOMAIN="" COMMAND_ARGS=()
    clear
    ui_header "LOCAL PASARGUARD INSTALL"
    if ! offline_require_ubuntu; then
        ui_error "This module currently supports Ubuntu only"
        pause
        return
    fi
    echo -e "${CYAN}Required file:${NC} $OFFLINE_LOCAL_PANEL_ARCHIVE"
    echo -e "${YELLOW}Place the panel standalone package in /root with this exact name.${NC}"
    echo ""
    if [ ! -f "$OFFLINE_LOCAL_PANEL_ARCHIVE" ]; then
        ui_error "Required archive not found: $OFFLINE_LOCAL_PANEL_ARCHIVE"
        pause
        return
    fi
    if ! offline_prepare_local_install_mirrors; then
        ui_error "Failed to prepare internal mirrors"
        pause
        return
    fi
    echo "Choose panel installation mode:"
    echo "1) With SSL"
    echo "2) Without SSL"
    echo ""
    read -r -p "Select [1-2]: " SSL_MODE
    case "$SSL_MODE" in
        1)
            read -r -p "Enter panel domain for SSL (example: panel.example.com): " SSL_DOMAIN
            if ! offline_validate_domain "$SSL_DOMAIN"; then
                ui_error "Invalid domain format"
                pause
                return
            fi
            COMMAND_ARGS=(install --database timescaledb --ssl-domain "$SSL_DOMAIN")
            ;;
        2|"")
            COMMAND_ARGS=(install --database timescaledb --no-ssl)
            ;;
        *)
            offline_invalid_option
            return
            ;;
    esac
    if [ -d "/opt/pasarguard" ]; then
        echo -e "${YELLOW}Existing PasarGuard installation detected at /opt/pasarguard.${NC}"
        read -r -p "Continue and allow standalone installer to override it? (y/N): " CONFIRM
        if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
            echo "Cancelled"
            pause
            return
        fi
        # FIX (MRM-096): the official installer asks "override?" FIRST, then
        # the mirror recalibrate questions — the stream must start with the
        # "y" captured above. The old order (y appended last) shifted the
        # stream: the override prompt consumed the first mirror "n" and the
        # whole install silently aborted on an existing install.
        RESPONSES+="y\n"
        if offline_is_known_apt_mirror "$(offline_get_current_apt_mirror 2>/dev/null || true)"; then RESPONSES+="n\n"; fi
        if offline_is_known_docker_mirror "$(offline_get_current_docker_mirror 2>/dev/null || true)"; then RESPONSES+="n\n"; fi
        RESPONSES+="n\n"
    else
        if offline_is_known_apt_mirror "$(offline_get_current_apt_mirror 2>/dev/null || true)"; then RESPONSES+="n\n"; fi
        if offline_is_known_docker_mirror "$(offline_get_current_docker_mirror 2>/dev/null || true)"; then RESPONSES+="n\n"; fi
        RESPONSES+="n\n"
    fi
    WORK_DIR="$(offline_extract_local_bundle "$OFFLINE_LOCAL_PANEL_ARCHIVE" mrm-local-panel)"
    if [ -z "$WORK_DIR" ] || [ ! -d "$WORK_DIR" ]; then
        ui_error "Failed to extract panel archive"
        pause
        return
    fi
    EXTRACTED_ROOT="$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)"
    [ -n "$EXTRACTED_ROOT" ] || EXTRACTED_ROOT="$WORK_DIR"
    if [ ! -f "$EXTRACTED_ROOT/iran-sanction/pasarguard-standalone.sh" ]; then
        ui_error "Standalone installer not found inside archive"
        rm -rf "$WORK_DIR" 2>/dev/null || true
        pause
        return
    fi
    chmod +x "$EXTRACTED_ROOT/iran-sanction/pasarguard-standalone.sh"
    ui_info "Installing standalone launcher..."
    if ! "$EXTRACTED_ROOT/iran-sanction/pasarguard-standalone.sh" install-script; then
        ui_error "Failed to install standalone PasarGuard launcher"
        rm -rf "$WORK_DIR" 2>/dev/null || true
        pause
        return
    fi
    ui_info "Running local PasarGuard installation..."
    if printf '%b' "$RESPONSES" | pasarguard "${COMMAND_ARGS[@]}"; then
        ui_success "PasarGuard installed successfully from local archive"
    else
        ui_error "PasarGuard installation failed"
    fi
    rm -rf "$WORK_DIR" 2>/dev/null || true
    pause
}

offline_install_node_local() {
    local WORK_DIR EXTRACTED_ROOT RESPONSES=""
    clear
    ui_header "LOCAL PGNODE INSTALL"
    if ! offline_require_ubuntu; then
        ui_error "This module currently supports Ubuntu only"
        pause
        return
    fi
    echo -e "${CYAN}Required file:${NC} $OFFLINE_LOCAL_NODE_ARCHIVE"
    echo -e "${YELLOW}Place the node standalone package in /root with this exact name.${NC}"
    echo -e "${YELLOW}Run this on the node server, not on the panel server.${NC}"
    echo ""
    if [ ! -f "$OFFLINE_LOCAL_NODE_ARCHIVE" ]; then
        ui_error "Required archive not found: $OFFLINE_LOCAL_NODE_ARCHIVE"
        pause
        return
    fi
    if [ -d "/opt/pg-node" ]; then
        ui_warning "Existing PgNode installation detected at /opt/pg-node"
        ui_info "For safety, local node install is only supported on a clean server in MRM."
        ui_info "If you need reinstall, uninstall the old node first and retry."
        pause
        return
    fi
    if ! offline_prepare_local_install_mirrors; then
        ui_error "Failed to prepare internal mirrors"
        pause
        return
    fi
    if offline_is_known_apt_mirror "$(offline_get_current_apt_mirror 2>/dev/null || true)"; then RESPONSES+="n\n"; fi
    if offline_is_known_docker_mirror "$(offline_get_current_docker_mirror 2>/dev/null || true)"; then RESPONSES+="n\n"; fi
    WORK_DIR="$(offline_extract_local_bundle "$OFFLINE_LOCAL_NODE_ARCHIVE" mrm-local-node)"
    if [ -z "$WORK_DIR" ] || [ ! -d "$WORK_DIR" ]; then
        ui_error "Failed to extract node archive"
        pause
        return
    fi
    EXTRACTED_ROOT="$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)"
    [ -n "$EXTRACTED_ROOT" ] || EXTRACTED_ROOT="$WORK_DIR"
    if [ ! -f "$EXTRACTED_ROOT/iran-sanction/pg-node-standalone.sh" ]; then
        ui_error "Standalone PgNode installer not found inside archive"
        rm -rf "$WORK_DIR" 2>/dev/null || true
        pause
        return
    fi
    chmod +x "$EXTRACTED_ROOT/iran-sanction/pg-node-standalone.sh"
    ui_info "Installing standalone PgNode launcher..."
    if ! "$EXTRACTED_ROOT/iran-sanction/pg-node-standalone.sh" install-script; then
        ui_error "Failed to install standalone PgNode launcher"
        rm -rf "$WORK_DIR" 2>/dev/null || true
        pause
        return
    fi
    ui_info "Running local PgNode installation..."
    if printf '%b' "$RESPONSES" | pg-node install -y; then
        ui_success "PgNode installed successfully from local archive"
    else
        ui_error "PgNode installation failed"
    fi
    rm -rf "$WORK_DIR" 2>/dev/null || true
    pause
}

offline_menu() {
    while true; do
        clear
        ui_header "IRAN / OFFLINE MODE v1.1.23"
        echo "1) 🇮🇷 Show Current Mirror Status"
        echo "2) 🧪 Test Iran Mirrors"
        echo "3) 📦 Apply Recommended Ubuntu APT Mirror [Preserves 3rd-party]"
        echo "4) 🐳 Apply Recommended Docker Mirror"
        echo "5) 🚀 Apply Both Recommended Mirrors"
        echo "6) 🧰 Offline Readiness Check"
        echo "7) 📦 Install PasarGuard Panel from Local Tarball"
        echo "8) ⚙️  Install PgNode from Local Tarball"
        echo "9) ♻️  Restore Last Mirror Backup"
        echo "0) ↩️  Back"
        echo ""
        read -p "Select: " OPT
        case "$OPT" in
            1) offline_show_status ;;
            2) offline_test_mirrors ;;
            3) offline_apply_recommended_apt ;;
            4) offline_apply_recommended_docker ;;
            5) offline_apply_both_recommended ;;
            6) offline_check_readiness ;;
            7) offline_install_panel_local ;;
            8) offline_install_node_local ;;
            9) offline_restore_latest_backup ;;
            0) return ;;
            *) offline_invalid_option ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    offline_menu
fi
