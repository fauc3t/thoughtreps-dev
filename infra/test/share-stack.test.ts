import * as cdk from 'aws-cdk-lib/core';
import * as route53 from 'aws-cdk-lib/aws-route53';
import { Match, Template } from 'aws-cdk-lib/assertions';
import { ShareStack } from '../lib/export-link/share-stack.js';

function synthShareStack() {
  const app = new cdk.App();
  const env = { account: '111111111111', region: 'us-east-1' };
  const zoneStack = new cdk.Stack(app, 'ZoneStack', { env });
  const zone = route53.HostedZone.fromHostedZoneAttributes(zoneStack, 'Zone', {
    hostedZoneId: 'Z1234567890ABC',
    zoneName: 'example.test',
  });
  const stack = new ShareStack(app, 'TestShareStack', {
    env,
    zone,
    domainName: 'example.test',
    exportLinkSubdomain: 'transfer',
    appAttestAppId: 'TEAM.com.example.app',
    feedbackFromAddress: 'feedback@example.test',
    feedbackToAddress: 'hello@example.test',
  });
  return Template.fromStack(stack);
}

type Statement = {
  Action: string | string[];
  Effect: string;
  Resource: unknown;
};

function statementsFor(template: Template, fnId: string): Statement[] {
  const fn = Object.entries(
    template.findResources('AWS::Lambda::Function'),
  ).find(([logicalId]) => logicalId.startsWith(fnId));
  expect(fn).toBeDefined();
  const roleRef = (
    fn?.[1].Properties as { Role: { 'Fn::GetAtt': [string, string] } }
  ).Role['Fn::GetAtt'][0];
  const policies = Object.values(
    template.findResources('AWS::IAM::Policy'),
  ).filter((policy) =>
    (policy.Properties as { Roles: Array<{ Ref: string }> }).Roles.some(
      (role) => role.Ref === roleRef,
    ),
  );
  expect(policies).toHaveLength(1);
  return (
    policies[0].Properties as { PolicyDocument: { Statement: Statement[] } }
  ).PolicyDocument.Statement;
}

const actionsOf = (statements: Statement[]) =>
  statements
    .flatMap((s) => (Array.isArray(s.Action) ? s.Action : [s.Action]))
    .sort();

const s3Statements = (statements: Statement[]) =>
  statements.filter((s) =>
    (Array.isArray(s.Action) ? s.Action : [s.Action]).some((a) =>
      a.startsWith('s3:'),
    ),
  );

