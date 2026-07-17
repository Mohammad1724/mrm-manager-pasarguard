#!/bin/bash
# MRM Manager v1.0.0

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi

settings_telegram_status() {
    if [ -n "${TG_CONFIG:-}" ] && [ -f "$TG_CONFIG" ]; then
        printf '%b' "${GREEN}Configured${NC}"
    else
        printf '%b' "${YELLOW}Not Configured${NC}"
    fi
}

settings_compose_or_na() {
    local TARGET="$1"
    local VALUE=""

    case "$TARGET" in
        panel)
            VALUE="$(get_panel_compose_file 2>/dev/null || true)"
            ;;
        node)
            VALUE="$(get_node_compose_file 2>/dev/null || true)"
            ;;
    esac

    if [ -n "$VALUE" ]; then
        printf '%s\n' "$VALUE"
    else
        printf '%s\n' "Not Found"
    fi
}

settings_show_summary() {
    clear
    detect_active_panel > /dev/null

    local ACTIVE_PANEL
    ACTIVE_PANEL="$(cat "$CONFIG_FILE" 2>/dev/null || echo unknown)"

    ui_header "SETTINGS CENTER"
    ui_section "Current Panel"
    ui_kv "Active Panel" "$ACTIVE_PANEL"
    ui_kv "Panel Directory" "${PANEL_DIR:-Not Set}"
    ui_kv "Data Directory" "${DATA_DIR:-Not Set}"
    ui_kv "Node Directory" "${NODE_DIR:-Not Set}"
    echo ""

    ui_section "Configuration Paths"
    ui_kv "panel.conf" "$CONFIG_FILE"
    ui_kv "Panel .env" "${PANEL_ENV:-Not Set}"
    ui_kv "Node .env" "${NODE_ENV:-Not Set}"
    ui_kv "Panel Compose" "$(settings_compose_or_na panel)"
    ui_kv "Node Compose" "$(settings_compose_or_na node)"
    echo ""

    ui_section "MRM & Feature Settings"
    ui_kv "MRM Install Dir" "/opt/mrm-manager"
    ui_kv "Theme Source URL" "${THEME_HTML_URL:-Not Set}"
    ui_kv "Backup Directory" "${BACKUP_DIR:-/root/mrm-backups}"
    ui_kv "Telegram Backup" "$(settings_telegram_status)"
    if declare -f mrm_latest_restore_point_text >/dev/null 2>&1; then
        ui_kv "Last Restore Point" "$(mrm_latest_restore_point_text)"
    fi
    echo ""

    pause
}

settings_menu() {
    while true; do
        clear
        detect_active_panel > /dev/null
        ui_header "SETTINGS CENTER"

        echo "1) 🧾 View Settings Summary"
        echo "2) 🔄 Change Active Panel"
        echo "3) 📝 Edit panel.conf"
        echo "4) 📝 Edit Panel .env"
        echo "5) 📝 Edit Node .env"
        echo "0) ↩️  Back"
        echo ""
        read -p "Select: " OPT

        case "$OPT" in
            1) settings_show_summary ;;
            2) change_panel; pause ;;
            3)
                if declare -f edit_file >/dev/null 2>&1; then
                    edit_file "$CONFIG_FILE"
                else
                    nano "$CONFIG_FILE"
                fi
                ;;
            4)
                if [ -n "$PANEL_ENV" ]; then
                    if declare -f edit_file >/dev/null 2>&1; then
                        edit_file "$PANEL_ENV"
                    else
                        nano "$PANEL_ENV"
                    fi
                else
                    ui_error "Panel .env path is not set"
                    pause
                fi
                ;;
            5)
                if [ -n "$NODE_ENV" ]; then
                    if declare -f edit_file >/dev/null 2>&1; then
                        edit_file "$NODE_ENV"
                    else
                        nano "$NODE_ENV"
                    fi
                else
                    ui_error "Node .env path is not set"
                    pause
                fi
                ;;
            0) return ;;
            *)
                if declare -f invalid_menu_option >/dev/null 2>&1; then
                    invalid_menu_option
                else
                    ui_error "Invalid option"
                    sleep 1
                fi
                ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    settings_menu
fi
