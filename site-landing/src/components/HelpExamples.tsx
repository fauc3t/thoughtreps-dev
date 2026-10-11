import type { ReactNode } from 'react';
import type {
  HelpExample,
  HelpExampleKind,
  HelpIconName,
} from '../content/help';
import { IconGlyph } from './HelpIcons';
import { Use } from './shared';

// Static mockups of the app, in the landing's card style. Every label and state
// here is copied from the Swift views; the thoughts are made-up everyday notes.

const panel = 'rounded-xl border-2 border-ink bg-paper';
const rows = 'divide-y-2 divide-hl';
const screenTitle =
  'text-[22px] leading-none font-black [font-family:var(--font-display)]';
const menuItem =
  'flex items-center justify-between gap-3 px-3.5 py-2.5 text-[15px]';
const caret =
  'ml-0.5 inline-block h-[1.1em] w-0.5 translate-y-[0.2em] bg-ink align-baseline';

function IconButton({ name }: { name: HelpIconName }) {
  return (
    <span className="grid size-8 shrink-0 place-items-center rounded-[9px] border-2 border-ink bg-paper">
      <IconGlyph name={name} className="size-4" />
    </span>
  );
}

function Status({ text, hot = false }: { text: string; hot?: boolean }) {
  return <span className={hot ? 'due' : 'due quiet'}>{text}</span>;
}

interface RowProps {
  title: string;
  preview?: ReactNode;
  tags?: string[];
  status?: { text: string; hot?: boolean };
  pinned?: boolean;
  thumb?: boolean;
}

function ThoughtRow({
  title,
  preview,
  tags = [],
  status,
  pinned = false,
  thumb = false,
}: RowProps) {
  return (
    <div className="flex min-w-0 items-start gap-3 p-3">
      <div className="flex min-w-0 flex-1 flex-col gap-1.5">
        <div className="flex items-baseline justify-between gap-2">
          <b className="line-clamp-2 text-[15px] leading-snug [overflow-wrap:anywhere]">
            {title}
          </b>
          {pinned && <IconGlyph name="pin" className="size-3.5" />}
        </div>
        {preview && (
          <p className="line-clamp-2 text-[13.5px] leading-snug text-muted">
            {preview}
          </p>
        )}
        <div className="flex flex-wrap items-center justify-between gap-x-2 gap-y-1.5">
          <span className="flex flex-wrap gap-1.5">
            {tags.map((tag) => (
              <span key={tag} className="chip">
                {tag}
              </span>
            ))}
          </span>
          {status && !pinned && <Status {...status} />}
        </div>
      </div>
      {thumb && (
        <span className="grid size-14 shrink-0 place-items-center rounded-[10px] border-2 border-ink bg-hl text-muted">
          <IconGlyph name="photo" className="size-5" />
        </span>
      )}
    </div>
  );
}

function ListLabel({ children }: { children: string }) {
  return <span className="label block px-3 pt-3">{children}</span>;
}

const QUOTE_ROW: RowProps = {
  title: 'One wild and precious life',
  preview:
    '“Tell me, what is it you plan to do with your one wild and precious life?”',
  tags: ['#quotes'],
  status: { text: 'due 2d ago', hot: true },
};

const REVIEW_ROW: RowProps = {
  title: 'Weekly review questions',
  preview: 'What did I learn? What will I drop?',
  tags: ['#weekly'],
  pinned: true,
};

function Loop() {
  const steps = [
    {
      name: '1 · Write',
      body: 'Word of the day: petrichor',
      note: 'few seconds',
    },
    { name: '2 · Wait', body: 'It leaves your timeline', note: '7 days' },
    {
      name: '3 · Meet it again',
      body: 'Back on your timeline',
      note: 'due today',
      hot: true,
    },
  ];
  return (
    <div className="grid gap-2.5 xs:grid-cols-3">
      {steps.map((step) => (
        <div
          key={step.name}
          className={`${panel} flex min-w-0 flex-col gap-2 p-3`}
        >
          <span className="label">{step.name}</span>
          <span className="text-[14.5px] leading-snug font-semibold">
            {step.body}
          </span>
          <Status text={step.note} hot={step.hot} />
        </div>
      ))}
    </div>
  );
}

const FORMAT_BAR: HelpIconName[] = [
  'heading',
  'bold',
  'italic',
  'list',
  'checklist',
  'code',
  'tag',
  'photo',
  'block',
];

