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

export interface SecurityHeaders {
  policyId: string;
  csp: string[];
  hsts: {
    AccessControlMaxAgeSec: number;
    IncludeSubdomains: boolean;
    Override: boolean;
  };
  frameOption: { FrameOption: string; Override: boolean };
  contentTypeOptions: { Override: boolean };
  referrerPolicy: string;
}

export function securityHeaders(template: Template): SecurityHeaders {
  const [policyId, policy] = Object.entries(
    template.findResources('AWS::CloudFront::ResponseHeadersPolicy'),
  )[0];
  const config = (
    policy.Properties as {
      ResponseHeadersPolicyConfig: {
        SecurityHeadersConfig: {
          ContentSecurityPolicy: { ContentSecurityPolicy: unknown };
          StrictTransportSecurity: SecurityHeaders['hsts'];
          FrameOptions: SecurityHeaders['frameOption'];
          ContentTypeOptions: SecurityHeaders['contentTypeOptions'];
          ReferrerPolicy: { ReferrerPolicy: string };
        };
      };
    }
  ).ResponseHeadersPolicyConfig.SecurityHeadersConfig;
  return {
    policyId,
    csp: resolveCsp(config.ContentSecurityPolicy.ContentSecurityPolicy).split(
      '; ',
    ),
    hsts: config.StrictTransportSecurity,
    frameOption: config.FrameOptions,
    contentTypeOptions: config.ContentTypeOptions,
    referrerPolicy: config.ReferrerPolicy.ReferrerPolicy,
  };
}

function resolveCsp(value: unknown): string {
  if (typeof value === 'string') return value;
  const node = value as {
    'Fn::Join'?: [string, unknown[]];
    'Fn::GetAtt'?: string[];
    Ref?: string;
  };
  if (node['Fn::Join']) {
    const [sep, parts] = node['Fn::Join'];
    return parts.map(resolveCsp).join(sep);
  }
  if (node.Ref) return `{${node.Ref}}`;
  if (node['Fn::GetAtt']) return `{${node['Fn::GetAtt'].join('.')}}`;
  throw new Error(`Unexpected CSP node: ${JSON.stringify(value)}`);
}
