#!/bin/bash
# MRM Manager Backup v${BACKUP_VERSION}
# Modular structure: each feature in its own file for easier maintenance

# ==========================================
# LOAD ALL MODULES
# ==========================================

BACKUP_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/backup" && pwd)"

source "$BACKUP_MODULE_DIR/init.sh"
source "$BACKUP_MODULE_DIR/telegram.sh"
source "$BACKUP_MODULE_DIR/smart_fix.sh"
source "$BACKUP_MODULE_DIR/database.sh"
source "$BACKUP_MODULE_DIR/backup_core.sh"
source "$BACKUP_MODULE_DIR/restore_core.sh"
source "$BACKUP_MODULE_DIR/xray.sh"
source "$BACKUP_MODULE_DIR/post_restore.sh"
source "$BACKUP_MODULE_DIR/menu.sh"

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
            "$NODE_DATA_DIR/xray-core/xray" -version 2>/dev/null | head -1 && true
            echo ""
            echo -e "${YELLOW}Restarting node container...${NC}"
            NODE_CNAME="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -i node | head -1)"
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