function Editor() {
  return (
    <div className={panel}>
      <div className="flex items-center justify-between gap-2 border-b-2 border-hl px-3 py-2.5 text-[14px]">
        <span className="text-muted">Cancel</span>
        <b>New thought</b>
        <span className="rounded-lg bg-ink px-2.5 py-1 font-semibold text-paper">
          Save
        </span>
      </div>
      <div className="px-3 py-3 text-[15px] leading-relaxed">
        <p className="text-[19px] leading-tight font-bold">
          Word of the day: petrichor
        </p>
        <p>
          The smell of <span className="text-muted">**</span>rain
          <span className="text-muted">**</span> on dry ground.{' '}
          <span className="font-semibold">#words</span>
          <span className={caret} />
        </p>
      </div>
      <p className="px-3 pb-3 text-[12.5px] text-muted">Tags: #words</p>
      <div className="flex items-center justify-between gap-3 border-t-2 border-hl px-3 py-2.5 text-[14px]">
        <span>Comes back every</span>
        <span className="font-semibold">Default (7 days)</span>
      </div>
      <div className="flex flex-wrap gap-1 border-t-2 border-hl p-2">
        {FORMAT_BAR.map((name) => (
          <IconButton key={name} name={name} />
        ))}
      </div>
    </div>
  );
}

function ThoughtStates() {
  const states = [
    {
      name: 'Waiting',
      note: 'Not on the Timeline yet',
      row: { title: 'Why is the sky blue?', status: { text: 'in 5 days' } },
      dashed: true,
    },
    {
      name: 'Due',
      note: 'On the Timeline',
      row: {
        title: 'Read: how bees see color',
        status: { text: 'due today', hot: true },
      },
    },
    {
      name: 'Pinned',
      note: 'Always at the top',
      row: { title: 'Weekly review questions', pinned: true },
    },
    {
      name: 'Archived',
      note: 'In the Archive tab',
      row: { title: 'Packing list for Lisbon', status: { text: 'Archived' } },
      dashed: true,
    },
  ];
  return (
    <div className="grid gap-2.5 xs:grid-cols-2">
      {states.map((state) => (
        <div key={state.name} className="flex min-w-0 flex-col gap-1.5">
          <span className="label">{state.name}</span>
          <div
            className={`${panel} ${state.dashed ? 'border-dashed' : ''} min-w-0 flex-1`}
          >
            <ThoughtRow {...state.row} />
          </div>
          <span className="text-[13px] text-muted">{state.note}</span>
        </div>
      ))}
    </div>
  );
}

function Timeline() {
  return (
    <div className={`${panel} relative pb-[72px]`}>
      <div className="flex items-center justify-between gap-2 px-3 pt-3">
        <span className={screenTitle}>Timeline</span>
        <span className="flex gap-1.5">
          <IconButton name="search" />
          <IconButton name="settings" />
        </span>
      </div>
      <ListLabel>Pinned</ListLabel>
      <ThoughtRow {...REVIEW_ROW} />
      <ListLabel>Due</ListLabel>
      <div className={rows}>
        <ThoughtRow {...QUOTE_ROW} />
        <ThoughtRow
          title="Read: how bees see color"
          preview="Saved from Safari."
          tags={['#toread']}
          status={{ text: 'due today', hot: true }}
        />
      </div>
      <span className="absolute right-3 bottom-3 grid size-[52px] place-items-center rounded-full border-2 border-ink bg-ink text-paper shadow-sticker-sm">
        <IconGlyph name="plus" className="size-6" />
      </span>
    </div>
  );
}

function ThoughtCard() {
  return (
    <div className={`${panel} ${rows}`}>
      <ThoughtRow {...QUOTE_ROW} thumb />
      <ThoughtRow {...REVIEW_ROW} />
    </div>
  );
}

function Match({ children }: { children: string }) {
  return <b className="font-bold text-ink">{children}</b>;
}

