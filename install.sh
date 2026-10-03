#!/bin/bash
# MRM Manager Installer
#   curl -fsSL https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/main/install.sh | sudo bash

INSTALL_DIR="/opt/mrm-manager"
# Pinned release ref + checksums: files are downloaded from this exact ref and
# verified against checksums.txt (integrity). install.sh itself is bootstrapped
# via the README curl command and therefore cannot self-verify.
REPO_BASE_URL="https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard"
REPO_REF="v1.5.10"
MANAGER_REPO_URL="$REPO_BASE_URL/$REPO_REF"
VERSION_REGISTRY_URL="$MANAGER_REPO_URL/versions.conf"
CHECKSUMS_URL="$MANAGER_REPO_URL/checksums.txt"
# MRM-004: bounded downloads, TLS only
CURL_BASE=(curl -fsSL --connect-timeout 10 --max-time 60 --proto '=https' --tlsv1.2)

# ─── Minimal UI (ui.sh is not installed yet — same look, self-contained) ─────
# 256-colour capable? `tput colors` is unreliable over SSH (Termius, PuTTY and
# Windows Terminal often announce TERM=xterm yet render 256 colours), so the
# terminal name / COLORTERM are trusted first. Same rule as manager/ui.sh.
has_256_colors() {
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
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; CYAN=$'\033[0;36m'
    BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'; TEXT=""; FRAME=$CYAN
    # Same palette as manager/ui.sh (amber) on 256-colour terminals, so the
    # installer looks like the manager regardless of the client's 16-colour theme.
    if has_256_colors && [ "${MRM_PALETTE:-amber}" != "classic" ]; then
        RED=$'\033[38;5;174m'; GREEN=$'\033[38;5;108m'; YELLOW=$'\033[38;5;215m'
        CYAN=$'\033[38;5;179m'; DIM=$'\033[38;5;244m'; TEXT=$'\033[38;5;250m'; FRAME=$'\033[38;5;238m'
        [ "${MRM_THEME:-dark}" = "light" ] && TEXT=""
    fi
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; BOLD=""; DIM=""; NC=""; TEXT=""; FRAME=""
fi
PAD="  "
TASK_OPEN=0
TASK_LABEL_LEN=0
_task_break() { [ "$TASK_OPEN" = 1 ] && { echo ""; TASK_OPEN=0; }; return 0; }
# پیام‌ها با بودجهٔ «عرض منهای پیشوند» شکسته می‌شوند؛ پیشوند = PAD + نشانگر + فاصله
_ui_msg() { # _ui_msg COLOUR GLYPH TEXT
    local C="$1" G="$2" T="$3" MAX FIRST=1 _l
    MAX=$(( $(ui_cols) - 4 ))
    [ "$MAX" -lt 12 ] && MAX=12
    ui_wrap "$T" "$MAX" | while IFS= read -r _l; do
        if [ "$FIRST" = 1 ]; then
            printf '%s%b%s%b %b%s%b\n' "$PAD" "$C" "$G" "$NC" "$TEXT" "${_l#"$PAD"}" "$NC"
            FIRST=0
        else
            printf '%s  %b%s%b\n' "$PAD" "$TEXT" "${_l#"$PAD"}" "$NC"
        fi
    done
}
ui_success() { _task_break; _ui_msg "$GREEN" "✔" "$1"; }
ui_error()   { _task_break; _ui_msg "$RED" "✘" "$1" >&2; }
ui_warning() { _task_break; _ui_msg "$YELLOW" "⚠" "$1"; }
ui_note()    { _task_break; ui_wrap "$1" | while IFS= read -r _l; do printf '%b%s%b\n' "$DIM" "$_l" "$NC"; done; }
ui_step()    { _task_break; printf '\n%s%s[%s/%s]%s %s%s%s\n' "$PAD" "$CYAN" "$1" "$2" "$NC" "$BOLD$TEXT" "$3" "$NC"; }
# ui_task "label" … ui_task_done ok|bad ["detail"]  —   › label … ✔ detail
ui_task() {
    # برچسب بلند هم بریده می‌شود تا خط پیشرفت از لبهٔ پنجره بیرون نزند
    local LABEL; LABEL="$(ui_cut "$1" $(( $(ui_cols) - 8 )))"
    TASK_LABEL_LEN=${#LABEL}
    printf '%s%s›%s %s%s%s %s…%s ' "$PAD" "$CYAN" "$NC" "$TEXT" "$LABEL" "$NC" "$DIM" "$NC"; TASK_OPEN=1
}
ui_task_done() {
    local C G; case "$1" in ok) C="$GREEN"; G="✔" ;; warn) C="$YELLOW"; G="⚠" ;; *) C="$RED"; G="✘" ;; esac
    if [ "$TASK_OPEN" = 1 ]; then
        printf '%s%s%s' "$C" "$G" "$NC"
        # بریدن جزئیات تا خط پیشرفت پنجره را نشکند
        # جزئیات به عرض باقی‌ماندهٔ خط محدود می‌شود: PAD + «› » + برچسب + « … » + نشانگر
        local BUDGET=$(( $(ui_cols) - ${TASK_LABEL_LEN:-0} - 9 ))
        # اگر جا برای جزئیات معنادار نباشد چاپ نمی‌شود («unreach…» گنگ‌تر از نبودنش است)
        [ -n "${2:-}" ] && [ "$BUDGET" -ge 8 ] && printf ' %s%s%s' "$DIM" "$(ui_cut "$2" "$BUDGET")" "$NC"
        echo ""
    else
        printf '%s%s%s%s %s%s%s\n' "$PAD" "$C" "$G" "$NC" "$TEXT" "${2:-done}" "$NC"
    fi
    TASK_OPEN=0
}
ui_repeat() { local OUT="" i; for ((i=0; i<${2:-0}; i++)); do OUT+="$1"; done; printf '%s' "$OUT"; }

