import { useEffect, useState } from 'react';
import { AppStoreButton, Use } from './shared';

export function Nav() {
  const link =
    'rounded-[10px] border-2 border-transparent px-3 py-2 text-[15px] font-medium no-underline transition-[border-color,background] duration-[120ms] hover:border-ink hover:bg-soft max-[680px]:hidden';
  return (
    <header className="flex items-center justify-between gap-4 py-[18px]">
      <a
        className="flex items-center gap-2.5 text-[19px] leading-none font-extrabold tracking-[-0.01em] no-underline [font-family:var(--font-display)] [font-variation-settings:'wdth'_108]"
        href="#top"
        aria-label="Thought Reps home"
      >
        <Use
          id="app-icon"
          className="size-[38px] rounded-[10px] border-2 border-ink shadow-sticker-sm"
        />
        Thought Reps
      </a>
      <nav className="flex items-center gap-1.5" aria-label="Page">
        <a className={link} href="#how">
          How it works
        </a>
        <a className={link} href="#features">
          Features
        </a>
        <a className={link} href="#privacy">
          Privacy
        </a>
        <a
          className="rounded-[10px] border-2 border-ink px-3 py-2 text-[15px] font-medium no-underline shadow-sticker-sm transition-[border-color,background] duration-[120ms] hover:bg-accent hover:text-accent-ink"
          href="#get"
        >
          Get the app
        </a>
      </nav>
    </header>
  );
}

const NOTES = [
  {
    title: 'One wild and precious life',
    body: '“Tell me, what is it you plan to do with your one wild and precious life?” — Mary Oliver',
    tags: ['#quotes'],
    due: 'due today',
    quiet: false,
  },
  {
    title: 'Read later: the case for slow email',
    body: "Saved Tuesday, 12 min read. You said you'd get to it.",
    tags: ['#toread'],
    due: 'due 2d ago',
    quiet: false,
  },
  {
    title: 'Weekly review questions',
    body: 'What moved forward? What stalled? What do I want to stop doing?',
    tags: ['#habits'],
    due: 'pinned',
    quiet: true,
  },
];

const CYCLE_MS = 4200;

function prefersReducedMotion() {
  return window.matchMedia('(prefers-reduced-motion: reduce)').matches;
}

function Deck() {
  const [pos, setPos] = useState([0, 1, 2]);
  const [swinging, setSwinging] = useState<number | null>(null);
  const [spins, setSpins] = useState(0);
  const [paused, setPaused] = useState(false);

  const cycle = () => {
    if (swinging !== null) return;
    const front = pos.indexOf(0);
    const demoted = pos.map((p, i) => (i === front ? p : p - 1));
    setSpins((s) => s + 1);
    if (prefersReducedMotion()) {
      demoted[front] = 2;
      setPos(demoted);
      return;
    }
    setPos(demoted);
    setSwinging(front);
  };

  useEffect(() => {
    if (paused || prefersReducedMotion()) return;
    const id = setInterval(() => {
      if (!document.hidden) cycle();
    }, CYCLE_MS);
    return () => clearInterval(id);
  });

  const finishSwing = (i: number) => {
    setPos((p) => p.map((v, j) => (j === i ? 2 : v)));
    setSwinging(null);
  };

  return (
    <div
      role="group"
      className="relative h-[420px] min-w-0 max-[920px]:h-[380px] max-[620px]:h-[340px]"
      aria-label="A stack of thoughts. Every few seconds the top one goes to the back and the next one comes up."
      onMouseEnter={() => setPaused(true)}
      onMouseLeave={() => setPaused(false)}
      onFocus={() => setPaused(true)}
      onBlur={() => setPaused(false)}
    >
      <div className="deck absolute top-1/2 left-1/2 h-[230px] w-[min(340px,86%)] max-[620px]:h-[210px]">
        {NOTES.map((n, i) => (
          <article
            key={n.title}
            className={`note stk${swinging === i ? ' swing' : ''}`}
            data-pos={pos[i]}
            onAnimationEnd={swinging === i ? () => finishSwing(i) : undefined}
          >
            <span className="text-[24px] leading-[1.15] font-extrabold tracking-[-0.01em] [font-family:var(--font-display)] [font-variation-settings:'wdth'_100] max-[620px]:text-[21px]">
              {n.title}
            </span>
            <span className="text-[16px] leading-normal text-muted">
              {n.body}
            </span>
            <div className="mt-auto flex flex-wrap items-center justify-between gap-2">
              <div className="flex flex-wrap gap-1.5">
                {n.tags.map((t) => (
                  <span key={t} className="chip">
                    {t}
                  </span>
                ))}
              </div>
              <span className={n.quiet ? 'due quiet' : 'due'}>{n.due}</span>
            </div>
          </article>
        ))}
      </div>
      <div
        className="absolute bottom-9 left-[4%] z-[5] grid size-[82px] place-items-center rounded-full stk max-[620px]:bottom-4 max-[620px]:size-[66px]"
        aria-hidden="true"
      >
        <svg
          className="size-[50px] text-accent transition-transform duration-[800ms] ease-[cubic-bezier(.5,0,.3,1)] max-[620px]:size-10"
          style={{ transform: `rotate(${spins * 360}deg)` }}
        >
          <use href="#loop" />
        </svg>
      </div>
      <button
        className="absolute right-[6%] bottom-[30px] z-[5] cursor-pointer rounded-[10px] border-2 border-ink bg-paper px-3 py-2.5 font-mono text-[13px] leading-none font-medium text-ink shadow-sticker-sm transition-[transform,box-shadow,background] duration-[120ms] hover:-translate-px hover:bg-soft hover:shadow-[3px_3px_0_var(--ink)] active:translate-[2px] active:shadow-none max-[620px]:right-[2%] max-[620px]:bottom-[18px]"
        type="button"
        onClick={cycle}
      >
        Bring the next one back
      </button>
    </div>
  );
}

export function Hero() {
  return (
    <section
      className="grid grid-cols-[minmax(0,1.05fr)_minmax(0,0.95fr)] items-center gap-14 pt-10 pb-22 max-[920px]:grid-cols-[minmax(0,1fr)] max-[920px]:gap-8 max-[920px]:pt-6 max-[920px]:pb-16"
      aria-labelledby="hero-h"
    >
      <div className="flex min-w-0 flex-col gap-6">
        <span className="label">Coming soon for iPhone · Free</span>
        <h1
          id="hero-h"
          className="text-[clamp(46px,7.4vw,92px)] leading-[0.92] font-black tracking-[-0.035em] [font-variation-settings:'wdth'_112]"
        >
          Write it down. It comes{' '}
          <span className="bg-[linear-gradient(transparent_60%,var(--hl)_60%,var(--hl)_92%,transparent_92%)] px-[0.04em]">
            back
          </span>
          <Use
            id="loop"
            className="ml-[0.06em] inline-block size-[0.7em] align-[-0.02em] text-accent"
          />
        </h1>
        <p className="max-w-[33em] text-[19px] text-muted">
          Thought Reps is a notebook that hands your ideas back to you. Jot
          something down in five seconds, and{' '}
          <strong className="font-semibold text-ink">
            a week later it&apos;s on your timeline again
          </strong>
          , so the good ones get a second look.
        </p>
        <div className="flex flex-wrap items-center gap-3.5">
          <AppStoreButton />
          <a className="btn ghost" href="#how">
            How it works
          </a>
        </div>
        <p className="mono text-muted">
          No account · Stays on your phone · iOS 18 or later
        </p>
      </div>
      <Deck />
    </section>
  );
}