function SearchResults() {
  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-center gap-2 rounded-xl border-2 border-ink bg-paper px-3 py-2.5 text-[15px]">
        <IconGlyph name="search" className="size-4 text-muted" />
        <span>
          reflec
          <span className={caret} />
        </span>
      </div>
      <div className="grid grid-cols-3 rounded-[10px] border-2 border-ink bg-paper p-0.5 text-center text-[13px] font-semibold">
        <span className="rounded-lg bg-ink py-1 text-paper">Active</span>
        <span className="py-1">Archived</span>
        <span className="py-1">All</span>
      </div>
      <div className={`${panel} ${rows}`}>
        <ThoughtRow
          title="Notes on reflection"
          preview={
            <>
              …a short habit of <Match>reflection</Match> each evening…
            </>
          }
          tags={['#journal']}
          status={{ text: 'Due', hot: true }}
        />
        <ThoughtRow
          title="Weekly review questions"
          preview={
            <>
              Take a minute for <Match>reflection</Match> on the week…
            </>
          }
          tags={['#weekly']}
          pinned
        />
        <ThoughtRow
          title="Why journals work"
          preview={
            <>
              …writing builds <Match>reflection</Match> into the day…
            </>
          }
          tags={['#journal']}
          status={{ text: 'Back in 3 days' }}
        />
      </div>
    </div>
  );
}

function FormatBar() {
  return (
    <div className="flex flex-col gap-3">
      <div className={`${panel} flex flex-wrap gap-1 p-1.5`}>
        {FORMAT_BAR.map((name) => (
          <span
            key={name}
            className={`grid size-8 shrink-0 place-items-center rounded-[9px] ${name === 'bold' ? 'bg-ink text-paper' : ''}`}
          >
            <IconGlyph name={name} className="size-4" />
          </span>
        ))}
      </div>
      <div className="flex flex-wrap items-center gap-2 text-[14px]">
        <span className="chip">petrichor</span>
        <IconGlyph name="bold" className="size-4" />
        <span aria-hidden="true">&rarr;</span>
        <span className="chip [overflow-wrap:anywhere]">**petrichor**</span>
      </div>
    </div>
  );
}

function MarkdownPair() {
  return (
    <div className="grid gap-2.5 xs:grid-cols-2">
      <div className="flex min-w-0 flex-col gap-1.5">
        <span className="label">You type</span>
        <pre
          className={`${panel} m-0 flex-1 p-3 font-mono text-[12.5px] leading-[1.6] [overflow-wrap:anywhere] whitespace-pre-wrap`}
        >
          {
            '# Word: petrichor\n**noun** the smell of rain\n> It hit before the first drop.\n- [ ] use it today\n#words'
          }
        </pre>
      </div>
      <div className="flex min-w-0 flex-col gap-1.5">
        <span className="label">You see</span>
        <div
          className={`${panel} flex flex-1 flex-col gap-1.5 p-3 text-[14.5px] leading-normal`}
        >
          <b className="text-[17px] leading-[1.2] font-extrabold [font-family:var(--font-display)]">
            Word: petrichor
          </b>
          <p>
            <b>noun</b> the smell of rain
          </p>
          <p className="border-l-[3px] border-ink pl-2.5 text-muted">
            It hit before the first drop.
          </p>
          <p className="flex items-center gap-2">
            <span className="size-4 shrink-0 rounded-[4px] border-2 border-ink" />
            use it today
          </p>
          <span className="chip self-start">#words</span>
        </div>
      </div>
    </div>
  );
}

function Gallery() {
  return (
    <div className="flex flex-col gap-2">
      <b className="text-[14px] font-semibold text-muted">Storm photos</b>
      <div className="flex gap-2 overflow-hidden">
        {['w-32', 'w-24', 'w-36'].map((width) => (
          <span
            key={width}
            className={`grid h-28 shrink-0 place-items-center rounded-xl border-2 border-ink bg-hl text-muted ${width}`}
          >
            <IconGlyph name="photo" className="size-6" />
          </span>
        ))}
      </div>
    </div>
  );
}

