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
mrm special  # تب «MRM · Special» در تنظیمات پنل + صفحه‌ی اشتراک
```

## 🧰 امکانات

- 🔐 **SSL** — دریافت، تمدید و مشاهده‌ی گواهی‌ها
- 💾 **Backup & Restore** — پشتیبان‌گیری، بازگردانی و ارسال خودکار به **Telegram** با زمان‌بندی
- 🩺 **PasarGuard Health** — بررسی `/health`، گواهی/CA_TYPE، وضعیت نودها و فاصله‌های `JOB_*` در برابر پیش‌فرض رسمی پنل
- 🎛️ **کنترل پنل** — مدیریت سرویس‌ها، مشاهده‌ی Logها و Monitor هشداردار
- 🌐 **Domain Separator** — جداسازی لینک پنل و لینک ساب + 🎨 مدیریت Theme
- ◆ **MRM Special** — تب تنظیمات اختصاصی داخل خودِ پنل PasarGuard + صفحه‌ی اشتراک حرفه‌ای (اتصال مستقیم یک‌لمسی، اعلان زمان‌بندی‌شده، چندزبانه) — با `mrm special`
- 🇮🇷 **ابزارهای ایران / Offline Mode**

## 🔄 به‌روزرسانی

از منوی اصلی گزینه‌ی **Update MRM Manager** (یا دستور `mrm update`)، یا اجرای دوباره‌ی دستور نصب (نسخه‌ی قبلی خودکار پشتیبان می‌شود).

- `mrm update` همیشه آخرین **ریلیز تگ‌شده** را نصب می‌کند و قبل از اجرا، هش SHA-256 نصاب را با `checksums.txt` همان ریلیز مقایسه می‌کند؛ در صورت مغایرت هیچ‌چیز اجرا نمی‌شود.
- اگر «MRM Special» فعال باشد، در پنل هم (Settings › MRM) نسخه‌ی جدید اعلام می‌شود و مالک پنل می‌تواند به‌روزرسانی را از همان‌جا آغاز کند.

## 🎨 ظاهر و رنگ‌ها

رابط خط فرمان از یک پالت ثابت ۲۵۶-رنگی استفاده می‌کند تا در همه‌ی کلاینت‌ها (Termius، Windows Terminal، iTerm و …) یکسان دیده شود. در صورت نیاز با متغیر محیطی قابل تغییر است:

| متغیر | مقدارها | توضیح |
|---|---|---|
| `MRM_PALETTE` | `amber` (پیش‌فرض) · `slate` · `teal` · `classic` | پالت رنگی؛ `classic` = رنگ‌های ۱۶-تایی تم خود ترمینال |
| `MRM_THEME` | `dark` (پیش‌فرض) · `light` | در تم روشن، رنگ پیش‌فرض متن ترمینال حفظ می‌شود |
| `NO_COLOR` / `MRM_COLOR=never` | — | بدون رنگ |

مثال: `MRM_PALETTE=slate mrm` — برای دائمی‌کردن، خط `export MRM_PALETTE=slate` را به `~/.bashrc` اضافه کنید.

## 🐞 گزارش مشکل

باگ یا پیشنهاد → [Issues](https://github.com/Mohammad1724/mrm-manager-pasarguard/issues)

## 📄 لایسنس

[GPL-3.0](LICENSE)
