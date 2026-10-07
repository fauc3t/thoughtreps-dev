import { useEffect, useId, useRef, useState } from 'react';
import type { FormEvent } from 'react';

export const WAITLIST_URL = 'https://transfer.thoughtreps.com/api/v1/waitlist';

const ERROR_COPY = {
  invalid: "That email doesn't look right.",
  rate: 'Too many tries. Wait a minute and try again.',
  generic: 'Something went wrong. Try again, or email hello@thoughtreps.com.',
} as const;

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

// `compact` (the hero) hides the label and hint visually; both stay in the
// accessibility tree, and the hero's mono line carries the hint's promise.
export function WaitlistForm({
  className = '',
  compact = false,
}: {
  className?: string;
  compact?: boolean;
}) {
  const uid = useId();
  const emailId = `${uid}-email`;
  const betaId = `${uid}-beta`;
  const errorId = `${uid}-error`;
  const hintId = `${uid}-hint`;
  const honeypotId = `${uid}-hp`;

  const [email, setEmail] = useState('');
  const [beta, setBeta] = useState(false);
  const [honeypot, setHoneypot] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<FormError | null>(null);
  const [joined, setJoined] = useState<{ email: string; beta: boolean } | null>(
    null,
  );
  const successRef = useRef<HTMLDivElement>(null);
  const emailRef = useRef<HTMLInputElement>(null);
  const inFlight = useRef(false);

  useEffect(() => {
    if (joined) successRef.current?.focus();
  }, [joined]);

  async function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    if (inFlight.current) return;
    const trimmed = email.trim();
    if (honeypot) {
      setJoined({ email: trimmed, beta });
      return;
    }
    if (!EMAIL_PATTERN.test(trimmed)) {
      setError('invalid');
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
      setJoined({ email: trimmed, beta });
    } else {
      setError(result);
      emailRef.current?.focus();
    }
  }

  if (joined) {
    return (
      <div
        ref={successRef}
        tabIndex={-1}
        className={`flex w-full max-w-[460px] flex-col gap-1 rounded-[14px] border-2 border-ink bg-soft px-4 py-3 text-left shadow-sticker-sm focus:outline-none ${className}`}
      >
        <p className="font-semibold text-ink">
          You&apos;re on the list. We&apos;ll email{' '}
          <span className="break-all">{joined.email}</span> when Thought Reps
          launches.
        </p>
        {joined.beta && (
          <p className="text-[15px] text-muted">
            We&apos;ll send a TestFlight invite too.
          </p>
        )}
      </div>
    );
  }

  return (
    <form
      onSubmit={onSubmit}
      noValidate
      className={`flex w-full max-w-[460px] flex-col gap-2.5 text-left ${className}`}
    >
      <label htmlFor={emailId} className={compact ? 'sr-only' : 'label -mb-1'}>
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
          aria-invalid={error === 'invalid' ? true : undefined}
          aria-describedby={error ? `${errorId} ${hintId}` : hintId}
          placeholder="you@example.com"
          readOnly={submitting}
          className="w-full min-w-0 flex-1 rounded-[10px] border-2 border-ink bg-paper px-3 py-2.5 text-[16px] leading-tight text-ink shadow-sticker-sm transition-[background,box-shadow] duration-[120ms] placeholder:text-muted hover:bg-soft focus-visible:bg-paper read-only:opacity-60 aria-[invalid=true]:border-dashed"
        />
        <button
          type="submit"
          aria-disabled={submitting}
          className="cursor-pointer rounded-[10px] border-2 border-ink bg-ink px-4 py-2.5 text-[16px] leading-tight font-semibold text-paper shadow-sticker-sm transition-[transform,box-shadow,background,color] duration-[120ms] hover:-translate-px hover:bg-accent hover:text-accent-ink hover:shadow-[3px_3px_0_var(--ink)] active:translate-[2px] active:shadow-none aria-disabled:cursor-not-allowed aria-disabled:opacity-60 aria-disabled:hover:translate-0 aria-disabled:hover:bg-ink aria-disabled:hover:text-paper aria-disabled:hover:shadow-sticker-sm"
        >
          {submitting ? 'Adding you...' : 'Notify me'}
        </button>
      </div>
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
      {error && (
        <p
          id={errorId}
          role="alert"
          className="text-[15px] font-medium text-ink underline decoration-wavy underline-offset-4"
        >
          {ERROR_COPY[error]}
        </p>
      )}
      <p
        id={hintId}
        className={compact ? 'sr-only' : 'text-[14px] leading-snug text-muted'}
      >
        One email at launch, plus a beta invite if you ask. Then we delete your
        address.
      </p>
    </form>
  );
}
