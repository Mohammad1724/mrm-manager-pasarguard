import { useMemo, useState } from 'react';
import { useTranslation } from 'react-i18next';
import {
  Sparkles,
  ShieldCheck,
  RefreshCcw,
} from 'lucide-react';
import { useUserInfo, useConfigData, useChartData } from '@/hooks/useUserData';
import { useLanguage } from '@/hooks/useLanguage';
import { Layout } from '@/components/layout';
import { ThemeToggle } from '@/components/theme-toggle';
import { LanguageSwitcher } from '@/components/language-switcher';
import { MasterHeroCard } from '@/components/master-hero-card';
import { FaqGuide } from '@/components/faq-guide';
import { AnnouncementBanner } from '@/components/announcement-banner';
import { TrafficChart } from '@/components/traffic-chart';
import { ConnectionLinks } from '@/components/connection-links';
import { ProminentSubscriptionLink } from '@/components/prominent-subscription-link';
import { AppsList } from '@/components/AppsList';
import { QRModal } from '@/components/qr-modal';
import type { UsageDataPoint } from '@/types/user';

/** نام پیش‌فرض فروشگاه پیش از دریافت تنظیمات از runtime.
 *
 *  چرا جانگهدار `__BRAND__`؟ چون `manager/theme.sh` هنگام نصب/بازاستقرار
 *  (`--redeploy`) همین توکن را در HTML نهایی با نام برند ادمین جانشین می‌کند.
 *  اگر توکن را حذف کنیم، آن مرحله بی‌هدف می‌شود و برند ایستا از کار می‌افتد.
 *  runtime هم همین مقدار را زنده جایگزین می‌کند و اگر تنظیمات در دسترس نباشد،
 *  نگهبان `deTokenizeBrand` تضمین می‌کند توکن خام روی صفحه نماند.
 *  برای build با نام ثابت: VITE_DEFAULT_BRAND=... */
const DEFAULT_BRAND = (import.meta.env.VITE_DEFAULT_BRAND as string | undefined)?.trim() || '__BRAND__';

const isUsageDataSeries = (value: unknown): value is UsageDataPoint[] => Array.isArray(value);

const getChartUsageData = (stats: unknown): UsageDataPoint[] => {
  if (!stats || typeof stats !== 'object' || Array.isArray(stats)) return [];
  return Object.values(stats).find(isUsageDataSeries) ?? [];
};

