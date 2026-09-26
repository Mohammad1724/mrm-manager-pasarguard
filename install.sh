#!/bin/bash
# MRM Manager Installer
#   curl -fsSL https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/main/install.sh | sudo bash

INSTALL_DIR="/opt/mrm-manager"
# Pinned release ref + checksums: files are downloaded from this exact ref and
# verified against checksums.txt (integrity). install.sh itself is bootstrapped
# via the README curl command and therefore cannot self-verify.
REPO_BASE_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard"
REPO_REF="v1.5.0"
MANAGER_REPO_URL="$REPO_BASE_URL/$REPO_REF"
VERSION_REGISTRY_URL="$MANAGER_REPO_URL/versions.conf"
CHECKSUMS_URL="$MANAGER_REPO_URL/checksums.txt"
# MRM-004: bounded downloads, TLS only
CURL_BASE=(curl -fsSL --connect-timeout 10 --max-time 60 --proto '=https' --tlsv1.2)

# ─── Minimal UI (ui.sh is not installed yet — same look, self-contained) ─────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; CYAN=$'\033[0;36m'
    BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; BOLD=""; DIM=""; NC=""
fi
PAD="  "
ui_success() { printf '%s%s✔%s %s\n' "$PAD" "$GREEN" "$NC" "$1"; }
ui_error()   { printf '%s%s✘%s %s\n' "$PAD" "$RED" "$NC" "$1" >&2; }
ui_warning() { printf '%s%s⚠%s %s\n' "$PAD" "$YELLOW" "$NC" "$1"; }
ui_note()    { printf '%s%s%s%s\n' "$PAD" "$DIM" "$1" "$NC"; }
ui_step()    { printf '\n%s%s[%s/%s]%s %s%s%s\n' "$PAD" "$CYAN" "$1" "$2" "$NC" "$BOLD" "$3" "$NC"; }
ui_header() {
    local TITLE="$1" W=56 LINE
    LINE="$(printf '%*s' $((W - 2)) '' | tr ' ' '─')"
    printf '\n%s%s┌%s┐%s\n' "$PAD" "$CYAN" "$LINE" "$NC"
    printf '%s%s│%s %s%-*s%s %s│%s\n' "$PAD" "$CYAN" "$NC" "$BOLD" $((W - 4)) "$TITLE" "$NC" "$CYAN" "$NC"
    printf '%s%s└%s┘%s\n\n' "$PAD" "$CYAN" "$LINE" "$NC"
}

# MRM-006: POSIX-safe root check (EUID is undefined under dash)
[ "$(id -u)" -ne 0 ] && { ui_error "Please run as root"; exit 1; }

# MRM-003: keep a rollback copy of the current install before overwriting
HAD_PREVIOUS=0
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "${INSTALL_DIR}.previous" 2>/dev/null
    cp -a "$INSTALL_DIR" "${INSTALL_DIR}.previous" 2>/dev/null && HAD_PREVIOUS=1
else
    mkdir -p "$INSTALL_DIR"
fi

# MRM-001: version is parsed (never sourced) from the pinned versions.conf
MRM_VERSION=""
VERSION_REGISTRY_FILE="$(mktemp)"
if "${CURL_BASE[@]}" -o "$VERSION_REGISTRY_FILE" "$VERSION_REGISTRY_URL" 2>/dev/null; then
    MRM_VERSION="$(grep -E '^MRM_VERSION=' "$VERSION_REGISTRY_FILE" 2>/dev/null | head -1 | cut -d'"' -f2)"
fi
rm -f "$VERSION_REGISTRY_FILE"

# Fallback only if registry fetch failed
if [ -z "$MRM_VERSION" ]; then
    MRM_VERSION="1.5.0"
fi

ui_header "MRM Manager Installer  v${MRM_VERSION}"
ui_note "Release: $REPO_REF  ·  Target: $INSTALL_DIR"
[ "$HAD_PREVIOUS" -eq 1 ] && ui_note "Rollback copy: ${INSTALL_DIR}.previous"

# MRM-001: integrity manifest (checksums.txt) is mandatory — abort if absent
CHECKSUMS_FILE="$(mktemp)"
trap 'rm -f "$CHECKSUMS_FILE"' EXIT
if ! "${CURL_BASE[@]}" -o "$CHECKSUMS_FILE" "$CHECKSUMS_URL" 2>/dev/null; then
    ui_error "Could not download checksums.txt ($CHECKSUMS_URL)"
    ui_note "Aborting to avoid installing unverified files."
    exit 1
fi

FAIL_COUNT=0