function BlurredBlock() {
  return (
    <div className="flex flex-col gap-3">
      <p className="text-[15px] font-semibold">
        Word of the day: petrichor. What does it mean?
      </p>
      <label className="group relative block cursor-pointer rounded-[14px] border-2 border-ink bg-paper p-3.5 transition-[transform,box-shadow] duration-150 hover:-translate-px hover:shadow-sticker-sm has-[:focus-visible]:outline-3 has-[:focus-visible]:outline-offset-2 has-[:focus-visible]:outline-accent">
        <input
          type="checkbox"
          className="sr-only"
          aria-label="Reveal the answer"
        />
        <span className="flex items-center justify-between gap-2 text-[14px] font-semibold">
          <span className="text-muted">Answer</span>
          <span className="text-ink underline decoration-2 underline-offset-[3px]">
            <span className="group-has-[:checked]:hidden">Tap to reveal</span>
            <span className="hidden group-has-[:checked]:inline">Hide</span>
          </span>
        </span>
        <span className="mt-2 block text-[15px] leading-[1.45] blur-[7px] transition-[filter] duration-[250ms] select-none group-has-[:checked]:blur-none group-has-[:checked]:select-text">
          The smell of rain on dry ground.
        </span>
      </label>
    </div>
  );
}

function TagList() {
  const tags = [
    { name: '#quotes', due: 2, total: 14 },
    { name: '#toread', due: 1, total: 6 },
    { name: '#words', due: 0, total: 9 },
  ];
  return (
    <div className="flex flex-col gap-3">
      <span className={screenTitle}>Tags</span>
      <div className="flex items-center gap-2 rounded-xl border-2 border-ink bg-paper px-3 py-2 text-[15px] text-muted">
        <IconGlyph name="search" className="size-4" />
        Filter tags
      </div>
      <div className={`${panel} ${rows}`}>
        {tags.map((tag) => (
          <TagRow key={tag.name} {...tag} />
        ))}
      </div>
      <div className={panel}>
        <TagRow name="Untagged" due={0} total={3} />
      </div>
    </div>
  );
}

function TagRow({
  name,
  due,
  total,
}: {
  name: string;
  due: number;
  total: number;
}) {
  return (
    <div className="flex items-center gap-3 px-3 py-3">
      <span className="size-2.5 shrink-0 rounded-full bg-ink" />
      <b className="min-w-0 flex-1 text-[15px] font-medium">{name}</b>
      {due > 0 && (
        <span className="rounded-full bg-hl px-2 py-0.5 text-[12px] font-semibold">
          {due} due
        </span>
      )}
      <span className="text-[14px] text-muted tabular-nums">{total}</span>
    </div>
  );
}

const COLOR_OPTIONS = [
  { name: 'Automatic', fill: '#3352D1' },
  { name: 'Blue', fill: '#3352D1' },
  { name: 'Teal', fill: '#1F8A70' },
  { name: 'Copper', fill: '#B56629' },
  { name: 'Purple', fill: '#7A4FC4' },
  { name: 'Rose', fill: '#BF4066' },
  { name: 'Steel Blue', fill: '#2E80AD' },
  { name: 'Green', fill: '#3F8F3A' },
  { name: 'Slate', fill: '#5F6B7A' },
  {
    name: 'Custom',
    fill: 'conic-gradient(red, yellow, lime, cyan, blue, magenta, red)',
  },
];

function ColorSheet() {
  return (
    <div className={panel}>
      <div className="flex items-center justify-between gap-2 border-b-2 border-hl px-3 py-2.5 text-[14px]">
        <span className="text-muted">Cancel</span>
        <b>Color</b>
        <span className="w-10" />
      </div>
      <div className="grid grid-cols-3 gap-2 p-3 text-center text-[12.5px]">
        {COLOR_OPTIONS.map((option, i) => (
          <span
            key={option.name}
            className="flex flex-col items-center gap-1.5"
          >
            <span
              className="grid size-11 place-items-center rounded-full text-white"
              style={{ background: option.fill }}
            >
              {i === 0 && <IconGlyph name="check" className="size-5" />}
            </span>
            {option.name}
          </span>
        ))}
      </div>
    </div>
  );
}

