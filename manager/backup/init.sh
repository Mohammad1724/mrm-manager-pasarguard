# =========================================================
# FIX for Bug #1: wrong SCRIPT_PATH pointed at init.sh,
# so cron ran init.sh directly (which only defines functions
# and never calls do_backup), causing auto backups to do nothing.
#
# Replace the original line in init.sh:
#   SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
# with the block below so SCRIPT_PATH always resolves to the
# real entry script (backup.sh) that contains the dispatch logic.
# =========================================================

# Resolve the entry script. When init.sh is sourced by backup.sh,
# BASH_SOURCE[1] points at backup.sh. When invoked directly, fall
# back to BASH_SOURCE[0] (but note: direct invocation is not the
# supported entry point).
if [ -n "${BASH_SOURCE[1]:-}" ]; then
    SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[1]}")"
else
    SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
fi

# If we somehow resolved to init.sh (e.g. invoked directly), point
# at the sibling backup.sh entry script instead.
if [ "$(basename "$SCRIPT_PATH")" = "init.sh" ]; then
    SCRIPT_PATH="$(dirname "$SCRIPT_PATH")/../backup.sh"
    SCRIPT_PATH="$(readlink -f "$SCRIPT_PATH")"
fi
