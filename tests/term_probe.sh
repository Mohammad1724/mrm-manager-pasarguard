#!/bin/bash
# term_probe.sh — صفحهٔ نمایندهٔ رابط ترمینال، برای سنجش عرض در tests/run_tests.sh
# چیز تعاملی ندارد؛ فقط چند سازندهٔ رابط را رندر می‌کند و بیرون می‌آید.
# استفاده: MRM_DIR=<repo>/manager bash tests/term_probe.sh
set -o pipefail

MRM_DIR="${MRM_DIR:?MRM_DIR لازم است}"
# shellcheck source=/dev/null
source "$MRM_DIR/ui.sh" || { echo "ui.sh not found" >&2; exit 1; }

ui_header "Main Menu" "Host: example.com · Panel: running"
ui_kv_state "Panel" ok "Running" "/opt/pasarguard"
ui_kv_state "SSL" warn "2 of 5 certificates expiring soon" "/var/lib/pasarguard/certs"
ui_kv_state "Backup" off "No backup yet"
ui_kv "System" "Disk 18% used · 20G free · RAM 631/1984 MB · Load 0.07"
ui_note "Missing tools: docker"
ui_section "Subscription Templates"
ui_menu_item 1 "Domain Separator" "separate panel and subscription domains"
ui_menu_item 2 "Theme Manager" "subscription page templates"
ui_menu_item 3 "MRM Special" "in-panel integration & settings"
ui_box_start ok "Backup created"
ui_box_line "File" "/var/backups/mrm/db_2026-10-03_2130.sql.gz"
ui_box_end
ui_divider
ui_bullet "Reload the panel after switching templates"
ui_note "Full log: /var/log/mrm/manager.log — open a second SSH session if you need to follow it live"
exit 0
