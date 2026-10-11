import { useState } from 'react';
import type { CSSProperties } from 'react';
import { useDateFromToday } from '../useDateFromToday';
import { SectionHead, StoreNote, Use } from './shared';
import { WaitlistForm } from './WaitlistForm';

const block = 'border-t-[2.5px] border-ink py-20 max-[620px]:py-[60px]';

const STEPS = [
  {
    f: 0,
    title: 'Write it',
    body: 'Tap + from anywhere. Markdown, photos and #tags all work, and it takes about five seconds.',
    status: 'saved',
  },
  {
    f: 0.5,
    title: 'Let it go',
    body: 'It stays off your timeline for 7 days, or whatever interval you set for that thought.',
    status: 'in 4 days',
  },
  {
    f: 1,
    title: 'Meet it again',
    body: "It's back on your timeline, marked due. Read it and it heads out for another lap. Archive it when you're done.",
    status: 'due today',
  },
] as const;

const displayHead =
  "text-[clamp(40px,8.4vw,96px)] leading-[0.95] font-black tracking-[-0.035em] [font-variation-settings:'wdth'_112]";

export function Why() {
  const lead = 'max-w-[65ch] text-[20px] leading-[1.6] max-[620px]:text-[18px]';
  return (
    <section
      className="band my-10 bg-ink py-[clamp(96px,14vw,184px)] text-paper"
      id="why"
      aria-labelledby="why-h"
    >
      <div className="mx-auto max-w-[1172px] px-4">
        <h2
          id="why-h"
          className="max-w-[18ch] text-[clamp(34px,5vw,72px)] leading-[1] font-black tracking-[-0.035em] [font-variation-settings:'wdth'_112]"
        >
          Notes apps are where ideas get forgotten.
        </h2>
        <p className={`${lead} mt-14 max-[620px]:mt-10`}>
          For centuries, readers copied lines they loved into notebooks called
          commonplace books, so they would read them again. Saving was never the
          point.
        </p>
        <p className="mt-10 text-[clamp(44px,6.4vw,80px)] leading-[0.95] font-black tracking-[-0.035em] [font-variation-settings:'wdth'_112] max-[620px]:mt-8">
          <strong className="font-black">Rereading was.</strong>
          <Use
            id="loop"
            className="ml-[0.1em] inline-block size-[0.6em] align-[-0.02em]"
          />
        </p>
        <p className={`${lead} mt-10 max-[620px]:mt-8`}>
          Thought Reps does the &ldquo;again&rdquo; part for you.
        </p>
      </div>
    </section>
  );
}

function CardFace({
  status,
  className = '',
}: {
  status: (typeof STEPS)[number]['status'];
  className?: string;
}) {
  const due = status === 'due today';
  return (
    <div className={`tl-face ${due ? 'tl-face-due' : ''} ${className}`}>
      <b className="text-[15px] font-semibold">Word: petrichor</b>
      <span className={due ? 'due' : 'mono text-muted'}>{status}</span>
    </div>
  );
}

const DAYS = [0, 1, 2, 3, 4, 5, 6, 7] as const;
const fraction = (f: number) => ({ '--f': f }) as CSSProperties;

export function HowItWorks() {
  return (
    <section
      className="py-20 max-[620px]:py-[60px]"
      id="how"
      aria-labelledby="how-h"
    >
      <SectionHead
        className="mb-14"
        id="how-h"
        title="Write it once. See it again in a week."
      >
        Thought Reps only shows you what&apos;s due today, and brings the rest
        back on schedule.
      </SectionHead>
      <div className="tl">
        <div className="tl-lane" aria-hidden="true">
          <div className="tl-card tl-moving">
            <CardFace status="saved" className="tl-f1" />
            <CardFace status="in 4 days" className="tl-f2" />
            <CardFace status="due today" className="tl-f3" />
          </div>
          {STEPS.map((s) => (
            <div
              key={s.status}
              className="tl-card tl-static"
              style={fraction(s.f)}
            >
              <CardFace status={s.status} />
            </div>
          ))}
        </div>
        <div className="tl-axis" aria-hidden="true">
          <div className="tl-line" />
          {DAYS.map((d) => (
            <span key={d}>
              <span className="tl-tick" style={fraction(d / 7)} />
              <span className="tl-day" style={fraction(d / 7)}>
                Day {d}
              </span>
            </span>
          ))}
        </div>
        <ol className="tl-steps m-0 list-none">
          {STEPS.map((s) => (
            <li key={s.title} className="flex min-w-0 flex-col gap-2">
              <h3 className="text-[26px] font-extrabold tracking-[-0.01em] [font-variation-settings:'wdth'_104] max-[639px]:text-[22px]">
                {s.title}
              </h3>
              <span
                className={`mono ${s.status === 'due today' ? 'text-ink' : 'text-muted'}`}
              >
                {s.status}
              </span>
              <p className="text-muted">{s.body}</p>
            </li>
          ))}
        </ol>
      </div>
    </section>
  );
}

