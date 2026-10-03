#!/usr/bin/env bash
# =============================================================================
# همگام‌سازی قرارداد UI در runtime هر دو خانواده
# =============================================================================
# فایل مرجع:  shared/ui-contract.js
#
# این اسکریپت بلوک قرارداد را از فایل مرجع برمی‌دارد و داخل runtime های
# MRM و Zomorod جای‌گذاری می‌کند. هرگز دستی ویرایش نکنید — منبع حقیقت یکی است.
#
#   bash shared/sync-contract.sh          # نوشتن
#   bash shared/sync-contract.sh --check   # فقط بررسی (برای CI؛ بدون تغییر)
# =============================================================================
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${ROOT}/shared/ui-contract.js"

START="/* >>> UI_CONTRACT_START >>> */"
END="/* <<< UI_CONTRACT_END <<< */"

# چیدمان را خودکار تشخیص می‌دهد: محیط کار (هر دو مخزن کنار هم) یا داخل مخزن MRM
if [[ -f "${ROOT}/plugin/mrm-runtime.js" ]]; then
  MRM_RUNTIME="${ROOT}/plugin/mrm-runtime.js"
else
  MRM_RUNTIME="${ROOT}/mrm-manager-pasarguard/plugin/mrm-runtime.js"
fi

TARGETS=(
  "${MRM_RUNTIME}"
  "${ROOT}/zomorod-template/plugin/zomorod-runtime.js"
)

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

[[ -f "${SOURCE}" ]] || { echo "مرجع قرارداد پیدا نشد: ${SOURCE}" >&2; exit 1; }

VERSION="$(grep -oE "var VERSION = '[^']+'" "${SOURCE}" | head -1 | sed "s/.*'\(.*\)'/\1/")"
echo "قرارداد: v${VERSION}  (مرجع: shared/ui-contract.js)"

FAIL=0
CHECKED=0
for target in "${TARGETS[@]}"; do
  [[ -f "${target}" ]] || { echo "  ⊘ رد شد (فایل نیست): ${target}"; continue; }
  CHECKED=$((CHECKED + 1))

  if grep -qF "${START}" "${target}"; then
    HAVE="$(sed -n "/$(printf '%s' "${START}" | sed 's/[][\.*^$/]/\\&/g')/,/$(printf '%s' "${END}" | sed 's/[][\.*^$/]/\\&/g')/p" "${target}" \
            | grep -oE "var VERSION = '[^']+'" | head -1 | sed "s/.*'\(.*\)'/\1/")"
  else
    HAVE="(نصب‌نشده)"
  fi

  if [[ "${HAVE}" == "${VERSION}" ]] && ! [[ ${CHECK} -eq 1 ]]; then
    echo "  ✔ به‌روز است: $(basename "$(dirname "$(dirname "${target}")")")/$(basename "${target}")"
    continue
  fi

  if [[ ${CHECK} -eq 1 ]]; then
    if [[ "${HAVE}" == "${VERSION}" ]]; then
      echo "  ✔ ${target##*/}: v${HAVE}"
    else
      echo "  ✘ ${target##*/}: v${HAVE} — مورد انتظار v${VERSION}" >&2
      FAIL=1
    fi
    continue
  fi

  python3 - "${target}" "${SOURCE}" "${START}" "${END}" <<'PY'
import sys
from pathlib import Path

target, source, start, end = (Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4])
body = source.read_text(encoding="utf-8").rstrip() + "\n"
block = f"{start}\n{body}{end}\n"

text = target.read_text(encoding="utf-8")
if start in text and end in text:
    head = text[: text.index(start)]
    tail = text[text.index(end) + len(end):]
    if tail.startswith("\n"):
        tail = tail[1:]
    text = head + block + tail
    action = "به‌روزرسانی شد"
else:
    # درج پس از خط 'use strict'; داخل IIFE
    marker = "'use strict';\n"
    if marker in text:
        i = text.index(marker) + len(marker)
        text = text[:i] + "\n" + block + text[i:]
    else:
        text = block + text
    action = "نصب شد"
target.write_text(text, encoding="utf-8")
print(f"  ✔ {action}: {target.name}")
PY
done

if [[ ${CHECK} -eq 1 ]]; then
  if [[ ${FAIL} -eq 1 ]]; then
    echo "" >&2
    echo "❌ قرارداد UI بین پروژه‌ها همگام نیست. اجرا کنید: bash shared/sync-contract.sh" >&2
    exit 1
  fi
  echo "✔ قرارداد v${VERSION} همگام است (${CHECKED} فایل بررسی شد)."
  exit 0
fi

echo "تمام."