verify_download() {
    # $1 = installed file path, $2 = repo-relative path (as in checksums.txt)
    local OUT="$1" REL="$2" EXPECTED ACTUAL
    EXPECTED="$(awk -v r="$REL" '$2 == r {print $1}' "$CHECKSUMS_FILE" | head -1)"
    if [ -z "$EXPECTED" ]; then
        ui_error "No checksum entry for $REL — rejected"
        rm -f "$OUT"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi
    ACTUAL="$(sha256sum "$OUT" 2>/dev/null | awk '{print $1}')"
    if [ "$EXPECTED" = "$ACTUAL" ]; then
        return 0
    fi
    ui_error "Checksum mismatch for $REL (expected ${EXPECTED:0:12}…, got ${ACTUAL:0:12}…)"
    rm -f "$OUT"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return 1
}

ui_step 1 4 "Preparing directories"
mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/backup" "$INSTALL_DIR/plugin" "$INSTALL_DIR/templates/subscription-classic" "$INSTALL_DIR/templates/subscription-special"

FILES=(
    "utils.sh" "ui.sh" "ssl.sh" "backup.sh" "domain_separator.sh"
    "theme.sh" "special.sh" "diagnostics.sh" "offline.sh"
    "safe_ops.sh" "monitor.sh" "pg_health.sh" "main.sh" "VERSION" "versions.conf"
)

PLUGIN_MODULES=(
    "mrm-special.js" "mrm-runtime.js" "integrate-dashboard.sh"
    "update-from-panel.sh" "sitecustomize.py" "mrm_admin_subscriptions.py"
    "mrm-integrator.service" "mrm-integrator.path" "mrm-integrator.timer"
    "mrm-panel-update.service" "mrm-panel-update.path"
    "mrm-template-switch.sh" "mrm-template-switch.service" "mrm-template-switch.path"
)

# Remove deprecated/unused files
rm -f "$INSTALL_DIR/site.sh" "$INSTALL_DIR/port_manager.sh" "$INSTALL_DIR/migrator.sh" "$INSTALL_DIR/mirza.sh" 2>/dev/null
ui_success "$INSTALL_DIR"

ui_step 2 4 "Core files"
for FILE in "${FILES[@]}"; do
    if [[ "$FILE" == "VERSION" || "$FILE" == "versions.conf" ]]; then
        URL="$MANAGER_REPO_URL/$FILE"
    else
        URL="$MANAGER_REPO_URL/manager/$FILE"
    fi
    if "${CURL_BASE[@]}" -o "$INSTALL_DIR/$FILE" "$URL" 2>/dev/null; then
        if [[ "$FILE" == "VERSION" || "$FILE" == "versions.conf" ]]; then
            REL="$FILE"
        else
            REL="manager/$FILE"
        fi
        if verify_download "$INSTALL_DIR/$FILE" "$REL"; then
            chmod +x "$INSTALL_DIR/$FILE" 2>/dev/null
            ui_success "$FILE"
        fi
    else
        # MRM-001/002: a failed file is only tolerated for the version text
        # files (regenerated locally from known constants); everything else
        # is a hard failure.
        if [ "$FILE" = "VERSION" ]; then
            echo "$MRM_VERSION" > "$INSTALL_DIR/$FILE"
            ui_success "$FILE (created locally)"
        elif [ "$FILE" = "versions.conf" ]; then
            cat > "$INSTALL_DIR/$FILE" << EOF
MRM_VERSION="$MRM_VERSION"
SSL_VERSION="1.0.9"
BACKUP_VERSION="1.0.5"
THEME_VERSION="2.2.1"
EOF
            ui_success "$FILE (created locally)"
        else
            ui_error "Download failed: $FILE"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    fi
done

ui_step 3 4 "Backup and plugin modules"
BACKUP_MODULES=(
    "init.sh" "telegram.sh" "smart_fix.sh" "database.sh"
    "backup_core.sh" "restore_core.sh" "xray.sh" "post_restore.sh" "menu.sh"
)

for MODULE in "${BACKUP_MODULES[@]}"; do
    URL="$MANAGER_REPO_URL/manager/backup/$MODULE"
    if "${CURL_BASE[@]}" -o "$INSTALL_DIR/backup/$MODULE" "$URL" 2>/dev/null; then
        if verify_download "$INSTALL_DIR/backup/$MODULE" "manager/backup/$MODULE"; then
            chmod +x "$INSTALL_DIR/backup/$MODULE" 2>/dev/null
            ui_success "backup/$MODULE"
        fi
    else
        ui_error "Download failed: backup/$MODULE"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

for MODULE in "${PLUGIN_MODULES[@]}"; do
    URL="$MANAGER_REPO_URL/plugin/$MODULE"
    if "${CURL_BASE[@]}" -o "$INSTALL_DIR/plugin/$MODULE" "$URL" 2>/dev/null; then
        if verify_download "$INSTALL_DIR/plugin/$MODULE" "plugin/$MODULE"; then
            case "$MODULE" in
                *.sh) chmod +x "$INSTALL_DIR/plugin/$MODULE" 2>/dev/null ;;
            esac
            ui_success "plugin/$MODULE"
        fi
    else
        ui_error "Download failed: plugin/$MODULE"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