function ShareSheet() {
  const apps: { name: string; icon?: HelpIconName }[] = [
    { name: 'Notes', icon: 'list' },
    { name: 'Reminders', icon: 'checklist' },
    { name: 'Thought Reps' },
    { name: 'More', icon: 'more' },
  ];
  return (
    <div className="flex flex-col gap-3">
      <div className={`${panel} p-3`}>
        <p className="border-b-2 border-hl pb-3 text-[14px] leading-snug text-muted">
          “The petrichor hit before the first drop.”
        </p>
        <div className="mt-3 grid grid-cols-4 gap-1.5 text-center text-[11.5px] leading-tight">
          {apps.map((app) => (
            <span
              key={app.name}
              className="flex min-w-0 flex-col items-center gap-1.5"
            >
              {app.name === 'Thought Reps' ? (
                <Use
                  id="app-icon"
                  className="size-12 rounded-xl border-2 border-ink shadow-sticker-sm"
                />
              ) : (
                <span className="grid size-12 place-items-center rounded-xl border-2 border-ink bg-soft">
                  {app.icon && <IconGlyph name={app.icon} className="size-5" />}
                </span>
              )}
              <span className={app.name === 'Thought Reps' ? 'font-bold' : ''}>
                {app.name}
              </span>
            </span>
          ))}
        </div>
      </div>
      <div className={panel}>
        <div className="flex items-center justify-between gap-2 border-b-2 border-hl px-3 py-2.5 text-[14px]">
          <span className="text-muted">Cancel</span>
          <b>New Thought</b>
          <span className="rounded-lg bg-ink px-2.5 py-1 font-semibold text-paper">
            Save
          </span>
        </div>
        <div className="px-3 py-3 text-[15px] leading-relaxed">
          <p>The petrichor hit before the first drop.</p>
          <p className="font-mono text-[13px] [overflow-wrap:anywhere]">
            https://example.com/petrichor
          </p>
        </div>
      </div>
    </div>
  );
}

function MenuItem({
  label,
  icon,
  selected,
}: {
  label: string;
  icon?: HelpIconName;
  selected?: boolean;
}) {
  return (
    <div className={menuItem}>
      <span className="flex min-w-0 items-center gap-2">
        {selected !== undefined && (
          <span className="grid size-4 shrink-0 place-items-center">
            {selected && <IconGlyph name="check" className="size-4" />}
          </span>
        )}
        {label}
      </span>
      {icon && <IconGlyph name={icon} className="size-4" />}
    </div>
  );
}

function SnoozeMenu() {
  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-center justify-end gap-3 text-[15px]">
        <IconButton name="pin" />
        <span className="font-semibold">Edit</span>
        <IconButton name="more" />
      </div>
      <div className={`${panel} ml-auto w-full max-w-[17rem]`}>
        <MenuItem label="Snooze until tomorrow" icon="snooze" />
        <MenuItem label="Snooze a week" icon="calendar" />
        <MenuItem label="Archive" icon="archive" />
        <div className="h-2 bg-hl" />
        <MenuItem label="Delete" icon="trash" />
      </div>
    </div>
  );
}

function IntervalMenu() {
  const choices = ['Day', '3 days', 'Week', '2 weeks', 'Month', '3 months'];
  const chip =
    'grid h-9 place-content-center rounded-[10px] text-[13px] font-semibold';
  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-baseline justify-between gap-3 text-[12px] text-muted">
        <span>Back in</span>
        <span>next: Oct 14</span>
      </div>
      <div className="grid grid-cols-5 gap-2">
        {['1d', '3d', '7d', '30d', '…'].map((label) => (
          <span
            key={label}
            className={
              label === '7d'
                ? `${chip} bg-ink text-paper`
                : `${chip} border border-hl bg-paper`
            }
          >
            {label}
          </span>
        ))}
      </div>
      <div className={`${panel} ml-auto w-full max-w-[15rem]`}>
        <MenuItem label="Default (7 days)" selected />
        {choices.map((choice) => (
          <MenuItem key={choice} label={choice} selected={false} />
        ))}
        <div className="h-2 bg-hl" />
        <MenuItem label="Custom…" />
      </div>
    </div>
  );
}

function LearnBar() {
  const button =
    'grid h-12 place-content-center justify-items-center gap-0.5 rounded-[10px] font-mono';
  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-center justify-between gap-3 font-mono text-[12px] text-muted">
        <span>How did it go?</span>
        <span className="flex items-center gap-1.5">
          Learn
          <span className="flex h-4 w-7 items-center justify-end rounded-full bg-ink p-0.5">
            <span className="size-3 rounded-full bg-paper" />
          </span>
        </span>
      </div>
      <div className="grid grid-cols-2 gap-2">
        <span className={`${button} border border-hl bg-paper`}>
          <span className="text-[13px] font-semibold">Again</span>
          <span className="text-[11px] opacity-70">Tomorrow</span>
        </span>
        <span className={`${button} bg-ink text-paper`}>
          <span className="text-[13px] font-semibold">Got it</span>
          <span className="text-[11px] opacity-70">In 12 days</span>
        </span>
      </div>
    </div>
  );
}

