import * as cdk from 'aws-cdk-lib/core';
import * as route53 from 'aws-cdk-lib/aws-route53';
import { Match, Template } from 'aws-cdk-lib/assertions';
import { LandingStack } from '../lib/landing-stack.js';

function synthLandingStack() {
  const app = new cdk.App();
  const env = { account: '111111111111', region: 'us-east-1' };
  const zoneStack = new cdk.Stack(app, 'ZoneStack', { env });
  const zone = route53.HostedZone.fromHostedZoneAttributes(zoneStack, 'Zone', {
    hostedZoneId: 'Z1234567890ABC',
    zoneName: 'example.test',
  });
  const stack = new LandingStack(app, 'TestLandingStack', {
    env,
    zone,
    domainName: 'example.test',
  });
  return Template.fromStack(stack);
}

describe('LandingStack', () => {
  const template = synthLandingStack();

  it('blocks all public access on the bucket and destroys it with the stack (pure build output)', () => {
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

  it('fronts the bucket with an Origin Access Control, not a legacy Origin Access Identity', () => {
    template.resourceCountIs('AWS::CloudFront::OriginAccessControl', 1);
    template.resourceCountIs(
      'AWS::CloudFront::CloudFrontOriginAccessIdentity',
      0,
    );
  });

  it('issues one DNS-validated cert covering the apex and www', () => {
    template.hasResourceProperties('AWS::CertificateManager::Certificate', {
      DomainName: 'example.test',
      SubjectAlternativeNames: ['www.example.test'],
      ValidationMethod: 'DNS',
    });
  });

  it('serves both the apex and www from one distribution that redirects HTTP to HTTPS', () => {
    template.resourceCountIs('AWS::CloudFront::Distribution', 1);
    template.hasResourceProperties('AWS::CloudFront::Distribution', {
      DistributionConfig: Match.objectLike({
        Aliases: ['example.test', 'www.example.test'],
        DefaultRootObject: 'index.html',
        DefaultCacheBehavior: Match.objectLike({
          ViewerProtocolPolicy: 'redirect-to-https',
        }),
      }),
    });
  });

  it('attaches the www-redirect function on viewer-request, 301-ing www to the apex', () => {
    template.hasResourceProperties('AWS::CloudFront::Function', {
      FunctionConfig: Match.objectLike({ Runtime: 'cloudfront-js-2.0' }),
    });
    const [fn] = Object.values(
      template.findResources('AWS::CloudFront::Function'),
    );
    const code = (fn.Properties as { FunctionCode: string }).FunctionCode;
    expect(code).toContain("'www.example.test'");
    expect(code).toContain('statusCode: 301');
    expect(code).toContain("'https://example.test'");
    template.hasResourceProperties('AWS::CloudFront::Distribution', {
      DistributionConfig: Match.objectLike({
        DefaultCacheBehavior: Match.objectLike({
          FunctionAssociations: [
            Match.objectLike({
              EventType: 'viewer-request',
              FunctionARN: Match.anyValue(),
            }),
          ],
        }),
      }),
    });
  });

  it('maps 403 and 404 to /404.html with a real 404 status (static site, not an SPA)', () => {
    template.hasResourceProperties('AWS::CloudFront::Distribution', {
      DistributionConfig: Match.objectLike({
        CustomErrorResponses: Match.arrayEquals([
          Match.objectLike({
            ErrorCode: 403,
            ResponseCode: 404,
            ResponsePagePath: '/404.html',
          }),
          Match.objectLike({
            ErrorCode: 404,
            ResponseCode: 404,
            ResponsePagePath: '/404.html',
          }),
        ]),
      }),
    });
  });

  it('writes A and AAAA alias records for both the apex and www', () => {
    for (const name of ['example.test.', 'www.example.test.']) {
      for (const type of ['A', 'AAAA']) {
        template.hasResourceProperties('AWS::Route53::RecordSet', {
          Name: name,
          Type: type,
          AliasTarget: Match.anyValue(),
        });
      }
    }
  });

  it('outputs what scripts/deploy-landing.sh reads', () => {
    template.hasOutput('LandingBucketName', {});
    template.hasOutput('LandingDistributionId', {});
    template.hasOutput('LandingUrl', { Value: 'https://example.test' });
  });
});
