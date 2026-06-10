<div align="center">

<img src="https://img.shields.io/badge/MRM-Manager-blue?style=for-the-badge&logo=gnu-bash&logoColor=white" alt="MRM Manager"/>

# 🛡️ MRM Manager

**ابزار مدیریت حرفه‌ای پنل‌های پروکسی**

پاسارگارد • 

---

[![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)
[![Version](https://img.shields.io/badge/version-2.0.0-blue?style=flat-square)]()
[![Bash](https://img.shields.io/badge/bash-5.0+-orange?style=flat-square&logo=gnu-bash)]()

[نصب](#-نصب) •
[امکانات](#-امکانات) •
[مهاجرت](#-مهاجرت) •
[بکاپ](#-بکاپ-تلگرام) •
[مشارکت](#-مشارکت)

</div>

---

## 📥 نصب

```bash
sudo bash -c "$(curl -sL https://raw.githubusercontent.com/Mohammad1724/mrm-manager-pasarguard/main/manager/install.sh)"
```

بعد از نصب:

```bash
mrm
```

---

## ✨ امکانات

<table>
<tr>
<td width="50%">

### 🔐 SSL و امنیت
- دریافت گواهی SSL رایگان
- پشتیبانی از چند دامنه
- تفکیک دامنه پنل و ساب

</td>
<td width="50%">

### 📦 بکاپ و ریستور
- بکاپ خودکار به تلگرام
- زمان‌بندی (ساعتی/روزانه)
- بازگردانی با یک کلیک

</td>
</tr>
<tr>
<td width="50%">

### 🔄 مهاجرت
- پاسارگارد ← ربکا
- تبدیل دیتابیس خودکار
- رولبک در صورت خطا

</td>
<td width="50%">

### ⚡ ابزارها
- مدیریت قالب صفحه ساب
- مدیریت سایت فیک
- کنترل سرویس و ادمین

</td>
</tr>
</table>

---

## 🔄 مهاجرت

انتقال از **پاسارگارد** به **ربکا** با حفظ تمام اطلاعات:

```
mrm → Tools & Settings → Migration Tools → Migrate to Rebecca
```

**قابلیت‌ها:**
- ✅ بکاپ کامل قبل از مهاجرت
- ✅ تبدیل TimescaleDB/SQLite به MySQL
- ✅ انتقال تنظیمات و گواهی‌ها
- ✅ امکان بازگشت (Rollback)

---

## 📱 بکاپ تلگرام

ارسال خودکار بکاپ به ربات تلگرام:

```
mrm → Backup & Restore → Telegram Settings
```

**تنظیمات:**
1. توکن ربات را وارد کنید
2. آیدی عددی چت را وارد کنید
3. زمان‌بندی را انتخاب کنید

---

## 🖥️ نمای منو

```
╔══════════════════════════════════════════════╗
║           MRM MANAGER v2.0                   ║
╚══════════════════════════════════════════════╝
  Panel: 🟢    Node: 🟢    Nginx: 🟢

  1) SSL Certificates
  2) Backup & Restore
  3) Tools & Settings
  4) Admin & Control

  0) Exit
```

---

## 📂 ساختار فایل‌ها

```
/opt/mrm-manager/
├── main.sh              # منوی اصلی
├── utils.sh             # توابع مشترک
├── ssl.sh               # مدیریت SSL
├── backup.sh            # بکاپ و تلگرام
├── migrator.sh          # ابزار مهاجرت
├── theme.sh             # مدیریت قالب
├── site.sh              # سایت فیک
├── port_manager.sh      # مدیریت پورت
└── domain_separator.sh  # تفکیک دامنه
```

---

## 🤝 مشارکت

از مشارکت شما استقبال می‌کنیم:

1. پروژه را Fork کنید
2. تغییرات خود را اعمال کنید
3. Pull Request ارسال کنید

**گزارش باگ:** [Issues](https://github.com/Mohammad1724/mrm-ssl-pasarguard/issues)

---

## 📜 لایسنس

این پروژه تحت لایسنس [MIT](LICENSE) منتشر شده است.

---

<div align="center">

**ساخته شده با ❤️ توسط [Mohammad1724](https://github.com/Mohammad1724)**

اگر مفید بود، ⭐ ستاره یادتون نره!

</div>
```
