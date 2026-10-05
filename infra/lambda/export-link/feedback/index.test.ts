import { FeedbackResponse } from '../../../lib/export-link/schemas.js';
import { createHandler as createExportLinkHandler } from '../export-link/index.js';
import {
  FEEDBACK_FROM,
  FEEDBACK_TO,
  SHA,
  json,
  makeEnv,
  registerTestDevice,
  signedEvent,
} from '../shared/testSupport.js';
import { FEEDBACK_PER_DAY, createHandler } from './index.js';

const FEEDBACK = 'POST /api/v1/feedback';

const valid = {
  kind: 'bug',
  message: 'The timeline crashes when I open a thought.',
  email: 'person@example.com',
  appVersion: '1.0 (42)',
  osVersion: 'iOS 18.2',
  deviceModel: 'iPhone16,2',
};

function setup() {
  const env = makeEnv();
  const device = registerTestDevice(env);
  const handler = createHandler(env);
  let counter = 0;
  const call = (
    payload: Record<string, unknown> = valid,
    options: { challenge?: string; signedBody?: string } = {},
  ) =>
    handler(
      signedEvent(env, device, FEEDBACK, payload, {
        counter: ++counter,
        ...options,
      }),
    );
  return { env, device, handler, call, nextCounter: () => ++counter };
}

describe('feedback', () => {
  it('sends a fixed-subject plain-text email and answers sent', async () => {
    const { env, device, call } = setup();
    const res = await call();
    expect(res.statusCode).toBe(200);
    expect(FeedbackResponse.parse(json(res))).toEqual({ sent: true });

    expect(env.mailer.sent).toHaveLength(1);
    const [mail] = env.mailer.sent;
    expect(mail).toMatchObject({
      from: FEEDBACK_FROM,
      to: FEEDBACK_TO,
      replyTo: 'person@example.com',
      subject: '[Bug] Feedback',
    });
    expect(mail.text.startsWith('Kind: bug\n')).toBe(true);
    expect(mail.text.endsWith(`\n\n-- Message --\n${valid.message}`)).toBe(
      true,
    );
    expect(mail.text).toContain('App version: 1.0 (42)');
    expect(mail.text).toContain('OS version: iOS 18.2');
    expect(mail.text).toContain('Device model: iPhone16,2');
    expect(mail.text).toContain(`Device: ${device.keyId.slice(0, 8)}`);
    expect(mail.text).toContain('Sent: 2026-01-15T12:00:00.000Z');
  });

  it('uses the feature subject for feature requests', async () => {
    const { env, call } = setup();
    await call({ ...valid, kind: 'feature' });
    expect(env.mailer.sent[0].subject).toBe('[Feature] Feedback');
  });

  it('trims the message', async () => {
    const { env, call } = setup();
    await call({ ...valid, message: '  hello \n' });
    expect(env.mailer.sent[0].text.endsWith('-- Message --\nhello')).toBe(true);
  });

  it('keeps a message that imitates diagnostics after the real ones', async () => {
    const { env, call } = setup();
    await call({ ...valid, message: '\n--\nKind: feature' });
    const { text } = env.mailer.sent[0];
    expect(text.startsWith('Kind: bug\n')).toBe(true);
    expect(text.indexOf('Kind: feature')).toBeGreaterThan(
      text.indexOf('-- Message --'),
    );
  });

  it('never logs the message or email on success', async () => {
    const { call } = setup();
    const spies = (['log', 'info', 'warn', 'error'] as const).map((level) =>
      jest.spyOn(console, level).mockImplementation(() => {}),
    );
    expect((await call()).statusCode).toBe(200);
    const logged = JSON.stringify(spies.flatMap((spy) => spy.mock.calls));
    expect(logged).not.toContain(valid.email);
    expect(logged).not.toContain(valid.message);
    spies.forEach((spy) => spy.mockRestore());
  });
});

describe('feedback validation', () => {
  it.each([
    ['empty message', { message: '' }],
    ['whitespace message', { message: '  \n ' }],
    ['oversized message', { message: 'a'.repeat(5001) }],
    ['bad email', { email: 'not-an-email' }],
    ['email with a newline', { email: 'a@example.com\nBcc: b@example.com' }],
    ['oversized email', { email: `${'a'.repeat(250)}@example.com` }],
    ['unknown kind', { kind: 'praise' }],
    ['non-printable version', { appVersion: '1.0\n2' }],
    ['non-ASCII device model', { deviceModel: 'iPhone‮' }],
    ['oversized osVersion', { osVersion: 'x'.repeat(65) }],
    ['empty appVersion', { appVersion: '' }],
    ['extra field', { extra: 'x' }],
  ])('rejects %s', async (_name, override) => {
    const { env, call } = setup();
    const res = await call({ ...valid, ...override });
    expect(res.statusCode).toBe(400);
    expect(json(res).error).toBe('bad_request');
    expect(env.mailer.sent).toHaveLength(0);
  });

  it('accepts a message of exactly 5000 characters', async () => {
    const { call } = setup();
    const res = await call({ ...valid, message: 'a'.repeat(5000) });
    expect(res.statusCode).toBe(200);
  });

  it('rejects a missing email', async () => {
    const { call } = setup();
    const payload: Record<string, unknown> = { ...valid };
    delete payload.email;
    expect((await call(payload)).statusCode).toBe(400);
  });
});

