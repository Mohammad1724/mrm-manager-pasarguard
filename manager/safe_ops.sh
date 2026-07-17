#!/bin/bash
# MRM Manager v1.0.0

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi
if ! declare -f ui_header >/dev/null 2>&1 && [ -r /opt/mrm-manager/ui.sh ]; then source /opt/mrm-manager/ui.sh; fi

SAFE_OPS_ROOT="/opt/mrm-manager/restore-points"

safe_ops_invalid_option() {
    if declare -f invalid_menu_option >/dev/null 2>&1; then
        invalid_menu_option
    else
        ui_error "Invalid option"
        sleep 1
    fi
}

mrm_ensure_restore_root() {
    mkdir -p "$SAFE_OPS_ROOT"
}

mrm_sanitize_restore_label() {
    printf '%s' "$1" | tr ' /' '__' | tr -cd '[:alnum:]_.-'
}

mrm_create_restore_point() {
    local LABEL="$1"
    local HOOKS="$2"
    shift 2 || true

    local SAFE_LABEL
    local RP_ID
    local RP_DIR
    local MANIFEST
    local TARGET
    local BACKUP_PATH

    mrm_ensure_restore_root || return 1

    SAFE_LABEL="$(mrm_sanitize_restore_label "$LABEL")"
    [ -n "$SAFE_LABEL" ] || SAFE_LABEL="restore-point"

    RP_ID="$(date +%Y%m%d_%H%M%S)_${SAFE_LABEL}"
    RP_DIR="$SAFE_OPS_ROOT/$RP_ID"
    MANIFEST="$RP_DIR/manifest.txt"

    mkdir -p "$RP_DIR/files" || return 1

    printf 'id=%s\n' "$RP_ID" > "$RP_DIR/meta.env"
    printf 'label=%s\n' "$LABEL" >> "$RP_DIR/meta.env"
    printf 'created_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$RP_DIR/meta.env"
    printf 'hooks=%s\n' "$HOOKS" >> "$RP_DIR/meta.env"

    : > "$MANIFEST"

    for TARGET in "$@"; do
        [ -n "$TARGET" ] || continue
        case "$TARGET" in
            /*) ;;
            *) continue ;;
        esac

        if [ -e "$TARGET" ]; then
            BACKUP_PATH="$RP_DIR/files$TARGET"
            mkdir -p "$(dirname "$BACKUP_PATH")" || return 1
            if ! cp -a "$TARGET" "$BACKUP_PATH" 2>/dev/null; then
                return 1
            fi
            printf 'present|%s\n' "$TARGET" >> "$MANIFEST"
        else
            printf 'absent|%s\n' "$TARGET" >> "$MANIFEST"
        fi
    done

    printf '%s\n' "$RP_ID"
}

mrm_get_latest_restore_point() {
    ls -1dt "$SAFE_OPS_ROOT"/* 2>/dev/null | head -1
}

mrm_latest_restore_point_text() {
    local LATEST
    LATEST="$(mrm_get_latest_restore_point)"

    if [ -n "$LATEST" ] && [ -d "$LATEST" ]; then
        basename "$LATEST"
    else
        echo "None"
    fi
}

mrm_apply_restore_hooks() {
    local HOOKS="$1"
    local HOOK

    IFS=',' read -r -a _HOOK_ARRAY <<< "$HOOKS"
    for HOOK in "${_HOOK_ARRAY[@]}"; do
        case "$HOOK" in
            panel)
                if declare -f restart_service >/dev/null 2>&1; then
                    restart_service "panel" >/dev/null 2>&1 || true
                fi
                ;;
            nginx)
                if command -v nginx >/dev/null 2>&1; then
                    nginx -t >/dev/null 2>&1 && systemctl restart nginx >/dev/null 2>&1 || true
                fi
                ;;
            panel+nginx|nginx+panel)
                if declare -f restart_service >/dev/null 2>&1; then
                    restart_service "panel" >/dev/null 2>&1 || true
                fi
                if command -v nginx >/dev/null 2>&1; then
                    nginx -t >/dev/null 2>&1 && systemctl restart nginx >/dev/null 2>&1 || true
                fi
                ;;
            none|"")
                ;;
        esac
    done
}

mrm_restore_point_by_dir() {
    local RP_DIR="$1"
    local MANIFEST="$RP_DIR/manifest.txt"
    local META_FILE="$RP_DIR/meta.env"
    local STATE
    local TARGET
    local BACKUP_PATH
    local HOOKS="none"

    [ -d "$RP_DIR" ] || return 1
    [ -f "$MANIFEST" ] || return 1

    if [ -f "$META_FILE" ]; then
        HOOKS="$(awk -F= '/^hooks=/{sub(/^hooks=/, ""); print $0}' "$META_FILE" 2>/dev/null)"
        [ -n "$HOOKS" ] || HOOKS="none"
    fi

    while IFS='|' read -r STATE TARGET; do
        [ -n "$TARGET" ] || continue
        case "$TARGET" in
            /*) ;;
            *) continue ;;
        esac
        [ "$TARGET" != "/" ] || continue

        if [ "$STATE" = "present" ]; then
            BACKUP_PATH="$RP_DIR/files$TARGET"
            rm -rf "$TARGET" 2>/dev/null || true
            mkdir -p "$(dirname "$TARGET")" 2>/dev/null || true
            cp -a "$BACKUP_PATH" "$TARGET" 2>/dev/null || return 1
        else
            rm -rf "$TARGET" 2>/dev/null || true
        fi
    done < "$MANIFEST"

    mrm_apply_restore_hooks "$HOOKS"
    return 0
}

mrm_list_restore_points() {
    clear
    ui_header "RESTORE POINTS"

    local POINTS
    local POINT
    local IDX=1
    local LABEL
    local DATE_LINE
    local HOOKS

    POINTS=$(ls -1dt "$SAFE_OPS_ROOT"/* 2>/dev/null)
    if [ -z "$POINTS" ]; then
        ui_warning "No restore points found"
        pause
        return
    fi

    ui_section "Available Restore Points"
    while IFS= read -r POINT; do
        [ -d "$POINT" ] || continue
        LABEL="$(awk -F= '/^label=/{sub(/^label=/, ""); print $0}' "$POINT/meta.env" 2>/dev/null)"
        DATE_LINE="$(awk -F= '/^created_at=/{sub(/^created_at=/, ""); print $0}' "$POINT/meta.env" 2>/dev/null)"
        HOOKS="$(awk -F= '/^hooks=/{sub(/^hooks=/, ""); print $0}' "$POINT/meta.env" 2>/dev/null)"
        [ -n "$LABEL" ] || LABEL="$(basename "$POINT")"
        [ -n "$DATE_LINE" ] || DATE_LINE="Unknown"
        [ -n "$HOOKS" ] || HOOKS="none"
        echo "$IDX) $(basename "$POINT")"
        echo "   Label: $LABEL"
        echo "   Date : $DATE_LINE"
        echo "   Hooks: $HOOKS"
        echo ""
        IDX=$((IDX + 1))
    done <<< "$POINTS"

    pause
}

mrm_restore_latest_point() {
    local LATEST

    clear
    ui_header "RESTORE LATEST POINT"

    LATEST="$(mrm_get_latest_restore_point)"
    if [ -z "$LATEST" ] || [ ! -d "$LATEST" ]; then
        ui_warning "No restore point found"
        pause
        return
    fi

    echo -e "${YELLOW}Latest restore point:${NC} $(basename "$LATEST")"
    echo ""
    read -r -p "Restore this point now? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Cancelled"
        pause
        return
    fi

    if mrm_restore_point_by_dir "$LATEST"; then
        ui_success "Restore point applied successfully"
    else
        ui_error "Failed to apply restore point"
    fi
    pause
}

mrm_restore_select_point() {
    clear
    ui_header "RESTORE SPECIFIC POINT"

    local -a POINTS=()
    local POINT
    local IDX=1
    local SEL

    while IFS= read -r POINT; do
        [ -d "$POINT" ] || continue
        POINTS+=("$POINT")
        echo "$IDX) $(basename "$POINT")"
        IDX=$((IDX + 1))
    done < <(ls -1dt "$SAFE_OPS_ROOT"/* 2>/dev/null)

    if [ "${#POINTS[@]}" -eq 0 ]; then
        ui_warning "No restore points found"
        pause
        return
    fi

    echo ""
    read -r -p "Select restore point (0 to cancel): " SEL
    [ "$SEL" = "0" ] && return

    if ! [[ "$SEL" =~ ^[0-9]+$ ]] || [ "$SEL" -lt 1 ] || [ "$SEL" -gt "${#POINTS[@]}" ]; then
        ui_error "Invalid selection"
        pause
        return
    fi

    POINT="${POINTS[$((SEL-1))]}"
    echo ""
    read -r -p "Restore $(basename "$POINT") now? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Cancelled"
        pause
        return
    fi

    if mrm_restore_point_by_dir "$POINT"; then
        ui_success "Restore point applied successfully"
    else
        ui_error "Failed to apply restore point"
    fi
    pause
}

mrm_delete_restore_point() {
    clear
    ui_header "DELETE RESTORE POINT"

    local -a POINTS=()
    local POINT
    local IDX=1
    local SEL

    while IFS= read -r POINT; do
        [ -d "$POINT" ] || continue
        POINTS+=("$POINT")
        echo "$IDX) $(basename "$POINT")"
        IDX=$((IDX + 1))
    done < <(ls -1dt "$SAFE_OPS_ROOT"/* 2>/dev/null)

    if [ "${#POINTS[@]}" -eq 0 ]; then
        ui_warning "No restore points found"
        pause
        return
    fi

    echo ""
    read -r -p "Select restore point to delete (0 to cancel): " SEL
    [ "$SEL" = "0" ] && return

    if ! [[ "$SEL" =~ ^[0-9]+$ ]] || [ "$SEL" -lt 1 ] || [ "$SEL" -gt "${#POINTS[@]}" ]; then
        ui_error "Invalid selection"
        pause
        return
    fi

    POINT="${POINTS[$((SEL-1))]}"
    echo ""
    read -r -p "Delete $(basename "$POINT") ? (y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        rm -rf "$POINT"
        ui_success "Restore point deleted"
    else
        echo "Cancelled"
    fi
    pause
}

mrm_manual_restore_point() {
    clear
    ui_header "CREATE MANUAL RESTORE POINT"

    detect_active_panel > /dev/null

    local LABEL
    local RP_ID

    read -r -p "Label for this restore point [manual]: " LABEL
    [ -z "$LABEL" ] && LABEL="manual"

    RP_ID="$(mrm_create_restore_point "$LABEL" "panel,nginx" "$PANEL_ENV" "$NODE_ENV" "/etc/nginx/conf.d/panel_separate.conf" "/etc/nginx/sites-available/default")"
    if [ -n "$RP_ID" ]; then
        ui_success "Restore point created: $RP_ID"
    else
        ui_error "Failed to create restore point"
    fi
    pause
}

safe_ops_menu() {
    while true; do
        clear
        ui_header "RESTORE POINTS & ROLLBACK"
        echo "1) 🧾 List Restore Points"
        echo "2) 💾 Create Manual Restore Point"
        echo "3) ♻️  Restore Latest Point"
        echo "4) 🎯 Restore Specific Point"
        echo "5) 🗑️  Delete Restore Point"
        echo "0) ↩️  Back"
        echo ""
        read -p "Select: " OPT

        case "$OPT" in
            1) mrm_list_restore_points ;;
            2) mrm_manual_restore_point ;;
            3) mrm_restore_latest_point ;;
            4) mrm_restore_select_point ;;
            5) mrm_delete_restore_point ;;
            0) return ;;
            *) safe_ops_invalid_option ;;
        esac
    done
}