export default function App() {
  const { t, i18n } = useTranslation();
  useLanguage();
  const [timeRange, setTimeRange] = useState('7d');
  const [masterQROpen, setMasterQROpen] = useState(false);
  const isFa = i18n.language.startsWith('fa');

  const { startTime, period } = useMemo(() => {
    const now = new Date();
    const start = new Date();
    let selectedPeriod = 'hour';

    switch (timeRange) {
      case '1h':
        start.setTime(now.getTime() - 60 * 60 * 1000);
        selectedPeriod = 'minute';
        break;
      case '12h':
        start.setTime(now.getTime() - 12 * 60 * 60 * 1000);
        break;
      case '24h':
        start.setTime(now.getTime() - 24 * 60 * 60 * 1000);
        break;
      case '30d':
        start.setTime(now.getTime() - 30 * 24 * 60 * 60 * 1000);
        selectedPeriod = 'day';
        break;
      case '90d':
        start.setTime(now.getTime() - 90 * 24 * 60 * 60 * 1000);
        selectedPeriod = 'day';
        break;
      default:
        start.setTime(now.getTime() - 7 * 24 * 60 * 60 * 1000);
        selectedPeriod = 'day';
    }

    return { startTime: start, period: selectedPeriod };
  }, [timeRange]);

  const { data, headers, error, isLoading, isValidating, refresh } = useUserInfo();
  const { data: configData } = useConfigData();
  const { chartData, chartError } = useChartData(startTime, period, true);

  const initialUser = typeof window !== 'undefined' ? window.__INITIAL_DATA__?.user : undefined;
  const effectiveData = data ?? initialUser;
  const hasData = Boolean(effectiveData);

  // اعلانِ رندرشده در سرور (اگر پنل آن را داده باشد) — از پلهٔ اول در صفحه است
  const ssrAnnounce = useMemo(() => {
    try {
      const el = document.getElementById('mrm-ssr-announce');
      if (!el?.textContent) return null;
      const parsed = JSON.parse(el.textContent);
      const text = typeof parsed?.text === 'string' ? parsed.text.trim() : '';
      const url = typeof parsed?.url === 'string' ? parsed.url.trim() : '';
      return { text, url };
    } catch {
      return null;
    }
  }, []);

  // Announcement message
  const rawAnnouncement = headers?.announce;
  const announcementMessage = useMemo(() => {
    if (!rawAnnouncement || typeof rawAnnouncement !== 'string') {
      return ssrAnnounce?.text || null;
    }
    if (rawAnnouncement.startsWith('base64:')) {
      try {
        const encoded = rawAnnouncement.slice(7).trim();
        return encoded ? decodeURIComponent(escape(atob(encoded))) : null;
      } catch {
        return rawAnnouncement.slice(7);
      }
    }
    try {
      return decodeURIComponent(rawAnnouncement);
    } catch {
      return rawAnnouncement;
    }
  }, [rawAnnouncement, ssrAnnounce]);

  const announceUrl =
    typeof headers?.['announce-url'] === 'string' && headers['announce-url'].trim()
      ? headers['announce-url']
      : ssrAnnounce?.url || null;

  const supportUrl =
    typeof headers?.['support-url'] === 'string' && headers['support-url'].trim()
      ? headers['support-url']
      : null;

  const subUrl = typeof window !== 'undefined'
    ? `${window.location.origin}${window.location.pathname.replace(/\/(info|raw)\/?$/, '').replace(/\/+$/, '')}`
    : '';

  // Loading Screen
  if (isLoading && !hasData) {
    return (
      <Layout>
        <div className="flex min-h-[85vh] items-center justify-center px-6" role="status">
          <div className="flex flex-col items-center gap-4 rounded-3xl border border-border/80 bg-card/80 p-8 shadow-2xl backdrop-blur-xl text-center max-w-xs w-full">
            <div className="flex size-14 items-center justify-center rounded-2xl bg-primary/10 text-primary">
              <RefreshCcw className="size-7 animate-spin" />
            </div>
            <div>
              <h1 className="text-lead font-bold text-foreground">
                {isFa ? 'در حال بارگذاری اطلاعات…' : t('common.loading')}
              </h1>
              <p className="text-micro text-muted-foreground mt-1">
                {isFa ? 'برقراری ارتباط با سرور پاسارگارد' : 'Connecting to PasarGuard...'}
              </p>
            </div>
          </div>
        </div>
      </Layout>
    );
  }

  // Error Screen
  if (error && !hasData && !isLoading && !isValidating) {
    return (
      <Layout>
        <div className="flex min-h-[85vh] items-center justify-center px-6">
          <div className="flex flex-col items-center gap-4 rounded-3xl border border-destructive/30 bg-card/90 p-8 shadow-2xl backdrop-blur-xl text-center max-w-sm w-full">
            <div className="flex size-14 items-center justify-center rounded-2xl bg-destructive/10 text-destructive">
              <span className="text-heading font-black">!</span>
            </div>
            <div>
              <h1 className="text-lead font-bold text-foreground">{t('dashboard.error')}</h1>
              <p className="text-micro text-muted-foreground mt-1">{error.message}</p>
            </div>
            <button
              type="button"
              className="inline-flex items-center gap-2 rounded-xl bg-primary px-5 py-2.5 text-micro font-bold text-primary-foreground shadow-sm transition hover:opacity-90 active:scale-95"
              onClick={() => refresh()}
            >
              <RefreshCcw className="size-3.5" />
              <span>{t('common.retry', 'تلاش دوباره')}</span>
            </button>
          </div>
        </div>
      </Layout>
    );
  }

  if (!effectiveData) return null;

  const hasLinks = Boolean(configData?.links?.length);
  const hasChart = !chartError;
  const chartUsage = getChartUsageData(chartData?.stats);

  return (
    <Layout>
      <div className="treasury-shell relative min-h-[100svh] overflow-hidden">
        {/* Subtle mesh background effect */}
        <div className="treasury-ambient pointer-events-none" aria-hidden="true" />

        {/* Sticky Frosted Header */}
        <header
          data-ui="nav"
          className="sticky top-0 z-40 w-full border-b border-border/50 bg-background/70 backdrop-blur-xl transition-all"
        >
          <div className="mx-auto flex h-16 max-w-5xl items-center justify-between px-4 sm:px-6">
            <div className="flex items-center gap-2.5" data-ui="brand-box" aria-label={DEFAULT_BRAND}>
              <div className="flex size-9 items-center justify-center rounded-xl bg-primary text-primary-foreground shadow-sm">
                <ShieldCheck className="size-5" aria-hidden="true" />
              </div>
              <div>
                <span
                  data-ui="brand"
                  className="font-extrabold text-foreground text-body tracking-tight block"
                >
                  {DEFAULT_BRAND}
                </span>
                <span className="text-micro text-muted-foreground -mt-0.5 block">
                  PasarGuard Security
                </span>
              </div>
            </div>

            <div className="flex items-center gap-2" data-ui="header-actions">
              <LanguageSwitcher />
              <ThemeToggle />
            </div>
          </div>
        </header>

        {/* Main Content Area */}
        {/* نقش لندمارک اصلی را Layout می‌دهد؛ این لایه فقط ظرف چیدمان است
            (لندمارک اصلی تودرتو برای صفحه‌خوان‌ها نامعتبر است). */}
        <div className="mx-auto max-w-5xl px-4 sm:px-6 py-6 sm:py-8 space-y-6">
          {/* عنوان صفحه: طرح MRM عنوانِ دیداری ندارد، ولی هر صفحه به یک سرتیتر
              سطح‌بالا نیاز دارد تا ساختار عناوین کامل باشد. */}
          <h1 className="sr-only">
            {isFa ? `اشتراک من — ${effectiveData?.username ?? ''}` : `My subscription — ${effectiveData?.username ?? ''}`}
          </h1>
          {/* Announcement Banner if present */}
          {announcementMessage && (
            <AnnouncementBanner message={announcementMessage} url={announceUrl} />
          )}

          {/* Master Account Hero Card */}
          <MasterHeroCard
            user={effectiveData}
            isValidating={isValidating}
            onRefresh={() => !isValidating && refresh()}
            supportUrl={supportUrl}
            onOpenQR={() => setMasterQROpen(true)}
          />

          {/* Connection Links & Configs */}
          <div id="connection-links" className="scroll-mt-24">
            {hasLinks ? (
              <ConnectionLinks links={configData!.links} />
            ) : (
              <ProminentSubscriptionLink hasChart={hasChart} />
            )}
          </div>

          {/* Usage Chart Section */}
          {hasChart && (
            <div className="w-full">
              <TrafficChart
                data={chartUsage}
                isLoading={!chartData}
                error={chartError}
                timeRange={timeRange}
                onTimeRangeChange={setTimeRange}
              />
            </div>
          )}

          {/* Supported Applications Section */}
          <div className="space-y-3 pt-2">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2">
                <div className="flex size-8 items-center justify-center rounded-xl bg-primary/10 text-primary">
                  <Sparkles className="size-4" />
                </div>
                <div>
                  <h2 className="text-body sm:text-lead font-bold text-foreground">
                    {isFa ? 'نرم‌افزارهای پیشنهادی' : t('apps.title')}
                  </h2>
                  <p className="text-micro text-muted-foreground">
                    {isFa ? 'بهترین برنامه‌ها متناسب با دیوایس شما' : 'Best tools for your platform'}
                  </p>
                </div>
              </div>
            </div>

            <AppsList />
          </div>

          {/* Connection Guide & Troubleshooting — راهنما بعد از محتوای اصلی می‌آید
              (پیش‌تر بین کارت وضعیت و لیست کانفیگ‌ها بود و دسترسی به کانفیگ را
              به ۲.۳ صفحه اسکرول عقب می‌انداخت) */}
          <FaqGuide />
        </div>
      </div>

      {/* Master QR Code Modal */}
      {effectiveData && (
        <QRModal
          open={masterQROpen}
          onOpenChange={setMasterQROpen}
          link={{
            protocol: 'unknown',
            name: `${effectiveData.username} · Subscription`,
            emoji: '',
            raw: subUrl,
          }}
        />
      )}
    </Layout>
  );
}