function SwipeActions() {
  const action =
    'grid w-[68px] shrink-0 place-content-center justify-items-center gap-1 text-[11.5px] font-semibold';
  return (
    <div className="flex flex-col gap-3">
      <span className="label">Swipe right</span>
      <div className="flex overflow-hidden rounded-xl border-2 border-ink bg-paper">
        <span className={`${action} bg-ink text-paper`}>
          <IconGlyph name="pin" className="size-4" />
          Pin
        </span>
        <div className="min-w-0 flex-1">
          <ThoughtRow {...QUOTE_ROW} preview={undefined} />
        </div>
      </div>
      <span className="label">Swipe left</span>
      <div className="flex overflow-hidden rounded-xl border-2 border-ink bg-paper">
        <div className="min-w-0 flex-1">
          <ThoughtRow {...QUOTE_ROW} preview={undefined} />
        </div>
        <span className={`${action} bg-hl text-ink`}>
          <IconGlyph name="snooze" className="size-4" />
          Tomorrow
        </span>
        <span className={`${action} bg-muted text-paper`}>
          <IconGlyph name="archive" className="size-4" />
          Archive
        </span>
      </div>
    </div>
  );
}

function PinnedArchived() {
  return (
    <div className="grid gap-2.5 xs:grid-cols-2">
      <div className="flex min-w-0 flex-col gap-1.5">
        <span className="label">Timeline</span>
        <div className={`${panel} min-w-0 flex-1`}>
          <ListLabel>Pinned</ListLabel>
          <ThoughtRow {...REVIEW_ROW} />
        </div>
      </div>
      <div className="flex min-w-0 flex-col gap-1.5">
        <span className="label">Archive</span>
        <div className={`${panel} ${rows} min-w-0 flex-1`}>
          <div className="flex flex-col gap-1 p-3">
            <b className="text-[15px] leading-snug">Packing list for Lisbon</b>
            <span className="text-[12.5px] text-muted">Archived Oct 3</span>
          </div>
          <div className="flex flex-col gap-1 p-3">
            <b className="text-[15px] leading-snug">Old reading list</b>
            <span className="text-[12.5px] text-muted">Archived Sep 21</span>
          </div>
        </div>
      </div>
    </div>
  );
}

function Notification() {
  return (
    <div className="mx-auto flex w-full max-w-sm items-center gap-3 rounded-[18px] border-2 border-ink bg-paper p-3 shadow-sticker-sm">
      <Use
        id="app-icon"
        className="size-10 shrink-0 rounded-[10px] border-2 border-ink"
      />
      <div className="min-w-0 flex-1 text-[14.5px] leading-snug">
        <b className="block">Thought Reps</b>
        <span className="block">3 thoughts are back today</span>
      </div>
      <span className="self-start text-[12px] text-muted">now</span>
    </div>
  );
}

function SettingRow({ icon, label }: { icon: HelpIconName; label: string }) {
  return (
    <div className="flex items-center gap-3 px-3 py-3 text-[15px]">
      <IconGlyph name={icon} className="size-[18px]" />
      <span className="min-w-0 [overflow-wrap:anywhere]">{label}</span>
    </div>
  );
}

function SettingsBackup() {
  return (
    <div className="flex flex-col gap-2">
      <span className="label">Backup</span>
      <div className={`${panel} ${rows}`}>
        <SettingRow icon="share" label="Export…" />
        <SettingRow icon="import" label="Import…" />
        <SettingRow icon="link" label="Share export as link" />
      </div>
      <p className="text-[12.5px] leading-snug text-muted">
        Exports every thought, tag and image to one file. Importing adds
        what&apos;s missing and keeps the newer version of a thought you already
        have.
      </p>
    </div>
  );
}

function ExportLink() {
  return (
    <div className={`${panel} ${rows}`}>
      <SettingRow icon="link" label="Share export as link" />
      <div className="flex flex-col gap-1 px-3 py-3">
        <span className="line-clamp-3 font-mono text-[12.5px] leading-snug [overflow-wrap:anywhere]">
          https://transfer.thoughtreps.com/x/Gh4mT9…#kB8w2Q…
        </span>
        <span className="text-[12.5px] text-muted">
          Expires tomorrow at 9:41 AM
        </span>
      </div>
      <SettingRow icon="copy" label="Copy link" />
      <SettingRow icon="share" label="Share link" />
      <SettingRow icon="clear" label="Revoke link" />
    </div>
  );
}

