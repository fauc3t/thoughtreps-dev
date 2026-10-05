import * as cdk from 'aws-cdk-lib/core';
import * as route53 from 'aws-cdk-lib/aws-route53';
import { Match, Template } from 'aws-cdk-lib/assertions';
import { MailStack } from '../lib/mail/mail-stack.js';

export const SHARED_RULE_SET = 'simple-mail-prod';

export function synthMailStack(
  options: {
    mailboxAddresses?: string[];
    forwardTo?: Record<string, string>;
  } = {},
) {
  const { mailboxAddresses = ['hello@example.test'], forwardTo } = options;
  const app = new cdk.App();
  const env = { account: '111111111111', region: 'us-east-1' };

  const zoneStack = new cdk.Stack(app, 'ZoneStack', { env });
  const zone = route53.HostedZone.fromHostedZoneAttributes(zoneStack, 'Zone', {
    hostedZoneId: 'Z1234567890ABC',
    zoneName: 'example.test',
  });

  const stack = new MailStack(app, 'TestMailStack', {
    env,
    zone,
    domainName: 'example.test',
    mailboxAddresses,
    alertEmail: 'alerts@example.test',
    envName: 'prod',
    sharedReceiptRuleSetName: SHARED_RULE_SET,
    forwardTo,
  });

  return Template.fromStack(stack);
}

export function statementActions(policy: Record<string, unknown>): string[] {
  const statements = (
    policy.Properties as {
      PolicyDocument: { Statement: Array<{ Action: string | string[] }> };
    }
  ).PolicyDocument.Statement;
  return statements
    .flatMap((statement) =>
      Array.isArray(statement.Action) ? statement.Action : [statement.Action],
    )
    .sort();
}

// A function's logical id and its role's default policy both start with the
// construct path (e.g. "ApiReplyFn"), so this finds the inline policy
// attached to exactly that function's role.
export function defaultPolicyFor(template: Template, constructPrefix: string) {
  const matches = Object.entries(
    template.findResources('AWS::IAM::Policy'),
  ).filter(([logicalId]) =>
    logicalId.startsWith(`${constructPrefix}ServiceRoleDefaultPolicy`),
  );
  expect(matches).toHaveLength(1);
  return matches[0][1];
}

// The shared provider Lambda behind other constructs would also be an
// AWS::Lambda::Function, so ForwardFn is counted by its FORWARD_MAP
// environment variable.
export function forwardFnLogicalIds(template: Template): string[] {
  return Object.keys(
    template.findResources('AWS::Lambda::Function', {
      Properties: Match.objectLike({
        Environment: Match.objectLike({
          Variables: Match.objectLike({ FORWARD_MAP: Match.anyValue() }),
        }),
      }),
    }),
  );
}