# MRM-002: a broken install must never be reported as success
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo ""
    ui_error "Install failed: ${FAIL_COUNT} file(s) missing or corrupt."
    ui_note "Nothing from the failed batch was installed (bad files removed)."
    if [ -d "${INSTALL_DIR}.previous" ]; then
        ui_note "The previous version is intact at ${INSTALL_DIR}.previous — restore with:"
        ui_note "  rm -rf $INSTALL_DIR && mv ${INSTALL_DIR}.previous $INSTALL_DIR"
    fi
    exit 1
fi

ui_step 4 4 "Subscription templates"
if [ -z "${DATA_DIR:-}" ]; then
    if [ -d "/var/lib/pasarguard" ]; then
        DATA_DIR="/var/lib/pasarguard"
    elif [ -d "/opt/pasarguard" ]; then
        DATA_DIR="/var/lib/pasarguard"
    fi
fi

if "${CURL_BASE[@]}" -o "$INSTALL_DIR/index.html" "$MANAGER_REPO_URL/templates/subscription/index.html" 2>/dev/null; then
    if verify_download "$INSTALL_DIR/index.html" "templates/subscription/index.html"; then
        ui_success "MRM Special template"
        mkdir -p "$INSTALL_DIR/templates/subscription-special" 2>/dev/null || true
        cp -f "$INSTALL_DIR/index.html" "$INSTALL_DIR/templates/subscription-special/index.html" 2>/dev/null || true
        if [ -n "$DATA_DIR" ] && [ -d "$DATA_DIR/templates" ]; then
            mkdir -p "$DATA_DIR/templates/subscription-special" 2>/dev/null || true
            cp -f "$INSTALL_DIR/index.html" "$DATA_DIR/templates/subscription-special/index.html" 2>/dev/null || true
            cp -f "$INSTALL_DIR/index.html" "$DATA_DIR/templates/.special.pristine.html" 2>/dev/null || true
        fi
    else
        ui_warning "MRM Special template skipped (bad checksum)"
    fi
else
    ui_warning "MRM Special template skipped (download failed)"
fi

if "${CURL_BASE[@]}" -o "$INSTALL_DIR/templates/subscription-classic/index.html" "$MANAGER_REPO_URL/templates/subscription-classic/index.html" 2>/dev/null; then
    if verify_download "$INSTALL_DIR/templates/subscription-classic/index.html" "templates/subscription-classic/index.html"; then
        ui_success "MRM Classic template"
        if [ -n "$DATA_DIR" ] && [ -d "$DATA_DIR/templates" ]; then
            mkdir -p "$DATA_DIR/templates/subscription-classic" 2>/dev/null || true
            cp -f "$INSTALL_DIR/templates/subscription-classic/index.html" "$DATA_DIR/templates/subscription-classic/index.html" 2>/dev/null || true
            cp -f "$INSTALL_DIR/templates/subscription-classic/index.html" "$DATA_DIR/templates/.classic.pristine.html" 2>/dev/null || true
        fi
    else
        ui_warning "MRM Classic template skipped (bad checksum)"
    fi
else
    ui_warning "MRM Classic template skipped (download failed)"
fi

# Refresh the template files the panel actually serves ($DATA_DIR/templates),
# keeping the owner's brand/news values and the active selection. Without this
# an update only replaced /opt/mrm-manager/index.html and customers kept seeing
# the old build forever.
bash "$INSTALL_DIR/theme.sh" --redeploy 2>/dev/null | sed "s/^/${PAD}/" || true

rm -f /usr/local/bin/mrm

# MRM-005: quoted heredoc — the fallback is evaluated at RUNTIME, not install time
cat > /usr/local/bin/mrm << 'EOF'
#!/bin/bash
if [[ "$1" == "--version" || "$1" == "-v" ]]; then
    [ -r /opt/mrm-manager/versions.conf ] && source /opt/mrm-manager/versions.conf
    echo "MRM Manager ${MRM_VERSION:-$(cat /opt/mrm-manager/VERSION 2>/dev/null || echo "1.5.0")}"
    exit 0
fi
exec bash /opt/mrm-manager/main.sh "$@"
EOF
chmod +x /usr/local/bin/mrm

# Installation succeeded — the rollback copy is no longer needed
rm -rf "${INSTALL_DIR}.previous" 2>/dev/null

echo ""
ui_success "${BOLD}MRM Manager v${MRM_VERSION} installed${NC}"
ui_note "Run it any time with:  mrm"
echo ""

# Safe read with fallback for non-interactive environments
if [ -t 0 ]; then
    printf '%s%s›%s Run MRM Manager now? %s[y/N]%s ' "$PAD" "$CYAN" "$NC" "$DIM" "$NC"
    read -t 10 -r RUN_NOW 2>/dev/null || RUN_NOW="n"
else
    RUN_NOW="n"
fi
echo ""
if [[ "$RUN_NOW" =~ ^[Yy]$ ]]; then
    exec /usr/local/bin/mrm
fi
exit 0
