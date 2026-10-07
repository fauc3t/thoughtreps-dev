import { Match } from 'aws-cdk-lib/assertions';
import { inboxPrefix } from '../lib/mail/inbox.js';
import {
  SHARED_RULE_SET,
  defaultPolicyFor,
  forwardFnLogicalIds,
  statementActions,
  synthMailStack,
} from './helpers.js';

describe('MailStack receiving', () => {
  const mailboxAddresses = ['hello@example.test', 'support@example.test'];
  const template = synthMailStack({ mailboxAddresses });

  it('creates no receipt rule set and never activates one — it only adds rules to the shared, already-active set', () => {
    template.resourceCountIs('AWS::SES::ReceiptRuleSet', 0);
    template.resourceCountIs('Custom::AWS', 0);
    expect(JSON.stringify(template.toJSON())).not.toContain(
      'etActiveReceiptRuleSet',
    );
  });

  it('adds one ReceiptRule per address to the shared rule set, each with a single S3 action at that address’s inbox prefix', () => {
    template.resourceCountIs('AWS::SES::ReceiptRule', mailboxAddresses.length);

    for (const address of mailboxAddresses) {
      template.hasResourceProperties('AWS::SES::ReceiptRule', {
        RuleSetName: SHARED_RULE_SET,
        Rule: Match.objectLike({
          Recipients: [address],
          // Exactly one action — not arrayWith, so a stray second action
          // would fail this test rather than silently passing.
          Actions: [
            Match.objectLike({
              S3Action: Match.objectLike({
                ObjectKeyPrefix: inboxPrefix(address),
              }),
            }),
          ],
        }),
      });
    }
  });

  it('blocks all public access on the mail bucket and retains it on delete/replace', () => {
    template.hasResource('AWS::S3::Bucket', {
      Properties: Match.objectLike({
        PublicAccessBlockConfiguration: {
          BlockPublicAcls: true,
          BlockPublicPolicy: true,
          IgnorePublicAcls: true,
          RestrictPublicBuckets: true,
        },
        VersioningConfiguration: { Status: 'Enabled' },
      }),
      DeletionPolicy: 'Retain',
      UpdateReplacePolicy: 'Retain',
    });
  });

  it('allows cross-origin GET/HEAD from the web app so the browser can read the bucket directly', () => {
    template.hasResourceProperties('AWS::S3::Bucket', {
      CorsConfiguration: Match.objectLike({
        CorsRules: Match.arrayWith([
          Match.objectLike({
            AllowedOrigins: Match.arrayWith([
              'http://localhost:*',
              'https://mail.example.test',
            ]),
            AllowedMethods: Match.arrayWith(['GET', 'HEAD']),
          }),
        ]),
      }),
    });
  });

  it('writes the exact inbound receiving MX record SES expects', () => {
    template.hasResourceProperties('AWS::Route53::RecordSet', {
      Name: 'example.test.',
      Type: 'MX',
      ResourceRecords: ['10 inbound-smtp.us-east-1.amazonaws.com'],
    });
  });

  it('always creates its own EmailIdentity, with bounce.{domain} as the MAIL FROM domain', () => {
    template.resourceCountIs('AWS::SES::EmailIdentity', 1);
    template.hasResourceProperties('AWS::SES::EmailIdentity', {
      EmailIdentity: 'example.test',
      MailFromAttributes: Match.objectLike({
        MailFromDomain: 'bounce.example.test',
      }),
    });
  });

  it('writes the MAIL FROM domain MX/SPF records on bounce.{domain}', () => {
    template.hasResourceProperties('AWS::Route53::RecordSet', {
      Name: 'bounce.example.test.',
      Type: 'MX',
      ResourceRecords: ['10 feedback-smtp.us-east-1.amazonses.com'],
    });
    template.hasResourceProperties('AWS::Route53::RecordSet', {
      Name: 'bounce.example.test.',
      Type: 'TXT',
      ResourceRecords: Match.arrayWith([Match.stringLikeRegexp('v=spf1')]),
    });
  });

  it('writes a monitor-only (p=none) DMARC record addressed to alertEmail', () => {
    template.hasResourceProperties('AWS::Route53::RecordSet', {
      Name: '_dmarc.example.test.',
      Type: 'TXT',
      ResourceRecords: Match.arrayWith([
        Match.stringLikeRegexp(
          '^"?v=DMARC1; p=none; rua=mailto:alerts@example\\.test"?$',
        ),
      ]),
    });
  });

  it('synthesizes no ForwardFn Lambda when forwardTo is omitted or empty, and every ReceiptRule keeps exactly one action', () => {
    expect(forwardFnLogicalIds(template)).toHaveLength(0);

    const emptyForwardTo = synthMailStack({ mailboxAddresses, forwardTo: {} });
    expect(forwardFnLogicalIds(emptyForwardTo)).toHaveLength(0);
    for (const address of mailboxAddresses) {
      emptyForwardTo.hasResourceProperties('AWS::SES::ReceiptRule', {
        Rule: Match.objectLike({
          Recipients: [address],
          Actions: [Match.objectLike({ S3Action: Match.anyValue() })],
        }),
      });
    }
  });
});

