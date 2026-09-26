#!/bin/bash
# MRM Manager backup.sh — Backup & Restore entry point
# Modular structure: each feature lives in backup/<module>.sh

# ─── Load modules ────────────────────────────────────────────────────────────
BACKUP_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/backup" && pwd)"

# Fail fast with a clear message if a module is missing (MRM-043)
for MODULE in init.sh telegram.sh smart_fix.sh database.sh backup_core.sh restore_core.sh xray.sh post_restore.sh menu.sh; do
    if [ -f "$BACKUP_MODULE_DIR/$MODULE" ] && [ -r "$BACKUP_MODULE_DIR/$MODULE" ]; then
        # shellcheck source=/dev/null
        source "$BACKUP_MODULE_DIR/$MODULE"
    else
        echo -e "\033[0;31m  ✘ Backup module missing or unreadable: $BACKUP_MODULE_DIR/$MODULE\033[0m" >&2
        echo -e "    Reinstall MRM Manager with: mrm update" >&2
        exit 1
    fi
done

# ─── fix-node CLI ────────────────────────────────────────────────────────────
backup_fix_node_cli() {
    setup_env
    init_backup_logging

    local FIX_VERBOSE=false
    [[ "${1:-}" == "--verbose" ]] || [[ "${1:-}" == "-v" ]] && FIX_VERBOSE=true
    export MRM_XRAY_VERBOSE="$FIX_VERBOSE"

    local NODE_DATA_DIR
    NODE_DATA_DIR="$(dirname "${NODE_DEF_CERTS:-/var/lib/pg-node/certs}" 2>/dev/null)"
    [ -z "$NODE_DATA_DIR" ] && NODE_DATA_DIR="/var/lib/pg-node"

    ui_header "Node xray-core Repair"
    ui_kv "Node data dir" "$NODE_DATA_DIR"
    ui_kv "Binary path" "$NODE_DATA_DIR/xray-core/xray"
    ui_kv "Architecture" "$(uname -m)"
    ui_kv "Verbose" "$FIX_VERBOSE"
    echo ""

    ui_note "Downloading / repairing xray-core…"
    if mrm_ensure_xray_core; then
        echo ""
        ui_success "xray-core ready: $NODE_DATA_DIR/xray-core/xray"
        local XRAY_VER
        XRAY_VER="$("$NODE_DATA_DIR/xray-core/xray" -version 2>/dev/null | head -1)"
        [ -n "$XRAY_VER" ] && ui_kv "Version" "$XRAY_VER"

        # The node binary is picked from XRAY_EXECUTABLE_PATH; without it the
        # node falls back to /usr/local/bin/xray inside the image and the repair
        # would do nothing. Align .env like the official installer (MRM-040)
        if [ -n "${NODE_ENV:-}" ] && [ -f "$NODE_ENV" ]; then
            if ! grep -q '^XRAY_EXECUTABLE_PATH' "$NODE_ENV"; then
                local NODE_CONT_PATH="$NODE_DATA_DIR/xray-core/xray"
                [ -n "$DATA_DIR" ] && NODE_CONT_PATH="$DATA_DIR/xray-core/xray"
                echo "XRAY_EXECUTABLE_PATH = \"$NODE_CONT_PATH\"" >> "$NODE_ENV"
                ui_info "Added XRAY_EXECUTABLE_PATH = \"$NODE_CONT_PATH\" to $NODE_ENV"
            fi
        fi
        echo ""
        ui_note "Restarting node container…"
        # Match the official pasarguard/node image — "grep -i node" could hit
        # unrelated containers (node-exporter, node-red…) (MRM-039)
        local NODE_CNAME
        NODE_CNAME="$(docker ps -a --format '{{.Names}} {{.Image}}' 2>/dev/null | awk '$2 ~ /^pasarguard\/node(:|$)/ {print $1; exit}')"
        [ -z "$NODE_CNAME" ] && NODE_CNAME="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -x 'node' | head -1)"
        if [ -n "$NODE_CNAME" ]; then
            if docker restart "$NODE_CNAME" >/dev/null 2>&1; then
                ui_success "Node restarted: $NODE_CNAME"
            else
                ui_error "Node restart failed: $NODE_CNAME"
            fi
        else
            ui_warning "No node container found — is the node docker-compose running?"
        fi
        echo ""
        return 0
    fi

    echo ""
    ui_box_start bad "xray-core repair failed"
    ui_box_line "Log" "$BACKUP_LOG"
    ui_box_end
    ui_text "Try the following:"
    ui_cmd "mrm fix-node --verbose" "show detailed errors"
    ui_cmd "apt install -y curl unzip" "make sure the tools exist"
    ui_cmd "curl -v https://github.com 2>&1 | head -5" "test GitHub reachability"
    echo ""
    ui_text "Manual download:"
    local ARCH
    ARCH="$( [ "$(uname -m)" = "aarch64" ] && echo arm64-v8a || echo 64 )"
    ui_cmd "curl -L \"https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH}.zip\" -o /tmp/xray.zip"
    ui_cmd "unzip -o /tmp/xray.zip -d $NODE_DATA_DIR/xray-core/"
    ui_cmd "chmod +x $NODE_DATA_DIR/xray-core/xray"
    ui_cmd "docker restart <node-container>"
    echo ""
    return 1
}

# ─── Entry point ─────────────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        auto)     do_backup "auto" ;;
        fix-node) backup_fix_node_cli "${2:-}"; exit $? ;;
        *)        backup_menu ;;
    esac
fi
