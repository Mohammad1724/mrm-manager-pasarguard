#!/bin/bash
# MRM Manager Backup v1.1.10
# Modular structure: each feature in its own file for easier maintenance

# ==========================================
# LOAD ALL MODULES
# ==========================================

BACKUP_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/backup" && pwd)"

# FIX: fail fast with a clear message if a module is missing (MRM-043)
for MODULE in init.sh telegram.sh smart_fix.sh database.sh backup_core.sh restore_core.sh xray.sh post_restore.sh menu.sh; do
    if [ -f "$BACKUP_MODULE_DIR/$MODULE" ] && [ -r "$BACKUP_MODULE_DIR/$MODULE" ]; then
        # shellcheck source=/dev/null
        source "$BACKUP_MODULE_DIR/$MODULE"
    else
        echo -e "\033[0;31m✘ Backup module missing or unreadable: $BACKUP_MODULE_DIR/$MODULE\033[0m" >&2
        echo -e "\033[0;31m  Reinstall MRM Manager or restore backup/modules/\033[0m" >&2
        exit 1
    fi
done

# ==========================================
# ENTRY POINT
# ==========================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ "$1" == "auto" ]; then
        do_backup "auto"
    elif [ "$1" == "fix-node" ]; then
        setup_env
        init_backup_logging

        FIX_VERBOSE=false
        [[ "$2" == "--verbose" ]] || [[ "$2" == "-v" ]] && FIX_VERBOSE=true
        export MRM_XRAY_VERBOSE="$FIX_VERBOSE"

        NODE_DATA_DIR="$(dirname "${NODE_DEF_CERTS:-/var/lib/pg-node/certs}" 2>/dev/null)"
        [ -z "$NODE_DATA_DIR" ] && NODE_DATA_DIR="/var/lib/pg-node"

        echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║  🔧 Node xray-core Repair Tool          ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${CYAN}Node data dir:${NC} $NODE_DATA_DIR"
        echo -e "  ${CYAN}Expected path:${NC} $NODE_DATA_DIR/xray-core/xray"
        echo -e "  ${CYAN}System arch:${NC}   $(uname -m)"
        echo -e "  ${CYAN}Verbose:${NC}       $FIX_VERBOSE"
        echo ""

        echo -e "${YELLOW}Downloading/repairing xray-core...${NC}"
        if mrm_ensure_xray_core; then
            echo ""
            echo -e "${GREEN}✔ xray-core ready: $NODE_DATA_DIR/xray-core/xray${NC}"
            "$NODE_DATA_DIR/xray-core/xray" -version 2>/dev/null | head -1 || true

            # FIX: the node binary is picked from XRAY_EXECUTABLE_PATH; without it
            # the node falls back to /usr/local/bin/xray inside the image and the
            # repair would do nothing. Align .env like the official installer (MRM-040)
            if [ -n "${NODE_ENV:-}" ] && [ -f "$NODE_ENV" ]; then
                if ! grep -q '^XRAY_EXECUTABLE_PATH' "$NODE_ENV"; then
                    NODE_CONT_PATH="$NODE_DATA_DIR/xray-core/xray"
                    [ -n "$DATA_DIR" ] && NODE_CONT_PATH="$DATA_DIR/xray-core/xray"
                    echo "XRAY_EXECUTABLE_PATH = \"$NODE_CONT_PATH\"" >> "$NODE_ENV"
                    echo -e "${CYAN}→ Added XRAY_EXECUTABLE_PATH = \"$NODE_CONT_PATH\" to $NODE_ENV${NC}"
                fi
            fi
            echo ""
            echo -e "${YELLOW}Restarting node container...${NC}"
            # FIX: match the official pasarguard/node image — "grep -i node" could
            # hit unrelated containers (node-exporter, node-red…) (MRM-039)
            NODE_CNAME="$(docker ps -a --format '{{.Names}} {{.Image}}' 2>/dev/null | awk '$2 ~ /^pasarguard\/node(:|$)/ {print $1; exit}')"
            [ -z "$NODE_CNAME" ] && NODE_CNAME="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -x 'node' | head -1)"
            if [ -n "$NODE_CNAME" ]; then
                if docker restart "$NODE_CNAME" >/dev/null 2>&1; then
                    echo -e "${GREEN}✔ Node restarted: $NODE_CNAME${NC}"
                else
                    echo -e "${RED}✘ Node restart failed: $NODE_CNAME${NC}"
                fi
            else
                echo -e "${YELLOW}⚠ No node container found (is the node docker-compose running?)${NC}"
            fi
            exit 0
        else
            echo ""
            echo -e "${RED}╔══════════════════════════════════════════╗${NC}"
            echo -e "${RED}║  ✘ REPAIR FAILED                        ║${NC}"
            echo -e "${RED}╚══════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${YELLOW}Try these steps:${NC}"
            echo -e "  1. ${CYAN}mrm fix-node --verbose${NC}  (see detailed errors)"
            echo -e "  2. ${CYAN}apt install -y curl unzip${NC}  (ensure tools exist)"
            echo -e "  3. ${CYAN}curl -v https://github.com 2>&1 | head -5${NC}  (test internet)"
            echo -e "  4. Manual download:"
            echo -e "     ${CYAN}ARCH=$( [ "$(uname -m)" = "aarch64" ] && echo arm64-v8a || echo 64 )${NC}"
            echo -e "     ${CYAN}curl -L \"https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-\$ARCH.zip\" -o /tmp/xray.zip${NC}"
            echo -e "     ${CYAN}unzip -o /tmp/xray.zip -d $NODE_DATA_DIR/xray-core/${NC}"
            echo -e "     ${CYAN}chmod +x $NODE_DATA_DIR/xray-core/xray${NC}"
            echo -e "     ${CYAN}docker restart \$(docker ps -a --format '{{.Names}}' | grep -i node | head -1)${NC}"
            echo ""
            echo -e "${YELLOW}Full log: $BACKUP_LOG${NC}"
            exit 1
        fi
    else
        backup_menu
    fi
fi
