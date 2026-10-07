import { WaitlistResponse } from '../../../lib/export-link/schemas.js';
import {
  FEEDBACK_TO,
  WAITLIST_FROM,
  json,
  makeEnv,
} from '../shared/testSupport.js';
import { createHandler } from './index.js';

const WAITLIST = 'POST /api/v1/waitlist';

const valid = { email: 'person@example.com', beta: false, honeypot: '' };

function setup() {
  const env = makeEnv();
  const handler = createHandler(env);
  const call = (payload: unknown = valid) =>
    handler({
      routeKey: WAITLIST,
      headers: { 'content-type': 'application/json' },
      body: typeof payload === 'string' ? payload : JSON.stringify(payload),
    });
  return { env, handler, call };
}

describe('waitlist signup', () => {
  it('stores the row, notifies the owner and answers ok', async () => {
    const { env, call } = setup();
    const res = await call({ ...valid, beta: true });
    expect(res.statusCode).toBe(200);
    expect(WaitlistResponse.parse(json(res))).toEqual({ ok: true });
    expect(env.waitlist.rows.get(valid.email)).toEqual({
      beta: true,
      createdAt: '2026-01-15T12:00:00.000Z',
    });

    expect(env.mailer.sent).toHaveLength(1);
    const [mail] = env.mailer.sent;
    expect(mail).toEqual({
      from: WAITLIST_FROM,
      to: FEEDBACK_TO,
      subject: '[Waitlist] New signup',
      text: 'Email: person@example.com\nBeta: yes\nSigned up: 2026-01-15T12:00:00.000Z',
    });
    expect(mail.replyTo).toBeUndefined();
  });

  it('trims and lowercases the email', async () => {
    const { env, call } = setup();
    await call({ ...valid, email: '  Person@Example.COM ' });
    expect([...env.waitlist.rows.keys()]).toEqual(['person@example.com']);
    expect(env.mailer.sent[0].text).toContain('Email: person@example.com');
  });

  it('never logs the email', async () => {
    const { call } = setup();
    const spies = (['log', 'info', 'warn', 'error'] as const).map((level) =>
      jest.spyOn(console, level).mockImplementation(() => {}),
    );
    expect((await call()).statusCode).toBe(200);
    const logged = JSON.stringify(spies.flatMap((spy) => spy.mock.calls));
    expect(logged).not.toContain(valid.email);
    spies.forEach((spy) => spy.mockRestore());
  });
});

describe('waitlist validation', () => {
  it.each([
    ['bad email', { email: 'not-an-email' }],
    ['email with a newline', { email: 'a@example.com\nBcc: b@example.com' }],
    ['oversized email', { email: `${'a'.repeat(250)}@example.com` }],
    ['non-boolean beta', { beta: 'yes' }],
    ['oversized honeypot', { honeypot: 'x'.repeat(201) }],
    ['extra field', { extra: 'x' }],
  ])('rejects %s', async (_name, override) => {
    const { env, call } = setup();
    const res = await call({ ...valid, ...override });
    expect(res.statusCode).toBe(400);
    expect(json(res)).toEqual({
      error: 'bad_request',
      message: 'Invalid request body',
    });
    expect(env.waitlist.rows.size).toBe(0);
    expect(env.mailer.sent).toHaveLength(0);
  });

  it('rejects a missing honeypot', async () => {
    const { call } = setup();
    expect((await call({ email: valid.email, beta: false })).statusCode).toBe(
      400,
    );
  });

  it('rejects a body that is not JSON', async () => {
    const { call } = setup();
    const res = await call('not json');
    expect(res.statusCode).toBe(400);
    expect(json(res)).toEqual({
      error: 'bad_request',
      message: 'Body must be JSON',
    });
  });

  it.each([['text/plain'], ['application/x-www-form-urlencoded'], [undefined]])(
    'rejects content type %s',
    async (contentType) => {
      const { env, handler } = setup();
      const res = await handler({
        routeKey: WAITLIST,
        headers: contentType ? { 'content-type': contentType } : {},
        body: JSON.stringify(valid),
      });
      expect(res.statusCode).toBe(400);
      expect(json(res).error).toBe('bad_request');
      expect(env.waitlist.rows.size).toBe(0);
    },
  );

  it('accepts application/json with a charset', async () => {
    const { handler } = setup();
    const res = await handler({
      routeKey: WAITLIST,
      headers: { 'content-type': 'application/json; charset=utf-8' },
      body: JSON.stringify(valid),
    });
    expect(res.statusCode).toBe(200);
  });

  it('rejects a missing body', async () => {
    const { handler } = setup();
    expect(
      (
        await handler({
          routeKey: WAITLIST,
          headers: { 'content-type': 'application/json' },
        })
      ).statusCode,
    ).toBe(400);
  });
});

describe('waitlist honeypot', () => {
  it('answers ok with no write or mail', async () => {
    const { env, call } = setup();
    const res = await call({ ...valid, honeypot: 'gotcha' });
    expect(res.statusCode).toBe(200);
    expect(json(res)).toEqual({ ok: true });
    expect(env.waitlist.rows.size).toBe(0);
    expect(env.mailer.sent).toHaveLength(0);
  });
});

describe('waitlist duplicates', () => {
  it('answers identically and sends no second mail', async () => {
    const { env, call } = setup();
    const first = await call();
    const second = await call();
    expect(second).toEqual(first);
    expect(env.mailer.sent).toHaveLength(1);
  });

  it('upgrades an existing row to beta but never downgrades it', async () => {
    const { env, call } = setup();
    await call({ ...valid, beta: false });
    const upgraded = await call({ ...valid, beta: true });
    expect(upgraded.statusCode).toBe(200);
    expect(env.waitlist.rows.get(valid.email)?.beta).toBe(true);
    await call({ ...valid, beta: false });
    expect(env.waitlist.rows.get(valid.email)?.beta).toBe(true);
    expect(env.mailer.sent).toHaveLength(1);
    expect(env.waitlist.rows.get(valid.email)?.createdAt).toBe(
      '2026-01-15T12:00:00.000Z',
    );
  });
});

describe('waitlist mail failure', () => {
  it('still answers ok, keeps the row and logs no PII', async () => {
    const { env, call } = setup();
    env.mailer.failWith = new Error(`SES said no to ${valid.email}`);
    const spy = jest.spyOn(console, 'error').mockImplementation(() => {});
    const res = await call();
    expect(res.statusCode).toBe(200);
    expect(json(res)).toEqual({ ok: true });
    expect(env.waitlist.rows.has(valid.email)).toBe(true);
    const logged = JSON.stringify(spy.mock.calls);
    expect(logged).toContain('waitlist notification failed');
    expect(logged).not.toContain(valid.email);
    spy.mockRestore();
  });
});

describe('waitlist storage failure', () => {
  it('answers 500 without leaking the email', async () => {
    const { env, call } = setup();
    jest
      .spyOn(env.waitlist, 'signUp')
      .mockRejectedValue(new Error(`boom ${valid.email}`));
    const spy = jest.spyOn(console, 'error').mockImplementation(() => {});
    const res = await call();
    expect(res.statusCode).toBe(500);
    expect(res.body).not.toContain(valid.email);
    expect(JSON.stringify(spy.mock.calls)).not.toContain(valid.email);
    jest.restoreAllMocks();
  });
});

describe('routing', () => {
  it('rejects unknown routes', async () => {
    const { handler } = setup();
    const res = await handler({ routeKey: 'POST /api/v1/nope', body: '{}' });
    expect(res.statusCode).toBe(404);
  });
});