# عرض مفید پنجره (منهای تورفتگی). زنجیرهٔ تشخیص: COLUMNS → stty size → tput cols.
# `stty size` از خودِ ترمینال می‌پرسد و با TERM ناشناخته/خالی هم کار می‌کند.
ui_cols() {
    local cols="${COLUMNS:-}"
    # یک منبع وقتی معتبر است که عدد باشد و ≥ ۲۰ ستون بدهد. pty بدون اندازه
    # («stty size» = 0 0) و ترمینال‌های عجیب نباید رابط را به یک‌ستونی برسانند.
    if [ -z "$cols" ] || ! [[ "$cols" =~ ^[0-9]+$ ]] || [ "$cols" -lt 20 ]; then
        cols="$(stty size 2>/dev/null | awk '{print $2}')"
    fi
    if [ -z "$cols" ] || ! [[ "$cols" =~ ^[0-9]+$ ]] || [ "$cols" -lt 20 ]; then
        cols="$(tput cols 2>/dev/null || echo 80)"
    fi
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
    [ "$cols" -lt 20 ] && cols=80
    local w=$(( cols - ${#PAD} ))
    [ "$w" -gt 100 ] && w=100      # متن‌های خیلی بلند روی ترمینال غول‌پیکر هم خوانا بمانند
    [ "$w" -lt 1 ] && w=1
    echo "$w"
}

# عرض متن: هر نویسه یک ستون. همهٔ نویسه‌های این رابط (✔ ✘ ⚠ › • —) یک‌ستونی‌اند؛
# در لوکیل C محافظه‌کارانه بیش‌برآورد می‌شود (زودتر می‌شکند) که بی‌خطر است.
ui_cut() {
    local s="$1" max="$2"
    [ "${#s}" -le "$max" ] && { printf '%s' "$s"; return 0; }
    [ "$max" -le 1 ] && { printf '%s' "${s:0:1}"; return 0; }
    printf '%s…' "${s:0:$(( max - 1 ))}"
}

# ui_wrap TEXT [MAX] — متن را پیش از سرریز کردن پنجره می‌شکند؛ واژهٔ بلند
# (URL/مسیر) هم تکه می‌شود تا خطی از لبهٔ ترمینال بیرون نزند.
ui_wrap() {
    local TEXT="$1" MAX="${2:-}" LINE="" WORD PIECE REST
    [ -n "$MAX" ] || MAX="$(ui_cols)"
    [ "$MAX" -lt 12 ] && MAX=12
    for WORD in $TEXT; do
        if [ "${#WORD}" -gt "$MAX" ]; then
            [ -n "$LINE" ] && { printf '%s%s\n' "$PAD" "$LINE"; LINE=""; }
            while [ "${#WORD}" -gt "$MAX" ]; do
                printf '%s%s\n' "$PAD" "${WORD:0:$MAX}"
                WORD="${WORD:$MAX}"
            done
            LINE="$WORD"
            continue
        fi
        if [ -z "$LINE" ]; then
            LINE="$WORD"
        elif [ $(( ${#LINE} + 1 + ${#WORD} )) -le "$MAX" ]; then
            LINE="$LINE $WORD"
        else
            printf '%s%s\n' "$PAD" "$LINE"
            LINE="$WORD"
        fi
    done
    [ -n "$LINE" ] && printf '%s%s\n' "$PAD" "$LINE"
    return 0
}
ui_bullet() {
    _task_break
    local FIRST=1 _l MAX
    MAX=$(( $(ui_cols) - 4 )); [ "$MAX" -lt 12 ] && MAX=12
    ui_wrap "$1" "$MAX" | while IFS= read -r _l; do
        if [ "$FIRST" = 1 ]; then
            printf '%s%b•%b %b%s%b\n' "$PAD" "$CYAN" "$NC" "$TEXT" "${_l#"$PAD"}" "$NC"; FIRST=0
        else
            printf '%s  %b%s%b\n' "$PAD" "$TEXT" "${_l#"$PAD"}" "$NC"
        fi
    done
}
# ask_run_now <seconds> [default] — live countdown, so the default is never a
# silent surprise when the operator walks away from the prompt.
ask_run_now() {
    local LEFT="${1:-10}" DEFAULT="${2:-n}" ANS=""
    # The countdown is drawn on stderr: the caller captures stdout for the answer,
    # so anything printed to stdout would never reach the operator.
    while [ "$LEFT" -gt 0 ]; do
        printf '\r%s%s›%s %sRun MRM Manager now?%s %s[y/N]%s %s(%ss)%s ' \
            "$PAD" "$CYAN" "$NC" "$TEXT" "$NC" "$DIM" "$NC" "$DIM" "$LEFT" "$NC" >&2
        if read -t 1 -r ANS; then printf '\n' >&2; printf '%s' "$ANS"; return 0; fi
        LEFT=$((LEFT - 1))
    done
    printf '\n' >&2
    printf '%s' "$DEFAULT"
}
ui_header() {
    local TITLE="$1" W LINE
    W="$(ui_cols)"
    [ "$W" -gt 56 ] && W=56        # سقف خوانایی قاب (متن‌ها سقف جداگانه دارند)
    # کف خوانایی روی پنجرهٔ باریک قربانی می‌شود: قابِ شکسته بدتر از قابِ کوتاه است
    if [ "${#TITLE}" -gt $(( W - 4 )) ]; then TITLE="$(ui_cut "$TITLE" $(( W - 4 )))"; fi
    LINE="$(ui_repeat '─' $((W - 2)))"      # no `tr`: it is byte-based and mangles UTF-8
    printf '\n%s%s┌%s┐%s\n' "$PAD" "$FRAME" "$LINE" "$NC"
    printf '%s%s│%s %s%-*s%s %s│%s\n' "$PAD" "$FRAME" "$NC" "$BOLD$TEXT" $((W - 4)) "$TITLE" "$NC" "$FRAME" "$NC"
    printf '%s%s└%s┘%s\n\n' "$PAD" "$FRAME" "$LINE" "$NC"
}

# MRM-006: POSIX-safe root check (EUID is undefined under dash)
[ "$(id -u)" -ne 0 ] && { ui_error "Please run as root"; exit 1; }

ui_header "MRM Manager Installer"

# ─── Pre-flight: fail before touching anything, with a way out ──────────────
MISSING_TOOLS=""
for TOOL in curl sha256sum awk grep sed; do
    command -v "$TOOL" >/dev/null 2>&1 || MISSING_TOOLS="$MISSING_TOOLS $TOOL"
done
if [ -n "$MISSING_TOOLS" ]; then
    ui_error "Missing required tools:${MISSING_TOOLS}"
    ui_note "Nothing was installed. Install them and re-run:"
    ui_note "  apt-get update && apt-get install -y${MISSING_TOOLS}"
    exit 1
fi

# Free space is measured on the filesystem that will hold $INSTALL_DIR.
MRM_MIN_FREE_MB="${MRM_MIN_FREE_MB:-50}"
TARGET_PARENT="$(dirname "$INSTALL_DIR")"
[ -d "$TARGET_PARENT" ] || TARGET_PARENT="/"
FREE_KB="$(df -Pk "$TARGET_PARENT" 2>/dev/null | awk 'NR==2 {print $4}')"
case "$FREE_KB" in ''|*[!0-9]*) FREE_KB=0 ;; esac
if [ "$FREE_KB" -lt $((MRM_MIN_FREE_MB * 1024)) ]; then
    ui_error "Not enough free space on $TARGET_PARENT: $((FREE_KB / 1024)) MB free, ${MRM_MIN_FREE_MB} MB needed"
    ui_note "Nothing was installed. Free some space (or lower MRM_MIN_FREE_MB) and re-run."
    exit 1
fi

# MRM-003: keep a rollback copy of the current install before overwriting
HAD_PREVIOUS=0
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "${INSTALL_DIR}.previous" 2>/dev/null
    cp -a "$INSTALL_DIR" "${INSTALL_DIR}.previous" 2>/dev/null && HAD_PREVIOUS=1
else
    mkdir -p "$INSTALL_DIR"
fi

# MRM-001: the version is parsed (never sourced) from the pinned versions.conf.
# The same fetch doubles as the connectivity probe: every file comes from this
# one host, so an unreachable host is reported here — once, with a fix —
# instead of surfacing as a stream of per-file download failures.
MRM_VERSION=""
VERSION_REGISTRY_FILE="$(mktemp)"
ui_task "Contacting the release host"
if "${CURL_BASE[@]}" -o "$VERSION_REGISTRY_FILE" "$VERSION_REGISTRY_URL" 2>/dev/null; then
    MRM_VERSION="$(grep -E '^MRM_VERSION=' "$VERSION_REGISTRY_FILE" 2>/dev/null | head -1 | cut -d'"' -f2)"
    ui_task_done ok "release $REPO_REF reachable"
else
    ui_task_done bad "unreachable"
    ui_error "This server cannot reach $REPO_BASE_URL"
    ui_note "Nothing was installed. Usual causes: no outbound network, broken DNS,"
    ui_note "a proxy that drops githubusercontent.com, or the release being unavailable."
    ui_note "Check with:  curl -I $REPO_BASE_URL/$REPO_REF/versions.conf"
    exit 1
fi
rm -f "$VERSION_REGISTRY_FILE"

# Fallback only if the registry answered but carried no version
if [ -z "$MRM_VERSION" ]; then
    MRM_VERSION="1.5.10"
    ui_warning "versions.conf answered without MRM_VERSION — assuming ${MRM_VERSION}"
fi

ui_note "Release: $REPO_REF  ·  Target: $INSTALL_DIR"
[ "$HAD_PREVIOUS" -eq 1 ] && ui_note "Rollback copy: ${INSTALL_DIR}.previous"

# MRM-001: integrity manifest (checksums.txt) is mandatory — abort if absent
CHECKSUMS_FILE="$(mktemp)"
trap 'rm -f "$CHECKSUMS_FILE"' EXIT
if ! "${CURL_BASE[@]}" -o "$CHECKSUMS_FILE" "$CHECKSUMS_URL" 2>/dev/null; then
    ui_error "Could not download the integrity manifest (checksums.txt)"
    ui_note "Nothing was installed — files are only written after their checksum is verified."
    ui_note "The release host answered the version check but not this file. Likely causes:"
    ui_note "  · the pinned release $REPO_REF no longer carries checksums.txt"
    ui_note "  · a proxy or filter dropped the connection mid-download"
    ui_note "Check with:  curl -I $CHECKSUMS_URL"
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

ui_step 1 5 "Preparing directories"
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

ui_step 2 5 "Core files"
OK_COUNT=0
ui_task "Downloading ${#FILES[@]} files"
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
            OK_COUNT=$((OK_COUNT + 1))
        fi
    else
        # MRM-001/002: a failed file is only tolerated for the version text
        # files (regenerated locally from known constants); everything else
        # is a hard failure.
        if [ "$FILE" = "VERSION" ]; then
            echo "$MRM_VERSION" > "$INSTALL_DIR/$FILE"
            ui_warning "$FILE could not be downloaded — created locally"
        elif [ "$FILE" = "versions.conf" ]; then
            cat > "$INSTALL_DIR/$FILE" << EOF
MRM_VERSION="$MRM_VERSION"
SSL_VERSION="1.0.10"
BACKUP_VERSION="1.0.9"
THEME_VERSION="2.2.1"
EOF
            ui_warning "$FILE could not be downloaded — created locally"
        else
            ui_error "Download failed: $FILE"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    fi
done
if [ "$FAIL_COUNT" -eq 0 ]; then ui_task_done ok "${OK_COUNT} files verified"; else ui_task_done bad "Core files: ${FAIL_COUNT} of ${#FILES[@]} failed"; fi

ui_step 3 5 "Backup and plugin modules"
BACKUP_MODULES=(
    "init.sh" "telegram.sh" "smart_fix.sh" "database.sh"
    "backup_core.sh" "restore_core.sh" "xray.sh" "post_restore.sh" "menu.sh"
)

GROUP_FAIL=$FAIL_COUNT; OK_COUNT=0
ui_task "Backup modules (${#BACKUP_MODULES[@]})"
for MODULE in "${BACKUP_MODULES[@]}"; do
    URL="$MANAGER_REPO_URL/manager/backup/$MODULE"
    if "${CURL_BASE[@]}" -o "$INSTALL_DIR/backup/$MODULE" "$URL" 2>/dev/null; then
        if verify_download "$INSTALL_DIR/backup/$MODULE" "manager/backup/$MODULE"; then
            chmod +x "$INSTALL_DIR/backup/$MODULE" 2>/dev/null
            OK_COUNT=$((OK_COUNT + 1))
        fi
    else
        ui_error "Download failed: backup/$MODULE"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done
if [ "$FAIL_COUNT" -eq "$GROUP_FAIL" ]; then ui_task_done ok "${OK_COUNT} files verified"; else ui_task_done bad "Backup modules: $((FAIL_COUNT - GROUP_FAIL)) of ${#BACKUP_MODULES[@]} failed"; fi

GROUP_FAIL=$FAIL_COUNT; OK_COUNT=0
ui_task "Panel plugin (${#PLUGIN_MODULES[@]})"
for MODULE in "${PLUGIN_MODULES[@]}"; do
    URL="$MANAGER_REPO_URL/plugin/$MODULE"
    if "${CURL_BASE[@]}" -o "$INSTALL_DIR/plugin/$MODULE" "$URL" 2>/dev/null; then
        if verify_download "$INSTALL_DIR/plugin/$MODULE" "plugin/$MODULE"; then
            case "$MODULE" in
                *.sh) chmod +x "$INSTALL_DIR/plugin/$MODULE" 2>/dev/null ;;
            esac
            OK_COUNT=$((OK_COUNT + 1))
        fi
    else
        ui_error "Download failed: plugin/$MODULE"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done
if [ "$FAIL_COUNT" -eq "$GROUP_FAIL" ]; then ui_task_done ok "${OK_COUNT} files verified"; else ui_task_done bad "Panel plugin: $((FAIL_COUNT - GROUP_FAIL)) of ${#PLUGIN_MODULES[@]} failed"; fi

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

ui_step 4 5 "Subscription templates"
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

ui_step 5 5 "Panel integration and CLI"

# Refresh the template files the panel actually serves ($DATA_DIR/templates),
# keeping the owner's brand/news values and the active selection. Without this
# an update only replaced /opt/mrm-manager/index.html and customers kept seeing
# the old build forever. Skipped where the panel is not installed (node-only servers).
TEMPLATES_LIVE=0
if [ -f /opt/pasarguard/.env ] || [ -d "${DATA_DIR:-/nonexistent}/templates" ]; then
    bash "$INSTALL_DIR/theme.sh" --redeploy 2>/dev/null | sed "s/^/${PAD}/" || true
    TEMPLATES_LIVE=1
else
    ui_note "Panel is not on this server — templates kept in $INSTALL_DIR for later use"
fi

rm -f /usr/local/bin/mrm

# MRM-005: quoted heredoc — the fallback is evaluated at RUNTIME, not install time
cat > /usr/local/bin/mrm << 'EOF'
#!/bin/bash
if [[ "$1" == "--version" || "$1" == "-v" ]]; then
    [ -r /opt/mrm-manager/versions.conf ] && source /opt/mrm-manager/versions.conf
    echo "MRM Manager ${MRM_VERSION:-$(cat /opt/mrm-manager/VERSION 2>/dev/null || echo "1.5.10")}"
    exit 0
fi
exec bash /opt/mrm-manager/main.sh "$@"
EOF
chmod +x /usr/local/bin/mrm
ui_success "mrm command ready"

# Installation succeeded — the rollback copy is no longer needed
rm -rf "${INSTALL_DIR}.previous" 2>/dev/null

# Record the installed release for the in-panel update check
# (plugin/mrm_admin_subscriptions.py reads $DATA_DIR/mrm/install-state.json).
# Only where the panel data directory exists — node-only servers have no panel.
if [ -n "${DATA_DIR:-}" ] && [ -d "$DATA_DIR" ]; then
    mkdir -p "$DATA_DIR/mrm" 2>/dev/null && \
    printf '{\n  "version": "%s",\n  "release": "%s",\n  "installed_at": "%s",\n  "source": "install.sh"\n}\n' \
        "$MRM_VERSION" "$REPO_REF" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$DATA_DIR/mrm/install-state.json" 2>/dev/null || true
    chmod 600 "$DATA_DIR/mrm/install-state.json" 2>/dev/null || true
    ui_success "Panel update check will report v${MRM_VERSION}"
fi

echo ""
ui_success "${BOLD}MRM Manager v${MRM_VERSION} installed${NC}"

# What the operator should do next — the install ends here, the experience does not.
echo ""
ui_note "Next steps"
ui_bullet "mrm  —  manager: status, SSL, backup, updates"
ui_bullet "PasarGuard panel → Settings → MRM Special  —  enable the tab, set the store"
if [ "$TEMPLATES_LIVE" -eq 1 ]; then
    ui_note "  Templates are already published. If the panel still serves the old page:  pasarguard restart"
else
    ui_note "  No panel on this server yet — templates are waiting in $INSTALL_DIR/templates"
fi
echo ""

# Safe read with fallback for non-interactive environments
if [ -t 0 ]; then
    RUN_NOW="$(ask_run_now 10 n)"
else
    RUN_NOW="n"
fi
echo ""
if [[ "$RUN_NOW" =~ ^[Yy]$ ]]; then
    exec /usr/local/bin/mrm
fi
exit 0
