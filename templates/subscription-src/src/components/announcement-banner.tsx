import { memo, useState, useEffect } from 'react';
import { Bell, ExternalLink, X } from 'lucide-react';

interface AnnouncementBannerProps {
  message: string;
  url?: string | null;
}

export const AnnouncementBanner = memo(({ message, url }: AnnouncementBannerProps) => {
  const [dismissed, setDismissed] = useState(false);

  useEffect(() => {
    try {
      const stored = sessionStorage.getItem('mrm-announcement-dismissed');
      if (stored === message) {
        setDismissed(true);
      }
    } catch {
      // ignore
    }
  }, [message]);

  if (dismissed || !message.trim()) return null;

  const handleDismiss = () => {
    setDismissed(true);
    try {
      sessionStorage.setItem('mrm-announcement-dismissed', message);
    } catch {
      // ignore
    }
  };

  return (
    <div
      role="alert"
      data-ui="announcement"
      className="relative mb-5 flex items-start gap-3 rounded-2xl border border-primary/25 bg-gradient-to-r from-primary/10 via-primary/5 to-transparent p-4 shadow-xs backdrop-blur-md animate-fadeIn"
    >
      <div className="flex size-8 shrink-0 items-center justify-center rounded-xl bg-primary/20 text-primary">
        <Bell className="size-4 animate-bounce" />
      </div>

      <div className="min-w-0 flex-1">
        <div className="text-micro font-semibold text-primary-text">اعلان مهم</div>
        <p className="mt-0.5 text-micro sm:text-body font-medium leading-relaxed text-foreground whitespace-pre-line break-words">
          {message}
        </p>
        {url && (
          <a
            href={url}
            target="_blank"
            rel="noopener noreferrer"
            className="ui-tap-row mt-2 inline-flex items-center gap-1 text-micro font-bold text-primary-text hover:underline"
          >
            <span>مشاهده اطلاعات تکمیلی</span>
            <ExternalLink className="size-3" />
          </a>
        )}
      </div>

      <button
        type="button"
        onClick={handleDismiss}
        aria-label="بستن اعلان"
        className="mrm-tap-target -m-1.5 grid size-11 shrink-0 place-items-center rounded-lg text-muted-foreground transition hover:bg-muted hover:text-foreground"
      >
        <X className="size-4" aria-hidden="true" />
      </button>
    </div>
  );
});
AnnouncementBanner.displayName = 'AnnouncementBanner';
