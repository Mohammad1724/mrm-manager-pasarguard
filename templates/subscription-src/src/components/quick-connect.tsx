import { useMemo, useState, useCallback, useEffect } from 'react';
import { useTranslation } from 'react-i18next';
import {
  Zap,
  ChevronDown,
  Copy,
  Check,
  Smartphone,
  Monitor,
  Apple,
  Bot,
} from 'lucide-react';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from '@/components/ui/dialog';
import { detectOS, type OperatingSystem } from '@/lib/osDetector';
import { useCopyToClipboard } from '@/hooks/useCopyToClipboard';
import { toast } from 'sonner';
import { cn } from '@/lib/utils';

/* ------------------------------------------------------------------ */
/*  اتصال مستقیم — Smart one-tap subscription import into VPN apps     */
/*  Deep-link schemes ported from the original MRM template (v1.x)     */
/* ------------------------------------------------------------------ */

type PlatformKey = 'android' | 'ios' | 'desktop';

interface ConnectAppDef {
  id: string;
  name: string;
  platforms: PlatformKey[];
  /** platforms where this app is shown with the "recommended" badge */
  recommended?: PlatformKey[];
  buildDeepLink: (subUrl: string, title: string) => string;
}

const b64url = (value: string) => btoa(unescape(encodeURIComponent(value)));

export const CONNECT_APPS: ConnectAppDef[] = [
  {
    id: 'v2rayng',
    name: 'v2rayNG',
    platforms: ['android'],
    recommended: ['android'],
    buildDeepLink: (u, n) =>
      `v2rayng://install-sub?url=${encodeURIComponent(u)}&name=${encodeURIComponent(n)}`,
  },
  {
    id: 'hiddify',
    name: 'Hiddify',
    platforms: ['android', 'ios', 'desktop'],
    recommended: ['ios', 'desktop'],
    buildDeepLink: (u) => `hiddify://import/${u}`,
  },
  {
    id: 'v2raytun',
    name: 'v2rayTun',
    platforms: ['android'],
    buildDeepLink: (u) => `v2raytun://import/${b64url(u)}`,
  },
  {
    id: 'happ',
    name: 'Happ',
    platforms: ['android', 'ios'],
    buildDeepLink: (u) => `happ://add/${b64url(u)}`,
  },
  {
    id: 'v2box',
    name: 'V2Box',
    platforms: ['android', 'ios'],
    buildDeepLink: (u, n) =>
      `v2box://install-sub?url=${encodeURIComponent(u)}&name=${encodeURIComponent(n)}`,
  },
  {
    id: 'streisand',
    name: 'Streisand',
    platforms: ['ios'],
    buildDeepLink: (u) => `streisand://import/${u}`,
  },
  {
    id: 'shadowrocket',
    name: 'Shadowrocket',
    platforms: ['ios'],
    buildDeepLink: (u, n) => `sub://${b64url(u)}#${encodeURIComponent(n)}`,
  },
  {
    id: 'stash',
    name: 'Stash',
    platforms: ['ios'],
    recommended: ['ios'],
    buildDeepLink: (u, n) =>
      `stash://install-config?url=${encodeURIComponent(u)}&name=${encodeURIComponent(n)}`,
  },
  {
    id: 'foxray',
    name: 'FoXray',
    platforms: ['ios'],
    buildDeepLink: (u) => `foxray://import/${u}`,
  },
];

const LAST_APP_KEY = 'mrm-connect-app';

const osToPlatform = (os: OperatingSystem): PlatformKey => {
  if (os === 'android' || os === 'androidtv') return 'android';
  if (os === 'ios' || os === 'appletv') return 'ios';
  return 'desktop';
};

export const getSubscriptionUrl = () =>
  `${window.location.origin}${window.location.pathname.replace(/\/(info|raw)\/?$/, '').replace(/\/+$/, '')}`;

const PLATFORM_META: Record<PlatformKey, { icon: typeof Smartphone; labelKey: string }> = {
  android: { icon: Smartphone, labelKey: 'quickConnect.platforms.android' },
  ios: { icon: Apple, labelKey: 'quickConnect.platforms.ios' },
  desktop: { icon: Monitor, labelKey: 'quickConnect.platforms.desktop' },
};