describe('MailStack with forwardTo configured', () => {
  const mailboxAddresses = ['hello@example.test', 'support@example.test'];
  const forwardTo = {
    'hello@example.test': 'me@personal.test',
    'support@example.test': 'me@personal.test',
  };
  const template = synthMailStack({ mailboxAddresses, forwardTo });

  it('creates exactly one ForwardFn Lambda, with FORWARD_MAP and MAIL_BUCKET_NAME in its environment', () => {
    expect(forwardFnLogicalIds(template)).toHaveLength(1);
    template.hasResourceProperties('AWS::Lambda::Function', {
      Environment: {
        Variables: Match.objectLike({
          FORWARD_MAP: JSON.stringify(forwardTo),
          MAIL_BUCKET_NAME: Match.anyValue(),
        }),
      },
    });
  });

  it('wires ForwardFn as a second receipt-rule action, after the S3 action, on each forwarded address’s own ReceiptRule — not an S3 event notification', () => {
    template.resourceCountIs('Custom::S3BucketNotifications', 0);

    const [forwardFnLogicalId] = forwardFnLogicalIds(template);

    for (const address of Object.keys(forwardTo)) {
      template.hasResourceProperties('AWS::SES::ReceiptRule', {
        RuleSetName: SHARED_RULE_SET,
        Rule: Match.objectLike({
          Recipients: [address],
          // Exactly two actions, in this exact order — SES executes a
          // rule's actions in order and ForwardFn's own read depends on the
          // S3 write having already happened.
          Actions: [
            Match.objectLike({
              S3Action: Match.objectLike({
                ObjectKeyPrefix: inboxPrefix(address),
              }),
            }),
            Match.objectLike({
              LambdaAction: Match.objectLike({
                FunctionArn: { 'Fn::GetAtt': [forwardFnLogicalId, 'Arn'] },
              }),
            }),
          ],
        }),
      });
    }
  });

  it("grants ForwardFn's role exactly s3:GetObject on the forwarded addresses' own inbox prefixes — not bucket.grantRead()'s account-wide GetBucket*/List*", () => {
    template.hasResourceProperties('AWS::IAM::Policy', {
      PolicyDocument: Match.objectLike({
        Statement: Match.arrayWith([
          Match.objectLike({
            Effect: 'Allow',
            Action: 's3:GetObject',
            Resource: Object.keys(forwardTo).map((address) => ({
              'Fn::Join': ['', [Match.anyValue(), `/${inboxPrefix(address)}*`]],
            })),
          }),
        ]),
      }),
    });
  });

  it("grants ForwardFn's role ses:SendRawEmail scoped by a ses:FromAddress condition matching exactly the forwarded addresses", () => {
    template.hasResourceProperties('AWS::IAM::Policy', {
      PolicyDocument: Match.objectLike({
        Statement: Match.arrayWith([
          Match.objectLike({
            Effect: 'Allow',
            Action: 'ses:SendRawEmail',
            Resource: '*',
            Condition: {
              StringEquals: { 'ses:FromAddress': Object.keys(forwardTo) },
            },
          }),
        ]),
      }),
    });
  });
});

describe('MailStack auth', () => {
  const template = synthMailStack();

  it('has no self-signup enabled', () => {
    template.hasResourceProperties('AWS::Cognito::UserPool', {
      AdminCreateUserConfig: Match.objectLike({
        AllowAdminCreateUserOnly: true,
      }),
    });
  });

  it("scopes the authenticated role's trust policy to authenticated identities, not unauthenticated", () => {
    template.hasResourceProperties('AWS::IAM::Role', {
      AssumeRolePolicyDocument: Match.objectLike({
        Statement: Match.arrayWith([
          Match.objectLike({
            Effect: 'Allow',
            Action: 'sts:AssumeRoleWithWebIdentity',
            Condition: Match.objectLike({
              'ForAnyValue:StringLike': {
                'cognito-identity.amazonaws.com:amr': 'authenticated',
              },
            }),
          }),
        ]),
      }),
    });
  });

  it('grants the identity pool authenticated role only Bucket.grantRead-level S3 access', () => {
    const policies = Object.entries(
      template.findResources('AWS::IAM::Policy'),
    ).filter(([logicalId]) => logicalId.startsWith('AuthIdentityPool'));
    expect(policies).toHaveLength(1);
    expect(statementActions(policies[0][1])).toEqual([
      's3:GetBucket*',
      's3:GetObject*',
      's3:List*',
    ]);
  });
});

