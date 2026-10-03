import { memo, useState } from 'react';
import { useTranslation } from 'react-i18next';
import {
  HelpCircle,
  Smartphone,
  Zap,
  ChevronDown,
  Sparkles,
  CheckCircle2,
  AlertCircle,
} from 'lucide-react';
import { cn } from '@/lib/utils';

export const FaqGuide = memo(() => {
  const { i18n } = useTranslation();
  const isFa = i18n.language.startsWith('fa');
  const [openIndex, setOpenIndex] = useState<number | null>(null);

  const toggle = (idx: number) => {
    setOpenIndex((prev) => (prev === idx ? null : idx));
  };

  const steps = [
    {
      icon: Smartphone,
      num: '۱',
      title: isFa ? 'نصب اپلیکیشن' : '1. Install App',
      desc: isFa
        ? 'از لیست پایین، اپلیکیشن مناسب دیوایس خود (v2rayNG برای اندروید، Streisand/Shadowrocket برای آیفون) را دانلود و باز کنید.'
        : 'Download the recommended app for your device from the list below.',
    },
    {
      icon: Zap,
      num: '۲',
      title: isFa ? 'لمس «اتصال مستقیم»' : '2. One-Tap Connect',
      desc: isFa
        ? 'دکمه بزرگ «اتصال مستقیم» در بالای صفحه را بزنید تا اشتراک و همه سرورها خودکار به نرم‌افزار شما منتقل شوند.'
        : 'Tap the "Quick Connect" button to automatically import your subscription into the app.',
    },
    {
      icon: CheckCircle2,
      num: '۳',
      title: isFa ? 'روشن کردن VPN' : '3. Switch On',
      desc: isFa
        ? 'داخل اپلیکیشن، دکمه اتصال (Connect یا آیکون دایره/V) را لمس کنید تا به سریع‌ترین سرور متصل شوید.'
        : 'Inside the app, tap Connect to enjoy secure, unrestricted internet.',
    },
  ];

  const faqs = [
    {
      q: isFa ? 'اگر اینترنت قطع شد یا وصل نشد چه کنم؟' : 'What if it fails to connect?',
      a: isFa
        ? '۱. مطمئن شوید فیلترشکن دیگری روی گوشی روشن نیست.\n۲. داخل نرم‌افزار خود، گزینه «Update Subscription» را بزنید تا آدرس سرورهای جدید دریافت شود.\n۳. تست پینگ بگیرید و سروری با کمترین پینگ یا لوکیشن دیگری (مثلاً آلمان، فنلاند یا هلند) را انتخاب کنید.'
        : '1. Make sure no other VPN is running.\n2. Tap "Update Subscription" in your app to refresh endpoints.\n3. Run a ping test and select a lower-latency server.',
    },
    {
      q: isFa ? 'چگونه لینک اشتراک را به صورت دستی وارد کنم؟' : 'How to import subscription manually?',
      a: isFa
        ? 'روی دکمه «کپی لینک» در بالای صفحه بزنید. سپس در اپلیکیشن خود به منوی تنظیمات سابسکریپشن بروید، علامت + را بزنید و لینک کپی‌شده را پیست (Paste) نمایید.'
        : 'Click "Copy Link" at the top of this page, then in your VPN app open the subscription manager, tap +, and paste the link.',
    },
    {
      q: isFa ? 'آیا این اشتراک روی چند دستگاه قابل استفاده است؟' : 'Can I use this on multiple devices?',
      a: isFa
        ? 'بله؛ می‌توانید همین لینک را روی گوشی، لپ‌تاپ و تبلت خود وارد کنید. حجم مصرفی به صورت مشترک از بسته حساب شما کسر می‌شود.'
        : 'Yes, you can import the same subscription on your phone, laptop, and tablet. Traffic is shared across devices.',
    },
  ];

  return (
    <section className="my-6 w-full rounded-3xl border border-border/70 bg-card/60 p-5 sm:p-6 shadow-sm backdrop-blur-xl">
      {/* Title */}
      <div className="flex items-center justify-between border-b border-border/50 pb-3.5 mb-5">
        <div className="flex items-center gap-2.5">
          <div className="flex size-9 items-center justify-center rounded-xl bg-primary/10 text-primary">
            <HelpCircle className="size-5" />
          </div>
          <div>
            <h2 className="text-body sm:text-lead font-bold text-foreground">
              {isFa ? 'راهنمای اتصال و رفع مشکل' : 'Quick Setup & FAQ'}
            </h2>
            <p className="text-micro text-muted-foreground">
              {isFa ? 'آموزش گام‌به‌گام اتصال در ۳ مرحله ساده' : 'Connect in 3 simple steps'}
            </p>
          </div>
        </div>
        <span className="hidden sm:inline-flex items-center gap-1 text-micro font-semibold text-primary-text bg-primary/10 px-2.5 py-1 rounded-full">
          <Sparkles className="size-3" />
          {isFa ? 'اتصال ۳۰ ثانیه‌ای' : '30s Setup'}
        </span>
      </div>

      {/* 3 Step Cards */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-3 mb-6">
        {steps.map((st, i) => {
          const Icon = st.icon;
          return (
            <div
              key={i}
              className="flex items-start gap-3 rounded-2xl border border-border/50 bg-background/50 p-3.5 transition hover:border-primary/40 hover:bg-background/80"
            >
              <div className="flex size-8 shrink-0 items-center justify-center rounded-xl bg-primary/15 text-primary">
                <Icon className="size-4" />
              </div>
              <div className="min-w-0 flex-1">
                <h3 className="text-micro sm:text-body font-bold text-foreground">{st.title}</h3>
                <p className="mt-1 text-micro leading-relaxed text-muted-foreground">{st.desc}</p>
              </div>
            </div>
          );
        })}
      </div>

      {/* Accordion FAQ items */}
      <div className="space-y-2">
        {faqs.map((faq, idx) => {
          const isOpen = openIndex === idx;
          return (
            <div
              key={idx}
              className="overflow-hidden rounded-2xl border border-border/50 bg-background/40 transition hover:bg-background/60"
            >
              <button
                type="button"
                onClick={() => toggle(idx)}
                className="flex w-full items-center justify-between p-3.5 text-right font-medium text-micro sm:text-body text-foreground"
              >
                <span className="flex items-center gap-2">
                  <AlertCircle className="size-3.5 text-primary shrink-0" />
                  <span>{faq.q}</span>
                </span>
                <ChevronDown
                  className={cn(
                    'size-4 text-muted-foreground transition-transform duration-200 shrink-0',
                    isOpen && 'rotate-180 text-primary'
                  )}
                />
              </button>
              {isOpen && (
                <div className="border-t border-border/40 px-4 py-3 text-micro leading-relaxed text-muted-foreground whitespace-pre-line bg-muted/20">
                  {faq.a}
                </div>
              )}
            </div>
          );
        })}
      </div>
    </section>
  );
});
FaqGuide.displayName = 'FaqGuide';
