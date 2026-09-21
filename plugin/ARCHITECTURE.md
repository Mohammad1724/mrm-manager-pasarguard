# معماری MRM Special

> این سند جزئیات فنی Integration MRM با PasarGuard را توضیح می‌دهد. مستندات اصلی پروژه فارسی است؛ نام APIها و مسیرهای فنی عمداً به شکل اصلی نگه داشته شده‌اند.

## هدف معماری

MRM Special باید سه ویژگی را هم‌زمان داشته باشد:

1. صفحه Subscription بتواند مستقل از Build اصلی Dashboard توسعه پیدا کند.
2. تنظیمات اصلی با PasarGuard دو نسخه متفاوت نداشته باشند.
3. آپدیت عادی PasarGuard فایل‌های اصلی افزونه و تنظیمات MRM را حذف نکند.

برای رسیدن به این هدف، پروژه از معماری دو لایه استفاده می‌کند.

```text
┌───────────────────────────────────────────────────────────┐
│                    PasarGuard Database                    │
│                                                           │
│ subscription.*               subscription.response_headers│
│ native settings              x-mrm-* settings         │
└───────────────┬─────────────────────────────┬─────────────┘
                │ /api/settings               │ /{token}/raw
                │                             │
        ┌───────▼────────┐              ┌─────▼─────────────┐
        │ MRM Special│              │ MRM Runtime  │
        │ Admin Control  │              │ Subscription UI  │
        └───────▲────────┘              └───────────────────┘
                │
        small generated-build loader
                │
┌───────────────┴───────────────────────────────────────────┐
│                 PasarGuard Dashboard                     │
└───────────────────────────────────────────────────────────┘
```

## لایه ۱: Subscription UI

صفحه اشتراک در مسیر زیر نصب می‌شود:

```text
/var/lib/pasarguard/templates/subscription/index.html
```

و PasarGuard از تنظیمات رسمی زیر برای Render آن استفاده می‌کند:

```dotenv
CUSTOM_TEMPLATES_DIRECTORY="/var/lib/pasarguard/templates/"
SUBSCRIPTION_PAGE_TEMPLATE="subscription/index.html"
```

Runtime MRM (`plugin/mrm-runtime.js`) در زمان Integration داخل HTML نهایی قرار می‌گیرد تا به Route استاتیک جدا در endpoint عمومی Subscription وابسته نباشد.

### دریافت تنظیمات Runtime

Runtime از endpoint native زیر استفاده می‌کند:

```text
/{subscription-path}/{token}/raw
```

PasarGuard در خروجی `raw`، Response Headerهای Subscription را نیز برمی‌گرداند. MRM فقط Headerهایی با Prefix زیر را مصرف می‌کند:

```text
x-mrm-
```

این روش دو مزیت دارد:

- endpoint عمومی اختصاصی برای تنظیمات MRM لازم نیست.
- تنظیمات در همان Database و Backup پاسارگارد باقی می‌مانند.

## لایه ۲: MRM Special Admin Control

فایل:

```text
plugin/mrm-special.js
```

داخل Origin داشبورد PasarGuard اجرا می‌شود. این فایل:

1. از Token موجود Dashboard استفاده می‌کند.
2. `GET /api/settings` را اجرا می‌کند.
3. تنظیمات native و MRM را در UI یکپارچه نمایش می‌دهد.
4. در Save، همان Settings object را با `PUT /api/settings` برمی‌گرداند.

### Native fields

این فیلدها توسط خود PasarGuard مالکیت و اعتبارسنجی می‌شوند:

```text
subscription.announce
subscription.announce_url
subscription.applications
subscription.allow_browser_config
subscription.manual_sub_request.links
subscription.manual_sub_request.wireguard
```

MRM برای آن‌ها Shadow Copy ایجاد نمی‌کند.

### MRM namespace

فیلدهای فقط مربوط به UI MRM در `subscription.response_headers` ذخیره می‌شوند:

```text
x-mrm-enabled
x-mrm-store-name-b64
x-mrm-show-configs
x-mrm-show-wireguard
x-mrm-show-ping
x-mrm-show-apps
x-mrm-show-announcement
x-mrm-announcement-mode
x-mrm-announcement-times
x-mrm-announcement-duration
```

### چرا نام فروشگاه Base64 است؟

PasarGuard قبل از ساخت HTTP Response، نام و مقدار Headerها را برای Latin-1 معتبر می‌کند. نامی مثل `MRM` یا یک Emoji مستقیماً در Header قابل ذخیره نیست و می‌تواند Response را نامعتبر کند.

بنابراین MRM نام فروشگاه را به UTF-8 bytes تبدیل و سپس Base64 می‌کند:

```text
shop name UTF-8
      │
      ▼
Base64 ASCII
      │
      ▼
x-mrm-store-name-b64
```

Runtime در مرورگر Base64 را decode می‌کند. بقیه مقادیر `x-mrm-*` فقط Boolean، زمان و عدد هستند و ذاتاً ASCII باقی می‌مانند.

## چرا افزونه سورس اصلی PasarGuard را Fork نمی‌کند؟

Patch کردن فایل‌های زیر در نصب کاربر هزینه نگهداری بالایی ایجاد می‌کند:

```text
app/*
dashboard/src/*
```

چون هر Upgrade یا rebuild می‌تواند Patch را overwrite کند یا Conflict بسازد.

در عوض، MRM فایل‌های مالک خودش را اینجا نگه می‌دارد:

```text
/opt/mrm/
```