interface QuickConnectProps {
  /** variant="hero" renders the big split button used inside the hero card */
  variant?: 'hero' | 'compact';
  className?: string;
}

export function QuickConnect({ variant = 'hero', className }: QuickConnectProps) {
  const { t } = useTranslation();
  const { copyToClipboard, isCopied } = useCopyToClipboard();
  const [dialogOpen, setDialogOpen] = useState(false);
  const detectedPlatform = useMemo(() => osToPlatform(detectOS()), []);
  const [activePlatform, setActivePlatform] = useState<PlatformKey>(detectedPlatform);
  const [lastAppId, setLastAppId] = useState<string | null>(null);

  useEffect(() => {
    try {
      setLastAppId(localStorage.getItem(LAST_APP_KEY));
    } catch {
      /* private mode */
    }
  }, []);

  const subscriptionUrl = useMemo(() => getSubscriptionUrl(), []);
  const pageTitle = typeof document !== 'undefined' ? document.title : 'subscription';

  const lastApp = useMemo(
    () => CONNECT_APPS.find((a) => a.id === lastAppId) ?? null,
    [lastAppId]
  );

  const connect = useCallback(
    (app: ConnectAppDef) => {
      try {
        localStorage.setItem(LAST_APP_KEY, app.id);
      } catch {
        /* ignore */
      }
      setLastAppId(app.id);
      setDialogOpen(false);
      toast.success(t('quickConnect.opening', { app: app.name }), {
        description: t('quickConnect.notOpened'),
        duration: 4000,
      });
      const link = app.buildDeepLink(subscriptionUrl, pageTitle);
      setTimeout(() => {
        window.location.href = link;
      }, 120);
    },
    [subscriptionUrl, pageTitle, t]
  );

  /** One-tap entry point: reuse last app, otherwise open the picker */
  const handleMainClick = useCallback(() => {
    if (lastApp) {
      connect(lastApp);
    } else {
      setDialogOpen(true);
    }
  }, [lastApp, connect]);

  const handleCopy = useCallback(() => {
    copyToClipboard(subscriptionUrl, t('quickConnect.copiedSuccess'));
  }, [copyToClipboard, subscriptionUrl, t]);

  const appsForPlatform = useMemo(
    () => CONNECT_APPS.filter((a) => a.platforms.includes(activePlatform)),
    [activePlatform]
  );

  const platformTabs: PlatformKey[] = ['android', 'ios', 'desktop'];

  return (
    <>
      {variant === 'hero' ? (
        <div className={cn('treasury-quick-split', className)}>
          <button type="button" className="treasury-quick-main" onClick={handleMainClick}>
            <Zap className="size-[18px] fill-current" />
            {lastApp
              ? t('quickConnect.connectWith', { app: lastApp.name })
              : t('quickConnect.title')}
          </button>
          <button
            type="button"
            className="treasury-quick-more"
            onClick={() => setDialogOpen(true)}
            aria-label={t('quickConnect.pickApp')}
            title={t('quickConnect.changeApp')}
          >
            <ChevronDown className="size-4" />
          </button>
        </div>
      ) : (
        <button
          type="button"
          className={cn('treasury-cta-chip', className)}
          onClick={handleMainClick}
        >
          <Zap className="size-3.5" />
          {t('quickConnect.title')}
        </button>
      )}

      <Dialog open={dialogOpen} onOpenChange={setDialogOpen}>
        <DialogContent className="mrm-connect-dialog" dir="rtl">
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2">
              <span className="mrm-connect-gem" aria-hidden="true">
                <Zap className="size-4" />
              </span>
              {t('quickConnect.pickApp')}
            </DialogTitle>
            <DialogDescription>{t('quickConnect.subtitle')}</DialogDescription>
          </DialogHeader>

          <div className="ios-segmented-control mrm-connect-tabs" role="tablist">
            {platformTabs.map((p) => {
              const Icon = PLATFORM_META[p].icon;
              return (
                <button
                  key={p}
                  type="button"
                  role="tab"
                  aria-selected={activePlatform === p}
                  className={`ios-segmented-item ${activePlatform === p ? 'is-selected' : ''}`}
                  onClick={() => setActivePlatform(p)}
                >
                  <Icon className="size-3.5" />
                  {t(PLATFORM_META[p].labelKey)}
                  {detectedPlatform === p ? ' ·' : ''}
                </button>
              );
            })}
          </div>

          <div className="mrm-app-grid">
            {appsForPlatform.map((app) => {
              const isRecommended = app.recommended?.includes(activePlatform);
              const isLast = app.id === lastAppId;
              return (
                <button
                  key={app.id}
                  type="button"
                  className={cn('mrm-app-row', isLast && 'is-last')}
                  onClick={() => connect(app)}
                >
                  <span className="mrm-app-icon" aria-hidden="true">
                    <Smartphone className="size-4" />
                  </span>
                  <span className="mrm-app-name">{app.name}</span>
                  {isRecommended && (
                    <span className="mrm-app-badge">{t('quickConnect.recommended')}</span>
                  )}
                  {isLast && <span className="mrm-app-badge is-last">{t('quickConnect.lastUsed')}</span>}
                  <span className="mrm-app-go" aria-hidden="true">
                    <Zap className="size-3.5 fill-current" />
                  </span>
                </button>
              );
            })}
          </div>

          <p className="mrm-connect-hint">
            <Bot className="size-3.5" aria-hidden="true" />
            {activePlatform === 'desktop'
              ? t('quickConnect.desktopHint')
              : t('quickConnect.mobileHint')}
          </p>

          <div className="mrm-connect-footer">
            <button type="button" className="ios-app-button" onClick={handleCopy}>
              {isCopied(subscriptionUrl) ? (
                <Check className="w-3 h-3" />
              ) : (
                <Copy className="w-3 h-3" />
              )}
              {isCopied(subscriptionUrl) ? t('qr.copied') : t('quickConnect.copyLink')}
            </button>
          </div>
        </DialogContent>
      </Dialog>
    </>
  );
}