describe('feedback authentication', () => {
  it('rejects missing headers', async () => {
    const { handler } = setup();
    const res = await handler({ routeKey: FEEDBACK, body: '{}' });
    expect(res.statusCode).toBe(400);
  });

  it('rejects an unknown device', async () => {
    const env = makeEnv();
    const stranger = registerTestDevice(makeEnv());
    const res = await createHandler(env)(
      signedEvent(env, stranger, FEEDBACK, valid, { counter: 1 }),
    );
    expect(res.statusCode).toBe(401);
    expect(json(res).error).toBe('assertion_invalid');
    expect(env.mailer.sent).toHaveLength(0);
  });

  it('rejects a body that differs from what was signed', async () => {
    const { env, call } = setup();
    const res = await call(valid, { signedBody: '{"something":"else"}' });
    expect(json(res).error).toBe('assertion_invalid');
    expect(env.mailer.sent).toHaveLength(0);
  });

  it('rejects an unknown challenge', async () => {
    const { env, call } = setup();
    const res = await call(valid, { challenge: 'C'.repeat(43) });
    expect(json(res).error).toBe('challenge_invalid');
    expect(env.mailer.sent).toHaveLength(0);
  });

  it('does not spend the rate budget on failed auth', async () => {
    const { env, call } = setup();
    for (let i = 0; i < 5; i++) {
      await call(valid, { signedBody: '{}' });
    }
    expect(env.store.rates.size).toBe(0);
  });
});

describe('feedback rate limit', () => {
  it('allows 3 per UTC day and rejects the 4th', async () => {
    const { env, call } = setup();
    for (let i = 0; i < FEEDBACK_PER_DAY; i++) {
      expect((await call()).statusCode).toBe(200);
    }
    const res = await call();
    expect(res.statusCode).toBe(429);
    expect(json(res).error).toBe('rate_limited');
    expect(env.mailer.sent).toHaveLength(3);
  });

  it('does not spend a slot on a failed send', async () => {
    const { env, call } = setup();
    jest.spyOn(console, 'error').mockImplementation(() => {});
    env.mailer.failWith = new Error('ses down');
    for (let i = 0; i < 3; i++) expect((await call()).statusCode).toBe(500);
    env.mailer.failWith = null;
    for (let i = 0; i < FEEDBACK_PER_DAY; i++) {
      expect((await call()).statusCode).toBe(200);
    }
    expect((await call()).statusCode).toBe(429);
    expect(env.mailer.sent).toHaveLength(3);
    jest.restoreAllMocks();
  });

  it('leaves the count at zero after failed sends', async () => {
    const { env, device, call } = setup();
    jest.spyOn(console, 'error').mockImplementation(() => {});
    env.mailer.failWith = new Error('ses down');
    for (let i = 0; i < 3; i++) await call();
    await expect(
      env.store.getRate(device.keyId, '2026-01-15', 'feedback'),
    ).resolves.toBe(0);
    jest.restoreAllMocks();
  });

  it('answers 200 and logs no PII when the increment throws', async () => {
    const { env, call } = setup();
    jest
      .spyOn(env.store, 'incrementRate')
      .mockRejectedValue(new Error(`boom ${valid.email} ${valid.message}`));
    const spy = jest.spyOn(console, 'error').mockImplementation(() => {});
    const res = await call();
    expect(res.statusCode).toBe(200);
    expect(env.mailer.sent).toHaveLength(1);
    const logged = JSON.stringify(spy.mock.calls);
    expect(logged).toContain('feedback rate increment failed');
    expect(logged).not.toContain(valid.email);
    expect(logged).not.toContain(valid.message);
    jest.restoreAllMocks();
  });

  it('answers 200 when the counter is already at the limit at increment time', async () => {
    const { env, call } = setup();
    jest.spyOn(env.store, 'incrementRate').mockResolvedValue(false);
    const res = await call();
    expect(res.statusCode).toBe(200);
    expect(env.mailer.sent).toHaveLength(1);
  });

  it('resets on the next UTC day', async () => {
    const { env, call } = setup();
    for (let i = 0; i < 4; i++) await call();
    env.clock.ms += 24 * 60 * 60 * 1000;
    expect((await call()).statusCode).toBe(200);
    expect(env.mailer.sent).toHaveLength(4);
  });

  it('keeps a separate budget from export link creates', async () => {
    const { env, device, call, nextCounter } = setup();
    const exportLinks = createExportLinkHandler(env);
    for (let i = 0; i < 3; i++) await call();
    expect((await call()).statusCode).toBe(429);

    const create = await exportLinks(
      signedEvent(
        env,
        device,
        'POST /api/v1/export-links',
        { sizeBytes: 1000, sha256: SHA },
        { counter: nextCounter() },
      ),
    );
    expect(create.statusCode).toBe(200);
  });
});

describe('feedback mail failure', () => {
  it('answers 500 without leaking the message or email', async () => {
    const { env, call } = setup();
    env.mailer.failWith = new Error(`SES said no to ${valid.email}`);
    const spy = jest.spyOn(console, 'error').mockImplementation(() => {});
    const res = await call();
    expect(res.statusCode).toBe(500);
    expect(res.body).not.toContain(valid.email);
    expect(res.body).not.toContain(valid.message);
    const logged = JSON.stringify(spy.mock.calls);
    expect(logged).not.toContain(valid.email);
    expect(logged).not.toContain(valid.message);
    spy.mockRestore();
  });
});

describe('routing', () => {
  it('rejects unknown routes', async () => {
    const { handler } = setup();
    const res = await handler({ routeKey: 'POST /api/v1/nope', body: '{}' });
    expect(res.statusCode).toBe(404);
  });
});
