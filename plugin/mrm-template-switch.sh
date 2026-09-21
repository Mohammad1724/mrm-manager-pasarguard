#!/usr/bin/env bash
# MRM Template Switch Bridge — runs on the HOST
# Applies a subscription-template switch (classic|special) requested from the
# PasarGuard panel (Settings → MRM → Template card). Modelled on
# update-from-panel.sh: request JSON in, status JSON out, flock-guarded.
set -Eeuo pipefail
DATA_DIR="${MRM_DATA_DIR:-/var/lib/pasarguard/mrm}"
REQUEST_FILE="${DATA_DIR}/template-request.json"
STATUS_FILE="${DATA_DIR}/template-status.json"
LOG_FILE="${DATA_DIR}/template-switch.log"
LOCK_FILE="${DATA_DIR}/.template-switch.lock"
THEME_CLI="${MRM_THEME_CLI:-/opt/mrm-manager/theme.sh}"

mkdir -p "${DATA_DIR}"; touch "${LOCK_FILE}"; chmod 600 "${LOCK_FILE}" || true
exec 9>"${LOCK_FILE}"; flock -n 9 || exit 0
trap 'rm -f "${REQUEST_FILE}"' EXIT
[[ -s "${REQUEST_FILE}" ]] || exit 0

read_template() { python3 - "${REQUEST_FILE}" <<'PY2'
import json,sys
try: value=json.load(open(sys.argv[1],encoding='utf-8')).get('template','')
except Exception: value=''
print(value if value in ('classic','special') else '')
PY2
}

tpl="$(read_template)"
if [[ -z "${tpl}" ]]; then rm -f "${REQUEST_FILE}"; exit 0; fi

rm -f "${LOG_FILE}"
if [[ ! -f "${THEME_CLI}" ]]; then
    python3 - "${STATUS_FILE}" "failed" "${tpl}" "theme.sh not found on the host" <<'PY2'
import json,sys
from datetime import datetime,timezone
from pathlib import Path
p=Path(sys.argv[1]); payload={'status':sys.argv[2],'active':sys.argv[3],'message':sys.argv[4],'started_at':datetime.now(timezone.utc).isoformat(),'finished_at':datetime.now(timezone.utc).isoformat()}
t=p.with_suffix('.json.tmp'); t.write_text(json.dumps(payload,indent=2)+'\n',encoding='utf-8'); t.chmod(0o600); t.replace(p)
PY2
    rm -f "${REQUEST_FILE}"; exit 1
fi

set +e
bash "${THEME_CLI}" --set-template "${tpl}" >"${LOG_FILE}" 2>&1
rc=$?
set -e
chmod 600 "${LOG_FILE}" 2>/dev/null || true
rm -f "${REQUEST_FILE}"
# theme.sh --set-template writes template-status.json itself (running →
# success/failed). Nothing else to do here.
exit "${rc}"