const tile = 'stk flex min-w-0 flex-col gap-3.5 p-6';
const tileTitle =
  "text-[23px] font-extrabold tracking-[-0.01em] [font-variation-settings:'wdth'_104]";
const tileText = 'text-[16px] text-muted';

function Markdown() {
  return (
    <article className={`${tile} col-span-2 max-[620px]:col-auto`}>
      <h3 className={tileTitle}>Markdown and photos</h3>
      <p className={tileText}>
        Headings, lists, quotes and images. It looks tidy when it comes back.
      </p>
      <div className="mt-auto grid grid-cols-2 gap-3.5 max-xs:grid-cols-[minmax(0,1fr)]">
        <pre
          className="m-0 min-w-0 rounded-xl bg-soft p-3.5 font-mono text-[13px] leading-[1.7] break-words whitespace-pre-wrap"
          aria-label="Markdown source"
        >
          <i className="text-muted not-italic">#</i> Word: petrichor{'\n'}
          <i className="text-muted not-italic">-</i>{' '}
          <i className="text-muted not-italic">**</i>noun
          <i className="text-muted not-italic">**</i> the smell of rain on dry
          earth{'\n'}
          <i className="text-muted not-italic">&gt;</i> The petrichor hit before
          the first drop.{'\n'}
          <i className="text-muted not-italic">![](</i>storm
          <i className="text-muted not-italic">)</i>
          {'\n'}
          #words #study
        </pre>
        <div
          className="flex min-w-0 flex-col gap-1.5 rounded-xl border-2 border-ink p-3.5 text-[14.5px] leading-normal"
          aria-label="Rendered"
        >
          <b className="text-[17px] leading-[1.2] font-extrabold [font-family:var(--font-display)]">
            Word: petrichor
          </b>
          <ul className="m-0 pl-[18px]">
            <li>
              <strong>noun</strong> the smell of rain on dry earth
            </li>
          </ul>
          <blockquote className="m-0 border-l-[3px] border-ink pl-2.5 text-muted">
            The petrichor hit before the first drop.
          </blockquote>
          <div className="grid h-[46px] place-items-center rounded-lg border-2 border-dashed border-ink font-mono text-[12px] text-muted">
            storm.heic
          </div>
        </div>
      </div>
    </article>
  );
}

function BlurredAnswers() {
  const [open, setOpen] = useState(false);
  return (
    <article
      className={`${tile} col-span-2 row-span-2 gap-5 p-8 max-[920px]:row-span-1 max-[620px]:col-auto max-[620px]:p-6`}
    >
      <h3 className="text-[clamp(30px,4.4vw,48px)] leading-none font-extrabold tracking-[-0.02em] [font-variation-settings:'wdth'_110]">
        Blurred answers
      </h3>
      <p className="max-w-[40ch] text-[18px] text-muted">
        Hide an answer under a blur and quiz yourself when it comes back.
      </p>
      <div className="mt-auto flex flex-col gap-4 rounded-xl border-2 border-ink px-5 py-5 min-[921px]:flex-1 min-[921px]:justify-center">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <span className="text-[clamp(18px,2.2vw,24px)] leading-tight font-bold">
            Quiz: what does <i>sonder</i> mean?
          </span>
          <button
            className="small-btn"
            type="button"
            aria-expanded={open}
            aria-controls="answer"
            onClick={() => setOpen(!open)}
          >
            {open ? 'Hide' : 'Reveal'}
          </button>
        </div>
        <p
          id="answer"
          className={`text-[clamp(20px,2.6vw,30px)] leading-[1.3] font-semibold transition-[filter] duration-[250ms] ${open ? 'blur-none' : 'blur-[9px] select-none'}`}
        >
          The feeling that every stranger has a life as vivid as your own.
        </p>
      </div>
    </article>
  );
}

function Tags() {
  const rows = [
    { tag: '#quotes', due: '2 due', total: 14 },
    { tag: '#toread', due: '1 due', total: 6 },
    { tag: '#words', due: '0 due', total: 9 },
  ];
  return (
    <article className={tile}>
      <h3 className={tileTitle}>#tags</h3>
      <p className={tileText}>
        Type #anything. Every tag gets its own timeline.
      </p>
      <ul className="m-0 mt-auto flex list-none flex-col gap-2 p-0">
        {rows.map((r) => (
          <li
            key={r.tag}
            className="flex items-center justify-between gap-2.5 font-mono text-[13px] text-muted tabular-nums"
          >
            <span className="chip">{r.tag}</span>
            <span>
              {r.due.startsWith('0') ? (
                r.due
              ) : (
                <b className="font-medium text-accent">{r.due}</b>
              )}{' '}
              · {r.total}
            </span>
          </li>
        ))}
      </ul>
    </article>
  );
}

