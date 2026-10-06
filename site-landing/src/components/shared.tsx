import type { ReactNode } from 'react';

export function Sprites() {
  return (
    <svg width="0" height="0" className="absolute" aria-hidden="true">
      <defs>
        <symbol id="app-icon" viewBox="0 0 100 100">
          <rect width="100" height="100" fill="var(--paper)" />
          {/* Paths from design-assets/app-icon/gen.cjs */}
          <g
            transform="translate(50 50) scale(2.05) translate(-2.74 1.37)"
            stroke="var(--ink)"
            strokeLinecap="round"
            strokeLinejoin="round"
          >
            <path
              d="M12.35 -12.8L12.98 -12.79L13.58 -12.66L14.15 -12.41L14.64 -12.04L15.05 -11.58L15.36 -11.04L15.55 -10.44L15.61 -9.81L15.61 5.72L15.55 6.36L15.36 6.96L15.05 7.51L14.64 7.98L14.15 8.36L13.58 8.63L12.98 8.77L12.35 8.8L4.07 8.3L0.27 11.01L0.61 8.1L0.08 8.01L-0.42 7.81L-0.88 7.52L-1.28 7.13L-1.6 6.68L-1.84 6.16L-1.99 5.62L-2.04 5.05L-2.04 -8.66L-1.99 -9.23L-1.84 -9.78L-1.6 -10.3L-1.28 -10.76L-0.88 -11.16L-0.42 -11.46L0.08 -11.67L0.61 -11.78ZM7.73 -16.92L8.53 -16.93L12.98 -12.79L12.35 -12.8ZM8.53 -16.93L9.31 -16.78L13.58 -12.66L12.98 -12.79ZM9.31 -16.78L10.03 -16.47L14.15 -12.41L13.58 -12.66ZM10.03 -16.47L10.68 -16L14.64 -12.04L14.15 -12.41ZM14.64 -12.04L15.05 -11.58L11.21 -15.41L10.68 -16ZM15.05 -11.58L15.36 -11.04L11.6 -14.7L11.21 -15.41ZM15.36 -11.04L15.55 -10.44L11.85 -13.9L11.6 -14.7ZM15.55 -10.44L15.61 -9.81L11.93 -13.06L11.85 -13.9ZM15.61 -9.81L15.61 5.72L11.93 7.62L11.93 -13.06ZM15.61 5.72L15.55 6.36L11.85 8.46L11.93 7.62ZM15.55 6.36L15.36 6.96L11.6 9.27L11.85 8.46ZM15.36 6.96L15.05 7.51L11.21 9.99L11.6 9.27ZM15.05 7.51L14.64 7.98L10.68 10.61L11.21 9.99ZM14.64 7.98L14.15 8.36L10.03 11.09L10.68 10.61ZM10.03 11.09L9.31 11.43L13.58 8.63L14.15 8.36ZM9.31 11.43L8.53 11.61L12.98 8.77L13.58 8.63ZM8.53 11.61L7.73 11.63L12.35 8.8L12.98 8.77ZM7.73 11.63L-2.69 10.78L4.07 8.3L12.35 8.8ZM4.07 8.3L0.27 11.01L-7.34 14.18L-2.69 10.78ZM-7.34 14.18L-6.93 10.43L0.61 8.1L0.27 11.01ZM-6.93 10.43L-7.57 10.31L0.08 8.01L0.61 8.1ZM-7.57 10.31L-8.18 10.05L-0.42 7.81L0.08 8.01ZM-8.18 10.05L-8.73 9.66L-0.88 7.52L-0.42 7.81ZM-8.73 9.66L-9.22 9.16L-1.28 7.13L-0.88 7.52ZM-9.22 9.16L-9.61 8.56L-1.6 6.68L-1.28 7.13ZM-9.61 8.56L-9.9 7.9L-1.84 6.16L-1.6 6.68ZM-9.9 7.9L-10.08 7.2L-1.99 5.62L-1.84 6.16ZM-10.08 7.2L-10.14 6.47L-2.04 5.05L-1.99 5.62ZM-10.14 6.47L-10.14 -11.1L-2.04 -8.66L-2.04 5.05ZM-10.14 -11.1L-10.08 -11.82L-1.99 -9.23L-2.04 -8.66ZM-10.08 -11.82L-9.9 -12.54L-1.84 -9.78L-1.99 -9.23ZM-9.9 -12.54L-9.61 -13.21L-1.6 -10.3L-1.84 -9.78ZM-9.61 -13.21L-9.22 -13.81L-1.28 -10.76L-1.6 -10.3ZM-9.22 -13.81L-8.73 -14.33L-0.88 -11.16L-1.28 -10.76ZM-8.73 -14.33L-8.18 -14.74L-0.42 -11.46L-0.88 -11.16ZM-8.18 -14.74L-7.57 -15.03L0.08 -11.67L-0.42 -11.46ZM-7.57 -15.03L-6.93 -15.18L0.61 -11.78L0.08 -11.67ZM-6.93 -15.18L7.73 -16.92L12.35 -12.8L0.61 -11.78Z"
              fill="var(--ink)"
              strokeWidth="3"
            />
            <path
              d="M7.73 -16.92L8.53 -16.93L9.31 -16.78L10.03 -16.47L10.68 -16L11.21 -15.41L11.6 -14.7L11.85 -13.9L11.93 -13.06L11.93 7.62L11.85 8.46L11.6 9.27L11.21 9.99L10.68 10.61L10.03 11.09L9.31 11.43L8.53 11.61L7.73 11.63L-2.69 10.78L-7.34 14.18L-6.93 10.43L-7.57 10.31L-8.18 10.05L-8.73 9.66L-9.22 9.16L-9.61 8.56L-9.9 7.9L-10.08 7.2L-10.14 6.47L-10.14 -11.1L-10.08 -11.82L-9.9 -12.54L-9.61 -13.21L-9.22 -13.81L-8.73 -14.33L-8.18 -14.74L-7.57 -15.03L-6.93 -15.18Z"
              fill="var(--paper)"
              strokeWidth="3"
            />
            <path d="M3.25 -8.33L3.7 -7.9L4.1 -7.41L4.44 -6.87L4.72 -6.28L4.92 -5.65L5.06 -5L5.12 -4.34L5.1 -3.66L5.01 -3L4.84 -2.35L4.6 -1.72L4.29 -1.13L3.92 -0.59L3.5 -0.1L3.03 0.33L2.51 0.69L1.97 0.98L1.39 1.2L0.81 1.34L0.22 1.4L-0.38 1.38L-0.96 1.29L-1.52 1.12L-2.05 0.88L-2.56 0.57L-3.02 0.21L-3.44 -0.22L-3.8 -0.69L-4.12 -1.21L-4.37 -1.77L-4.56 -2.35L-4.69 -2.96L-4.75 -3.57L-4.75 -4.2L-4.68 -4.82L-4.55 -5.43L-4.35 -6.03L-4.09 -6.59L-3.77 -7.13L-3.4 -7.62" fill="none" strokeWidth="3.2" />
            <path d="M-5.34 -9.68L-1.03 -10.43L-1.41 -5.5Z" fill="var(--ink)" strokeWidth="1.2" />
            <path d="M-5.27 5.77L5.71 6.25" fill="none" strokeWidth="3" />
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
