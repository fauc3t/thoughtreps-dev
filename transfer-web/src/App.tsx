import { useEffect, useReducer, useRef, type ReactNode, type Ref } from 'react';
import {
  ApiFailure,
  claimLink,
  getStatus,
  markDone,
  type Claim,
} from './lib/api';
import type { ParsedLink } from './lib/link';
import { exportFilename, saveFile } from './lib/save';
import {
  downloadAndDecrypt,
  TransferError,
  type TransferFailure,
} from './lib/transfer';

type Unavailable = 'used' | 'expired' | 'revoked' | 'not_found';
type Working =
  | { phase: 'claiming' }
  | { phase: 'downloading'; loaded: number; total: number }
  | { phase: 'verifying' | 'decrypting' | 'saving' };

type State =
  | { kind: 'loading' }
  | { kind: 'load_error' }
  | { kind: 'ready'; sizeBytes: number; expiresAt: string; retryable: boolean }
  | { kind: 'unavailable'; reason: Unavailable }
  | { kind: 'working'; sizeBytes: number; expiresAt: string; work: Working }
  | { kind: 'saved' }
  | {
      kind: 'failed';
      failure: TransferFailure;
      sizeBytes: number;
      expiresAt: string;
      retryClaim: Claim | null;
    };

type Action =
  | { type: 'loading' }
  | { type: 'load_error' }
  | { type: 'ready'; sizeBytes: number; expiresAt: string; retryable?: boolean }
  | { type: 'unavailable'; reason: Unavailable }
  | { type: 'work'; work: Working }
  | { type: 'saved' }
  | { type: 'failed'; failure: TransferFailure; retryClaim: Claim | null };

function reducer(state: State, action: Action): State {
  switch (action.type) {
    case 'loading':
      return { kind: 'loading' };
    case 'load_error':
      return { kind: 'load_error' };
    case 'ready':
      return {
        kind: 'ready',
        sizeBytes: action.sizeBytes,
        expiresAt: action.expiresAt,
        retryable: action.retryable ?? false,
      };
    case 'unavailable':
      return { kind: 'unavailable', reason: action.reason };
    case 'work':
      return state.kind === 'ready' ||
        state.kind === 'working' ||
        state.kind === 'failed'
        ? {
            kind: 'working',
            sizeBytes: state.sizeBytes,
            expiresAt: state.expiresAt,
            work: action.work,
          }
        : state;
    case 'saved':
      return { kind: 'saved' };
    case 'failed':
      return state.kind === 'working'
        ? {
            kind: 'failed',
            failure: action.failure,
            sizeBytes: state.sizeBytes,
            expiresAt: state.expiresAt,
            retryClaim: action.retryClaim,
          }
        : state;
  }
}

const UNAVAILABLE_COPY: Record<Unavailable, { title: string; body: string }> = {
  used: {
    title: 'This link has already been used.',
    body: 'Export links work once. To move your thoughts again, make a new link in Thought Reps.',
  },
  expired: {
    title: 'This link has expired.',
    body: 'Export links last 24 hours. Make a new link in Thought Reps.',
  },
  revoked: {
    title: 'This link was cancelled.',
    body: 'It was replaced or revoked in the app. Use the newest link, or make a new one in Thought Reps.',
  },
  not_found: {
    title: 'We couldn’t find this link.',
    body: 'Check that you copied the whole link, or make a new one in Thought Reps.',
  },
};

const FAILURE_COPY: Record<TransferFailure, { title: string; body: string }> = {
  download: {
    title: 'The download didn’t finish.',
    body: 'The connection dropped, or the file is too large for this browser to hold in memory.',
  },
  integrity: {
    title: 'The downloaded file was damaged.',
    body: 'It didn’t match what was uploaded, so nothing was saved.',
  },
  format: {
    title: 'This isn’t a Thought Reps export.',
    body: 'The file doesn’t have the expected format, so nothing was saved.',
  },
  decrypt: {
    title: 'We couldn’t unlock the file.',
    body: 'The key in the link is wrong or the file is corrupt.',
  },
  not_export: {
    title: 'This isn’t a Thought Reps export.',
    body: 'The unlocked file isn’t a Thought Reps backup, so nothing was saved.',
  },
};

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  const units = ['KB', 'MB', 'GB'];
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return `${value.toFixed(value < 10 ? 1 : 0)} ${units[unit]}`;
}

