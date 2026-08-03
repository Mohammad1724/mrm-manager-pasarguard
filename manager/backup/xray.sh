#!/bin/bash
# MRM Backup - Xray Module
# Download xray-core binary + geo files if missing

mrm_xray_arch() {
    case "$(uname -m 2>/dev/null)" in
        aarch64|arm64)          echo "arm64-v8a" ;;
        armv7l|armv7)           echo "arm32-v7a" ;;
        x86_64|amd64|*)         echo "64" ;;
    esac
}

# Download Xray-core binary if missing (backups intentionally exclude the ~25MB
# binary + geo files; the panel needs them at /var/lib/pg-node/xray-core/xray).
# Mirrors the official installer's download logic. No-op if already present.
mrm_ensure_xray_core() {
    local VERBOSE="${MRM_XRAY_VERBOSE:-false}"
    local XRAY_DIR ASSETS_DIR XRAY_BIN
    local NODE_DATA
    NODE_DATA="$(dirname "${NODE_DEF_CERTS:-/var/lib/pg-node/certs}" 2>/dev/null)"
    [ -z "$NODE_DATA" ] && NODE_DATA="/var/lib/pg-node"
    XRAY_DIR="$NODE_DATA/xray-core"
    ASSETS_DIR="$NODE_DATA/assets"
    XRAY_BIN="$XRAY_DIR/xray"

    _xlog() { [ "$VERBOSE" = true ] && echo -e "  ${CYAN}→${NC} $*" || true; log_backup "INFO" "$*"; }
    _xerr() { [ "$VERBOSE" = true ] && echo -e "  ${RED}✘${NC} $*" || true; log_backup "ERROR" "$*"; }
    _xok()  { [ "$VERBOSE" = true ] && echo -e "  ${GREEN}✔${NC} $*" || true; log_backup "SUCCESS" "$*"; }

    # --- Step 0: Check if already working ---
    local XRAY_OK=false
    if [ -x "$XRAY_BIN" ]; then
        if "$XRAY_BIN" -version >/dev/null 2>&1; then
            XRAY_OK=true
            _xok "xray-core already working: $XRAY_BIN"
        else
            _xlog "xray binary present but not runnable (wrong arch?) - re-downloading"
            rm -f "$XRAY_BIN"
        fi
    fi

    mkdir -p "$XRAY_DIR" "$ASSETS_DIR" 2>/dev/null || { _xerr "Cannot create dirs: $XRAY_DIR $ASSETS_DIR"; return 1; }

    # --- Step 1: Ensure prerequisites ---
    if ! command -v curl >/dev/null 2>&1; then
        _xerr "curl is NOT installed! Installing..."
        if [ "$VERBOSE" = true ]; then
            apt-get update -qq && apt-get install -y -qq curl 2>/dev/null || yum install -y curl 2>/dev/null || { _xerr "Cannot install curl"; return 1; }
        else
            apt-get update -qq && apt-get install -y -qq curl 2>/dev/null || yum install -y curl 2>/dev/null || { log_backup "ERROR" "Cannot install curl"; return 1; }
        fi
        _xok "curl installed"
    fi

    if ! command -v unzip >/dev/null 2>&1; then
        _xlog "unzip is NOT installed! Installing..."
        if [ "$VERBOSE" = true ]; then
            apt-get update -qq && apt-get install -y -qq unzip 2>/dev/null || yum install -y unzip 2>/dev/null || { _xerr "Cannot install unzip"; return 1; }
        else
            apt-get update -qq && apt-get install -y -qq unzip 2>/dev/null || yum install -y unzip 2>/dev/null || { log_backup "ERROR" "Cannot install unzip"; return 1; }
        fi
        _xok "unzip installed"
    fi

    if ! command -v unzip >/dev/null 2>&1; then
        _xerr "unzip still not available after install attempt!"
        return 1
    fi

    # --- Step 2: Download geo files if missing ---
    if [ ! -f "$ASSETS_DIR/geoip.dat" ] || [ ! -f "$ASSETS_DIR/geosite.dat" ]; then
        _xlog "Downloading geo files..."
        local GEO_MIRRORS=(
            "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
            "https://gh.api.99988866.xyz/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
            "https://ghfast.top/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
            "https://mirror.ghproxy.com/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
        )
        local GEO_OK=false
        for MIRROR in "${GEO_MIRRORS[@]}"; do
            [ "$GEO_OK" = true ] && break
            _xlog "Trying geo mirror: $MIRROR"
            local CURL_ERR
            CURL_ERR="$(mktemp /tmp/geo_err.XXXXXX)"
            curl -fsSL --connect-timeout 20 --max-time 120 "$MIRROR/geoip.dat" -o "$ASSETS_DIR/geoip.dat" 2>"$CURL_ERR" || true
            curl -fsSL --connect-timeout 20 --max-time 120 "$MIRROR/geosite.dat" -o "$ASSETS_DIR/geosite.dat" 2>>"$CURL_ERR" || true
            if [ -s "$ASSETS_DIR/geoip.dat" ] && [ -s "$ASSETS_DIR/geosite.dat" ]; then
                GEO_OK=true
                _xok "Geo files downloaded from mirror"
            else
                if [ "$VERBOSE" = true ] && [ -s "$CURL_ERR" ]; then
                    _xlog "Mirror failed: $(head -1 "$CURL_ERR")"
                fi
                rm -f "$ASSETS_DIR/geoip.dat" "$ASSETS_DIR/geosite.dat" 2>/dev/null
            fi
            rm -f "$CURL_ERR"
        done
        [ "$GEO_OK" = false ] && _xerr "All geo mirrors failed"
    fi

    if [ "$XRAY_OK" = true ]; then
        return 0
    fi

    # --- Step 3: Download xray-core binary ---
    local ARCH
    ARCH="$(mrm_xray_arch)"
    _xlog "System arch: $(uname -m) → xray arch: $ARCH"
    _xlog "Target path: $XRAY_BIN"

    # Test basic internet connectivity first
    if ! curl -fsSL --connect-timeout 10 "https://www.google.com" -o /dev/null 2>/dev/null &&        ! curl -fsSL --connect-timeout 10 "https://1.1.1.1" -o /dev/null 2>/dev/null; then
        _xerr "NO INTERNET CONNECTION detected! Cannot download xray-core."
        _xerr "Check: curl -v https://github.com 2>&1 | head -20"
        return 1
    fi
    _xok "Internet connectivity confirmed"

    local XRAY_MIRRORS=(
        "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH}.zip"
        "https://gh.api.99988866.xyz/https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH}.zip"
        "https://ghfast.top/https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH}.zip"
        "https://mirror.ghproxy.com/https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH}.zip"
    )

    local TMPZ DOWNLOADED=false LAST_ERR=""
    TMPZ="$(mktemp /tmp/xray.XXXXXX.zip)" || { _xerr "Cannot create temp file"; return 1; }

    for MIRROR_URL in "${XRAY_MIRRORS[@]}"; do
        [ "$DOWNLOADED" = true ] && break
        _xlog "Trying: $MIRROR_URL"
        local CURL_ERR_FILE
        CURL_ERR_FILE="$(mktemp /tmp/xray_err.XXXXXX)"
        if curl -fsSL --connect-timeout 20 --max-time 180 "$MIRROR_URL" -o "$TMPZ" 2>"$CURL_ERR_FILE"; then
            if [ -s "$TMPZ" ]; then
                local ZIP_SIZE
                ZIP_SIZE="$(stat -c%s "$TMPZ" 2>/dev/null || echo 0)"
                _xlog "Downloaded: $(( ZIP_SIZE / 1024 ))KB"
                if unzip -o "$TMPZ" -d "$XRAY_DIR" >/dev/null 2>/dev/null; then
                    chmod +x "$XRAY_DIR/xray" 2>/dev/null
                    if [ -x "$XRAY_BIN" ] && "$XRAY_BIN" -version >/dev/null 2>&1; then
                        DOWNLOADED=true
                        _xok "xray-core downloaded and verified!"
                    else
                        _xerr "xray binary not runnable after extraction (wrong arch: $(uname -m))"
                        rm -f "$XRAY_BIN" 2>/dev/null
                    fi
                else
                    _xerr "unzip failed! Trying to install unzip..."
                    apt-get install -y -qq unzip 2>/dev/null || yum install -y -qq unzip 2>/dev/null || true
                    if command -v unzip >/dev/null 2>&1; then
                        unzip -o "$TMPZ" -d "$XRAY_DIR" >/dev/null 2>/dev/null &&                         chmod +x "$XRAY_DIR/xray" 2>/dev/null &&                         [ -x "$XRAY_BIN" ] && "$XRAY_BIN" -version >/dev/null 2>&1 &&                         DOWNLOADED=true && _xok "xray-core downloaded after unzip reinstall!"
                    fi
                fi
            else
                _xerr "Downloaded file is empty (0 bytes)"
            fi
        else
            LAST_ERR="$(cat "$CURL_ERR_FILE" 2>/dev/null | head -1)"
            if [ "$VERBOSE" = true ] && [ -n "$LAST_ERR" ]; then
                _xlog "curl error: $LAST_ERR"
            fi
        fi
        rm -f "$CURL_ERR_FILE" "$TMPZ" 2>/dev/null
        TMPZ="$(mktemp /tmp/xray.XXXXXX.zip)" 2>/dev/null || true
    done

    rm -f "$TMPZ" 2>/dev/null

    if [ "$DOWNLOADED" = true ]; then
        return 0
    fi

    _xerr "ALL MIRRORS FAILED!"
    _xerr "Target: $XRAY_BIN"
    _xerr "Arch: $ARCH ($(uname -m))"
    if [ -n "$LAST_ERR" ]; then
        _xerr "Last error: $LAST_ERR"
    fi
    _xerr ""
    _xerr "Manual fix options:"
    _xerr "  1. mrm fix-node --verbose  (show detailed errors)"
    _xerr "  2. curl -v https://github.com  (test connectivity)"
    _xerr "  3. Download manually and place at: $XRAY_BIN"
    return 1
}

# Pick which DB file to restore from a backup root. Prints "TYPE|PATH"
# (sqlite MUST be checked before *.sql - "db.sqlite3" matches "*db.sql*"!)
