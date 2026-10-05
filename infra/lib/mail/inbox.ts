// Single source of truth for the "each address is an inbox" S3 key shape.
// MailStack uses inboxPrefix() as a receipt rule's S3 action
// objectKeyPrefix; the Lambdas and mail-web (via the package's
// `@thoughtreps/infra/mail/inbox` export) use the exact same function as
// an S3 key prefix. Neither side hardcodes the "/inbox/" literal —
// that's the drift this package exists to prevent.
export function normalizeAddress(address: string): string {
  return address.trim().toLowerCase();
}

export function inboxPrefix(address: string): string {
  return `${normalizeAddress(address)}/inbox/`;
}
