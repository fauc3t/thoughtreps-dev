import { useRef, useState } from 'react';

const COPY_BUTTON =
  'inline-flex cursor-pointer items-center justify-center self-start rounded-[12px] border-2 border-ink bg-paper px-4 py-2 font-display text-base font-extrabold text-ink transition duration-100 hover:bg-soft focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ink active:translate-y-px';

type CopyState = 'idle' | 'copied' | 'manual';

export function IosImportNote() {
  const [copy, setCopy] = useState<CopyState>('idle');
  const fieldRef = useRef<HTMLInputElement>(null);

  async function copyLink() {
    try {
      await navigator.clipboard.writeText(window.location.href);
      setCopy('copied');
    } catch {
      setCopy('manual');
      requestAnimationFrame(() => fieldRef.current?.select());
    }
  }

  return (
    <div className="flex flex-col gap-3 border-t-2 border-ink/15 pt-4">
      <p className="text-muted">
        Have Thought Reps on this iPhone? Copy this link, then in the app go to
        Settings, then under Backup tap Import… and choose From a Link…
      </p>
      <button type="button" className={COPY_BUTTON} onClick={() => void copyLink()}>
        Copy link
      </button>
      {copy === 'manual' && (
        <input
          ref={fieldRef}
          readOnly
          value={window.location.href}
          aria-label="Export link"
          onFocus={(e) => e.currentTarget.select()}
          className="w-full rounded-[10px] border-2 border-ink bg-paper px-3 py-2 font-mono text-sm text-ink"
        />
      )}
      <p role="status" className="min-h-[1.6em] font-medium">
        {copy === 'copied' && 'Copied'}
        {copy === 'manual' && 'Couldn’t copy. Select the link above and copy it.'}
      </p>
    </div>
  );
}