و فقط به Build تولیدشده Dashboard یک Loader کوچک اضافه می‌کند.

## تب واقعی Settings

PasarGuard تب‌های Settings را داخل یک نوار افقی Render می‌کند. MRM Loader همان Tab Bar را در DOM پیدا کرده و دکمه زیر را به انتهای آن اضافه می‌کند:

```text
◆ MRM تمپلیت  Special
```

کلیک روی این Tab، Control Plane MRM را در همان Origin باز می‌کند. Route رسمی upstream اضافه نمی‌شود، چون PasarGuard در نسخه هدف API رسمی برای Register کردن third-party route/tab ندارد.

## Self-healing integration

اسکریپت زیر idempotent است:

```text
/opt/mrm/plugin/integrate-dashboard.sh
```

هر بار اجرا:

- وجود Runtime MRM را در Subscription Template تضمین می‌کند.
- `mrm-special.js` را داخل statics تولیدشده Dashboard کپی می‌کند.
- Loader را فقط در صورت نبودن به `index.html` و `404.html` اضافه می‌کند.
- Subscription Template یا فایل JS را فقط وقتی تغییر واقعی وجود داشته باشد دوباره می‌نویسد.

برای اجرا بعد از Upgrade دو مکانیزم وجود دارد.

### Path watcher

```text
mrm-integrator.path
```

تغییر فایل Build اصلی Dashboard را مشاهده می‌کند و Integration را دوباره اجرا می‌کند.

### Fallback timer

```text
mrm-integrator.timer
```

هر پنج دقیقه Health Check را اجرا می‌کند. این Timer برای حالتی است که مسیر Build در زمان نصب موجود نبوده یا رویداد File Watch از دست رفته باشد.

## چرا این یک Plugin API واقعی PasarGuard نیست؟

در نسخه‌ای که MRM بر اساس آن طراحی شده، PasarGuard API رسمی برای Register کردن third-party Dashboard route/tab ندارد. بنابراین Loader MRM یک compatibility layer است، نه Plugin API رسمی upstream.

این تمایز مهم است:

- **داده و تنظیمات:** مبتنی بر API/DB خود PasarGuard.
- **نمایش Tab در Dashboard:** self-healing integration روی Build تولیدشده.

اگر PasarGuard در آینده Plugin API رسمی ارائه کند، مسیر مطلوب MRM مهاجرت Admin Control به همان API خواهد بود و namespace تنظیمات فعلی می‌تواند بدون Migration مخرب حفظ شود.

## WireGuard flow

وقتی کاربر روی دانلود WireGuard می‌زند:

```text
Browser
  │
  ├── GET /{subscription}/{token}/wireguard
  │
PasarGuard
  │  validates user / HWID / enabled format
  │  renders native WireGuard configuration
  ▼
.conf download
```

MRM WireGuard را خودش Generate نمی‌کند؛ در بخش Special از قابلیت native PasarGuard استفاده می‌کند.

Toggle نمایش WireGuard در Runtime هم کارت دانلود اختصاصی و هم ردیف‌های پروتکل `WG` در لیست کانفیگ‌ها را کنترل می‌کند. `manual_sub_request.wireguard` همچنان Switch اصلی native در PasarGuard است.

## Announcement scheduling

PasarGuard مسئول متن اصلی اعلان است. MRM فقط Visibility Window را کنترل می‌کند.

نمونه:

```text
announcement-mode     = scheduled
announcement-times    = 09:00,14:30,21:00
announcement-duration = 60
```

Runtime ساعت Local Browser را با هر Window مقایسه می‌کند. با Duration برابر ۶۰، Window ساعت `14:30` تا `15:29` فعال است.

## مدل امنیت

### Admin side

- MRM Token جدید صادر نمی‌کند.
- Credential جدا ذخیره نمی‌کند.
- درخواست Admin همان Origin به `/api/settings` ارسال می‌شود.
- Authorization و RBAC توسط PasarGuard انجام می‌شود.

### Subscription side

- endpoint اختصاصی بدون احراز هویت ایجاد نمی‌شود.
- Runtime فقط endpointهای Subscription همان Token کاربر را مصرف می‌کند.
- WireGuard همچنان از validation خود PasarGuard عبور می‌کند.

## Compatibility contract

MRM Special به این رفتارهای upstream متکی است:

1. Custom Templates همچنان پشتیبانی شوند.
2. `/api/settings` شکل کلی Subscription Settings را حفظ کند.
3. `subscription.response_headers` حذف نشود.
4. `/{token}/raw` Response Headerها را ارائه دهد.
5. Manual `wireguard` endpoint وجود داشته باشد.
6. Dashboard یک HTML build قابل سرو داشته باشد.
7. نوار Settings در DOM قابل تشخیص باقی بماند.

تغییر breaking در موارد بالا باید با Release جدید MRM پاسخ داده شود.

## Recovery

اجرای دستی Integration:

```bash
sudo /opt/mrm/plugin/integrate-dashboard.sh
```

بررسی Timer و Watcher:

```bash
systemctl status mrm-integrator.path
systemctl status mrm-integrator.timer
journalctl -u mrm-integrator.service --no-pager -n 100
```

Backupهای Installer:

```text
/opt/mrm/backups/<timestamp>/
```

## اصل طراحی

> هر چیزی که PasarGuard خودش مالک آن است، در PasarGuard ذخیره و اعتبارسنجی شود؛ هر چیزی که فقط مربوط به ظاهر و رفتار MRM است، namespaced و قابل حذف باقی بماند.
