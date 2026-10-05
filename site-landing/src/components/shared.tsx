import type { ReactNode } from 'react';

export function Sprites() {
  return (
    <svg width="0" height="0" className="absolute" aria-hidden="true">
      <defs>
        <symbol id="app-icon" viewBox="0 0 100 100">
          <rect width="100" height="100" fill="var(--paper)" />
          <g
            transform="translate(50 50) scale(2.02) translate(-19.3 -19)"
            stroke="var(--ink)"
            strokeLinecap="round"
            strokeLinejoin="round"
          >
            <rect
              x="9"
              y="4"
              width="22"
              height="24"
              rx="4"
              transform="rotate(9 20 16)"
              fill="var(--soft)"
              strokeWidth="3"
            />
            <rect
              x="5"
              y="9"
              width="24"
              height="25"
              rx="4"
              fill="var(--paper)"
              strokeWidth="3"
            />
            <path
              d="M20.47 14.86A5.4 5.4 0 1 1 13.18 15.18"
              fill="none"
              strokeWidth="3.2"
            />
            <path
              d="M10.92 12.92L15.87 12.5L15.45 17.45Z"
              fill="var(--ink)"
              strokeWidth="1"
            />
            <path d="M11 29h12" fill="none" strokeWidth="3" />
          </g>
        </symbol>
        <symbol id="loop" viewBox="0 0 24 24">
          <path
            d="M17.3 6.1A8 8 0 1 1 6.3 6.6"
            fill="none"
            stroke="currentColor"
            strokeWidth="3"
            strokeLinecap="round"
          />
          <path
            d="M3.2 3.6L8.6 3.3L8.2 9.1Z"
            fill="currentColor"
            stroke="currentColor"
            strokeWidth="1"
            strokeLinejoin="round"
          />
        </symbol>
      </defs>
    </svg>
  );
}

export function Use({ id, className }: { id: string; className?: string }) {
  return (
    <svg className={className} aria-hidden="true">
      <use href={`#${id}`} />
    </svg>
  );
}

export function AppStoreButton() {
  return (
    <div className="soon">
      <svg
        width="24"
        height="24"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        aria-hidden="true"
      >
        <rect x="6" y="2.5" width="12" height="19" rx="3" />
        <path d="M10.5 18.5h3" />
      </svg>
      <span>
        <small>Coming soon to the</small>
        <b>App Store</b>
      </span>
    </div>
  );
}

export function SectionHead({
  label,
  id,
  title,
  children,
  className = '',
}: {
  label: string;
  id: string;
  title: string;
  children?: ReactNode;
  className?: string;
}) {
  return (
    <div className={`flex max-w-[680px] flex-col gap-3.5 ${className}`}>
      <span className="label">{label}</span>
      <h2
        id={id}
        className="text-[clamp(34px,5vw,58px)] leading-[0.98] font-black tracking-[-0.03em] [font-variation-settings:'wdth'_110]"
      >
        {title}
      </h2>
      {children && (
        <p className="max-w-[34em] text-[18px] text-muted">{children}</p>
      )}
    </div>
  );
}
