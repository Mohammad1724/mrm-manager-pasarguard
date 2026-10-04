(() => {
  'use strict';

/* >>> UI_CONTRACT_START >>> */
/* =============================================================================
 * PasarGuard Subscription UI Contract — v1.0.0
 * =============================================================================
 * قرارداد مشترک DOM بین «قالب صفحه‌ی اشتراک» و «runtime تنظیمات».
 *
 * چرا لازم است؟
 *   runtime ها با querySelector روی DOM قالب کار می‌کنند. وقتی قالب بازنویسی
 *   می‌شود و runtime به‌روز نمی‌شود، تنظیمات ادمین بی‌صدا از کار می‌افتند:
 *   نه خطایی، نه هشداری. (در ممیزی MRM Special: ۲۶ از ۲۸ سلکتور مرده بودند.)
 *
 * راه‌حل:
 *   ۱. قالب‌ها عناصر را با data-ui="<name>" علامت می‌زنند — نه با کلاس ظاهری.
 *   ۲. runtime ها فقط از این قرارداد می‌خوانند (با fallback به سلکتور قدیمی،
 *      تا نصب‌های به‌روزنشده نشکنند).
 *   ۳. diagnose() در راه‌اندازی، عناصر گم‌شده را با صدای بلند گزارش می‌کند.
 *
 * قانون طلایی:
 *   کلاس‌ها برای «ظاهر» هستند و آزادانه تغییر می‌کنند.
 *   data-ui برای «رفتار» است و قرارداد است.
 *
 * سازگاری: هر دو خانواده MRM و Zomorod می‌توانند همین فایل را بدون تغییر
 * استفاده کنند. تغییر در MAP نیازمند افزایش VERSION و گزارش در CHANGELOG است.
 * ========================================================================== */

var UI_CONTRACT = (function () {
  'use strict';

  var VERSION = '1.0.0';

  /* نگاشت نام منطقی → سلکتور قراردادی + سلکتورهای قدیمی (به ترتیب اولویت)
     منتقل‌شده از mrm-runtime.js و zomorod-runtime.js نسخه‌های پیش از v1.0.0 */
  var MAP = {
    /* --- هویت ------------------------------------------------------------ */
    brand: {
      contract: '[data-ui="brand"]',
      legacy: ['.treasury-brand > span:last-child', '.treasury-brand', '.brand'],
      label: 'نام فروشگاه',
    },
    brandBox: {
      contract: '[data-ui="brand-box"]',
      legacy: ['.treasury-brand'],
      label: 'ظرف برند (aria-label)',
    },
    nav: {
      contract: '[data-ui="nav"]',
      legacy: ['.treasury-navigation', 'header'],
      label: 'نوار بالا',
    },
    headerActions: {
      contract: '[data-ui="header-actions"]',
      legacy: ['.treasury-navigation .ios-container > div:last-child',
               '.treasury-navigation .ios-container .flex.shrink-0'],
      label: 'ناحیه‌ی اکشن‌های هدر (پشتیبانی)',
    },
    support: {
      contract: '[data-ui="support"]',
      legacy: ['#mrm-support-link', '#zomorod-support-link', '.support-btn', 'a[href*="t.me"]'],
      label: 'لینک پشتیبانی',
    },

    /* --- اعلان ----------------------------------------------------------- */
    announcement: {
      contract: '[data-ui="announcement"]',
      legacy: ['.treasury-notice', '.mrm-special-announcement', '.zomorod-special-announcement'],
      label: 'کارت اعلان',
    },

    /* --- کانفیگ‌ها -------------------------------------------------------- */
    configs: {
      contract: '[data-ui="configs"]',
      legacy: ['.treasury-links-section', '#connection-links'],
      label: 'بخش کانفیگ‌ها',
    },
    configRow: {
      contract: '[data-ui="config-row"]',
      legacy: ['.treasury-config-card', '.treasury-server-row'],
      label: 'ردیف کانفیگ',
    },
    configProtocol: {
      contract: '[data-ui="config-protocol"]',
      legacy: ['.treasury-config-protocol', '.ios-protocol-badge'],
      label: 'نشان پروتکل',
    },
    wireguard: {
      contract: '[data-ui="wireguard"]',
      legacy: ['a[download][href$="/wireguard"]'],
      label: 'دکمه/ردیف وایرگارد',
    },
    quickConnect: {
      contract: '[data-ui="quick-connect"]',
      legacy: ['.treasury-quick-action', '.treasury-quick-main'],
      label: 'دکمه‌ی اتصال سریع',
    },

    /* --- آمار و ابزار ----------------------------------------------------- */
    ping: {
      contract: '[data-ui="ping"]',
      legacy: ['.treasury-server-ping'],
      label: 'نشانگر پینگ',
    },
    apps: {
      contract: '[data-ui="apps"]',
      legacy: ['.apps-list', '[data-section="apps"]'],
      label: 'بخش اپلیکیشن‌ها',
    },
    sectionTitle: {
      contract: '[data-ui="section-title"]',
      legacy: ['.treasury-section-title'],
      label: 'عنوان بخش',
    },
  };

  /* وضعیت داخلی: کدام عناصر روی DOM فعلی با قرارداد پیدا شدند */
  var runtimeState = {
    resolved: {},   // name → 'contract' | 'legacy' | 'missing'
    warned: {},
  };

  function doc() {
    return (typeof document !== 'undefined') ? document : null;
  }

  /* همه‌ی عناصر یک نام منطقی — قرارداد اول، بعد legacy */
  function all(name) {
    var d = doc();
    if (!d) return [];
    var def = MAP[name];
    if (!def) return [];
    var found = [];
    try { found = Array.prototype.slice.call(d.querySelectorAll(def.contract)); } catch (e) { found = []; }
    if (found.length) {
      runtimeState.resolved[name] = 'contract';
      return found;
    }
    for (var i = 0; i < def.legacy.length; i++) {
      try { found = Array.prototype.slice.call(d.querySelectorAll(def.legacy[i])); } catch (e) { found = []; }
      if (found.length) {
        runtimeState.resolved[name] = 'legacy';
        return found;
      }
    }
    runtimeState.resolved[name] = 'missing';
    return [];
  }

  function one(name) {
    var list = all(name);
    return list.length ? list[0] : null;
  }

  function has(name) {
    return all(name).length > 0;
  }

  /* وضعیت همه‌ی نام‌ها — برای گزارش و تست */
  function status() {
    var out = {};
    Object.keys(MAP).forEach(function (k) {
      var list = all(k);
      out[k] = { found: list.length, via: runtimeState.resolved[k], label: MAP[k].label };
    });
    return out;
  }

  /* تشخیص: عناصر گم‌شده را برمی‌گرداند */
  function missing() {
    return Object.keys(MAP).filter(function (k) { return all(k).length === 0; });
  }

  /* گزارش وضعیت. policy: 'silent' | 'warn' | 'throw' */
  function diagnose(policy, tag) {
    var miss = missing();
    var usedLegacy = Object.keys(MAP).filter(function (k) {
      all(k);
      return runtimeState.resolved[k] === 'legacy';
    });
    var report = {
      contract: VERSION,
      tag: tag || 'ui-contract',
      missing: miss,
      legacyFallback: usedLegacy,
      ok: miss.length === 0,
    };
    if (miss.length || usedLegacy.length) {
      var msg = '[' + report.tag + '] قرارداد UI v' + VERSION + ': ' +
        miss.length + ' عنصر گم‌شده' +
        (usedLegacy.length ? ' · ' + usedLegacy.length + ' مورد با سلکتور قدیمی کار می‌کند' : '');
      if (miss.length) {
        msg += '\n  گم‌شده: ' + miss.map(function (k) {
          return k + ' (' + MAP[k].label + ')';
        }).join(', ');
        msg += '\n  نتیجه: تنظیمات مربوط به این عناصر بی‌اثر خواهند بود.';
      }
      if (usedLegacy.length) {
        msg += '\n  legacy: ' + usedLegacy.join(', ') +
               '\n  توصیه: قالب را به قرارداد v' + VERSION + ' به‌روز کنید.';
      }
      if (policy === 'throw' && miss.length) {
        throw new Error(msg);
      }
      if (policy !== 'silent' && typeof console !== 'undefined' && console.warn) {
        console.warn(msg);
      }
      /* ردپای ماشین‌خوان روی DOM — برای تست خودکار و پشتیبانی */
      try {
        var root = doc().documentElement;
        if (root) {
          root.setAttribute('data-ui-contract', VERSION);
          root.setAttribute('data-ui-missing', miss.join(',') || '');
          root.setAttribute('data-ui-legacy', usedLegacy.join(',') || '');
        }
      } catch (e) { /* بی‌اهمیت */ }
    } else {
      try {
        var r2 = doc().documentElement;
        if (r2) {
          r2.setAttribute('data-ui-contract', VERSION);
          r2.setAttribute('data-ui-missing', '');
          r2.setAttribute('data-ui-legacy', '');
        }
      } catch (e2) { /* بی‌اهمیت */ }
    }
    return report;
  }

  /* پنهان/نمایش با حفظ مقدار اصلی — همان الگوی امن پیشین */
  var ORIGINAL_ATTR = 'data-ui-original-display';

  function setDisplay(node, visible) {
    if (!node || node.nodeType !== 1) return;
    if (visible) {
      if (node.hasAttribute(ORIGINAL_ATTR)) {
        node.style.display = node.getAttribute(ORIGINAL_ATTR) || '';
        node.removeAttribute(ORIGINAL_ATTR);
      } else if ((node.style.display || '') === 'none') {
        node.style.display = '';
      }
    } else if (!node.hasAttribute(ORIGINAL_ATTR)) {
      node.setAttribute(ORIGINAL_ATTR, node.style.display || '');
      node.style.display = 'none';
    }
  }

  function showAll(name, visible) {
    all(name).forEach(function (n) { setDisplay(n, visible); });
    return all(name).length;
  }

  /* بازگردانی همه‌ی تغییرات نمایشی */
  function restoreAll() {
    var d = doc();
    if (!d) return 0;
    var nodes = d.querySelectorAll('[' + ORIGINAL_ATTR + ']');
    Array.prototype.forEach.call(nodes, function (n) {
      n.style.display = n.getAttribute(ORIGINAL_ATTR) || '';
      n.removeAttribute(ORIGINAL_ATTR);
    });
    return nodes.length;
  }

  return {
    VERSION: VERSION,
    MAP: MAP,
    all: all,
    one: one,
    has: has,
    status: status,
    missing: missing,
    diagnose: diagnose,
    setDisplay: setDisplay,
    showAll: showAll,
    restoreAll: restoreAll,
    ORIGINAL_ATTR: ORIGINAL_ATTR,
  };
})();

if (typeof window !== 'undefined') { window.__UI_CONTRACT__ = UI_CONTRACT; }
/* <<< UI_CONTRACT_END <<< */

  // Detect active template: MRM Classic or MRM Special
  const isClassic = Boolean(document.getElementById('guideBanner') || document.querySelector('.status-main'));
  const isSpecial = Boolean(document.querySelector('.treasury-shell') || document.querySelector('#root') || document.querySelector('#app'));

  if (!isClassic && !isSpecial) {
    return;
  }

  /* قرارداد مشترک DOM (تزریق‌شده از shared/ui-contract.js) */
  const UI = window.__UI_CONTRACT__;

  const PREFIX = 'x-mrm-';
  const SUPPORT_ID = 'mrm-support-link';
  const THEME_STYLE_ID = 'mrm-theme-style';
  const THEME_DEFAULTS = { primary: '#2DB7B2', secondary: '#0B6E6A' };
  const DEFAULTS = {
    enabled: true,
    storeName: 'MRM',
    supportId: '',
    showConfigs: true,
    showWireGuard: false,
    showPing: true,
    showApps: true,
    showAnnouncement: false,
    announcementMode: 'always',
    announcementTimes: '',
    announcementDuration: 60,
    themePrimary: THEME_DEFAULTS.primary,
    themeSecondary: THEME_DEFAULTS.secondary,
  };

  const state = {
    config: { ...DEFAULTS },
    raw: null,
    loaded: false,
  };

  let applyQueued = false;
  let refreshInFlight = false;
  let domObserver = null;
  const REFRESH_INTERVAL_MS = 5 * 60 * 1000;

  const specialCss = `
    .mrm-special-announcement{
      position:relative!important;
      isolation:isolate;
      overflow:hidden!important;
      border-color:color-mix(in srgb,var(--treasury-emerald-bright) 42%,transparent)!important;
      background:
        radial-gradient(circle at 8% 18%,color-mix(in srgb,var(--treasury-emerald-bright) 16%,transparent),transparent 34%),
        radial-gradient(circle at 92% 82%,color-mix(in srgb,var(--treasury-gold) 18%,transparent),transparent 36%),
        linear-gradient(135deg,color-mix(in srgb,var(--treasury-emerald) 10%,transparent),color-mix(in srgb,var(--treasury-emerald-bright) 5.5%,transparent) 48%,color-mix(in srgb,var(--treasury-gold) 9%,transparent))!important;
      box-shadow:0 12px 38px color-mix(in srgb,var(--treasury-emerald) 12%,transparent),0 0 0 1px color-mix(in srgb,var(--treasury-gold) 8%,transparent),inset 0 1px 0 rgba(255,255,255,.08)!important;
      animation:mrmAnnBreathe 3.4s ease-in-out infinite;
    }
    .mrm-special-announcement>*{position:relative;z-index:2}
    .mrm-special-announcement:before{
      content:"";
      position:absolute;
      z-index:1;
      width:38%;
      height:220%;
      top:-60%;
      left:-52%;
      pointer-events:none;
      background:linear-gradient(90deg,transparent,rgba(255,255,255,.20),color-mix(in srgb,var(--treasury-gold-bright) 17%,transparent),transparent);
      transform:translateX(0) rotate(14deg);
      animation:mrmAnnSweep 4.8s cubic-bezier(.3,.7,.2,1) infinite;
    }
    .mrm-special-announcement .treasury-notice-icon{
      color:var(--treasury-gold-bright)!important;
      border-color:color-mix(in srgb,var(--treasury-gold) 26%,transparent)!important;
      background:linear-gradient(145deg,var(--treasury-emerald-deep),var(--treasury-emerald) 62%,var(--treasury-gold))!important;
      box-shadow:0 0 0 1px rgba(255,255,255,.08),0 0 24px color-mix(in srgb,var(--treasury-emerald-bright) 20%,transparent)!important;
      animation:mrmAnnIcon 2.1s ease-in-out infinite;
    }
    .mrm-special-announcement h2{
      color:var(--treasury-emerald)!important;
      text-shadow:0 0 18px color-mix(in srgb,var(--treasury-emerald-bright) 12%,transparent);
    }
    html.dark .mrm-special-announcement h2{color:var(--treasury-emerald-bright)!important}
    #${SUPPORT_ID}{
      min-height:34px;
      display:inline-flex;
      align-items:center;
      gap:.4rem;
      padding:.42rem .62rem;
      border-radius:999px;
      border:1px solid color-mix(in srgb,var(--treasury-emerald-bright) 20%,transparent);
      color:inherit;
      background:linear-gradient(135deg,color-mix(in srgb,var(--treasury-emerald-bright) 8%,transparent),color-mix(in srgb,var(--treasury-gold) 8%,transparent));
      font-size:.72rem;
      font-weight:750;
      text-decoration:none;
      white-space:nowrap;
      transition:transform .16s ease,border-color .16s ease,background .16s ease;
    }
    #${SUPPORT_ID}:hover{transform:translateY(-1px);border-color:color-mix(in srgb,var(--treasury-emerald-bright) 38%,transparent);background:linear-gradient(135deg,color-mix(in srgb,var(--treasury-emerald-bright) 12%,transparent),color-mix(in srgb,var(--treasury-gold) 11%,transparent))}
    #${SUPPORT_ID} .mrm-support-gem{color:var(--treasury-emerald-bright);font-size:.78rem;line-height:1}
    #${SUPPORT_ID} .mrm-support-label{max-width:128px;overflow:hidden;text-overflow:ellipsis}
    @media(max-width:560px){ #${SUPPORT_ID}{padding:.42rem .52rem}#${SUPPORT_ID} .mrm-support-value{display:none}}
    /* جابه‌جایی با transform، نه left: انیمیشن left در هر فریم یک layout
       shift ثبت می‌کرد (۰٫۰۸ CLS فقط از همین نوار درخشان). */
    @keyframes mrmAnnSweep{
      0%,12%{transform:translateX(0) rotate(14deg);opacity:0}
      22%{opacity:1}
      58%{transform:translateX(458%) rotate(14deg);opacity:.8}
      70%,100%{transform:translateX(458%) rotate(14deg);opacity:0}
    }
    @keyframes mrmAnnBreathe{
      0%,100%{transform:translateY(0);box-shadow:0 12px 38px color-mix(in srgb,var(--treasury-emerald) 12%,transparent),0 0 0 1px color-mix(in srgb,var(--treasury-gold) 8%,transparent)}
      50%{transform:translateY(-1px);box-shadow:0 16px 46px color-mix(in srgb,var(--treasury-emerald) 18%,transparent),0 0 0 1px color-mix(in srgb,var(--treasury-gold) 16%,transparent),0 0 30px color-mix(in srgb,var(--treasury-emerald-bright) 8%,transparent)}
    }
    @keyframes mrmAnnIcon{
      0%,100%{transform:scale(1) rotate(0deg)}
      50%{transform:scale(1.06) rotate(-3deg)}
    }
    @media(prefers-reduced-motion:reduce){
      .mrm-special-announcement,.mrm-special-announcement:before,.mrm-special-announcement .treasury-notice-icon{animation:none!important}
    }
    /* پنهان‌سازیِ زودهنگام بخش کانفیگ‌ها/اتصال سریع — پیش از اولین رنگ.
       کلاس روی <html> و قاعدهٔ CSS اینجا با هم کار می‌کنند تا کلیدِ ادمین
       (show-configs=false) باعث «رندر و بعد ناپدید شدن» کارت و پرش چیدمان
       نشود؛ runtime همین‌که پاسخ /raw رسید کلاس را می‌گذارد. */
    html.mrm-hide-connections [data-ui="configs"],
    html.mrm-hide-connections #connection-links,
    html.mrm-hide-connections .treasury-links-section,
    html.mrm-hide-connections [data-ui="quick-connect"],
    html.mrm-hide-connections .treasury-quick-action,
    html.mrm-hide-connections .treasury-quick-main{display:none!important}
  `;

  if (!document.getElementById('mrm-runtime-style')) {
    const style = document.createElement('style');
    style.id = 'mrm-runtime-style';
    style.textContent = specialCss;
    document.head.appendChild(style);
  }

  const bool = (value, fallback) => {
    if (value == null || value === '') return fallback;
    return !['0', 'false', 'off', 'no'].includes(String(value).trim().toLowerCase());
  };

  const normalizeHeaders = (headers) => Object.fromEntries(
    Object.entries(headers || {}).map(([key, value]) => [String(key).toLowerCase(), String(value ?? '')])
  );

  const header = (headers, name) => headers[`${PREFIX}${name}`] ?? '';

  const normalizeHex = (input, fallback) => {
    const value = String(input || '').trim().toUpperCase();
    return /^#[0-9A-F]{6}$/.test(value) ? value : fallback;
  };
  const hexToRgb = (hex) => {
    const value = normalizeHex(hex, '#000000').slice(1);
    return { r: parseInt(value.slice(0, 2), 16), g: parseInt(value.slice(2, 4), 16), b: parseInt(value.slice(4, 6), 16) };
  };
  const rgbToHex = (r, g, b) => '#' + [r, g, b]
    .map((value) => Math.max(0, Math.min(255, Math.round(value))).toString(16).padStart(2, '0'))
    .join('').toUpperCase();
  const mixHex = (hex, target, amount) => {
    const a = hexToRgb(hex), b = hexToRgb(target), t = Math.max(0, Math.min(1, amount));
    return rgbToHex(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t);
  };
  const rgbaHex = (hex, alpha) => {
    const { r, g, b } = hexToRgb(hex);
    return `rgba(${r},${g},${b},${alpha})`;
  };
  const contrastText = (hex) => {
    const { r, g, b } = hexToRgb(hex);
    const lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
    return lum > 0.62 ? '#172015' : '#FFFFFF';
  };

  const applyTheme = (config) => {
    const primary = normalizeHex(config?.themePrimary, DEFAULTS.themePrimary);
    const secondary = normalizeHex(config?.themeSecondary, DEFAULTS.themeSecondary);
    const primaryChanged = primary !== THEME_DEFAULTS.primary;
    const secondaryChanged = secondary !== THEME_DEFAULTS.secondary;
    let style = document.getElementById(THEME_STYLE_ID);

    // No customization means no CSS override at all, preserving the exact
    // upstream MRM palette byte-for-byte.
    if (!primaryChanged && !secondaryChanged) {
      style?.remove();
      return;
    }

    if (!style) {
      style = document.createElement('style');
      style.id = THEME_STYLE_ID;
      document.head.appendChild(style);
    }

    const light = [];
    const dark = [];

    const darkPrimary = mixHex(primary, '#FFFFFF', 0.18);
    const primaryBright = mixHex(primary, '#FFFFFF', 0.28);
    const darkPrimaryBright = mixHex(primary, '#FFFFFF', 0.4);
    const darkSecondary = mixHex(secondary, '#FFFFFF', 0.12);
    const secondaryDeep = mixHex(secondary, '#000000', 0.28);
    const secondaryBright = mixHex(secondary, '#FFFFFF', 0.12);
    const darkSecondaryBright = mixHex(secondary, '#FFFFFF', 0.24);

    // Once a custom theme is active, recolor the neutral canvas too. Previously
    // these variables stayed on the original green-tinted defaults, which left a
    // visible emerald haze behind blue/violet/custom palettes.
    const surfaceSeed = secondaryChanged ? secondary : primary;
    const lightBackground = mixHex(surfaceSeed, '#FFFFFF', 0.965);
    const lightCardSolid = mixHex(surfaceSeed, '#FFFFFF', 0.986);
    const lightMuted = mixHex(surfaceSeed, '#FFFFFF', 0.915);
    const lightAccent = mixHex(primary, '#FFFFFF', 0.92);
    const lightForeground = mixHex(surfaceSeed, '#121716', 0.9);

    const darkBackground = mixHex(surfaceSeed, '#050708', 0.84);
    const darkCardSolid = mixHex(surfaceSeed, '#111416', 0.76);
    const darkMuted = mixHex(surfaceSeed, '#1A1E20', 0.72);
    const darkAccent = mixHex(primary, '#20242A', 0.76);
    const darkForeground = mixHex(primary, '#F3F6F5', 0.965);

    light.push(
      `--background:${lightBackground}`,
      `--foreground:${lightForeground}`,
      `--card:${rgbaHex(lightCardSolid,.94)}`,
      `--card-solid:${lightCardSolid}`,
      `--card-foreground:${lightForeground}`,
      `--popover:${rgbaHex(lightCardSolid,.96)}`,
      `--popover-foreground:${lightForeground}`,
      `--muted:${lightMuted}`,
      `--muted-foreground:${mixHex(lightForeground, '#FFFFFF', 0.46)}`,
      `--accent:${lightAccent}`,
      `--accent-foreground:${lightForeground}`,
      `--border:${rgbaHex(surfaceSeed,.15)}`,
      `--input:${rgbaHex(surfaceSeed,.09)}`,
      `--separator:${rgbaHex(surfaceSeed,.12)}`,
      `--material:${rgbaHex(lightBackground,.82)}`,
      `--material-strong:${rgbaHex(lightCardSolid,.92)}`,
      `--shadow:0 1px 2px rgba(8,12,14,.04),0 12px 34px ${rgbaHex(surfaceSeed,.08)}`,
      `--shadow-raised:0 2px 4px rgba(8,12,14,.06),0 22px 54px ${rgbaHex(surfaceSeed,.12)}`,
      `--primary:${primary}`,
      `--primary-soft:${rgbaHex(primary,.12)}`,
      `--primary-foreground:${contrastText(primary)}`,
      `--ring:${primary}`,
      `--secondary:${secondary}`,
      `--secondary-foreground:${contrastText(secondary)}`,
      `--treasury-gold:${primary}`,
      `--treasury-gold-bright:${primaryBright}`,
      `--treasury-gold-foreground:${contrastText(primary)}`,
      `--treasury-emerald:${secondary}`,
      `--treasury-emerald-deep:${secondaryDeep}`,
      `--treasury-emerald-bright:${secondaryBright}`,
      `--treasury-emerald-foreground:${contrastText(secondary)}`,
    );

    dark.push(
      `--background:${darkBackground}`,
      `--foreground:${darkForeground}`,
      `--card:${rgbaHex(darkCardSolid,.91)}`,
      `--card-solid:${darkCardSolid}`,
      `--card-foreground:${darkForeground}`,
      `--popover:${rgbaHex(darkCardSolid,.96)}`,
      `--popover-foreground:${darkForeground}`,
      `--muted:${darkMuted}`,
      `--muted-foreground:${mixHex(darkForeground, '#000000', 0.36)}`,
      `--accent:${darkAccent}`,
      `--accent-foreground:${darkForeground}`,
      `--border:${rgbaHex(mixHex(surfaceSeed, '#FFFFFF', .28),.16)}`,
      `--input:${rgbaHex(mixHex(surfaceSeed, '#FFFFFF', .32),.10)}`,
      `--separator:${rgbaHex(mixHex(surfaceSeed, '#FFFFFF', .24),.13)}`,
      `--material:${rgbaHex(darkBackground,.80)}`,
      `--material-strong:${rgbaHex(darkCardSolid,.93)}`,
      `--shadow:0 1px 2px rgba(0,0,0,.22),0 16px 42px rgba(0,0,0,.26)`,
      `--shadow-raised:0 2px 4px rgba(0,0,0,.28),0 26px 64px rgba(0,0,0,.34)`,
      `--primary:${darkPrimary}`,
      `--primary-soft:${rgbaHex(darkPrimary,.14)}`,
      `--primary-foreground:${contrastText(darkPrimary)}`,
      `--ring:${darkPrimary}`,
      `--secondary:${darkSecondary}`,
      `--secondary-foreground:${contrastText(darkSecondary)}`,
      `--treasury-gold:${primary}`,
      `--treasury-gold-bright:${darkPrimaryBright}`,
      `--treasury-gold-foreground:${contrastText(primary)}`,
      `--treasury-emerald:${secondary}`,
      `--treasury-emerald-deep:${secondaryDeep}`,
      `--treasury-emerald-bright:${darkSecondaryBright}`,
      `--treasury-emerald-foreground:${contrastText(secondary)}`,
    );

    style.textContent = `
      :root{${light.join(';')}}
      .treasury-shell{${light.join(';')}}
      .dark{${dark.join(';')}}
      .dark .treasury-shell{${dark.join(';')}}`;
  };

  const decodeUtf8Base64 = (value) => {
    if (!value) return '';
    try {
      const binary = atob(value);
      return new TextDecoder().decode(Uint8Array.from(binary, (c) => c.charCodeAt(0)));
    } catch {
      return '';
    }
  };

  const supportLabelFromUrl = (value) => {
    const raw = String(value || '').trim();
    if (!raw) return '';
    try {
      const parsed = new URL(raw, window.location.origin);
      if (['t.me', 'www.t.me', 'telegram.me', 'www.telegram.me'].includes(parsed.hostname.toLowerCase())) {
        const path = parsed.pathname.replace(/^\/+|\/+$/g, '');
        if (path && !path.includes('/') && !path.startsWith('+')) return `@${path}`;
      }
    } catch (_) {}
    return raw;
  };

  const supportHref = (value) => {
    const raw = String(value || '').trim();
    if (!raw) return '';
    const username = raw.startsWith('@') ? raw.slice(1) : raw;
    if (/^[A-Za-z0-9_]{4,64}$/.test(username)) return `https://t.me/${username}`;
    if (/^(?:https?:\/\/|tg:\/\/)/i.test(raw)) return raw;
    return '';
  };

  const parseConfig = (raw) => {
    const headers = normalizeHeaders(raw?.headers);
    const encodedSupport = decodeUtf8Base64(header(headers, 'support-id-b64').trim());
    return {
      enabled: bool(header(headers, 'enabled'), DEFAULTS.enabled),
      storeName: decodeUtf8Base64(header(headers, 'store-name-b64').trim()) || header(headers, 'store-name').trim() || DEFAULTS.storeName,
      supportId: encodedSupport || header(headers, 'support-id').trim() || supportLabelFromUrl(headers['support-url']) || DEFAULTS.supportId,
      showConfigs: bool(header(headers, 'show-configs'), DEFAULTS.showConfigs),
      showWireGuard: bool(header(headers, 'show-wireguard'), DEFAULTS.showWireGuard),
      showPing: bool(header(headers, 'show-ping'), DEFAULTS.showPing),
      showApps: bool(header(headers, 'show-apps'), DEFAULTS.showApps),
      showAnnouncement: bool(header(headers, 'show-announcement'), DEFAULTS.showAnnouncement),
      announcementMode: header(headers, 'announcement-mode') === 'scheduled' ? 'scheduled' : 'always',
      announcementTimes: header(headers, 'announcement-times'),
      announcementDuration: Math.max(1, Math.min(1440, Number(header(headers, 'announcement-duration')) || DEFAULTS.announcementDuration)),
      themePrimary: normalizeHex(header(headers, 'theme-primary'), DEFAULTS.themePrimary),
      themeSecondary: normalizeHex(header(headers, 'theme-secondary'), DEFAULTS.themeSecondary),
    };
  };

  const basePath = () => window.location.pathname.replace(/\/+$/, '');

  async function fetchRaw() {
    /* اگر اسکریپت بوت (داخل قالب) واکشی را در حین پارس شروع کرده باشد، همان
       پاسخ را مصرف می‌کنیم: یک درخواست، و زودتر از اولین رنگِ React. */
    const early = window.__mrmRawPromise;
    if (early && typeof early.then === 'function') {
      try {
        return await early;
      } catch (error) {
        /* بوت شکست خورد؛ خودمان دوباره تلاش می‌کنیم (مسیر اصلی پایین) */
      }
    }
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 7000);
    try {
      const response = await fetch(`${window.location.origin}${basePath()}/raw`, {
        headers: { Accept: 'application/json' },
        cache: 'no-store',
        signal: controller.signal,
      });
      if (!response.ok) throw new Error(`raw endpoint returned ${response.status}`);
      return await response.json();
    } finally {
      clearTimeout(timeout);
    }
  }

  const setDisplay = (node, visible) => {
    if (!(node instanceof HTMLElement)) return;
    if (!node.hasAttribute('data-mrm-original-display')) {
      node.setAttribute('data-mrm-original-display', node.style.display || '');
    }
    const target = visible ? (node.getAttribute('data-mrm-original-display') || '') : 'none';
    if (node.style.display !== target) node.style.display = target;
  };

  const updateBrand = (name) => {
    if (!name) return;
    /* همه‌ی عناصر قرارداد با نام logical «brand» — در هدر و فوتر و هرجای دیگر.
       پیش از این فقط '.treasury-brand' هدف بود که در قالب بازنویسی‌شده وجود نداشت. */
    UI.all('brand').forEach((label) => {
      if (label.textContent !== name) label.textContent = name;
    });
    UI.all('brandBox').forEach((box) => {
      if (box.getAttribute('aria-label') !== name) box.setAttribute('aria-label', name);
    });
    /* عنوان سند: الگوی «<برند> · <نام کاربر>» را حفظ می‌کند */
    const t = document.title || '';
    if (t && !t.startsWith(name)) {
      const sep = t.includes('·') ? '·' : (t.includes(' - ') ? ' - ' : null);
      if (sep) {
        const parts = t.split(sep);
        parts[0] = ' ' + name + ' ';
        document.title = parts.join(sep);
      }
    }
  };

  /* جانگهدار `__BRAND__` را `manager/theme.sh` در زمان استقرار جانشین می‌کند.
     اگر آن مرحله اجرا نشده باشد (نصب دستی، فایل کهنه) و تنظیمات هم در دسترس
     نباشند، کاربر متن خام توکن را می‌دید. این نگهبان فقط متنی را عوض می‌کند که
     واقعاً توکن است، پس برند جانشین‌شده‌ی theme.sh را دست نمی‌زند. */
  const deTokenizeBrand = () => {
    const TOKEN = /^__[A-Za-z_]+__$/;
    UI.all('brand').forEach((node) => {
      const text = (node.textContent || '').trim();
      if (TOKEN.test(text)) node.textContent = DEFAULTS.storeName;
    });
    const title = document.title || '';
    if (/__[A-Za-z_]+__/.test(title)) {
      document.title = title.replace(/__[A-Za-z_]+__/g, DEFAULTS.storeName).trim();
    }
  };

  const applySupport = (supportId) => {
    const href = supportHref(supportId);
    let link = document.getElementById(SUPPORT_ID);
    if (!href) {
      if (link) link.remove();
      return;
    }

    const controls = document.querySelector('.treasury-navigation .ios-container .flex.shrink-0')
      || document.querySelector('.treasury-navigation .ios-container > div:last-child');
    if (!(controls instanceof HTMLElement)) return;

    if (!(link instanceof HTMLAnchorElement)) {
      link = document.createElement('a');
      link.id = SUPPORT_ID;
      link.target = '_blank';
      link.rel = 'noopener noreferrer';
      link.innerHTML = '<span class="mrm-support-gem">◆</span><span class="mrm-support-label">پشتیبانی</span><span class="mrm-support-value"></span>';
      controls.insertBefore(link, controls.firstChild);
    }

    if (link.href !== new URL(href, window.location.origin).href) link.href = href;
    const valueNode = link.querySelector('.mrm-support-value');
    const label = supportLabelFromUrl(supportId);
    if (valueNode && valueNode.textContent !== label) valueNode.textContent = label;
    const title = `پشتیبانی ${label}`.trim();
    if (link.title !== title) link.title = title;
  };

  const isWireGuardRow = (row) => {
    /* اول قرارداد صریح، بعد خواندن متن نشان */
    const declared = row.getAttribute && row.getAttribute('data-protocol');
    if (declared) return /^(wg|wireguard)$/i.test(declared);
    const badge = UI.one('configProtocol') && row.querySelector('[data-ui="config-protocol"]');
    const protocol = (badge || row.querySelector('.treasury-config-protocol, .ios-protocol-badge'))
      ?.textContent?.trim().toUpperCase();
    return protocol === 'WG' || protocol === 'WIREGUARD';
  };

  const applyConnections = (config) => {
    // Support both the legacy server rows and the current subscription card UI.
    const rows = UI.all('configRow').filter((row) => row instanceof HTMLElement);
    const hasWireGuard = rows.some(isWireGuardRow);

    rows.forEach((row) => {
      const visible = isWireGuardRow(row) ? config.showWireGuard : config.showConfigs;
      setDisplay(row, visible);
    });

    // The dedicated archive action is rendered separately from the config rows.
    // Keep it in sync with the same WireGuard visibility switch.
    UI.all('wireguard').forEach((node) => {
      setDisplay(node, config.showWireGuard);
    });

    const showSection = config.showConfigs || (config.showWireGuard && hasWireGuard);
    UI.all('configs').forEach((node) => setDisplay(node, showSection));
    UI.all('quickConnect').forEach((node) => setDisplay(node, showSection));
    /* با DOM واقعی، همان تصمیم را روی کلاس ریشه هم تازه کن (منبعِ یکسان) */
    syncEarlyConnectionsVisibility(config, hasWireGuard);

    return hasWireGuard;
  };

  const applyPing = (visible) => {
    UI.showAll('ping', visible);
  };

  const applyApps = (visible) => {
    /* مسیر قراردادی: یک ظرف واحد برای کل بخش اپلیکیشن‌ها */
    const containers = UI.all('apps');
    if (containers.length) {
      containers.forEach((node) => setDisplay(node, visible));
      return;
    }
    /* مسیر قدیمی: عنوان + همسایه‌اش */
    UI.all('sectionTitle').forEach((title) => {
      const text = title.textContent || '';
      if (!/اپلیکیشن|application/i.test(text)) return;
      setDisplay(title, visible);
      setDisplay(title.nextElementSibling, visible);
    });
  };

  const nativeAnnouncement = () => {
    const headers = normalizeHeaders(state.raw?.headers);
    return String(headers.announce || '').trim();
  };

  const announcementIsInWindow = (config) => {
    if (config.announcementMode !== 'scheduled') return true;
    const times = String(config.announcementTimes || '')
      .split(',')
      .map((value) => value.trim())
      .filter((value) => /^([01]\d|2[0-3]):[0-5]\d$/.test(value));
    if (!times.length) return false;

    const now = new Date();
    const nowMinutes = now.getHours() * 60 + now.getMinutes();
    return times.some((time) => {
      const [hour, minute] = time.split(':').map(Number);
      const start = hour * 60 + minute;
      const diff = (nowMinutes - start + 1440) % 1440;
      return diff < config.announcementDuration;
    });
  };

  const applyAnnouncement = (config) => {
    const hasAnnouncement = nativeAnnouncement().length > 0;
    const visible = config.showAnnouncement && hasAnnouncement && announcementIsInWindow(config);

    UI.all('announcement').forEach((notice) => {
      if (!(notice instanceof HTMLElement)) return;
      setDisplay(notice, visible);
      if (visible) notice.classList.add('mrm-special-announcement');
      else notice.classList.remove('mrm-special-announcement');
    });
  };

  const restoreOriginalUi = () => {
    document.querySelectorAll('[data-mrm-original-display]').forEach((node) => {
      if (!(node instanceof HTMLElement)) return;
      node.style.display = node.getAttribute('data-mrm-original-display') || '';
      node.removeAttribute('data-mrm-original-display');
    });
    document.querySelectorAll('.mrm-special-announcement').forEach((node) => node.classList.remove('mrm-special-announcement'));
    document.getElementById(SUPPORT_ID)?.remove();
    document.getElementById(THEME_STYLE_ID)?.remove();
    document.getElementById('mrm-classic-theme-style')?.remove();
    document.documentElement.removeAttribute('data-mrm');
  };

  const observeDom = () => {
    if (!domObserver || !document.documentElement) return;
    domObserver.observe(document.documentElement, { subtree: true, childList: true });
  };

  // ─── CLASSIC TEMPLATE HANDLERS (MRM Classic) ──────────────────────────
  const applyClassicTheme = (config) => {
    const primary = normalizeHex(config?.themePrimary, DEFAULTS.themePrimary);
    const secondary = normalizeHex(config?.themeSecondary, DEFAULTS.themeSecondary);
    const primaryChanged = primary !== THEME_DEFAULTS.primary;
    const secondaryChanged = secondary !== THEME_DEFAULTS.secondary;
    const styleId = 'mrm-classic-theme-style';
    let style = document.getElementById(styleId);

    if (!primaryChanged && !secondaryChanged) {
      style?.remove();
      return;
    }

    if (!style) {
      style = document.createElement('style');
      style.id = styleId;
      document.head.appendChild(style);
    }

    const primarySoft = rgbaHex(primary, 0.12);
    const primaryGlow = rgbaHex(primary, 0.28);
    const secondaryDark = mixHex(secondary, '#000000', 0.2);
    const secondaryGlow = rgbaHex(secondary, 0.3);
    const borderAccent = rgbaHex(primary, 0.28);

    const darkPrimary = mixHex(primary, '#FFFFFF', 0.2);
    const darkPrimarySoft = rgbaHex(darkPrimary, 0.14);
    const darkPrimaryGlow = rgbaHex(darkPrimary, 0.25);
    const darkSecondary = mixHex(secondary, '#FFFFFF', 0.15);
    const darkSecondaryDark = secondary;
    const darkSecondaryGlow = rgbaHex(darkSecondary, 0.28);
    const darkBorderAccent = rgbaHex(darkPrimary, 0.28);

    style.textContent = `
      :root {
        --accent: ${primary}!important;
        --accent-soft: ${primarySoft}!important;
        --accent-glow: ${primaryGlow}!important;
        --border-accent: ${borderAccent}!important;
        --teal: ${secondary}!important;
        --teal-dark: ${secondaryDark}!important;
        --teal-glow: ${secondaryGlow}!important;
      }
      .dark {
        --accent: ${darkPrimary}!important;
        --accent-soft: ${darkPrimarySoft}!important;
        --accent-glow: ${darkPrimaryGlow}!important;
        --border-accent: ${darkBorderAccent}!important;
        --teal: ${darkSecondary}!important;
        --teal-dark: ${darkSecondaryDark}!important;
        --teal-glow: ${darkSecondaryGlow}!important;
      }
    `;
  };

  const updateClassicBrand = (name) => {
    if (!name || name === '__BRAND__') return;
    document.querySelectorAll('.brand').forEach((el) => {
      if (el.textContent !== name) el.textContent = name;
    });
    if (document.title !== name) document.title = name;
  };

  const applyClassicSupport = (supportId) => {
    const href = supportHref(supportId);
    if (!href) return;
    UI.all('support').forEach((btn) => {
      if (btn instanceof HTMLAnchorElement && btn.href !== href) {
        btn.href = href;
      }
    });
    const renewBtn = document.getElementById('renewBtn');
    if (renewBtn instanceof HTMLAnchorElement && renewBtn.href !== href) {
      renewBtn.href = href;
    }
  };

  const applyClassicConnections = (config) => {
    const configsBtn = document.querySelector('button[onclick*="showConfigs"]');
    setDisplay(configsBtn, config.showConfigs);
    syncEarlyConnectionsVisibility(config, null);
  };

  const applyClassicApps = (visible) => {
    const dlGrid = document.querySelector('.dl-grid');
    const separator = document.querySelector('.separator');
    setDisplay(dlGrid, visible);
    setDisplay(separator, visible);
  };

  const applyClassicAnnouncement = (config) => {
    const annBox = document.getElementById('announcement');
    const annTextEl = document.getElementById('announceText');
    const text = nativeAnnouncement() || (annTextEl ? annTextEl.textContent : '');
    const hasText = Boolean(text && text !== '__NEWS__' && text.trim().length > 0);
    const isWindow = announcementIsInWindow(config);
    const visible = config.showAnnouncement && hasText && isWindow;

    if (annBox instanceof HTMLElement) {
      if (visible) {
        if (nativeAnnouncement() && annTextEl && annTextEl.textContent !== nativeAnnouncement()) {
          annTextEl.textContent = nativeAnnouncement();
        }
        annBox.classList.add('show');
        setDisplay(annBox, true);
      } else {
        annBox.classList.remove('show');
        setDisplay(annBox, false);
      }
    }
  };

  /* پایان بوت: صفحهٔ بوتِ نصب‌شده در قالب را برمی‌دارد. قالب تا وقتی تنظیمات
     اِعمال نشده صفحه را پنهان نگه می‌دارد تا اولین رنگِ کاربر با حالت درست
     باشد (نه رندر با تم/نمایشِ پیش‌فرض و اصلاحِ بعدی → پرش چیدمان). */
  const finishBoot = () => {
    try {
      if (typeof window.__mrmFinishBoot === 'function') {
        window.__mrmFinishBoot();
        return;
      }
      document.documentElement.removeAttribute('data-mrm-booting');
      document.getElementById('mrm-boot-screen')?.remove();
    } catch (error) { /* برنداشتن صفحهٔ بوت هرگز نباید اجرای runtime را متوقف کند */ }
  };

  const apply = () => {
    applyQueued = false;
    if (!state.loaded) return;

    domObserver?.disconnect();
    try {
      const config = state.config;
      if (!config.enabled) {
        restoreOriginalUi();
        finishBoot();
        return;
      }
      if (isSpecial) {
        applyTheme(config);
        updateBrand(config.storeName);
        deTokenizeBrand();
        applySupport(config.supportId);
        applyConnections(config);
        applyPing(config.showPing);
        applyApps(config.showApps);
        applyAnnouncement(config);
      }
      if (isClassic) {
        applyClassicTheme(config);
        updateClassicBrand(config.storeName);
        applyClassicSupport(config.supportId);
        applyClassicConnections(config);
        applyClassicApps(config.showApps);
        applyClassicAnnouncement(config);
      }

      if (document.documentElement.getAttribute('data-mrm') !== 'active') {
        document.documentElement.setAttribute('data-mrm', 'active');
      }
      /* صفت تشخیص را در هر پاس تازه کن. در boot هنوز React کوه‌نشین نشده و
         همه‌چیز «گم‌شده» به نظر می‌رسد؛ اگر فقط یک‌بار نوشته شود، پشتیبانی
         و CI گزارش کهنه می‌بینند. */
      UI.diagnose('silent', 'mrm-runtime');
      finishBoot();
    } finally {
      observeDom();
    }
  };

  const scheduleApply = () => {
    if (applyQueued) return;
    applyQueued = true;
    requestAnimationFrame(apply);
  };

  /* ── تصمیمِ زودهنگامِ «بخش اتصال‌ها» ────────────────────────────────────
     show-configs=false یعنی ادمین بخش کانفیگ/اتصال سریع را خاموش کرده است.
     اگر این تصمیم پس از اولین رنگ گرفته شود، کارت رندر می‌شود و سپس ناپدید
     می‌شود → پرش چیدمان (اندازه‌گیری‌شده: CLS 0.05 روی دسکتاپ). پس تصمیم را
     به‌صورت کلاس روی <html> می‌گذاریم؛ قاعدهٔ CSS همان کلاس، کارتِ رندرشدهٔ
     React را از اولین رنگ پنهان نگه می‌دارد و setDisplay بعدی بی‌اثر می‌شود. */
  const ssrHasWireGuard = () => {
    try {
      const data = window.__INITIAL_DATA__ || {};
      const links = Array.isArray(data.links) ? data.links : [];
      if (links.some((link) => typeof link === 'string' && /^wireguard:\/\//i.test(link))) return true;
      const wg = data.user && data.user.proxy_settings ? data.user.proxy_settings.wireguard : null;
      return Boolean(wg && (wg.public_key || (Array.isArray(wg.peer_ips) && wg.peer_ips.length)));
    } catch (error) {
      return false;
    }
  };

  /* domHasWireGuard را وقتی داریم که DOM ساخته شده باشد؛ در غیر این‌صورت به
     دادهٔ رندرشدهٔ سرور (__INITIAL_DATA__) تکیه می‌کنیم. */
  const syncEarlyConnectionsVisibility = (config, domHasWireGuard) => {
    try {
      const root = document.documentElement;
      if (!root || !root.classList || !config) return;
      const hasWireGuard = (domHasWireGuard === null || domHasWireGuard === undefined)
        ? ssrHasWireGuard()
        : Boolean(domHasWireGuard);
      const hide = !config.showConfigs && !(config.showWireGuard && hasWireGuard);
      root.classList.toggle('mrm-hide-connections', hide);
    } catch (error) { /* هیچ‌گاه به‌خاطر پنهان‌سازی، اجرای runtime را متوقف نکن */ }
  };

  const whenDomReady = (callback) => {
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', callback, { once: true });
    else callback();
  };

  const refreshSettings = async ({ initial = false } = {}) => {
    if (refreshInFlight) return;
    refreshInFlight = true;
    try {
      const raw = await fetchRaw();
      state.raw = raw;
      state.config = parseConfig(raw);
      state.loaded = true;
      /* پیش از هر رندر/رنگ: کارت‌هایی که باید پنهان بمانند، از پلهٔ اول پنهان‌اند */
      syncEarlyConnectionsVisibility(state.config, null);
      scheduleApply();
    } catch (error) {
      if (initial) {
        console.warn('[MRM] runtime settings unavailable; original template remains untouched.', error);
        whenDomReady(() => {
          document.documentElement.classList.remove('mrm-hide-connections');
          restoreOriginalUi();
          deTokenizeBrand();   /* حتی وقتی تنظیمات نمی‌رسد، توکن خام روی صفحه نماند */
          finishBoot();        /* تنظیمات نیامد → صفحه با قالب اصلی آزاد شود */
        });
        state.loaded = false;
      } else {
        console.warn('[MRM] runtime refresh failed; keeping last known settings.', error);
      }
    } finally {
      refreshInFlight = false;
    }
  };

  /* واکشی تنظیمات همین حالا (هنگام پارس اسکریپت) شروع می‌شود: پاسخی که برای
     تصمیم «نمایش/پنهانِ» بخش اتصال‌ها لازم است، دیگر تا DOMContentLoaded
     منتظر نمی‌ماند و پیش از اولین رنگِ React می‌رسد. */
  const initialLoad = refreshSettings({ initial: true });

  const start = async () => {
    /* شکست بی‌صدا → شکست پرصدا: اگر قالب قرارداد را رعایت نکند، گزارش می‌دهد */
    try {
      const report = UI.diagnose('warn', 'mrm-runtime');
      if (report.missing.length && typeof console !== 'undefined' && console.info) {
        console.info('[mrm] قرارداد v' + UI.VERSION + ' — عناصر گم‌شده تنظیمات را بی‌اثر می‌کنند. ' +
          'برای جزئیات: UI_CONTRACT.status()');
      }
    } catch (e) { /* هیچ‌گاه به‌خاطر تشخیص، اجرا را متوقف نکن */ }

    /* ناظر DOM را زودتر نصب می‌کنیم؛ ممکن است مونت‌شدن React پیش از
       DOMContentLoaded رخ دهد و تغییراتش از دست برود. */
    if (!domObserver) {
      domObserver = new MutationObserver(scheduleApply);
      observeDom();
    }
    await initialLoad;
    /* یک اِعمال کامل بعد از ساخته‌شدن DOM، مستقل از ناظر (idempotent) */
    scheduleApply();

    // Settings rarely change while a subscription page is open. Refresh less
    // often and never poll a background tab; DOM changes are already handled by
    // the observer, so the previous 30-second forced repaint is unnecessary.
    window.setInterval(() => {
      if (!document.hidden) void refreshSettings();
    }, REFRESH_INTERVAL_MS);
    document.addEventListener('visibilitychange', () => {
      if (!document.hidden) void refreshSettings();
    });
  };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true });
  else start();
})();