function formatExpiry(iso: string): string {
  return new Intl.DateTimeFormat(undefined, {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(new Date(iso));
}

function workLabel(work: Working): string {
  switch (work.phase) {
    case 'claiming':
      return 'Starting…';
    case 'downloading':
      return `Downloading… ${Math.floor((work.loaded / work.total) * 100)}%`;
    case 'verifying':
      return 'Checking the file…';
    case 'decrypting':
      return 'Unlocking…';
    case 'saving':
      return 'Saving…';
  }
}

const BUTTON =
  'inline-flex cursor-pointer items-center justify-center rounded-[14px] border-[2.5px] border-ink bg-ink px-6 py-3 font-display text-lg font-extrabold text-paper shadow-sticker transition duration-100 hover:-translate-x-0.5 hover:-translate-y-0.5 hover:shadow-[6px_6px_0_var(--ink)] active:translate-x-[3px] active:translate-y-[3px] active:shadow-[1px_1px_0_var(--ink)] disabled:pointer-events-none disabled:opacity-60';

function Message({
  title,
  children,
  headingRef,
}: {
  title: string;
  children?: ReactNode;
  headingRef?: Ref<HTMLHeadingElement>;
}) {
  return (
    <>
      <h2
        ref={headingRef}
        tabIndex={-1}
        className="text-2xl leading-tight font-extrabold outline-none"
      >
        {title}
      </h2>
      {children && <p className="text-muted">{children}</p>}
    </>
  );
}

export function App({ link }: { link: ParsedLink }) {
  const [state, dispatch] = useReducer(reducer, { kind: 'loading' });
  const [attempt, retryLoad] = useReducer((n: number) => n + 1, 0);

  const id = link.ok ? link.id : null;
  useEffect(() => {
    if (!id) return;
    const controller = new AbortController();
    getStatus(id, controller.signal).then(
      (status) =>
        dispatch(
          status.status === 'ready'
            ? {
                type: 'ready',
                sizeBytes: status.sizeBytes,
                expiresAt: status.expiresAt,
              }
            : { type: 'unavailable', reason: status.status },
        ),
      (err: unknown) => {
        if (controller.signal.aborted) return;
        dispatch(
          err instanceof ApiFailure && err.kind === 'not_found'
            ? { type: 'unavailable', reason: 'not_found' }
            : { type: 'load_error' },
        );
      },
    );
    return () => controller.abort();
  }, [id, attempt]);

  const headingRef = useRef<HTMLHeadingElement>(null);
  const interacted = useRef(false);
  useEffect(() => {
    if (interacted.current) headingRef.current?.focus();
  }, [state.kind]);

  async function transfer(claim: Claim) {
    if (!link.ok) return;
    try {
      const zip = await downloadAndDecrypt(
        {
          url: claim.download.url,
          sizeBytes: claim.sizeBytes,
          sha256: claim.sha256,
        },
        link.key,
        (phase) =>
          dispatch({
            type: 'work',
            work:
              phase === 'downloading'
                ? { phase, loaded: 0, total: claim.sizeBytes }
                : { phase },
          }),
        (loaded) =>
          dispatch({
            type: 'work',
            work: { phase: 'downloading', loaded, total: claim.sizeBytes },
          }),
      );
      dispatch({ type: 'work', work: { phase: 'saving' } });
      saveFile(zip, exportFilename(new Date()));
    } catch (err) {
      const failure = err instanceof TransferError ? err.failure : 'download';
      const urlStillValid = Date.now() < Date.parse(claim.download.expiresAt);
      dispatch({
        type: 'failed',
        failure,
        retryClaim: failure === 'download' && urlStillValid ? claim : null,
      });
      return;
    }
    dispatch({ type: 'saved' });
    void markDone(link.id);
  }

  async function download() {
    if (!link.ok || (state.kind !== 'ready' && state.kind !== 'working')) {
      return;
    }
    interacted.current = true;
    dispatch({ type: 'work', work: { phase: 'claiming' } });
    let claim: Claim;
    try {
      claim = await claimLink(link.id);
    } catch (err) {
      if (
        err instanceof ApiFailure &&
        (err.kind === 'used' ||
          err.kind === 'expired' ||
          err.kind === 'revoked' ||
          err.kind === 'not_found')
      ) {
        dispatch({ type: 'unavailable', reason: err.kind });
      } else {
        dispatch({
          type: 'ready',
          sizeBytes: state.sizeBytes,
          expiresAt: state.expiresAt,
          retryable: true,
        });
      }
      return;
    }
    await transfer(claim);
  }

  function retryDownload(claim: Claim) {
    interacted.current = true;
    dispatch({ type: 'work', work: { phase: 'downloading', loaded: 0, total: claim.sizeBytes } });
    void transfer(claim);
  }

  const retryClaim = state.kind === 'failed' ? state.retryClaim : null;

  return (
    <div className="flex min-h-dvh flex-col">
      <header className="mx-auto flex w-full max-w-xl items-center py-[18px]">
        <a
          className="-mx-2 flex items-center gap-2.5 rounded-[12px] border-2 border-transparent px-2 py-1.5 text-[19px] leading-none font-extrabold tracking-[-0.01em] no-underline transition-[border-color,background] duration-[120ms] [font-family:var(--font-display)] [font-variation-settings:'wdth'_108] hover:border-ink hover:bg-soft focus-visible:border-ink"
          href="https://thoughtreps.com"
        >
          <img
            src="/favicon.svg"
            alt=""
            className="size-[38px] rounded-[10px] border-2 border-ink shadow-[2px_2px_0_var(--ink)]"
          />
          Thought Reps
        </a>
      </header>
      <main className="mx-auto flex w-full max-w-xl flex-1 flex-col justify-center pb-10">
        <h1 className="mb-6 text-4xl leading-none font-extrabold [font-variation-settings:'wdth'_110]">
          Your Thought Reps export
        </h1>
        <section className="stk flex flex-col gap-4 p-6">
          <div aria-live="polite" className="flex flex-col gap-3">
            {renderStatus(link, state, headingRef)}
          </div>
          {(state.kind === 'ready' || state.kind === 'working') && (
            <button
              type="button"
              className={BUTTON}
              disabled={state.kind === 'working'}
              onClick={() => void download()}
            >
              Download
            </button>
          )}
          {retryClaim && (
            <button
              type="button"
              className={BUTTON}
              onClick={() => retryDownload(retryClaim)}
            >
              Try again
            </button>
          )}
          {state.kind === 'load_error' && (
            <button type="button" className={BUTTON} onClick={retryLoad}>
              Try again
            </button>
          )}
          {state.kind === 'working' && state.work.phase === 'downloading' && (
            <progress
              className="progress"
              max={state.work.total}
              value={state.work.loaded}
              aria-label="Download progress"
            />
          )}
        </section>
      </main>
    </div>
  );
}

function renderStatus(
  link: ParsedLink,
  state: State,
  headingRef: Ref<HTMLHeadingElement>,
): ReactNode {
  if (!link.ok) {
    return (
      <Message headingRef={headingRef} title="This link is incomplete — copy the whole link, including the part after #." />
    );
  }
  switch (state.kind) {
    case 'loading':
      return <Message headingRef={headingRef} title="Checking your link…" />;
    case 'load_error':
      return (
        <Message headingRef={headingRef} title="We couldn’t reach the server.">
          Check your connection and try again. Your link hasn’t been used.
        </Message>
      );
    case 'ready':
    case 'working':
      return (
        <>
          <Message
            headingRef={headingRef}
            title={
              state.kind === 'working'
                ? workLabel(state.work)
                : 'Your export is ready.'
            }
          >
            {formatBytes(state.sizeBytes)} · available until{' '}
            {formatExpiry(state.expiresAt)}
          </Message>
          {state.kind === 'ready' && state.retryable && (
            <p role="alert" className="font-medium">
              Something went wrong starting the download. Your link hasn’t been
              used, so you can try again.
            </p>
          )}
          <p className="text-muted">
            This link works once. After you download, it’s used up.
          </p>
        </>
      );
    case 'unavailable':
      return <Message headingRef={headingRef} {...UNAVAILABLE_COPY[state.reason]} />;
    case 'saved':
      return (
        <Message headingRef={headingRef} title="Saved.">
          Open the file on your iPhone with Thought Reps to import it. This link
          is now used up.
        </Message>
      );
    case 'failed': {
      const { title, body } = FAILURE_COPY[state.failure];
      return (
        <Message headingRef={headingRef} title={title}>
          {body}{' '}
          {state.retryClaim
            ? 'The link is still valid for a few minutes, so you can try again.'
            : 'This link is now used up, so make a new one in Thought Reps.'}
        </Message>
      );
    }
  }
}