describe('ShareStack', () => {
  const template = synthShareStack();

  it('keeps the export bucket private, encrypted, SSL-only and NOT versioned', () => {
    const buckets = template.findResources('AWS::S3::Bucket', {
      Properties: Match.objectLike({
        LifecycleConfiguration: Match.anyValue(),
      }),
    });
    const [bucket] = Object.values(buckets);
    expect(Object.keys(buckets)).toHaveLength(1);
    expect(bucket.DeletionPolicy).toBe('Delete');
    const props = bucket.Properties as Record<string, unknown>;
    expect(props.VersioningConfiguration).toBeUndefined();
    expect(props.PublicAccessBlockConfiguration).toEqual({
      BlockPublicAcls: true,
      BlockPublicPolicy: true,
      IgnorePublicAcls: true,
      RestrictPublicBuckets: true,
    });
    expect(props.BucketEncryption).toEqual({
      ServerSideEncryptionConfiguration: [
        { ServerSideEncryptionByDefault: { SSEAlgorithm: 'AES256' } },
      ],
    });
  });

  it('expires objects and aborts multipart uploads after 2 days', () => {
    template.hasResourceProperties('AWS::S3::Bucket', {
      LifecycleConfiguration: {
        Rules: [
          Match.objectLike({
            Status: 'Enabled',
            ExpirationInDays: 2,
            AbortIncompleteMultipartUpload: { DaysAfterInitiation: 1 },
          }),
        ],
      },
    });
  });

  it('allows only GET from the transfer origin via CORS', () => {
    template.hasResourceProperties('AWS::S3::Bucket', {
      CorsConfiguration: {
        CorsRules: [
          Match.objectLike({
            AllowedMethods: ['GET'],
            AllowedOrigins: ['https://transfer.example.test'],
          }),
        ],
      },
    });
  });

  it('denies non-SSL access to the export bucket', () => {
    template.hasResourceProperties('AWS::S3::BucketPolicy', {
      PolicyDocument: {
        Statement: Match.arrayWith([
          Match.objectLike({
            Effect: 'Deny',
            Condition: { Bool: { 'aws:SecureTransport': 'false' } },
          }),
        ]),
      },
    });
  });

  it('defines the table with TTL, on-demand billing and the sparse openIndex', () => {
    template.hasResource('AWS::DynamoDB::Table', {
      Properties: Match.objectLike({
        KeySchema: [{ AttributeName: 'pk', KeyType: 'HASH' }],
        BillingMode: 'PAY_PER_REQUEST',
        TimeToLiveSpecification: { AttributeName: 'ttl', Enabled: true },
        GlobalSecondaryIndexes: [
          Match.objectLike({
            IndexName: 'openIndex',
            KeySchema: [
              { AttributeName: 'sweep', KeyType: 'HASH' },
              { AttributeName: 'sweepAt', KeyType: 'RANGE' },
            ],
          }),
        ],
        AttributeDefinitions: Match.arrayWith([
          { AttributeName: 'sweep', AttributeType: 'S' },
          { AttributeName: 'sweepAt', AttributeType: 'N' },
        ]),
      }),
      DeletionPolicy: 'Delete',
    });
  });

  it('scopes every S3 grant to exports/* and never grants bucket-wide actions', () => {
    for (const fnId of [
      'ApiDeviceFn',
      'ApiExportLinkFn',
      'ApiFeedbackFn',
      'ApiPublicFn',
      'ApiSweepFn',
    ]) {
      for (const statement of s3Statements(statementsFor(template, fnId))) {
        const actions = Array.isArray(statement.Action)
          ? statement.Action
          : [statement.Action];
        expect(actions.some((a) => /List|GetBucket/.test(a))).toBe(false);
        expect(JSON.stringify(statement.Resource)).toContain('/exports/*');
      }
    }
  });

  it('gives each function exactly its S3 and DynamoDB actions', () => {
    const s3Of = (fnId: string) =>
      actionsOf(s3Statements(statementsFor(template, fnId)));
    expect(s3Of('ApiDeviceFn')).toEqual([]);
    expect(s3Of('ApiFeedbackFn')).toEqual([]);
    expect(s3Of('ApiExportLinkFn')).toEqual([
      's3:DeleteObject',
      's3:GetObject',
      's3:PutObject',
    ]);
    expect(s3Of('ApiPublicFn')).toEqual(['s3:DeleteObject', 's3:GetObject']);
    expect(s3Of('ApiSweepFn')).toEqual(['s3:DeleteObject']);

    const dynamoOf = (fnId: string) =>
      actionsOf(
        statementsFor(template, fnId).filter((s) =>
          [s.Action].flat().some((a) => a.startsWith('dynamodb:')),
        ),
      );
    expect(dynamoOf('ApiDeviceFn')).toEqual([
      'dynamodb:DeleteItem',
      'dynamodb:PutItem',
    ]);
    expect(dynamoOf('ApiFeedbackFn')).toEqual([
      'dynamodb:DeleteItem',
      'dynamodb:GetItem',
      'dynamodb:UpdateItem',
    ]);
    expect(dynamoOf('ApiSweepFn')).toEqual([
      'dynamodb:Query',
      'dynamodb:UpdateItem',
    ]);
    expect(dynamoOf('ApiPublicFn')).toEqual([
      'dynamodb:GetItem',
      'dynamodb:UpdateItem',
    ]);
  });

  it('lets FeedbackFn send only as the feedback address and passes the addresses via env', () => {
    const send = statementsFor(template, 'ApiFeedbackFn').filter((s) =>
      [s.Action].flat().some((a) => a.startsWith('ses:')),
    );
    expect(send).toHaveLength(1);
    expect(send[0]).toMatchObject({
      Action: 'ses:SendEmail',
      Effect: 'Allow',
      Resource: '*',
      Condition: {
        StringEquals: { 'ses:FromAddress': 'feedback@example.test' },
      },
    });
    template.hasResourceProperties('AWS::Lambda::Function', {
      Environment: {
        Variables: Match.objectLike({
          FEEDBACK_FROM_ADDRESS: 'feedback@example.test',
          FEEDBACK_TO_ADDRESS: 'hello@example.test',
        }),
      },
    });
  });

  it('limits the sweeper Query to the openIndex index', () => {
    const query = statementsFor(template, 'ApiSweepFn').find((s) =>
      [s.Action].flat().includes('dynamodb:Query'),
    );
    expect(JSON.stringify(query?.Resource)).toContain('/index/openIndex');
  });

  it('runs the sweeper every 15 minutes', () => {
    template.hasResourceProperties('AWS::Events::Rule', {
      ScheduleExpression: 'rate(15 minutes)',
      Targets: [Match.objectLike({ Arn: Match.anyValue() })],
    });
  });

  it('runs all five functions on Node 24', () => {
    for (const name of [
      'DeviceFn',
      'ExportLinkFn',
      'FeedbackFn',
      'PublicFn',
      'SweepFn',
    ]) {
      const fns = Object.entries(
        template.findResources('AWS::Lambda::Function', {
          Properties: Match.objectLike({ Runtime: 'nodejs24.x' }),
        }),
      ).filter(([logicalId]) => logicalId.startsWith(`Api${name}`));
      expect(fns).toHaveLength(1);
    }
  });

  it('routes every API path under /api/v1', () => {
    const routes = Object.values(
      template.findResources('AWS::ApiGatewayV2::Route'),
    )
      .map((r) => (r.Properties as { RouteKey: string }).RouteKey)
      .sort();
    expect(routes).toEqual(
      [
        'GET /api/v1/export-links/{id}',
        'POST /api/v1/challenge',
        'POST /api/v1/devices',
        'POST /api/v1/export-links',
        'POST /api/v1/export-links/complete',
        'POST /api/v1/export-links/current',
        'POST /api/v1/export-links/revoke',
        'POST /api/v1/export-links/{id}/claim',
        'POST /api/v1/export-links/{id}/done',
        'POST /api/v1/feedback',
      ].sort(),
    );
  });

  it('throttles the default stage to rate 10 / burst 20 and sets no CORS', () => {
    template.hasResourceProperties('AWS::ApiGatewayV2::Stage', {
      StageName: '$default',
      DefaultRouteSettings: {
        ThrottlingRateLimit: 10,
        ThrottlingBurstLimit: 20,
      },
    });
    const [api] = Object.values(
      template.findResources('AWS::ApiGatewayV2::Api'),
    );
    expect((api.Properties as Record<string, unknown>).CorsConfiguration).toBe(
      undefined,
    );
  });

  it('serves the site and /api/* from one distribution on transfer.example.test', () => {
    template.resourceCountIs('AWS::CloudFront::Distribution', 1);
    template.hasResourceProperties('AWS::CloudFront::Distribution', {
      DistributionConfig: Match.objectLike({
        Aliases: ['transfer.example.test'],
        DefaultCacheBehavior: Match.objectLike({
          ViewerProtocolPolicy: 'redirect-to-https',
          FunctionAssociations: [
            Match.objectLike({ EventType: 'viewer-request' }),
          ],
        }),
        CacheBehaviors: [
          Match.objectLike({
            PathPattern: '/api/*',
            ViewerProtocolPolicy: 'https-only',
            AllowedMethods: [
              'GET',
              'HEAD',
              'OPTIONS',
              'PUT',
              'PATCH',
              'POST',
              'DELETE',
            ],
            // Managed CachingDisabled / AllViewerExceptHostHeader policies.
            CachePolicyId: '4135ea2d-6df8-44a3-9df3-4b5a84be39ad',
            OriginRequestPolicyId: 'b689b0a8-53d0-40ab-baf2-68738e2966ac',
          }),
        ],
      }),
    });
  });

  it('points the /api/* origin at the HTTP API and the default origin at the private site bucket via OAC', () => {
    template.resourceCountIs('AWS::CloudFront::OriginAccessControl', 1);
    template.hasResourceProperties('AWS::CloudFront::Distribution', {
      DistributionConfig: Match.objectLike({
        Origins: Match.arrayWith([
          Match.objectLike({ OriginAccessControlId: Match.anyValue() }),
          Match.objectLike({
            CustomOriginConfig: Match.objectLike({
              OriginProtocolPolicy: 'https-only',
            }),
            DomainName: Match.objectLike({
              'Fn::Join': Match.arrayWith([
                Match.arrayWith(['.execute-api.us-east-1.']),
              ]),
            }),
          }),
        ]),
      }),
    });
  });

  it('rewrites /x/* to /index.html on viewer-request', () => {
    const [fn] = Object.values(
      template.findResources('AWS::CloudFront::Function'),
    );
    const code = (fn.Properties as { FunctionCode: string }).FunctionCode;
    expect(code).toContain("indexOf('/x/') === 0");
    expect(code).toContain("request.uri = '/index.html'");
    expect(
      (fn.Properties as { FunctionConfig: { Runtime: string } }).FunctionConfig
        .Runtime,
    ).toBe('cloudfront-js-2.0');
  });

  it('issues a DNS-validated cert and A/AAAA aliases for the transfer host', () => {
    template.hasResourceProperties('AWS::CertificateManager::Certificate', {
      DomainName: 'transfer.example.test',
      ValidationMethod: 'DNS',
    });
    for (const type of ['A', 'AAAA']) {
      template.hasResourceProperties('AWS::Route53::RecordSet', {
        Name: 'transfer.example.test.',
        Type: type,
        AliasTarget: Match.anyValue(),
      });
    }
  });

  it('exposes the outputs deploy tooling reads', () => {
    for (const key of [
      'ExportBucketName',
      'ExportLinkTableName',
      'TransferSiteBucketName',
      'TransferDistributionId',
    ]) {
      template.hasOutput(key, {});
    }
    template.hasOutput('TransferUrl', {
      Value: 'https://transfer.example.test',
    });
    template.hasOutput('ExportApiUrl', {
      Value: 'https://transfer.example.test/api/v1',
    });
  });
});
