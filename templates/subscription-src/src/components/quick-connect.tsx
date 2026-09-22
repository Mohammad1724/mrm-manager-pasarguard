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
  Loader2,
  X,
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
  /** store / download links per platform — used by the auto-install flow */
  stores?: Partial<Record<PlatformKey, { label: string; url: string }[]>>;
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
    stores: {
      android: [
        { label: 'Bazaar', url: 'https://cafebazaar.ir/app/com.v2ray.ang' },
        { label: 'Myket', url: 'https://myket.ir/app/com.v2ray.ang' },
        { label: 'Google Play', url: 'https://play.google.com/store/apps/details?id=com.v2ray.ang' },
      ],
    },
  },
  {
    id: 'hiddify',
    name: 'Hiddify',
    platforms: ['android', 'ios', 'desktop'],
    recommended: ['ios', 'desktop'],
    buildDeepLink: (u) => `hiddify://import/${u}`,
    stores: {
      android: [
        { label: 'Bazaar', url: 'https://cafebazaar.ir/app/com.hiddify.app' },
        { label: 'Google Play', url: 'https://play.google.com/store/apps/details?id=com.hiddify.app' },
      ],
      ios: [{ label: 'App Store', url: 'https://apps.apple.com/app/id6596777532' }],
      desktop: [{ label: 'Download', url: 'https://hiddify.com/download' }],
    },
  },
  {
    id: 'v2raytun',
    name: 'v2rayTun',
    platforms: ['android'],
    buildDeepLink: (u) => `v2raytun://import/${b64url(u)}`,
    stores: {
      android: [
        { label: 'Bazaar', url: 'https://cafebazaar.ir/search?q=v2rayTun' },
        { label: 'Myket', url: 'https://myket.ir/search?q=v2rayTun' },
      ],
    },
  },
  {
    id: 'happ',
    name: 'Happ',
    platforms: ['android', 'ios'],
    buildDeepLink: (u) => `happ://add/${b64url(u)}`,
    stores: {
      android: [{ label: 'Bazaar', url: 'https://cafebazaar.ir/search?q=Happ' }],
      ios: [{ label: 'App Store', url: 'https://apps.apple.com/app/id6504287215' }],
    },
  },
  {
    id: 'v2box',
    name: 'V2Box',
    platforms: ['android', 'ios'],
    buildDeepLink: (u, n) =>
      `v2box://install-sub?url=${encodeURIComponent(u)}&name=${encodeURIComponent(n)}`,
    stores: {
      android: [
        { label: 'Google Play', url: 'https://play.google.com/store/apps/details?id=com.v2box.v2ray' },
        { label: 'Bazaar', url: 'https://cafebazaar.ir/search?q=V2Box' },
      ],
      ios: [{ label: 'App Store', url: 'https://apps.apple.com/app/id6446814690' }],
    },
  },
  {
    id: 'streisand',
    name: 'Streisand',
    platforms: ['ios'],
    buildDeepLink: (u) => `streisand://import/${u}`,
    stores: { ios: [{ label: 'App Store', url: 'https://apps.apple.com/app/id6450534064' }] },
  },
  {
    id: 'shadowrocket',
    name: 'Shadowrocket',
    platforms: ['ios'],
    buildDeepLink: (u, n) => `sub://${b64url(u)}#${encodeURIComponent(n)}`,
    stores: { ios: [{ label: 'App Store', url: 'https://apps.apple.com/app/id932747118' }] },
  },
  {
    id: 'stash',
    name: 'Stash',
    platforms: ['ios'],
    recommended: ['ios'],
    buildDeepLink: (u, n) =>
      `stash://install-config?url=${encodeURIComponent(u)}&name=${encodeURIComponent(n)}`,
    stores: { ios: [{ label: 'App Store', url: 'https://apps.apple.com/app/id1596063349' }] },
  },
  {
    id: 'foxray',
    name: 'FoXray',
    platforms: ['ios'],
    buildDeepLink: (u) => `foxray://import/${u}`,
    stores: { ios: [{ label: 'App Store', url: 'https://apps.apple.com/us/search?term=foxray' }] },
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

  const recommendedApp = useMemo(
    () =>
      CONNECT_APPS.find(
        (a) => a.platforms.includes(detectedPlatform) && a.recommended?.includes(detectedPlatform)
      ) ??
      CONNECT_APPS.find((a) => a.platforms.includes(detectedPlatform)) ??
      null,
    [detectedPlatform]
  );

  type FlowStage = 'detect' | 'install' | 'import' | 'done' | 'fail';
  const [flowStage, setFlowStage] = useState<FlowStage | null>(null);
  const [flowApp, setFlowApp] = useState<ConnectAppDef | null>(null);

  const rememberApp = useCallback((app: ConnectAppDef) => {
    try {
      localStorage.setItem(LAST_APP_KEY, app.id);
    } catch {
      /* ignore */
    }
    setLastAppId(app.id);
  }, []);

  /** Fire the deep link and resolve whether the OS handed off to an app. */
  const tryAutoOpen = useCallback(
    (app: ConnectAppDef) =>
      new Promise<boolean>((resolve) => {
        let settled = false;
        const cleanup = () => {
          clearTimeout(timer);
          document.removeEventListener('visibilitychange', onVisibility);
          window.removeEventListener('blur', onBlur);
        };
        const finish = (opened: boolean) => {
          if (settled) return;
          settled = true;
          cleanup();
          resolve(opened);
        };
        const onVisibility = () => {
          if (document.visibilityState === 'hidden') finish(true);
        };
        const onBlur = () => finish(true);
        const timer = setTimeout(() => finish(false), 1800);
        document.addEventListener('visibilitychange', onVisibility);
        window.addEventListener('blur', onBlur);
        window.location.href = app.buildDeepLink(subscriptionUrl, pageTitle);
      }),
    [subscriptionUrl, pageTitle]
  );

  /** Resolve true when the user leaves to the store and comes back. */
  const waitForReturn = useCallback(
    () =>
      new Promise<boolean>((resolve) => {
        let hidden = false;
        let settled = false;
        const cleanup = () => {
          clearTimeout(timer);
          document.removeEventListener('visibilitychange', onVis);
        };
        const finish = (ok: boolean) => {
          if (settled) return;
          settled = true;
          cleanup();
          resolve(ok);
        };
        const onVis = () => {
          if (document.visibilityState === 'hidden') {
            hidden = true;
            return;
          }
          if (hidden) finish(true);
        };
        const timer = setTimeout(() => finish(false), 180000);
        document.addEventListener('visibilitychange', onVis);
      }),
    []
  );

  /** Full auto journey for total beginners: probe → install → import → done. */
  const runAutoConnect = useCallback(
    async (app: ConnectAppDef) => {
      setFlowApp(app);
      setDialogOpen(true);
      setFlowStage('detect');
      const opened = await tryAutoOpen(app);
      if (opened) {
        rememberApp(app);
        setFlowStage('done');
        setTimeout(() => setDialogOpen(false), 2000);
        return;
      }
      const links = app.stores?.[detectedPlatform] ?? [];
      if (detectedPlatform === 'desktop' || links.length === 0) {
        setFlowStage('fail');
        return;
      }
      setFlowStage('install');
      window.open(links[0].url, '_blank', 'noopener');
      const cameBack = await waitForReturn();
      if (!cameBack) {
        setFlowStage('fail');
        return;
      }
      await new Promise((r) => setTimeout(r, 700));
      setFlowStage('import');
      const ok = await tryAutoOpen(app);
      if (ok) {
        rememberApp(app);
        setFlowStage('done');
        setTimeout(() => setDialogOpen(false), 2400);
      } else {
        setFlowStage('fail');
      }
    },
    [tryAutoOpen, rememberApp, waitForReturn, detectedPlatform]
  );

  const connect = useCallback(
    (app: ConnectAppDef) => {
      rememberApp(app);
      void runAutoConnect(app);
    },
    [rememberApp, runAutoConnect]
  );

  /** One tap does everything — the saved app first, else the device's best. */
  const handleMainClick = useCallback(() => {
    const target = lastApp ?? recommendedApp;
    if (target) {
      void runAutoConnect(target);
    } else {
      setFlowStage(null);
      setDialogOpen(true);
    }
  }, [lastApp, recommendedApp, runAutoConnect]);

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

      <Dialog open={dialogOpen} onOpenChange={(open) => { setDialogOpen(open); if (!open) setFlowStage(null); }}>
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

          {flowStage ? (
            <div className="mrm-auto-flow" role="status">
              <div className={`mrm-auto-step ${flowStage === 'detect' ? 'is-active' : 'is-done'}`}>
                <span className="mrm-auto-dot">
                  {flowStage === 'detect' ? <Loader2 className="size-4 animate-spin" /> : <Check className="size-4" />}
                </span>
                <div>
                  <b>{t('quickConnect.autoDetect')}</b>
                  <div className="mrm-auto-sub">{flowApp?.name}</div>
                </div>
              </div>
              {flowStage !== 'detect' && (
                <div className={`mrm-auto-step ${flowStage === 'install' ? 'is-active' : flowStage === 'fail' ? 'is-fail' : 'is-done'}`}>
                  <span className="mrm-auto-dot">
                    {flowStage === 'install' ? <Loader2 className="size-4 animate-spin" /> : flowStage === 'fail' ? <X className="size-4" /> : <Check className="size-4" />}
                  </span>
                  <div>
                    <b>{t('quickConnect.autoInstallTitle')}</b>
                    <div className="mrm-auto-sub">{t('quickConnect.autoInstallHint')}</div>
                  </div>
                </div>
              )}
              {(flowStage === 'import' || flowStage === 'done') && (
                <div className={`mrm-auto-step ${flowStage === 'import' ? 'is-active' : 'is-done'}`}>
                  <span className="mrm-auto-dot">
                    {flowStage === 'import' ? <Loader2 className="size-4 animate-spin" /> : <Check className="size-4" />}
                  </span>
                  <div>
                    <b>{t('quickConnect.autoImportTitle')}</b>
                    <div className="mrm-auto-sub">{t('quickConnect.autoImportHint')}</div>
                  </div>
                </div>
              )}
              {flowStage === 'done' && (
                <div className="mrm-auto-done">
                  <Check className="size-5" />
                  {t('quickConnect.autoDone')}
                </div>
              )}
              {flowStage === 'fail' && (
                <div className="mrm-auto-fail">
                  <b>{t('quickConnect.autoManualTitle')}</b>
                  <p className="mrm-auto-sub">{t('quickConnect.autoManualHint')}</p>
                  <div className="mrm-auto-stores">
                    {Object.values(flowApp?.stores ?? {})
                      .flat()
                      .filter(Boolean)
                      .map((s) => (
                        <a key={s!.url} className="ios-app-button" href={s!.url} target="_blank" rel="noopener noreferrer">
                          {s!.label}
                        </a>
                      ))}
                  </div>
                  <div className="mrm-auto-stores">
                    <button type="button" className="ios-app-button" onClick={() => flowApp && runAutoConnect(flowApp)}>
                      {t('quickConnect.autoRetry')}
                    </button>
                  </div>
                </div>
              )}
            </div>
          ) : (
          <>
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
          </>
          )}
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
        
      </span>
      <span className="mrm-guide-text">{t('quickConnect.guide')}</span>
      <button type="button" className="mrm-guide-close" onClick={dismiss} aria-label="✕">
        ✕
      </button>
    </div>
  );
}
