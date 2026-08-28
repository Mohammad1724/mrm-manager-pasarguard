# 🛡️ MRM Manager

مدیریت روزمره‌ی سرور **PasarGuard** از خط فرمان — گواهی SSL، پشتیبان‌گیری و Telegram، سلامت پنل، و ابزارهای ایران، همه در یک منو.

[![License](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/Bash-5%2B-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)

## ⚡ نصب

روی سرور با دسترسی `root`:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/main/install.sh)"
```

نصب خودکار و بدون پرسش است؛ پس از اتمام، MRM **به‌صورت خودکار اجرا نمی‌شود** — خودتان فرمان را بزنید:

```bash
mrm          # منوی اصلی
mrm health   # بررسی سلامت پنل PasarGuard
mrm temp-key # کلید موقت Owner (بازنشانی ادمین)
```

## 🧰 امکانات

- 🔐 **SSL** — دریافت، تمدید و مشاهده‌ی گواهی‌ها
- 💾 **Backup & Restore** — پشتیبان‌گیری، بازگردانی و ارسال خودکار به **Telegram** با زمان‌بندی
- 🩺 **PasarGuard Health** — بررسی `/health`، گواهی/CA_TYPE، وضعیت نودها و فاصله‌های `JOB_*` در برابر پیش‌فرض رسمی پنل
- 🎛️ **کنترل پنل** — مدیریت سرویس‌ها، مشاهده‌ی Logها و Monitor هشداردار
- 🌐 **Domain Separator** — جداسازی لینک پنل و لینک ساب + 🎨 مدیریت Theme
- 🇮🇷 **ابزارهای ایران / Offline Mode**

## 🔄 به‌روزرسانی

از منوی اصلی گزینه‌ی **Update Script**، یا اجرای دوباره‌ی دستور نصب (نسخه‌ی قبلی خودکار پشتیبان می‌شود).

## 🐞 گزارش مشکل

باگ یا پیشنهاد → [Issues](https://github.com/Mohammad1724/mrm-manager-pasarguard/issues)

## 📄 لایسنس

[GPL-3.0](LICENSE)