function Pinned() {
  return (
    <article className={tile}>
      <h3 className={tileTitle}>Pin the keepers</h3>
      <p className={tileText}>Pinned thoughts stay at the top every day.</p>
      <div className="mt-auto flex flex-col gap-1 rounded-xl border-2 border-ink px-4 py-3.5">
        <div className="flex items-center justify-between gap-2 font-semibold">
          What makes a good day
          <svg
            width="18"
            height="18"
            viewBox="0 0 24 24"
            fill="currentColor"
            stroke="currentColor"
            strokeWidth="1.6"
            strokeLinejoin="round"
            aria-label="Pinned"
            role="img"
          >
            <path d="M9 3h6l-1 6 4 4H6l4-4z" />
            <path d="M12 13v8" fill="none" />
          </svg>
        </div>
        <span className="text-[14px] text-muted">
          Walk before screens. Cook something. Text a friend.
        </span>
      </div>
    </article>
  );
}

function Snooze() {
  const fmt = useDateFromToday();
  const [result, setResult] = useState<'archive' | number | null>(null);
  const snooze = [
    { label: 'Snooze 1 day', value: 1 },
    { label: 'Snooze 1 week', value: 7 },
  ];
  return (
    <article className={tile}>
      <h3 className={tileTitle}>Snooze or archive</h3>
      <p className={tileText}>
        Not today? Push it back. Done with it? Archive it. Search still finds
        anything you&apos;ve written, even archived.
      </p>
      <div className="mt-auto">
        <div
          className="flex flex-wrap gap-3"
          role="group"
          aria-label="What to do with this thought"
        >
          {snooze.map((s) => (
            <button
              key={s.value}
              className="small-btn"
              type="button"
              onClick={() => setResult(s.value)}
            >
              {s.label}
            </button>
          ))}
          <button
            className="small-btn"
            type="button"
            onClick={() => setResult('archive')}
          >
            Archive
          </button>
        </div>
        <p
          className="mt-3 min-h-[1.4em] font-mono text-[13px] text-muted"
          aria-live="polite"
        >
          {result === null ? (
            <>
              Read later: slow email ·{' '}
              <b className="font-medium text-accent">due today</b>
            </>
          ) : result === 'archive' ? (
            'Archived · restore it any time'
          ) : (
            <>
              Snoozed · back on{' '}
              <b className="font-medium text-accent">
                {fmt ? fmt(result) : `in ${result === 1 ? '1 day' : '1 week'}`}
              </b>
            </>
          )}
        </p>
      </div>
    </article>
  );
}

function Rhythm() {
  const fmt = useDateFromToday();
  const [days, setDays] = useState(7);
  return (
    <article className={`${tile} col-span-2 max-[620px]:col-auto`}>
      <h3 className={tileTitle}>Your own rhythm</h3>
      <p className={tileText}>
        Every 7 days by default. Memorizing something? Bring it back tomorrow.
        Slow-burn idea? Next month.
      </p>
      <div className="mt-auto">
        <div
          className="inline-flex flex-wrap gap-x-1.5 gap-y-3"
          role="group"
          aria-label="Bring this thought back every"
        >
          {[1, 3, 7, 30].map((n) => (
            <button
              key={n}
              className="small-btn"
              type="button"
              aria-pressed={days === n}
              onClick={() => setDays(n)}
            >
              {n === 1 ? '1 day' : `${n} days`}
            </button>
          ))}
        </div>
        <p className="mt-3 font-mono text-[14px] text-muted" aria-live="polite">
          Read today · back {fmt ? 'on' : 'in'}{' '}
          <b className="font-medium text-ink">
            {fmt ? fmt(days) : `${days} days`}
          </b>
        </p>
      </div>
    </article>
  );
}

function Nudge() {
  return (
    <article className={tile}>
      <h3 className={tileTitle}>One nudge a day</h3>
      <p className={tileText}>
        Pick a time. If nothing is due, you won&apos;t hear from it.
      </p>
      <div
        className="mt-auto flex items-center gap-3 rounded-2xl border-2 border-ink bg-paper px-3.5 py-3"
        role="img"
        aria-label="Notification at 8:00 AM: 4 thoughts are back today."
      >
        <Use
          id="app-icon"
          className="size-10 flex-none rounded-[10px] border-2 border-ink"
        />
        <div className="min-w-0 flex-1">
          <div className="flex justify-between gap-2 font-mono text-[12px] text-muted">
            <span>THOUGHT REPS</span>
            <span>8:00 AM</span>
          </div>
          <div className="text-[15px] font-semibold">
            4 thoughts are back today.
          </div>
        </div>
      </div>
    </article>
  );
}

