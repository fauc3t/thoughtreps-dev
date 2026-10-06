// Same toggle as site-landing's shared.tsx (no shared package between the two).
// Wired up by public/theme.js (click delegation), so it works on prerendered
// pages without hydration; CSS picks which glyph shows. Sun and moon glyphs are
// from Lucide 1.52.0 (see public/third-party-licenses.txt).
export function ThemeToggle({ className = '' }: { className?: string }) {
  return (
    <button
      type="button"
      data-theme-toggle
      aria-label="Switch between light and dark mode"
      title="Light or dark mode"
      className={`grid size-[42px] shrink-0 cursor-pointer place-items-center rounded-[10px] border-2 border-transparent bg-transparent p-0 text-ink transition-[border-color,background] duration-[120ms] hover:border-ink hover:bg-soft ${className}`}
    >
      <ThemeGlyphs />
    </button>
  );
}

function ThemeGlyphs() {
  const svg = {
    className: 'size-5',
    viewBox: '0 0 24 24',
    fill: 'none',
    stroke: 'currentColor',
    strokeWidth: 2,
    strokeLinecap: 'round' as const,
    strokeLinejoin: 'round' as const,
    'aria-hidden': true,
  };
  return (
    <>
      <svg {...svg} className={`theme-moon ${svg.className}`}>
        <path d="M20.985 12.486a9 9 0 1 1-9.473-9.472c.405-.022.617.46.402.803a6 6 0 0 0 8.268 8.268c.344-.215.825-.004.803.401" />
      </svg>
      <svg {...svg} className={`theme-sun ${svg.className}`}>
        <circle cx="12" cy="12" r="4" />
        <path d="M12 2v2M12 20v2m-7.07-17.07 1.41 1.41m11.32 11.32 1.41 1.41M2 12h2m16 0h2M6.34 17.66l-1.41 1.41M19.07 4.93l-1.41 1.41" />
      </svg>
    </>
  );
}
