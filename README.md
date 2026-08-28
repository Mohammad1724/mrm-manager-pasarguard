# 🛡️ MRM Manager

مدیر خط فرمان ساده برای نگهداری و مدیریت **PasarGuard**.

[![License](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/Bash-5%2B-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)

## نصب

روی سرور با دسترسی `root` اجرا کنید:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/main/install.sh)"
```

پس از نصب:

```bash
mrm
```

## امکانات

- 🔐 دریافت، تمدید و مشاهده‌ی گواهی‌های SSL
- 💾 ایجاد، مشاهده و بازگردانی Backup
- 🤖 ارسال Backup به Telegram و زمان‌بندی آن
- 🎛️ کنترل سرویس‌های Panel و مشاهده‌ی Logها
- 🌐 جداسازی لینک‌پنل و لینک‌ساب Domain Separator
- 🎨 مدیریت Theme
- 🩺 بررسی سلامت سرویس‌ها و منابع سرور
- 📊 Monitor و هشدار Telegram
- 🇮🇷 ابزارهای Iran / Offline Mode
- ❤️ PasarGuard Health (`mrm health`): چک `/health` پنل، گواهی/CA_TYPE، وضعیت نودها (keep_alive / خطاها / زمان‌ها) و فاصله‌های JOB_* در برابر پیش‌فرض رسمی پنل
- 🔑 کلید موقت Owner (`mrm temp-key`): معادل `pasarguard-cli generate-temp-key` برای بازنشانی ادمین

## منوی اصلی

پس از اجرای `mrm`، وضعیت Panel، Node، Nginx، SSL، Backup و Telegram نمایش داده می‌شود.

```text
1) 🔐 SSL Certificates
2) 💾 Backup & Restore
3) 🎛️ Panel Control
4) 🛠️ Tools
5) 🔄 Update Script
6) 🗑️ Uninstall

0) 🚪 Exit
```

## به‌روزرسانی

از منوی اصلی گزینه‌ی **Update Script** را انتخاب کنید یا Installer را دوباره اجرا کنید:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/main/install.sh)"
```

## گزارش مشکل

برای گزارش باگ یا پیشنهاد، از بخش [Issues](https://github.com/Mohammad1724/mrm-manager-pasarguard/issues) استفاده کنید.

## لایسنس

این پروژه تحت لایسنس [GPL-3.0](LICENSE) منتشر شده است.
