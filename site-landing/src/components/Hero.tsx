import { useEffect, useState } from 'react';
import type { MouseEvent } from 'react';
import { useWaitlistJoined } from '../waitlistStore';
import { StoreNote, ThemeToggle, Use } from './shared';
import { WaitlistForm } from './WaitlistForm';

const WAITLIST_INPUT_ID = 'waitlist-email';

function focusWaitlist(e: MouseEvent<HTMLAnchorElement>) {
  const input = document.getElementById(WAITLIST_INPUT_ID);
  if (!input) return;
  e.preventDefault();
  input.scrollIntoView({ block: 'center' });
  input.focus({ preventScroll: true });
}

export function Nav({
  base = '',
  helpCurrent = false,
}: {
  base?: string;
  helpCurrent?: boolean;
}) {
  const joined = useWaitlistJoined();
  const link =
    'rounded-[10px] border-2 border-transparent px-3 py-2 text-[15px] font-medium no-underline transition-[border-color,background] duration-[120ms] hover:border-ink hover:bg-soft aria-[current=page]:border-ink aria-[current=page]:bg-soft';
  const hideOnPhone = 'max-[680px]:hidden';
  return (
    <header className="flex items-center justify-between gap-3 py-[18px]">
      <a
        className="flex items-center gap-2.5 whitespace-nowrap text-[19px] leading-none font-extrabold tracking-[-0.01em] no-underline [font-family:var(--font-display)] [font-variation-settings:'wdth'_108]"
        href={base || '#top'}
        aria-label="Thought Reps home"
      >
        <Use
          id="app-icon"
          className="size-[38px] shrink-0 rounded-[10px] border-2 border-ink shadow-sticker-sm"
        />
        Thought Reps
      </a>
      <nav className="flex items-center gap-1.5" aria-label="Page">
        <a className={`${link} ${hideOnPhone}`} href={`${base}#how`}>
          How it works
        </a>
        <a className={`${link} ${hideOnPhone}`} href={`${base}#features`}>
          Features
        </a>
        <a className={`${link} ${hideOnPhone}`} href="/privacy">
          Privacy
        </a>
        <a
          className={`${link} ${hideOnPhone}`}
          href="/help"
          aria-current={helpCurrent ? 'page' : undefined}
        >
          Help
        </a>
        <ThemeToggle />
        {joined ? (
          <span className="rounded-[10px] border-2 border-ink bg-soft px-3 py-2 text-[15px] font-medium whitespace-nowrap">
            <span className="max-[480px]:hidden">You&apos;re on the list</span>
            <span className="min-[481px]:hidden">On the list</span>
          </span>
        ) : (
          <a
            className="rounded-[10px] border-2 border-ink px-3 py-2 text-[15px] font-medium whitespace-nowrap no-underline shadow-sticker-sm transition-[border-color,background] duration-[120ms] hover:bg-accent hover:text-accent-ink"
            href={`${base}#${WAITLIST_INPUT_ID}`}
            onClick={focusWaitlist}
          >
            Join<span className="max-[480px]:hidden"> the</span> waitlist
          </a>
        )}
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
      className="relative h-[420px] min-w-0 min-[921px]:col-start-2 min-[921px]:row-span-4 min-[921px]:row-start-1 max-[920px]:row-start-2 max-[920px]:h-[380px] max-[620px]:h-[310px]"
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
            aria-hidden={pos[i] === 0 ? undefined : true}
            inert={pos[i] !== 0}
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
        className="absolute bottom-9 left-[4%] z-[5] grid size-[82px] place-items-center rounded-full stk max-[620px]:hidden"
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
        className="absolute right-[6%] bottom-[30px] z-[5] cursor-pointer rounded-[10px] border-2 border-ink bg-paper px-3 py-2.5 font-mono text-[13px] leading-none font-medium text-ink shadow-sticker-sm transition-[transform,box-shadow,background] duration-[120ms] hover:-translate-px hover:bg-soft hover:shadow-[3px_3px_0_var(--ink)] active:translate-[2px] active:shadow-none max-[620px]:right-[2%] max-[620px]:bottom-1"
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
      className="grid grid-cols-[minmax(0,1.05fr)_minmax(0,0.95fr)] grid-rows-[1fr_auto_auto_1fr] gap-x-14 gap-y-6 pt-10 pb-22 max-[920px]:grid-cols-[minmax(0,1fr)] max-[920px]:grid-rows-none max-[920px]:gap-y-5 max-[920px]:pt-6 max-[920px]:pb-16"
      aria-labelledby="hero-h"
    >
      <h1
        id="hero-h"
        className="col-start-1 row-start-2 min-w-0 text-[clamp(40px,7.4vw,92px)] leading-[0.92] min-[921px]:text-[clamp(46px,5vw,64px)] font-black tracking-[-0.035em] [font-variation-settings:'wdth'_112] max-[920px]:row-start-1"
      >
        Write it down.{' '}
        <span className="block">
          It comes{' '}
          <span className="[box-decoration-break:clone] bg-[linear-gradient(transparent_60%,var(--hl)_60%,var(--hl)_92%,transparent_92%)] px-[0.04em]">
            back
          </span>
          <Use
            id="loop"
            className="ml-[0.06em] inline-block size-[0.7em] align-[-0.02em] text-accent"
          />
        </span>
      </h1>
      <div className="col-start-1 row-start-3 flex min-w-0 flex-col gap-5 max-[920px]:row-start-3">
        <p className="max-w-[33em] text-[20px] leading-[1.5] text-muted max-[620px]:text-[18px]">
          Thought Reps is a notebook that hands your ideas back to you. Jot
          something down in five seconds, and{' '}
          <strong className="font-semibold text-ink">
            a week later it&apos;s on your timeline again
          </strong>
          , so the good ones get a second look.
        </p>
        <WaitlistForm
          inputId={WAITLIST_INPUT_ID}
          hint="$6.99 once · No subscription · No account · Your email is deleted after launch"
        />
        <StoreNote detail="iOS 18+" />
      </div>
      <Deck />
    </section>
  );
}
