#!/usr/bin/env bash
# همگام‌سازی هستهٔ مشترک طراحی (shared/design-tokens.css) با هر دو قالب
#
#   bash shared/sync-tokens.sh            → تزریق/به‌روزرسانی
#   bash shared/sync-tokens.sh --check    → فقط بررسی واگرایی (کد خروج ۱ = واگرا)
#
# تزریق بین نشانگرها انجام می‌شود، پس اجرای مکرر بی‌خطر است (idempotent).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/shared/design-tokens.css"

# چیدمان را خودکار تشخیص می‌دهد: محیط کار (هر دو مخزن کنار هم) یا داخل مخزن MRM
if [[ -f "${ROOT}/templates/subscription-src/src/index.css" ]]; then
  MRM_CSS="${ROOT}/templates/subscription-src/src/index.css"
else
  MRM_CSS="${ROOT}/mrm-manager-pasarguard/templates/subscription-src/src/index.css"
fi
ZMD_CSS="${ROOT}/zomorod-template/src/index.css"

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

if [[ ! -f "${SRC}" ]]; then
  echo "✘ فایل منبع پیدا نشد: ${SRC}" >&2
  exit 2
fi

exec python3 - "${SRC}" "${MRM_CSS}" "${ZMD_CSS}" "${CHECK}" <<'PY'
import re, sys
from pathlib import Path

src_path = Path(sys.argv[1])
targets = [Path(p) for p in sys.argv[2:4]]
check = sys.argv[4] == "1"

SECTIONS = ("ROOT", "THEME", "COMPONENTS")
LABEL = {"ROOT": "متغیرهای پایه", "THEME": "توکن‌های Tailwind", "COMPONENTS": "کلاس‌های مشترک"}

src = src_path.read_text(encoding="utf-8")
sections = {}
for name in SECTIONS:
    m = re.search(rf"/\* >>> SECTION: {name} >>> \*/\n(.*?)/\* <<< SECTION: {name} <<< \*/", src, re.S)
    if not m:
        sys.exit(f"✘ بخش {name} در فایل منبع پیدا نشد: {src_path}")
    sections[name] = m.group(1)

mver = re.search(r"نسخه:\s*([0-9][0-9.]*)", src)
version = mver.group(1) if mver else "?"


def start_marker(name):
    return f"/* >>> UI_TOKENS_{name}_START >>> */"


def end_marker(name):
    return f"/* <<< UI_TOKENS_{name}_END <<< */"


def extract(text, name):
    m = re.search(
        rf"{re.escape(start_marker(name))}\n(.*?){re.escape(end_marker(name))}", text, re.S
    )
    return m.group(1) if m else None


def norm(body):
    return "\n".join(line.rstrip() for line in body.strip("\n").splitlines())


def insert_before_block_close(text, header_re, block):
    """درج block پیش از آکولاد بستنِ بلوکی که با header_re شروع می‌شود."""
    m = re.search(header_re, text, re.M)
    if not m:
        return None
    brace = text.index("{", m.end() - 1)
    close = text.find("\n}", brace)
    if close == -1:
        return None
    return text[: close + 1] + "\n" + block + text[close + 1 :]


def inject(text, name, body):
    block = f"{start_marker(name)}\n{body}{end_marker(name)}"
    if start_marker(name) in text:
        return re.sub(
            rf"{re.escape(start_marker(name))}\n.*?{re.escape(end_marker(name))}",
            lambda _m: block,
            text,
            count=1,
            flags=re.S,
        )
    if name == "THEME":
        out = insert_before_block_close(text, r"^@theme inline \{", block)
    elif name == "ROOT":
        out = insert_before_block_close(text, r"^:root \{", block)
    else:
        out = text.rstrip("\n") + f"\n\n@layer components {{\n{block}\n}}\n"
    if out is None:
        raise SystemExit(f"✘ لنگر تزریق برای بخش {name} پیدا نشد")
    return out


print(f"هستهٔ طراحی: v{version}  (منبع: shared/design-tokens.css)")
rc = 0
for t in targets:
    if not t.is_file():
        print(f"  ⊘ رد شد (فایل نیست): {t}")
        continue
    text = t.read_text(encoding="utf-8")
    rel = t.name if t.parent.name != "src" else f"{t.parent.parent.name}/{t.name}"

    if check:
        drift = []
        for name in SECTIONS:
            cur = extract(text, name)
            if cur is None:
                drift.append(f"{LABEL[name]}: تزریق نشده")
            elif norm(cur) != norm(sections[name]):
                drift.append(f"{LABEL[name]}: واگرا")
        if drift:
            rc = 1
            print(f"  ✘ {rel} — " + " · ".join(drift))
        else:
            print(f"  ✔ {rel} — هر {len(SECTIONS)} بخش همگام")
    else:
        for name in SECTIONS:
            text = inject(text, name, sections[name])
        t.write_text(text, encoding="utf-8")
        print(f"  ✔ {rel} — {len(SECTIONS)} بخش تزریق شد")

if check:
    print("✔ هستهٔ طراحی همگام است." if rc == 0 else "✘ واگرایی هستهٔ طراحی — `sync-tokens.sh` را اجرا کنید.")
sys.exit(rc)
PY