/* ------------------------------------------------------------------ */
/*  Renew button — turns into a pulsing "renew now" alert when the     */
/*  plan is about to expire (< 5 days) or traffic is nearly gone (<20%) */
/* ------------------------------------------------------------------ */

interface RenewButtonProps {
  supportUrl?: string | null;
  urgent?: boolean;
  className?: string;
}

export function RenewButton({ supportUrl, urgent = false, className }: RenewButtonProps) {
  const { t } = useTranslation();

  /* Keep the classic MRM placeholder flow: theme.sh replaces __BOT__.
     The segment check survives build-minification AND partial replacement:
     only an unreplaced placeholder segment starts with '__'. */
  const rawDefault = 'https://t.me/__BOT__';
  const href = useMemo(() => {
    if (supportUrl && /^https?:\/\//i.test(supportUrl)) return supportUrl;
    const lastSegment = rawDefault.split('/').pop() ?? '';
    if (lastSegment.startsWith('__')) return null; /* unreplaced → hide */
    return rawDefault;
  }, [supportUrl]);

  if (!href) return null;

  return (
    <a
      href={href}
      target="_blank"
      rel="noopener noreferrer"
      className={cn('treasury-cta-chip', urgent && 'is-urgent', className)}
    >
      {urgent ? `⚠️ ${t('renew.urgent')}` : t('renew.normal')}
    </a>
  );
}

/**
 * Guide banner shown on first visit — teaches the one-tap connect flow.
 */
export function ConnectGuide() {
  const { t } = useTranslation();
  const [visible, setVisible] = useState(false);

  useEffect(() => {
    try {
      if (!localStorage.getItem('mrm-guide-shown')) setVisible(true);
    } catch {
      /* ignore */
    }
  }, []);

  if (!visible) return null;

  const dismiss = () => {
    setVisible(false);
    try {
      localStorage.setItem('mrm-guide-shown', '1');
    } catch {
      /* ignore */
    }
  };

  return (
    <div className="mrm-guide animate-fadeIn" role="note">
      <span className="mrm-guide-icon" aria-hidden="true">
        💡
      </span>
      <span className="mrm-guide-text">{t('quickConnect.guide')}</span>
      <button type="button" className="mrm-guide-close" onClick={dismiss} aria-label="✕">
        ✕
      </button>
    </div>
  );
}
