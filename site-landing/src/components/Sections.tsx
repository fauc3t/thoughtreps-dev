import { useState } from 'react';
import { useDateFromToday } from '../useDateFromToday';
import { SectionHead, StoreNote, Use } from './shared';
import { WaitlistForm } from './WaitlistForm';

const block = 'border-t-[2.5px] border-ink py-20 max-[620px]:py-[60px]';

const STEPS = [
  {
    n: '1',
    title: 'Write it',
    body: 'Tap + from anywhere. Markdown, photos and #tags all work, and it takes about five seconds.',
    status: 'saved',
  },
  {
    n: '2',
    title: 'Let it go',
    body: 'It stays off your timeline for 7 days, or whatever interval you set for that thought.',
    status: 'in 4 days',
  },
  {
    n: '3',
    title: 'Meet it again',
    body: "It's back on your timeline, marked due. Read it and it heads out for another lap. Archive it when you're done.",
    status: 'due today',
  },
] as const;

export function Why() {
  return (
    <section className={block} id="why" aria-labelledby="why-h">
      <div className="grid grid-cols-[minmax(0,1.5fr)_minmax(0,1fr)] items-end gap-14 max-[920px]:grid-cols-[minmax(0,1fr)] max-[920px]:gap-7">
        <h2
          id="why-h"
          className="text-[clamp(38px,5.6vw,72px)] leading-[0.95] font-black tracking-[-0.035em] [font-variation-settings:'wdth'_112]"
        >
          Most notes apps are where ideas go to be forgotten.
        </h2>
        <p className="text-[19px] leading-[1.6] text-muted">
          For centuries, readers copied lines they loved into notebooks called
          commonplace books, so they would read them again. Saving was never the
          point.{' '}
          <strong className="font-semibold text-ink">Rereading was.</strong>{' '}
          Thought Reps does the &ldquo;again&rdquo; part for you.
        </p>
      </div>
    </section>
  );
}

export function HowItWorks() {
  return (
    <section className={block} id="how" aria-labelledby="how-h">
      <SectionHead
        className="mb-11"
        id="how-h"
        title="Write it once. See it again in a week."
      >
        Thought Reps only shows you what&apos;s due today, and brings the rest
        back on schedule.
      </SectionHead>
      <ol className="m-0 grid list-none grid-cols-3 gap-6 p-0 max-[920px]:grid-cols-[minmax(0,1fr)]">
        {STEPS.map((s, i) => (
          <li key={s.n} className="stk flex min-w-0 flex-col gap-3 p-6">
            <span
              className="grid size-11 place-items-center rounded-full border-[2.5px] border-ink text-[20px] leading-none font-extrabold [font-family:var(--font-display)]"
              aria-hidden="true"
            >
              {s.n}
            </span>
            <h3 className="text-[26px] font-extrabold tracking-[-0.01em] [font-variation-settings:'wdth'_104]">
              {s.title}
            </h3>
            <p className="text-muted">{s.body}</p>
            <div
              className={`mt-1.5 flex items-center justify-between gap-2.5 rounded-xl border-2 px-3.5 py-3 ${
                i === STEPS.length - 1
                  ? 'border-solid border-ink bg-soft'
                  : 'border-dashed border-ink'
              }`}
            >
              <b className="min-w-0 truncate text-[15px] font-semibold">
                Word: petrichor
              </b>
              <span className={i === STEPS.length - 1 ? 'due' : 'mono'}>
                {s.status}
              </span>
            </div>
          </li>
        ))}
      </ol>
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
    <article className={tile}>
      <h3 className={tileTitle}>Blurred answers</h3>
      <p className={tileText}>
        Hide an answer under a blur and quiz yourself when it comes back.
      </p>
      <div className="mt-auto flex flex-col gap-2 rounded-xl border-2 border-ink px-4 py-3.5">
        <div className="flex items-center justify-between gap-2">
          <span className="text-[14px] font-semibold">
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
          className={`text-[15px] leading-[1.45] transition-[filter] duration-[250ms] ${open ? 'blur-none' : 'blur-[7px] select-none'}`}
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
      <div className="grid grid-cols-3 gap-[22px] max-[920px]:grid-cols-2 max-[620px]:grid-cols-[minmax(0,1fr)]">
        <Markdown />
        <BlurredAnswers />
        <Tags />
        <Pinned />
        <Snooze />
        <Rhythm />
        <Nudge />
      </div>
    </section>
  );
}

const check = <path d="M5 12.5l4.5 4.5L19 7.5" />;

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
  const icon = 'mt-0.5 size-[26px]';
  return (
    <section className={block} id="privacy" aria-labelledby="priv-h">
      <div className="grid grid-cols-2 items-start gap-14 max-[920px]:grid-cols-[minmax(0,1fr)] max-[920px]:gap-8">
        <SectionHead id="priv-h" title="Your thoughts stay on your phone.">
          There&apos;s no account and nothing to sign in to. Back it up whenever
          you like, as files you own.{' '}
          <a
            className="font-medium text-ink underline decoration-2 underline-offset-[3px] hover:bg-hl"
            href="/privacy"
          >
            Read the privacy policy
          </a>
        </SectionHead>
        <ul className="m-0 flex list-none flex-col p-0">
          {FACTS.map((f, i) => (
            <li
              key={f.title}
              className={`grid grid-cols-[32px_minmax(0,1fr)] gap-3.5 border-b-2 border-ink py-[18px] ${i === 0 ? 'border-t-2' : ''}`}
            >
              <svg
                className={icon}
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2.2"
                strokeLinecap="round"
                strokeLinejoin="round"
                aria-hidden="true"
              >
                {check}
              </svg>
              <div>
                <b className="block text-[19px] leading-tight font-extrabold [font-family:var(--font-display)] [font-variation-settings:'wdth'_104]">
                  {f.title}
                </b>
                <span className="text-[16px] text-muted">{f.body}</span>
              </div>
            </li>
          ))}
        </ul>
      </div>
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
      <Use
        id="app-icon"
        className="size-32 rounded-[30px] border-[2.5px] border-ink shadow-sticker-lg"
      />
      <h2
        id="get-h"
        className="max-w-[12ch] text-[clamp(40px,7vw,84px)] leading-[0.92] font-black tracking-[-0.035em] [font-variation-settings:'wdth'_112]"
      >
        Start with one thought.
      </h2>
      <p className="text-[18px] text-muted">
        {fmt ? (
          <>
            See it again on <span className="mono">{fmt(7)}</span>.
          </>
        ) : (
          'See it again next week.'
        )}
      </p>
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
