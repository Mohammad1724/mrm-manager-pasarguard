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
