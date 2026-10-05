export type EnvName = 'prod';

export interface EnvConfig {
  envName: EnvName;
  account: string;
  region: string; // must be an SES-receiving-capable region — see mail/mail-stack.ts
  domainName: string;
  mailboxAddresses: string[];
  // Feeds the `rua=mailto:` address on the _dmarc TXT record.
  alertEmail: string;
  // Received address -> forwarding destination. Each forwarded address's
  // receipt rule gets a second (Lambda) action after its S3 action; see
  // mail/mail-stack.ts. Empty/unset means no ForwardFn at all.
  forwardTo?: Record<string, string>;
  // SES allows one active receipt rule set per region, and account
  // 041459489812 is shared with strands prod, whose `simple-mail-prod` set
  // is already the active one. This app adds its receipt rules to that
  // existing set by name and never creates or activates a rule set of its
  // own. The set is owned by the `SimpleMail-prod-Mail` stack in the
  // separate ~/dev/simple-mail repo, so tearing that stack down removes
  // our rules too.
  sharedReceiptRuleSetName: string;
}

const ENV_CONFIGS: Record<EnvName, EnvConfig> = {
  prod: {
    envName: 'prod',
    account: '041459489812',
    region: 'us-east-1',
    domainName: 'thoughtreps.com',
    mailboxAddresses: ['hello@thoughtreps.com'],
    alertEmail: 'me@nickhorn.com',
    // me@nickhorn.com is already a verified recipient identity in this
    // account (SES production access is on account-wide), so forwarding
    // needs no extra identity.
    forwardTo: { 'hello@thoughtreps.com': 'me@nickhorn.com' },
    sharedReceiptRuleSetName: 'simple-mail-prod',
  },
};

export function resolveEnvConfig(contextEnv: unknown): EnvConfig {
  const requested = typeof contextEnv === 'string' ? contextEnv : 'prod';
  if (requested !== 'prod') {
    throw new Error(
      `Unknown environment "${requested}" — only -c env=prod exists`,
    );
  }
  return ENV_CONFIGS[requested];
}
