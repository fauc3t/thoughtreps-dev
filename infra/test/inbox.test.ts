import { inboxPrefix, normalizeAddress } from '../lib/mail/inbox.js';

describe('normalizeAddress', () => {
  it('lowercases and trims an address', () => {
    expect(normalizeAddress('  Hello@Example.COM  ')).toBe('hello@example.com');
  });
});

describe('inboxPrefix', () => {
  it('builds the {address}/inbox/ prefix from a normalized address', () => {
    expect(inboxPrefix('Hello@Example.COM')).toBe('hello@example.com/inbox/');
  });
});
