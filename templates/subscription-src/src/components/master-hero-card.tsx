import { useMemo, type FC } from 'react';
import { useTranslation } from 'react-i18next';
import {
  ShieldCheck,
  AlertTriangle,
  RefreshCcw,
  CalendarDays,
  Database,
  ArrowDownToLine,
  Clock,
  ChevronDown,
  Copy,
  Check,
  QrCode,
  Sparkles,
} from 'lucide-react';
import { OnlineBadge } from '@/components/online-badge';
import { QuickConnect, RenewButton } from '@/components/quick-connect';
import { useCopyToClipboard } from '@/hooks/useCopyToClipboard';
import { formatDate } from '@/lib/dateFormatter';
import { cn } from '@/lib/utils';
import type { UserInfo } from '@/types/user';

const formatBytes = (bytes: number) => {
  if (!bytes || bytes <= 0 || Number.isNaN(bytes)) return '0 B';
  const unit = 1024;
  const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
  const index = Math.floor(Math.log(bytes) / Math.log(unit));
  if (index < 0 || index >= sizes.length) return '0 B';
  return `${(bytes / Math.pow(unit, index)).toFixed(2)} ${sizes[index]}`;
};

interface MasterHeroCardProps {
  user: UserInfo;
  isValidating: boolean;
  onRefresh: () => void;
  supportUrl?: string | null;
  onOpenQR: () => void;
}

