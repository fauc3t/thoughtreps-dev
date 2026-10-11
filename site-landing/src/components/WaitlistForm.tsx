import { useEffect, useId, useRef, useState } from 'react';
import type { FormEvent, ReactNode } from 'react';
import { setWaitlistJoined, useWaitlistJoined } from '../waitlistStore';

export const WAITLIST_URL = 'https://transfer.thoughtreps.com/api/v1/waitlist';

const ERROR_COPY = {
  empty: 'Enter your email first.',
  invalid: 'Check the address: it needs an @ and a domain.',
  rate: 'Too many tries. Wait a minute and try again.',
  generic: 'Something went wrong. Try again, or email hello@thoughtreps.com.',
} as const;

const DEFAULT_HINT =
  'One email at launch, plus a beta invite if you ask. Then we delete your address.';

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

type FormError = keyof typeof ERROR_COPY;

async function submitWaitlist(
  email: string,
  beta: boolean,
): Promise<'ok' | FormError> {
  try {
    const res = await fetch(WAITLIST_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, beta, honeypot: '' }),
    });
    if (res.status === 200) return 'ok';
    if (res.status === 400) return 'invalid';
    if (res.status === 429) return 'rate';
    return 'generic';
  } catch {
    return 'generic';
  }
}

// Every form on the page shares the joined state (waitlistStore), so signing
// up in one turns the others into the confirmation. Only the form that was
// submitted announces it and takes focus.
export function WaitlistForm({
  className = '',
  inputId,
  hint = DEFAULT_HINT,
}: {
  className?: string;
  inputId?: string;
  hint?: ReactNode;
}) {
  const uid = useId();
  const emailId = inputId ?? `${uid}-email`;
  const betaId = `${uid}-beta`;
  const errorId = `${uid}-error`;
  const hintId = `${uid}-hint`;
  const honeypotId = `${uid}-hp`;

  const [email, setEmail] = useState('');
  const [beta, setBeta] = useState(false);
  const [honeypot, setHoneypot] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<FormError | null>(null);
  const [submittedHere, setSubmittedHere] = useState(false);
  const joined = useWaitlistJoined();
  const successRef = useRef<HTMLDivElement>(null);
  const emailRef = useRef<HTMLInputElement>(null);
  const inFlight = useRef(false);

  useEffect(() => {
    if (joined && submittedHere) successRef.current?.focus();
  }, [joined, submittedHere]);

  async function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    if (inFlight.current) return;
    const trimmed = email.trim();
    setSubmittedHere(true);
    if (honeypot) {
      setWaitlistJoined({ email: trimmed, beta });
      return;
    }
    if (!EMAIL_PATTERN.test(trimmed)) {
      setError(trimmed ? 'invalid' : 'empty');
      emailRef.current?.focus();
      return;
    }
    inFlight.current = true;
    setSubmitting(true);
    setError(null);
    const result = await submitWaitlist(trimmed, beta);
    inFlight.current = false;
    setSubmitting(false);
    if (result === 'ok') {
      setWaitlistJoined({ email: trimmed, beta });
    } else {
      setError(result);
      emailRef.current?.focus();
    }
  }

  const emailProblem = error === 'empty' || error === 'invalid';

  return (
    <div className={`w-full max-w-[460px] text-left ${className}`}>
      {!joined && (
        <form onSubmit={onSubmit} noValidate className="flex flex-col gap-2.5">
          <label htmlFor={emailId} className="label -mb-1">
            Email
          </label>
          <div className="flex flex-col gap-2.5 xs:flex-row">
            <input
              ref={emailRef}
              id={emailId}
              type="email"
              name="email"
              autoComplete="email"
              required
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              aria-invalid={emailProblem ? true : undefined}
              aria-describedby={error ? `${errorId} ${hintId}` : hintId}
              placeholder="you@example.com"
              readOnly={submitting}
              className="w-full min-w-0 flex-1 rounded-[10px] border-2 border-ink bg-paper px-3 py-2.5 text-[16px] leading-tight text-ink shadow-sticker-sm transition-[background,box-shadow] duration-[120ms] placeholder:text-muted hover:bg-soft focus-visible:bg-paper read-only:opacity-60 aria-[invalid=true]:border-4 aria-[invalid=true]:px-2.5 aria-[invalid=true]:py-2 aria-[invalid=true]:shadow-none"
            />
            <button
              type="submit"
              aria-disabled={submitting}
              className="cursor-pointer rounded-[10px] border-2 border-ink bg-ink px-4 py-2.5 text-[16px] leading-tight font-semibold text-paper shadow-sticker-sm transition-[transform,box-shadow,background,color] duration-[120ms] hover:-translate-px hover:bg-accent hover:text-accent-ink hover:shadow-[3px_3px_0_var(--ink)] active:translate-[2px] active:shadow-none aria-disabled:cursor-not-allowed aria-disabled:opacity-60 aria-disabled:hover:translate-0 aria-disabled:hover:bg-ink aria-disabled:hover:text-paper aria-disabled:hover:shadow-sticker-sm"
            >
              {submitting ? 'Adding you...' : 'Notify me'}
            </button>
          </div>
          {error && (
            <p
              id={errorId}
              role="alert"
              className="flex items-start gap-2 text-[15px] leading-snug font-semibold text-ink"
            >
              <span
                aria-hidden="true"
                className="mt-px grid size-5 shrink-0 place-items-center rounded-md bg-ink text-[13px] leading-none font-extrabold text-paper"
              >
                !
              </span>
              {ERROR_COPY[error]}
            </p>
          )}
          <div className="sr-only" aria-hidden="true">
            <label htmlFor={honeypotId}>Leave this empty</label>
            <input
              id={honeypotId}
              type="text"
              name="website_url"
              tabIndex={-1}
              autoComplete="off"
              value={honeypot}
              onChange={(e) => setHoneypot(e.target.value)}
            />
          </div>
          <label
            htmlFor={betaId}
            className="flex cursor-pointer items-start gap-2.5 text-[15px] text-ink"
          >
            <input
              id={betaId}
              type="checkbox"
              checked={beta}
              onChange={(e) => setBeta(e.target.checked)}
              className="mt-1 size-4 shrink-0 cursor-pointer accent-accent"
            />
            Also send me a TestFlight invite to try the beta
          </label>
          <p
            id={hintId}
            className="font-mono text-[13px] leading-snug tracking-[0.01em] text-muted"
          >
            {hint}
          </p>
        </form>
      )}
      <div role="status" aria-live={submittedHere ? 'polite' : 'off'}>
        {joined && (
          <div
            ref={successRef}
            tabIndex={-1}
            className="flex flex-col gap-1 rounded-[14px] border-2 border-ink bg-soft px-4 py-3 shadow-sticker-sm focus:outline-none"
          >
            <p className="font-semibold text-ink">
              You&apos;re on the list. We&apos;ll email{' '}
              {joined.email ? (
                <span className="break-all">{joined.email}</span>
              ) : (
                'you'
              )}{' '}
              when Thought Reps launches.
            </p>
            {joined.beta && (
              <p className="text-[15px] text-muted">
                We&apos;ll send a TestFlight invite too.
              </p>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