function ImportMenu() {
  return (
    <div className="flex flex-col gap-2">
      <span className="label">After tapping Import…</span>
      <div className={`${panel} ${rows}`}>
        <SettingRow icon="import" label="From a File…" />
        <SettingRow icon="link" label="From a Link…" />
      </div>
    </div>
  );
}

function SheetButton({ label, primary }: { label: string; primary?: boolean }) {
  return (
    <span
      className={`inline-flex items-center justify-center rounded-[10px] border-2 border-ink px-3 py-1.5 text-[14px] font-bold ${primary ? 'bg-ink text-paper' : 'bg-paper'}`}
    >
      {label}
    </span>
  );
}

function ImportLink() {
  return (
    <div className="grid gap-2.5 xs:grid-cols-2">
      <div className={`${panel} flex min-w-0 flex-col gap-3 p-3`}>
        <b className="text-[15px]">Import from Link</b>
        <span className="text-[12.5px] text-muted">Paste your export link</span>
        <span className="line-clamp-2 rounded-lg border-2 border-ink px-2 py-1.5 font-mono text-[12px] leading-snug [overflow-wrap:anywhere]">
          https://transfer.thoughtreps.com/x/Gh4mT9…#kB8w2Q…
        </span>
        <div className="flex gap-2">
          <SheetButton label="Paste" />
          <SheetButton label="Continue" primary />
        </div>
      </div>
      <div className={`${panel} flex min-w-0 flex-col gap-3 p-3`}>
        <b className="text-[15px]">Import from Link</b>
        <span className="text-[14px]">1.5 MB</span>
        <span className="text-[12.5px] text-muted">
          Expires tomorrow at 9:41 AM
        </span>
        <div>
          <SheetButton label="Import" primary />
        </div>
      </div>
    </div>
  );
}

function Stats() {
  const weeks = [
    0, 1, 0, 0, 2, 1, 0, 3, 1, 0, 0, 1, 2, 0, 1, 4, 2, 0, 1, 1, 0, 2, 3, 1, 0,
    0, 1, 2, 1, 0, 0, 1, 3, 2, 1, 0, 1, 0, 2, 4, 1, 1, 0, 2, 1, 0, 3, 2, 1, 0,
    1, 2,
  ];
  const steps = ['opacity-40', 'opacity-60', 'opacity-80', 'opacity-100'];
  const stat = (title: string, value: string, detail?: string) => (
    <div className="flex items-center justify-between gap-3 p-3">
      <span className="flex flex-col gap-0.5">
        <span className="text-[15px]">{title}</span>
        {detail && <span className="text-[12.5px] text-muted">{detail}</span>}
      </span>
      <b className="text-[18px]">{value}</b>
    </div>
  );
  return (
    <div className="flex flex-col gap-3">
      <span className={screenTitle}>Stats</span>
      <ListLabel>Basics</ListLabel>
      <div className={`${panel} ${rows}`}>
        {stat('Thoughts written', '128', '9 this month')}
        {stat('Revisits', '412', '97 thoughts seen at least once')}
        {stat('Active', '104')}
        {stat('Archived', '24')}
      </div>
      <ListLabel>Most revisited</ListLabel>
      <div className={panel}>
        <div className="flex flex-col gap-1 p-3">
          <b className="text-[15px] leading-snug">Weekly review questions</b>
          <span className="text-[12.5px] font-medium text-muted">
            Seen 14 times
          </span>
        </div>
      </div>
      <ListLabel>Writing rhythm</ListLabel>
      <div className={`${panel} flex flex-col gap-3 p-3`}>
        <div className="grid grid-cols-13 gap-1">
          {weeks.map((count, index) => (
            <span
              key={index}
              className={
                count === 0
                  ? 'aspect-square rounded-[3px] border border-hl'
                  : `aspect-square rounded-[3px] bg-ink ${steps[count - 1]}`
              }
            />
          ))}
        </div>
        <span className="text-[12.5px] text-muted">
          58 thoughts in the last year
        </span>
      </div>
    </div>
  );
}