export const MasterHeroCard: FC<MasterHeroCardProps> = ({
  user,
  isValidating,
  onRefresh,
  supportUrl,
  onOpenQR,
}) => {
  const { t, i18n } = useTranslation();
  const { copyToClipboard, isCopied } = useCopyToClipboard();
  const isFa = i18n.language.startsWith('fa');
  const locale = isFa ? 'fa-IR' : i18n.language;

  const normalizedStatus = useMemo(() => {
    const s = String(user.status || 'active').toLowerCase();
    return ['active', 'disabled', 'limited', 'expired', 'on_hold'].includes(s) ? s : 'active';
  }, [user.status]);

  const usedBytes = user.used_traffic || 0;
  const limitBytes = user.data_limit || 0;
  const remainingBytes = Math.max(0, limitBytes - usedBytes);

  const usagePercent = useMemo(() => {
    if (!limitBytes) return 0;
    return Math.min(100, Math.max(0, (usedBytes / limitBytes) * 100));
  }, [limitBytes, usedBytes]);

  const remainingPercent = limitBytes ? Math.max(0, 100 - usagePercent) : 100;
  const isDepleted = limitBytes > 0 && remainingBytes <= 0;

  // Days remaining
  const daysLeft = useMemo(() => {
    if (!user.expire || user.expire === '0') return null;
    const ms = new Date(user.expire).getTime() - Date.now();
    return Number.isNaN(ms) ? null : Math.ceil(ms / 86400000);
  }, [user.expire]);

  const isUrgent = useMemo(() => {
    const lowTime = daysLeft !== null && daysLeft <= 4;
    const lowTraffic = limitBytes > 0 && remainingPercent < 15;
    return lowTime || lowTraffic;
  }, [daysLeft, limitBytes, remainingPercent]);

  const statusConfig = ({
    active: {
      label: isFa ? 'متصل و فعال' : t('status.active', 'Active'),
      color: 'text-emerald-500 dark:text-emerald-400',
      bg: 'bg-emerald-500/10 dark:bg-emerald-400/15 border-emerald-500/30 text-emerald-700 dark:text-emerald-300',
      dot: 'bg-emerald-500 animate-pulse',
    },
    limited: {
      label: isFa ? 'حجم به اتمام رسیده' : t('status.limited', 'Data Limit Reached'),
      color: 'text-rose-500',
      bg: 'bg-rose-500/10 border-rose-500/30 text-rose-700 dark:text-rose-300',
      dot: 'bg-rose-500',
    },
    expired: {
      label: isFa ? 'منقضی شده' : t('status.expired', 'Expired'),
      color: 'text-amber-500',
      bg: 'bg-amber-500/10 border-amber-500/30 text-amber-700 dark:text-amber-300',
      dot: 'bg-amber-500',
    },
    disabled: {
      label: isFa ? 'غیرفعال' : t('status.disabled', 'Disabled'),
      color: 'text-muted-foreground',
      bg: 'bg-muted border-border text-muted-foreground',
      dot: 'bg-muted-foreground',
    },
    on_hold: {
      label: isFa ? 'در انتظار اتصال اول' : t('status.on_hold', 'On Hold'),
      color: 'text-sky-500',
      bg: 'bg-sky-500/10 border-sky-500/30 text-sky-700 dark:text-sky-300',
      dot: 'bg-sky-500',
    },
  } as Record<string, { label: string; color: string; bg: string; dot: string }>)[normalizedStatus] || {
    label: isFa ? 'متصل و فعال' : 'Active',
    color: 'text-emerald-500',
    bg: 'bg-emerald-500/10 border-emerald-500/30 text-emerald-700',
    dot: 'bg-emerald-500',
  };

  const subUrl = typeof window !== 'undefined'
    ? `${window.location.origin}${window.location.pathname.replace(/\/(info|raw)\/?$/, '').replace(/\/+$/, '')}`
    : '';

  const scrollToConfigs = () => {
    document.getElementById('connection-links')?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  };

  const handleCopySub = () => {
    copyToClipboard(subUrl, subUrl);
  };

  const expiryLabel = useMemo(() => {
    if (!user.expire || user.expire === '0') return isFa ? 'بدون محدودیت زمانی' : t('userInfo.noTimeLimit');
    return formatDate(user.expire, locale);
  }, [user.expire, isFa, locale, t]);

  // SVG Gauge Calculations
  const radius = 78;
  const stroke = 12;
  const normalizedRadius = radius - stroke * 2;
  const circumference = normalizedRadius * 2 * Math.PI;
  // Semi-arc or 270 degree arc
  const arcLength = circumference * 0.75;
  const strokeDashoffset = arcLength - (remainingPercent / 100) * arcLength;

  return (
    <section className="relative w-full rounded-3xl border border-white/20 dark:border-white/10 bg-gradient-to-b from-card/90 via-card/75 to-card/95 p-5 sm:p-7 shadow-xl shadow-black/5 backdrop-blur-2xl transition-all">
      {/* Ambient background glow */}
      <div
        className={cn(
          'pointer-events-none absolute -top-24 -left-24 h-64 w-64 rounded-full blur-3xl opacity-35 transition-all',
          isDepleted ? 'bg-rose-500/25' : 'bg-primary/25'
        )}
        aria-hidden="true"
      />
      <div
        className="pointer-events-none absolute -bottom-20 -right-20 h-56 w-56 rounded-full bg-accent/20 blur-3xl opacity-30"
        aria-hidden="true"
      />

      {/* Top Bar: Identity & Status Pill & Refresh */}
      <div className="relative z-10 flex flex-wrap items-center justify-between gap-3 border-b border-border/50 pb-4">
        <div className="flex items-center gap-3">
          <div className="flex size-11 items-center justify-center rounded-2xl bg-primary/10 text-primary shadow-inner">
            {isDepleted ? (
              <AlertTriangle className="size-6 text-rose-500 animate-bounce" />
            ) : (
              <ShieldCheck className="size-6 text-primary" />
            )}
          </div>
          <div>
            <div className="flex items-center gap-2">
              <span className="font-bold text-foreground text-lead tracking-tight" dir="ltr">
                {user.username}
              </span>
              <OnlineBadge lastOnline={user.online_at} />
            </div>
            <p className="text-micro text-muted-foreground flex items-center gap-1 mt-0.5">
              <Sparkles className="size-3 text-primary" />
              {isFa ? 'اشتراک فعال پاسارگارد' : 'PasarGuard Active Service'}
            </p>
          </div>
        </div>

        <div className="flex items-center gap-2">
          {/* Status Pill */}
          <div
            className={cn(
              'inline-flex items-center gap-1.5 rounded-full border px-3 py-1 text-micro font-semibold shadow-xs',
              statusConfig.bg
            )}
          >
            <span className={cn('size-2 rounded-full', statusConfig.dot)} aria-hidden="true" />
            <span>{statusConfig.label}</span>
          </div>

          {/* Refresh Button */}
          <button
            type="button"
            onClick={onRefresh}
            disabled={isValidating}
            title={isFa ? 'به‌روزرسانی وضعیت' : 'Refresh info'}
            className="mrm-tap-44 flex size-11 items-center justify-center rounded-full border border-border/80 bg-background/60 text-muted-foreground transition hover:border-primary hover:text-foreground active:scale-90"
          >
            <RefreshCcw className={cn('size-3.5', isValidating && 'animate-spin text-primary')} />
          </button>
        </div>
      </div>

      {/* Core Centerpiece: Circular Remaining Gauge + Dynamic Numbers */}
      <div className="relative z-10 my-6 flex flex-col md:flex-row items-center justify-between gap-6">
        {/* Left / Center: Circular Progress Widget */}
        <div className="relative flex shrink-0 items-center justify-center">
          <svg
            height={radius * 2}
            width={radius * 2}
            className="rotate-135 transition-all duration-700"
          >
            {/* Background Track */}
            <circle
              stroke="currentColor"
              fill="transparent"
              strokeWidth={stroke}
              strokeDasharray={`${arcLength} ${circumference}`}
              strokeLinecap="round"
              className="text-muted/40"
              r={normalizedRadius}
              cx={radius}
              cy={radius}
            />
            {/* Animated Progress Arc */}
            <circle
              stroke="url(#heroProgressGradient)"
              fill="transparent"
              strokeWidth={stroke}
              strokeDasharray={`${arcLength} ${circumference}`}
              style={{ strokeDashoffset }}
              strokeLinecap="round"
              className="transition-all duration-1000 ease-out"
              r={normalizedRadius}
              cx={radius}
              cy={radius}
            />
            <defs>
              <linearGradient id="heroProgressGradient" x1="0%" y1="0%" x2="100%" y2="100%">
                <stop offset="0%" stopColor="var(--primary)" />
                <stop offset="100%" stopColor={isDepleted ? '#ef4444' : '#14b8a6'} />
              </linearGradient>
            </defs>
          </svg>

          {/* Center text inside Circle */}
          <div className="absolute inset-0 flex flex-col items-center justify-center text-center">
            <span className="text-heading font-black tracking-tight text-foreground" dir="ltr">
              {limitBytes ? Math.round(remainingPercent) : 100}%
            </span>
            <span className="text-micro font-medium text-muted-foreground">
              {isFa ? 'باقی‌مانده' : t('remaining', 'Remaining')}
            </span>
          </div>
        </div>

        {/* Right / Center Stats Highlight */}
        <div className="flex flex-1 flex-col items-center md:items-start text-center md:text-right gap-2">
          <div className="text-micro font-semibold uppercase tracking-wider text-muted-foreground">
            {isFa ? 'میزان ترافیک قابل استفاده' : 'Available Traffic'}
          </div>
          <div className="flex items-baseline gap-2">
            <span className="text-display sm:text-hero font-extrabold tracking-tight text-foreground" dir="ltr">
              {limitBytes ? formatBytes(remainingBytes) : isFa ? 'نامحدود' : 'Unlimited'}
            </span>
            {limitBytes > 0 && (
              <span className="text-body font-medium text-muted-foreground" dir="ltr">
                / {formatBytes(limitBytes)}
              </span>
            )}
          </div>

          {/* Expiry Pill */}
          <div className="mt-1 flex flex-wrap items-center justify-center md:justify-start gap-2">
            <div
              className={cn(
                'inline-flex items-center gap-1.5 rounded-full px-3 py-1 text-micro font-medium',
                daysLeft !== null && daysLeft <= 4
                  ? 'bg-amber-500/15 text-amber-700 dark:text-amber-300 border border-amber-500/30'
                  : 'bg-muted/70 text-muted-foreground border border-border/50'
              )}
            >
              <CalendarDays className="size-3.5" />
              <span>
                {daysLeft !== null
                  ? daysLeft <= 0
                    ? isFa ? 'منقضی شده' : 'Expired'
                    : isFa
                      ? `${daysLeft.toLocaleString('fa-IR')} روز باقی‌مانده`
                      : `${daysLeft} days remaining`
                  : expiryLabel}
              </span>
            </div>
            {isUrgent && (
              <span className="inline-flex items-center gap-1 rounded-full bg-rose-500/15 px-2.5 py-0.5 text-micro font-bold text-rose-600 dark:text-rose-400 border border-rose-500/20 animate-pulse">
                {isFa ? '⚠️ نیاز به تمدید' : '⚠️ Renew Soon'}
              </span>
            )}
          </div>
        </div>
      </div>

      {/* 4 Bento Metrics Grid */}
      <div className="relative z-10 grid grid-cols-2 lg:grid-cols-4 gap-2.5 my-5">
        <div className="rounded-2xl border border-border/60 bg-background/50 p-3 shadow-xs">
          <div className="flex items-center gap-1.5 text-micro text-muted-foreground">
            <Database className="size-3.5 text-primary" />
            <span>{isFa ? 'حجم کل بسته' : t('userInfo.totalLimit', 'Total Limit')}</span>
          </div>
          <div className="mt-1.5 text-body sm:text-lead font-bold text-foreground" dir="ltr">
            {limitBytes ? formatBytes(limitBytes) : isFa ? 'نامحدود' : 'Unlimited'}
          </div>
        </div>

        <div className="rounded-2xl border border-border/60 bg-background/50 p-3 shadow-xs">
          <div className="flex items-center gap-1.5 text-micro text-muted-foreground">
            <ArrowDownToLine className="size-3.5 text-amber-500" />
            <span>{isFa ? 'مصرف‌شده' : t('userInfo.usedTraffic', 'Used Traffic')}</span>
          </div>
          <div className="mt-1.5 text-body sm:text-lead font-bold text-foreground" dir="ltr">
            {formatBytes(usedBytes)}
          </div>
        </div>

        <div className="rounded-2xl border border-border/60 bg-background/50 p-3 shadow-xs">
          <div className="flex items-center gap-1.5 text-micro text-muted-foreground">
            <Clock className="size-3.5 text-sky-500" />
            <span>{isFa ? 'تاریخ انقضا' : t('userInfo.expiryDate', 'Expires')}</span>
          </div>
          <div className="mt-1.5 text-micro sm:text-body font-semibold text-foreground truncate" title={expiryLabel}>
            {expiryLabel}
          </div>
        </div>

        <div className="rounded-2xl border border-border/60 bg-background/50 p-3 shadow-xs">
          <div className="flex items-center gap-1.5 text-micro text-muted-foreground">
            <Sparkles className="size-3.5 text-violet-500" />
            <span>{isFa ? 'مصرف کل دوره' : t('userInfo.lifetimeTraffic', 'Lifetime')}</span>
          </div>
          <div className="mt-1.5 text-body sm:text-lead font-bold text-foreground" dir="ltr">
            {formatBytes(user.lifetime_used_traffic || usedBytes)}
          </div>
        </div>
      </div>

      {/* Action Strip: Quick Connect & Secondary Actions */}
      <div className="relative z-10 flex flex-col sm:flex-row items-stretch sm:items-center justify-between gap-2.5 pt-2 border-t border-border/40">
        <div className="w-full sm:w-auto sm:flex-1 max-w-sm">
          <QuickConnect variant="hero" />
        </div>

        <div className="flex flex-wrap items-center gap-2">
          {/* Copy Sub Link Button */}
          <button
            type="button"
            onClick={handleCopySub}
            className={cn(
              'inline-flex flex-1 sm:flex-none items-center justify-center gap-1.5 rounded-xl border border-border bg-background/80 px-3.5 py-2.5 text-micro font-semibold text-foreground shadow-xs transition hover:bg-muted active:scale-95',
              isCopied(subUrl) && 'border-emerald-500 text-emerald-600 dark:text-emerald-400 bg-emerald-500/10'
            )}
            title={isFa ? 'کپی لینک سابسکریپشن' : 'Copy subscription URL'}
          >
            {isCopied(subUrl) ? <Check className="size-4" /> : <Copy className="size-4" />}
            <span>{isCopied(subUrl) ? (isFa ? 'کپی شد!' : 'Copied!') : (isFa ? 'کپی لینک' : 'Copy Link')}</span>
          </button>

          {/* QR Button */}
          <button
            type="button"
            onClick={onOpenQR}
            className="ui-tap inline-flex items-center justify-center rounded-xl border border-border bg-background/80 p-0 text-foreground shadow-xs transition hover:bg-muted active:scale-95"
            title={isFa ? 'نمایش بارکد QR' : 'Show QR Code'}
          >
            <QrCode className="size-4" />
          </button>

          {/* Jump to Configs */}
          <button
            type="button"
            onClick={scrollToConfigs}
            className="ui-tap-row inline-flex items-center justify-center gap-1 rounded-xl border border-border bg-background/80 px-3 py-2.5 text-micro font-medium text-foreground shadow-xs transition hover:bg-muted active:scale-95"
          >
            <span>{isFa ? 'کانفیگ‌ها' : 'Configs'}</span>
            <ChevronDown className="size-3.5 text-muted-foreground" />
          </button>

          {/* Renew Button if configured or urgent */}
          <RenewButton supportUrl={supportUrl} urgent={isUrgent} />
        </div>
      </div>
    </section>
  );
};
