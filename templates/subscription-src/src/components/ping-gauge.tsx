import type { CSSProperties } from 'react';
import { cn } from '@/lib/utils';

/* ------------------------------------------------------------------ */
/*  عقربه‌ی پینگ — mini needle gauge (0–300ms mapped to ±88deg)          */
/*  Signature MRM Special visual: animated needle + turquoise arc       */
/* ------------------------------------------------------------------ */

export interface PingGaugeProps {
  /** estimated latency in milliseconds */
  ms: number;
  className?: string;
}

const needleAngle = (ms: number): number => {
  const value = Number.isFinite(ms) && ms > 0 ? ms : 999;
  const t = Math.min(value, 300) / 300; // 0..1
  return -88 + t * 176;
};

export function PingGauge({ ms, className }: PingGaugeProps) {
  const angle = needleAngle(ms);
  return (
    <svg
      className={cn('treasury-ping-gauge', className)}
      viewBox="0 0 48 30"
      role="img"
      aria-label={`${ms} ms`}
    >
      <path className="treasury-ping-track" d="M5 27 A19 19 0 0 1 43 27" />
      <path
        className="treasury-ping-track-ok"
        d="M5 27 A19 19 0 0 1 43 27"
        pathLength={100}
        strokeDasharray="30 100"
      />
      <g
        className="treasury-ping-needle"
        style={{ '--needle-angle': `${angle}deg` } as CSSProperties}
      >
        <line x1="24" y1="27" x2="24" y2="11" />
      </g>
      <circle className="treasury-ping-hub" cx="24" cy="27" r="2.4" />
    </svg>
  );
}