export function Features() {
  return (
    <section className={block} id="features" aria-labelledby="feat-h">
      <SectionHead
        className="mb-11"
        id="feat-h"
        title="Small app. Everything a thought needs."
      />
      <div className="grid grid-flow-dense grid-cols-3 gap-[22px] max-[920px]:grid-cols-2 max-[620px]:grid-cols-[minmax(0,1fr)]">
        <BlurredAnswers />
        <Tags />
        <Pinned />
        <Markdown />
        <Snooze />
        <Rhythm />
        <Nudge />
      </div>
    </section>
  );
}

const FACTS = [
  { title: 'No account', body: 'Open the app and start writing.' },
  {
    title: 'Stored on your iPhone',
    body: 'Text and images stay in the app, on your device.',
  },
  {
    title: 'Back up any time',
    body: 'Save everything to a .thoughtreps file, or move to a new phone with a one-time link.',
  },
  {
    title: 'For your eyes only',
    body: "Send an export to another device and it's encrypted on your iPhone first. Only your link can open it, not even us.",
  },
];

export function Privacy() {
  return (
    <section className={block} id="privacy" aria-labelledby="priv-h">
      <h2
        id="priv-h"
        className="text-[clamp(36px,5.4vw,64px)] leading-[1] font-black tracking-[-0.035em] [font-variation-settings:'wdth'_112]"
      >
        <span className="block">No account.</span>
        <span className="block">No trackers.</span>
        <span className="block">Just your phone.</span>
      </h2>
      <p className="mt-10 max-w-[65ch] text-[18px] leading-[1.55] text-muted">
        There&apos;s no account and nothing to sign in to. Back it up whenever
        you like, as files you own.{' '}
        <a
          className="font-medium text-ink underline decoration-2 underline-offset-[3px] hover:bg-hl"
          href="/privacy"
        >
          Read the privacy policy
        </a>
      </p>
      <ul className="m-0 mt-12 grid list-none grid-cols-4 gap-x-8 gap-y-8 p-0 max-[1023px]:grid-cols-2 max-[620px]:grid-cols-[minmax(0,1fr)]">
        {FACTS.map((f) => (
          <li key={f.title} className="flex flex-col gap-2">
            <b className="font-mono text-[14px] leading-tight font-medium tracking-[0.02em]">
              {f.title}
            </b>
            <span className="text-[16px] leading-normal text-muted">
              {f.body}
            </span>
          </li>
        ))}
      </ul>
    </section>
  );
}

export function FinalCta() {
  const fmt = useDateFromToday();
  return (
    <section
      className="flex flex-col items-center gap-[26px] border-t-[2.5px] border-ink pt-24 pb-20 text-center"
      id="get"
      aria-labelledby="get-h"
    >
      <h2 id="get-h" className={displayHead}>
        Write one today.
      </h2>
      <div
        className="stk my-4 flex w-[min(380px,100%)] -rotate-2 flex-col gap-10 p-6 text-left shadow-sticker-lg"
        aria-hidden="true"
      >
        <p className="text-[28px] leading-[1.1] font-extrabold tracking-[-0.01em] [font-variation-settings:'wdth'_100]">
          Your first thought
        </p>
        <div className="flex flex-wrap gap-2">
          <span className="chip">written today</span>
          <span className="chip">{`back ${fmt ? fmt(7) : 'next week'}`}</span>
        </div>
      </div>
      <WaitlistForm />
      <StoreNote />
    </section>
  );
}

export function Footer({ base = '' }: { base?: string }) {
  const link = 'no-underline hover:text-ink hover:underline';
  return (
    <footer className="flex flex-wrap justify-between gap-4 border-t-[2.5px] border-ink pt-6 pb-10 font-mono text-[13px] text-muted">
      <span suppressHydrationWarning>
        {`© ${new Date().getFullYear()} Thought Reps LLC`}
      </span>
      <nav className="flex flex-wrap gap-4" aria-label="Footer">
        <a className={link} href={`${base}#how`}>
          How it works
        </a>
        <a className={link} href={`${base}#features`}>
          Features
        </a>
        <a className={link} href="/privacy">
          Privacy
        </a>
        <a className={link} href="/help">
          Help
        </a>
        <a className={link} href="/blog">
          Blog
        </a>
        <a className={link} href="/support">
          Support
        </a>
        <a className={link} href="/third-party-licenses.txt">
          Licenses
        </a>
        <a className={link} href="mailto:hello@thoughtreps.com">
          hello@thoughtreps.com
        </a>
      </nav>
    </footer>
  );
}
