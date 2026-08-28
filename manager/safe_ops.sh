#!/bin/bash
# MRM Manager v1.1.24

if [ -z "$PANEL_DIR" ]; then source /opt/mrm-manager/utils.sh; fi
if ! declare -f ui_header >/dev/null 2>&1 && [ -r /opt/mrm-manager/ui.sh ]; then source /opt/mrm-manager/ui.sh; fi

SAFE_OPS_ROOT="/opt/mrm-manager/restore-points"


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
        # FIX (MRM-100): mirror the restore-side "/" guard — without it,
        # a caller passing "/" would trigger "cp -a / <restore-point>/files/"
        [ "$TARGET" != "/" ] || continue

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

    # FIX (MRM-101): pre-flight - every "present" entry's backup must exist
    # BEFORE anything is touched (the loop used to rm -rf the live target first
    # and then fail on a missing/corrupt backup, losing the live file).
    while IFS='|' read -r STATE TARGET; do
        [ "$STATE" = "present" ] || continue
        [ -n "$TARGET" ] || continue
        case "$TARGET" in
            /*) ;;
            *) continue ;;
        esac
        [ "$TARGET" != "/" ] || continue
        if [ ! -e "$RP_DIR/files$TARGET" ] 2>/dev/null; then
            echo "ERROR: restore point incomplete - backup missing: $TARGET. Aborting without changes." >&2
            return 1
        fi
    done < "$MANIFEST"

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