function IpadLayout() {
  const side = ['Timeline', 'Tags', 'Archive', 'Stats'];
  return (
    <div className="grid grid-cols-[auto_1fr_1fr] gap-2">
      <div className={`${panel} flex flex-col gap-1 p-2 text-[13px]`}>
        {side.map((name, i) => (
          <span
            key={name}
            className={`rounded-md px-2 py-1.5 ${i === 0 ? 'bg-hl font-bold' : ''}`}
          >
            {name}
          </span>
        ))}
      </div>
      <div className={`${panel} ${rows}`}>
        <ThoughtRow {...QUOTE_ROW} />
        <ThoughtRow {...REVIEW_ROW} />
      </div>
      <div
        className={`${panel} flex flex-col items-center justify-center gap-1 p-3 text-center`}
      >
        <b className="text-[15px]">Select a thought</b>
        <span className="text-[12.5px] text-muted">
          Pick one from the list to read it.
        </span>
      </div>
    </div>
  );
}

const THEMES = [
  { name: 'Ink', tagline: 'Clean outlines, Archivo and Paper Mono.' },
  { name: 'Library', tagline: 'Warm paper, old-style serifs, oxblood ink.' },
  { name: 'Midnight', tagline: 'Deep navy and gold, always dark.' },
  { name: 'Garden', tagline: 'Soft sage, rounded type, pillowy cards.' },
  { name: 'Terminal', tagline: 'Green phosphor on black. Menlo everywhere.' },
  { name: 'Pop', tagline: 'Cream, coral and thick ink outlines.' },
];

function Themes() {
  return (
    <div className="flex flex-col gap-2">
      <div className={`${panel} ${rows}`}>
        {THEMES.map((t, i) => (
          <div key={t.name} className="px-3 py-3">
            <div className="flex items-center justify-between gap-2 text-[15px]">
              <span className="font-bold">{t.name}</span>
              {i === 0 && (
                <span className="flex items-center gap-1 text-[13px]">
                  <IconGlyph name="check" className="size-[14px]" />
                  In use
                </span>
              )}
            </div>
            <p className="text-[12.5px] leading-snug text-muted">{t.tagline}</p>
          </div>
        ))}
      </div>
      <p className="text-[12.5px] leading-snug text-muted">
        Themes change colors, title fonts and cards. Your thought text font is
        set under Appearance.
      </p>
    </div>
  );
}

const EXAMPLES: Record<
  HelpExampleKind,
  { Mock: () => ReactNode; interactive?: boolean }
> = {
  loop: { Mock: Loop },
  editor: { Mock: Editor },
  'thought-states': { Mock: ThoughtStates },
  timeline: { Mock: Timeline },
  'thought-card': { Mock: ThoughtCard },
  'search-results': { Mock: SearchResults },
  'format-bar': { Mock: FormatBar },
  'markdown-pair': { Mock: MarkdownPair },
  gallery: { Mock: Gallery },
  'blurred-block': { Mock: BlurredBlock, interactive: true },
  'tag-list': { Mock: TagList },
  'color-sheet': { Mock: ColorSheet },
  'share-sheet': { Mock: ShareSheet },
  'snooze-menu': { Mock: SnoozeMenu },
  'interval-menu': { Mock: IntervalMenu },
  'learn-bar': { Mock: LearnBar },
  'swipe-actions': { Mock: SwipeActions },
  'pinned-archived': { Mock: PinnedArchived },
  notification: { Mock: Notification },
  'settings-backup': { Mock: SettingsBackup },
  'export-link': { Mock: ExportLink },
  'import-link': { Mock: ImportLink },
  'import-menu': { Mock: ImportMenu },
  stats: { Mock: Stats },
  themes: { Mock: Themes },
  'ipad-layout': { Mock: IpadLayout },
};

/** The mockup is hidden from screen readers; the caption stands in for it. Only the blurred block is real, focusable UI. */
export function HelpExampleView({ example }: { example: HelpExample }) {
  const { Mock, interactive } = EXAMPLES[example.kind];
  return (
    <figure className="mt-5 mb-1">
      <div
        aria-hidden={interactive ? undefined : true}
        className="min-w-0 overflow-hidden rounded-[14px] border-[2.5px] border-ink bg-soft p-3 xs:p-4"
      >
        <Mock />
      </div>
      <figcaption className="mt-2 text-[14px] leading-snug text-muted">
        {example.caption}
      </figcaption>
    </figure>
  );
}