describe('MailStack api', () => {
  const mailboxAddresses = ['hello@example.test', 'support@example.test'];
  const template = synthMailStack({ mailboxAddresses });

  function attachmentBucketId(): string {
    const ids = Object.keys(template.findResources('AWS::S3::Bucket')).filter(
      (id) => id.startsWith('AttachmentBucket'),
    );
    expect(ids).toHaveLength(1);
    return ids[0];
  }

  it("scopes the JWT authorizer to a single audience and doesn't provision a second, silently-drifted user pool client", () => {
    template.hasResourceProperties('AWS::ApiGatewayV2::Authorizer', {
      AuthorizerType: 'JWT',
    });
    const [authorizer] = Object.values(
      template.findResources('AWS::ApiGatewayV2::Authorizer'),
    );
    const audience = (
      authorizer.Properties as { JwtConfiguration: { Audience: unknown[] } }
    ).JwtConfiguration.Audience;
    expect(audience).toHaveLength(1);

    template.resourceCountIs('AWS::Cognito::UserPoolClient', 1);
  });

  it("grants the reply Lambda's role read-only mail S3 plus ses:SendRawEmail (what SES v2 raw sends are authorized as) scoped by a ses:FromAddress condition matching mailboxAddresses", () => {
    template.hasResourceProperties('AWS::IAM::Policy', {
      PolicyDocument: Match.objectLike({
        Statement: Match.arrayWith([
          Match.objectLike({
            Effect: 'Allow',
            Action: 'ses:SendRawEmail',
            Resource: '*',
            Condition: {
              StringEquals: { 'ses:FromAddress': mailboxAddresses },
            },
          }),
        ]),
      }),
    });
    expect(statementActions(defaultPolicyFor(template, 'ApiReplyFn'))).toEqual([
      's3:DeleteObject',
      's3:GetBucket*',
      's3:GetObject',
      's3:GetObject*',
      's3:List*',
      'ses:SendRawEmail',
    ]);
  });

  it("grants the reply Lambda exactly GetObject+DeleteObject on the attachment bucket's objects and the upload Lambda exactly PutObject", () => {
    const objectsOfAttachmentBucket = {
      'Fn::Join': ['', [{ 'Fn::GetAtt': [attachmentBucketId(), 'Arn'] }, '/*']],
    };
    template.hasResourceProperties('AWS::IAM::Policy', {
      PolicyDocument: Match.objectLike({
        Statement: Match.arrayWith([
          {
            Effect: 'Allow',
            Action: ['s3:GetObject', 's3:DeleteObject'],
            Resource: objectsOfAttachmentBucket,
          },
        ]),
      }),
    });
    template.hasResourceProperties('AWS::IAM::Policy', {
      PolicyDocument: {
        Version: '2012-10-17',
        Statement: [
          {
            Effect: 'Allow',
            Action: 's3:PutObject',
            Resource: objectsOfAttachmentBucket,
          },
        ],
      },
    });
  });

  it('gives ReplyFn 1024 MB and a 29s timeout, and passes the attachment bucket to both attachment Lambdas', () => {
    template.hasResourceProperties('AWS::Lambda::Function', {
      MemorySize: 1024,
      Timeout: 29,
      Environment: {
        Variables: Match.objectLike({
          ATTACHMENT_BUCKET_NAME: { Ref: attachmentBucketId() },
          MAIL_BUCKET_NAME: Match.anyValue(),
        }),
      },
    });
    template.hasResourceProperties('AWS::Lambda::Function', {
      Environment: {
        Variables: {
          ATTACHMENT_BUCKET_NAME: { Ref: attachmentBucketId() },
          MAILBOX_ADDRESSES: mailboxAddresses.join(','),
        },
      },
    });
  });

  it('creates an unversioned, SSL-only, private attachment bucket that expires objects after 1 day and allows POST from the web origins', () => {
    const buckets = template.findResources('AWS::S3::Bucket');
    const properties = buckets[attachmentBucketId()].Properties as Record<
      string,
      unknown
    >;
    expect(properties.VersioningConfiguration).toBeUndefined();
    expect(properties.PublicAccessBlockConfiguration).toEqual({
      BlockPublicAcls: true,
      BlockPublicPolicy: true,
      IgnorePublicAcls: true,
      RestrictPublicBuckets: true,
    });
    expect(properties.LifecycleConfiguration).toEqual({
      Rules: [
        {
          Status: 'Enabled',
          ExpirationInDays: 1,
          AbortIncompleteMultipartUpload: { DaysAfterInitiation: 1 },
        },
      ],
    });
    expect(properties.CorsConfiguration).toEqual({
      CorsRules: [
        expect.objectContaining({
          AllowedMethods: ['POST'],
          AllowedOrigins: ['http://localhost:*', 'https://mail.example.test'],
        }),
      ],
    });
    expect(buckets[attachmentBucketId()].DeletionPolicy).toBe('Delete');
    template.hasResourceProperties('AWS::S3::BucketPolicy', {
      Bucket: { Ref: attachmentBucketId() },
      PolicyDocument: Match.objectLike({
        Statement: Match.arrayWith([
          Match.objectLike({
            Effect: 'Deny',
            Condition: { Bool: { 'aws:SecureTransport': 'false' } },
          }),
        ]),
      }),
    });
  });

  it("grants the delete Lambda's role exactly s3:DeleteObject, one resource per mailbox's own inbox prefix — not arnForObjects('*')", () => {
    template.hasResourceProperties('AWS::IAM::Policy', {
      PolicyDocument: {
        Version: '2012-10-17',
        Statement: [
          {
            Effect: 'Allow',
            Action: 's3:DeleteObject',
            Resource: mailboxAddresses.map((address) => ({
              'Fn::Join': ['', [Match.anyValue(), `/${inboxPrefix(address)}*`]],
            })),
          },
        ],
      },
    });
  });

  it('exposes exactly one POST /reply, /attachments and /delete route on a single HttpApi, all behind the same JWT authorizer', () => {
    template.resourceCountIs('AWS::ApiGatewayV2::Api', 1);
    template.resourceCountIs('AWS::ApiGatewayV2::Route', 3);
    template.hasResourceProperties('AWS::ApiGatewayV2::Route', {
      RouteKey: 'POST /attachments',
      AuthorizationType: 'JWT',
    });
    template.hasResourceProperties('AWS::ApiGatewayV2::Route', {
      RouteKey: 'POST /reply',
      AuthorizationType: 'JWT',
    });
    template.hasResourceProperties('AWS::ApiGatewayV2::Route', {
      RouteKey: 'POST /delete',
      AuthorizationType: 'JWT',
    });

    const authorizerIds = Object.values(
      template.findResources('AWS::ApiGatewayV2::Route'),
    ).map(
      (route) =>
        (route.Properties as { AuthorizerId: { Ref: string } }).AuthorizerId
          .Ref,
    );
    expect(new Set(authorizerIds).size).toBe(1);
  });
});

