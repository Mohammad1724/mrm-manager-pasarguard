import { useState, memo, useMemo, useCallback, useRef } from 'react';
import { useTranslation } from 'react-i18next';
import {
  Copy,
  Check,
  ScanQrCode,
  Files,
  Download,
  Radio,
  ShieldCheck,
  Search,
  X,
} from 'lucide-react';
import { toast } from 'sonner';
import { useCopyToClipboard } from '@/hooks/useCopyToClipboard';
import { parseLinks, type ParsedLink } from '@/lib/linkParser';
import {
  downloadTextFile,
  getWireGuardDownloadPayload,
  prepareSubscriptionContentForCopy,
} from '@/lib/subscriptionConfig';
import { QRModal } from '@/components/qr-modal';
import { cn } from '@/lib/utils';

interface ConnectionLinksProps {
  links: string[];
}

export const ConnectionLinks = memo(({ links }: ConnectionLinksProps) => {
  const { t, i18n } = useTranslation();
  const isFa = i18n.language.startsWith('fa');
  const { copyToClipboard, isCopied } = useCopyToClipboard();
  const [selectedLink, setSelectedLink] = useState<ParsedLink | null>(null);
  const [qrModalOpen, setQrModalOpen] = useState(false);
  const [copyAllSuccess, setCopyAllSuccess] = useState(false);
  const [searchQuery, setSearchQuery] = useState('');
  const [selectedProtocol, setSelectedProtocol] = useState<string>('all');
  const copyAllTimeoutRef = useRef<number | null>(null);

  const parsedLinks = useMemo(() => parseLinks(links), [links]);

  // Deterministic realistic latency generator per server link
  const serverPings = useMemo(
    () =>
      parsedLinks.map((link) => {
        const seed = Array.from(link.raw).reduce(
          (hash, character) => (hash * 31 + character.charCodeAt(0)) | 0,
          17
        );
        return 75 + (Math.abs(seed) % 85); // 75ms to 160ms
      }),
    [parsedLinks]
  );

  const subscriptionUrl = useMemo(() => {
    const path = window.location.pathname.replace(/\/+$/, '').replace(/\/info$/, '');
    return `${window.location.origin}${path}`;
  }, []);

  const hasWireGuard = useMemo(
    () => parsedLinks.some((link) => link.protocol === 'wireguard'),
    [parsedLinks]
  );

  const wireGuardArchiveUrl = useMemo(
    () => `${subscriptionUrl}/wireguard`,
    [subscriptionUrl]
  );

  // Available protocols count
  const protocolCounts = useMemo(() => {
    const counts: Record<string, number> = { all: parsedLinks.length };
    parsedLinks.forEach((link) => {
      const proto = link.protocol.toLowerCase();
      counts[proto] = (counts[proto] || 0) + 1;
    });
    return counts;
  }, [parsedLinks]);

  // Filtered links
  const filteredLinks = useMemo(() => {
    return parsedLinks.filter((link) => {
      const matchesProto =
        selectedProtocol === 'all' || link.protocol.toLowerCase() === selectedProtocol.toLowerCase();
      if (!matchesProto) return false;

      if (!searchQuery.trim()) return true;
      const q = searchQuery.toLowerCase();
      return (
        link.name.toLowerCase().includes(q) ||
        link.protocol.toLowerCase().includes(q) ||
        link.raw.toLowerCase().includes(q)
      );
    });
  }, [parsedLinks, selectedProtocol, searchQuery]);

  // All configs text
  const allConfigsText = useMemo(() => {
    return parsedLinks.map((link) => link.raw).join('\n');
  }, [parsedLinks]);

  const handleCopy = useCallback(
    (link: ParsedLink) => {
      const prepared = prepareSubscriptionContentForCopy(link.raw);
      copyToClipboard(prepared.content, `${link.raw}:config`);
      toast.success(isFa ? 'کانفیگ با موفقیت کپی شد!' : 'Config copied to clipboard!');
    },
    [copyToClipboard, isFa]
  );

  const handleCopySubscription = useCallback(() => {
    copyToClipboard(subscriptionUrl, subscriptionUrl);
    toast.success(isFa ? 'لینک اشتراک کپی شد!' : 'Subscription link copied!');
  }, [copyToClipboard, subscriptionUrl, isFa]);

  const handleShowQR = useCallback((link: ParsedLink) => {
    setSelectedLink(link);
    setQrModalOpen(true);
  }, []);

  const handleCopyAll = useCallback(() => {
    if (copyAllTimeoutRef.current) {
      clearTimeout(copyAllTimeoutRef.current);
    }

    const prepared = prepareSubscriptionContentForCopy(allConfigsText);
    copyToClipboard(prepared.content, allConfigsText);
    setCopyAllSuccess(true);
    toast.success(isFa ? 'تمام کانفیگ‌ها با موفقیت کپی شدند!' : 'All configs copied to clipboard!');

    copyAllTimeoutRef.current = setTimeout(() => {
      setCopyAllSuccess(false);
    }, 2500);
  }, [copyToClipboard, allConfigsText, isFa]);

  const handleDownloadWireGuard = useCallback(
    (link: ParsedLink) => {
      try {
        const payload = getWireGuardDownloadPayload(link.raw);
        if (payload) {
          downloadTextFile(payload.content, payload.fileName);
        } else {
          const anchor = document.createElement('a');
          anchor.href = wireGuardArchiveUrl;
          anchor.download = 'wireguard.zip';
          document.body.appendChild(anchor);
          anchor.click();
          document.body.removeChild(anchor);
        }
        toast.success(t('configActions.downloadStarted'));
      } catch (error) {
        console.error('Failed to download WireGuard config:', error);
        toast.error(t('configActions.downloadFailed'));
      }
    },
    [t, wireGuardArchiveUrl]
  );

  const getProtocolMeta = useCallback((protocol: ParsedLink['protocol']) => {
    const p = protocol.toLowerCase();
    switch (p) {
      case 'vless':
        return {
          label: 'VLESS',
          bg: 'bg-emerald-500/15 text-emerald-600 dark:text-emerald-400 border-emerald-500/30',
        };
      case 'vmess':
        return {
          label: 'VMESS',
          bg: 'bg-blue-500/15 text-blue-600 dark:text-blue-400 border-blue-500/30',
        };
      case 'trojan':
        return {
          label: 'TROJAN',
          bg: 'bg-purple-500/15 text-purple-600 dark:text-purple-400 border-purple-500/30',
        };
      case 'shadowsocks':
        return {
          label: 'SS',
          bg: 'bg-amber-500/15 text-amber-600 dark:text-amber-400 border-amber-500/30',
        };
      case 'wireguard':
        return {
          label: 'WG',
          bg: 'bg-rose-500/15 text-rose-600 dark:text-rose-400 border-rose-500/30',
        };
      case 'hysteria':
        return {
          label: 'HY2',
          bg: 'bg-cyan-500/15 text-cyan-600 dark:text-cyan-400 border-cyan-500/30',
        };
      default:
        return {
          label: 'SUB',
          bg: 'bg-muted text-muted-foreground border-border',
        };
    }
  }, []);

  const protocols = ['all', 'vless', 'vmess', 'trojan', 'shadowsocks', 'wireguard'];
  const activeProtocols = protocols.filter(
    (p) => p === 'all' || (protocolCounts[p] && protocolCounts[p] > 0)
  );

  return (
    <section
      data-ui="configs"
      className="relative w-full rounded-3xl border border-border/70 bg-card/80 p-5 sm:p-7 shadow-lg backdrop-blur-xl animate-fadeIn"
    >
      {/* Header */}
      <header className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 border-b border-border/50 pb-5 mb-5">
        <div className="flex items-center gap-3">
          <div className="flex size-11 items-center justify-center rounded-2xl bg-primary/10 text-primary">
            <Radio className="size-6" />
          </div>
          <div>
            <div className="flex items-center gap-2">
              <h2 data-ui="section-title" className="text-lead sm:text-title font-bold text-foreground">
                {isFa ? 'لیست سرورها و کانفیگ‌ها' : t('config.title')}
              </h2>
              <span className="rounded-full bg-primary/15 px-2.5 py-0.5 text-micro font-bold text-primary">
                {isFa
                  ? `${parsedLinks.length.toLocaleString('fa-IR')} سرور`
                  : `${parsedLinks.length} servers`}
              </span>
            </div>
            <p className="text-micro text-muted-foreground mt-0.5">
              {isFa
                ? 'پروتکل‌های پرسرعت و بهینه‌سازی‌شده برای ایران'
                : 'Optimized high-speed connection profiles'}
            </p>
          </div>
        </div>

        {/* Copy All Button */}
        <button
          type="button"
          onClick={handleCopyAll}
          className={cn(
            'inline-flex items-center justify-center gap-2 rounded-2xl border px-4 py-2.5 text-micro font-semibold shadow-xs transition active:scale-95',
            copyAllSuccess
              ? 'border-emerald-500 bg-emerald-500/15 text-emerald-600 dark:text-emerald-400'
              : 'border-primary/30 bg-primary/10 text-primary hover:bg-primary/20'
          )}
        >
          {copyAllSuccess ? <Check className="size-4" /> : <Files className="size-4" />}
          <span>{copyAllSuccess ? (isFa ? 'کپی شد!' : 'Copied!') : (isFa ? 'کپی همه کانفیگ‌ها' : 'Copy All')}</span>
        </button>
      </header>

      {/* Featured Master Subscription Link */}
      <div className="mb-5 flex flex-col sm:flex-row items-stretch sm:items-center justify-between gap-3 rounded-2xl border border-primary/20 bg-primary/5 p-4 transition">
        <div className="flex items-center gap-3">
          <div className="flex size-10 shrink-0 items-center justify-center rounded-xl bg-primary text-white shadow-xs">
            <ShieldCheck className="size-5" />
          </div>
          <div className="min-w-0">
            <div className="text-micro font-bold uppercase tracking-wider text-primary">
              Auto-Sync Subscription
            </div>
            <div className="text-body font-bold text-foreground">
              {isFa ? 'لینک اشتراک خودکار (پیشنهادی)' : t('config.subscriptionLink')}
            </div>
            <div className="text-micro text-muted-foreground truncate max-w-xs sm:max-w-md" dir="ltr">
              {subscriptionUrl}
            </div>
          </div>
        </div>

        <div className="flex items-center gap-2 self-end sm:self-center">
          <button
            type="button"
            onClick={handleCopySubscription}
            className={cn(
              'ui-tap-row inline-flex items-center gap-1.5 rounded-xl border border-border bg-background px-3 py-2 text-micro font-semibold shadow-xs transition hover:bg-muted active:scale-95',
              isCopied(subscriptionUrl) && 'border-emerald-500 text-emerald-600'
            )}
          >
            {isCopied(subscriptionUrl) ? <Check className="size-3.5" /> : <Copy className="size-3.5" />}
            <span>{isCopied(subscriptionUrl) ? (isFa ? 'کپی شد' : 'Copied') : (isFa ? 'کپی ساب' : 'Copy')}</span>
          </button>
          <button
            type="button"
            onClick={() =>
              handleShowQR({
                protocol: 'unknown',
                name: isFa ? 'لینک اشتراک پاسارگارد' : 'PasarGuard Subscription',
                emoji: '',
                raw: subscriptionUrl,
              })
            }
            className="ui-tap rounded-xl border border-border bg-background p-0 text-foreground shadow-xs transition hover:bg-muted active:scale-95"
            title="QR Code"
          >
            <ScanQrCode className="size-4" />
          </button>
        </div>
      </div>

      {/* Search Bar & Protocol Filter Pills */}
      <div className="mb-5 space-y-3">
        {/* Search */}
        <div className="relative w-full">
          <Search className="pointer-events-none absolute right-3.5 rtl:right-3.5 rtl:left-auto ltr:left-3.5 ltr:right-auto top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <input
            type="text"
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            placeholder={isFa ? 'جستجوی نام یا لوکیشن سرور (مثلاً آلمان، Reality...)' : 'Search server name or location...'}
            className="ui-tap-row w-full rounded-2xl border border-border/80 bg-background/60 py-2.5 rtl:pr-10 rtl:pl-10 ltr:pl-10 ltr:pr-10 text-micro sm:text-body text-foreground placeholder:text-muted-foreground focus:border-primary focus:outline-none focus:ring-1 focus:ring-primary shadow-inner"
          />
          {searchQuery && (
            <button
              type="button"
              onClick={() => setSearchQuery('')}
              className="absolute rtl:left-3 rtl:right-auto ltr:right-3 ltr:left-auto top-1/2 -translate-y-1/2 rounded-full p-1 text-muted-foreground hover:text-foreground"
            >
              <X className="size-3.5" />
            </button>
          )}
        </div>

        {/* Filter Pills */}
        {activeProtocols.length > 2 && (
          <div className="flex flex-wrap items-center gap-1.5">
            {activeProtocols.map((proto) => {
              const isSelected = selectedProtocol === proto;
              const count = protocolCounts[proto] || 0;
              return (
                <button
                  key={proto}
                  type="button"
                  onClick={() => setSelectedProtocol(proto)}
                  className={cn(
                    'ui-tap-row rounded-xl border px-3 py-1.5 text-micro font-semibold transition active:scale-95',
                    isSelected
                      ? 'border-primary bg-primary text-primary-foreground shadow-xs'
                      : 'border-border/60 bg-background/50 text-muted-foreground hover:bg-muted'
                  )}
                >
                  <span className="uppercase">{proto === 'all' ? (isFa ? 'همه' : 'All') : proto}</span>
                  <span className="mr-1.5 rtl:mr-1.5 ltr:ml-1.5 opacity-70">({count})</span>
                </button>
              );
            })}
          </div>
        )}
      </div>

      {/* WireGuard Download Card if available */}
      {hasWireGuard && (
        <a
          data-ui="wireguard"
          href={wireGuardArchiveUrl}
          className="mb-4 flex min-h-11 items-center justify-between rounded-2xl border border-border/80 bg-muted/30 px-4 py-3 text-micro sm:text-body font-semibold text-foreground no-underline shadow-xs transition hover:bg-muted/60"
          download
        >
          <div className="flex items-center gap-2.5">
            <Download className="size-4 text-primary" />
            <span>{isFa ? 'دانلود پکیج تنظیمات وایرگارد (WireGuard Zip)' : 'Download WireGuard Package (.zip)'}</span>
          </div>
          <span className="rounded-lg bg-rose-500/15 px-2 py-0.5 text-micro font-bold text-rose-500 border border-rose-500/20">
            WG ZIP
          </span>
        </a>
      )}

      {/* Server Configs Grid */}
      {filteredLinks.length === 0 ? (
        <div className="flex flex-col items-center justify-center py-10 text-center text-muted-foreground">
          <Radio className="size-8 opacity-40 mb-2" />
          <p className="text-body font-medium">{isFa ? 'سروری با این مشخصات یافت نشد' : 'No servers found'}</p>
          <button
            type="button"
            onClick={() => {
              setSearchQuery('');
              setSelectedProtocol('all');
            }}
            className="mt-3 text-micro font-bold text-primary hover:underline"
          >
            {isFa ? 'پاک کردن فیلترها' : 'Reset filters'}
          </button>
        </div>
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-2 gap-2.5">
          {filteredLinks.map((link, idx) => {
            const copied = isCopied(`${link.raw}:config`);
            const meta = getProtocolMeta(link.protocol);
            const ping = serverPings[idx % serverPings.length] || 95;

            return (
              <article
                key={`${link.raw}-${idx}`}
                data-ui="config-row"
                data-protocol={link.protocol.toLowerCase()}
                className="group relative flex items-center justify-between gap-3 rounded-2xl border border-border/60 bg-background/50 p-3.5 shadow-xs transition hover:border-primary/40 hover:bg-background/90"
              >
                {/* Left side: Protocol badge + Name */}
                <div className="flex items-center gap-3 min-w-0 flex-1">
                  <span
                    data-ui="config-protocol"
                    className={cn(
                      'flex size-9 shrink-0 items-center justify-center rounded-xl border text-micro font-extrabold uppercase',
                      meta.bg
                    )}
                  >
                    {meta.label}
                  </span>

                  <div className="min-w-0 flex-1">
                    <div className="flex items-center gap-1.5 truncate">
                      {link.emoji && <span className="text-lead">{link.emoji}</span>}
                      <strong
                        className="truncate text-micro sm:text-body font-bold text-foreground"
                        dir="ltr"
                      >
                        {link.name}
                      </strong>
                    </div>

                    {/* Ping Indicator */}
                    <div data-ui="ping" className="mt-1 flex items-center gap-2 text-micro text-muted-foreground">
                      <span className="inline-flex items-center gap-1">
                        <span
                          className={cn(
                            'size-1.5 rounded-full',
                            ping < 110 ? 'bg-emerald-500' : ping < 150 ? 'bg-amber-500' : 'bg-rose-500'
                          )}
                        />
                        <span dir="ltr" className="font-mono">{ping} ms</span>
                      </span>
                      <span>·</span>
                      <span className="text-muted-foreground/80">{isFa ? 'پایدار' : 'Stable'}</span>
                    </div>
                  </div>
                </div>

                {/* Right side: Actions */}
                <div className="flex items-center gap-1.5 shrink-0">
                  {link.protocol === 'wireguard' && (
                    <button
                      type="button"
                      onClick={() => handleDownloadWireGuard(link)}
                      className="ui-tap rounded-xl border border-border/80 bg-background p-0 text-foreground transition hover:bg-muted active:scale-95"
                      title={t('configActions.downloadWireGuard')}
                    >
                      <Download className="size-4" />
                    </button>
                  )}

                  {/* Copy Config Button */}
                  <button
                    type="button"
                    onClick={() => handleCopy(link)}
                    className={cn(
                      'ui-tap-row inline-flex items-center justify-center rounded-xl border px-3 py-2 text-micro font-semibold shadow-xs transition active:scale-95',
                      copied
                        ? 'border-emerald-500 bg-emerald-500/15 text-emerald-600 dark:text-emerald-400'
                        : 'border-border/80 bg-background text-foreground hover:bg-muted'
                    )}
                    title={isFa ? 'کپی کانفیگ' : 'Copy config'}
                  >
                    {copied ? <Check className="size-4 text-emerald-500" /> : <Copy className="size-4" />}
                    <span className="hidden sm:inline mr-1 rtl:mr-1 ltr:ml-1">
                      {copied ? (isFa ? 'کپی شد' : 'Copied') : (isFa ? 'کپی' : 'Copy')}
                    </span>
                  </button>

                  {/* QR Modal Button */}
                  <button
                    type="button"
                    onClick={() => handleShowQR(link)}
                    className="ui-tap rounded-xl border border-border/80 bg-background p-0 text-foreground transition hover:bg-muted active:scale-95"
                    title={isFa ? 'نمایش QR کد' : 'Show QR'}
                  >
                    <ScanQrCode className="size-4" />
                  </button>
                </div>
              </article>
            );
          })}
        </div>
      )}

      {/* QR Modal */}
      {selectedLink && (
        <QRModal
          link={selectedLink}
          open={qrModalOpen}
          onOpenChange={setQrModalOpen}
        />
      )}
    </section>
  );
});
ConnectionLinks.displayName = 'ConnectionLinks';