describe('MailStack web hosting', () => {
  const template = synthMailStack();

  it('blocks all public access on the site bucket, destroying it with the stack (pure build output)', () => {
    template.hasResource('AWS::S3::Bucket', {
      Properties: Match.objectLike({
        PublicAccessBlockConfiguration: {
          BlockPublicAcls: true,
          BlockPublicPolicy: true,
          IgnorePublicAcls: true,
          RestrictPublicBuckets: true,
        },
      }),
      DeletionPolicy: 'Delete',
    });
  });

  it('serves mail.{domain} through an Origin Access Control with an SPA 403/404 -> /index.html 200 fallback', () => {
    template.resourceCountIs('AWS::CloudFront::OriginAccessControl', 1);
    template.resourceCountIs(
      'AWS::CloudFront::CloudFrontOriginAccessIdentity',
      0,
    );
    template.hasResourceProperties('AWS::CloudFront::Distribution', {
      DistributionConfig: Match.objectLike({
        Aliases: ['mail.example.test'],
        CustomErrorResponses: Match.arrayWith([
          Match.objectLike({
            ErrorCode: 403,
            ResponseCode: 200,
            ResponsePagePath: '/index.html',
          }),
          Match.objectLike({
            ErrorCode: 404,
            ResponseCode: 200,
            ResponsePagePath: '/index.html',
          }),
        ]),
      }),
    });
    template.hasResourceProperties('AWS::CertificateManager::Certificate', {
      DomainName: 'mail.example.test',
    });
    template.hasResourceProperties('AWS::Route53::RecordSet', {
      Name: 'mail.example.test.',
      Type: 'A',
    });
    template.hasResourceProperties('AWS::Route53::RecordSet', {
      Name: 'mail.example.test.',
      Type: 'AAAA',
    });
  });
});

describe('MailStack outputs', () => {
  it('exposes exactly the keys scripts/deploy-mail-web.sh reads', () => {
    const outputs = Object.keys(synthMailStack().toJSON().Outputs).sort();
    expect(outputs).toEqual(
      [
        'ApiUrl',
        'IdentityPoolId',
        'MailBucketName',
        'MailWebBucketName',
        'MailWebDistributionId',
        'MailWebUrl',
        'MailboxAddresses',
        'UserPoolClientId',
        'UserPoolId',
      ].sort(),
    );
  });

  it('comma-joins the mailbox addresses', () => {
    synthMailStack({
      mailboxAddresses: ['a@example.test', 'b@example.test'],
    }).hasOutput('MailboxAddresses', {
      Value: 'a@example.test,b@example.test',
    });
  });
});
