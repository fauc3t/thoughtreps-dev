import * as cdk from 'aws-cdk-lib/core';
import * as route53 from 'aws-cdk-lib/aws-route53';
import { Match, Template } from 'aws-cdk-lib/assertions';
import { LandingStack } from '../lib/landing-stack.js';
import { securityHeaders } from './helpers.js';

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
    exportLinkSubdomain: 'transfer',
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

  describe('viewer-request function behavior', () => {
    const [fn] = Object.values(
      template.findResources('AWS::CloudFront::Function'),
    );
    const code = (fn.Properties as { FunctionCode: string }).FunctionCode;
    type Req = {
      uri: string;
      headers: Record<string, { value: string }>;
      querystring: Record<
        string,
        { value?: string; multiValue?: { value: string }[] }
      >;
    };
    const handler = new Function(`${code}; return handler;`)() as (event: {
      request: Req;
    }) => Req & {
      statusCode?: number;
      headers: Record<string, { value: string }>;
    };
    const run = (
      uri: string,
      host = 'example.test',
      querystring: Req['querystring'] = {},
    ) =>
      handler({
        request: { uri, headers: { host: { value: host } }, querystring },
      });

    it.each([
      ['/', '/index.html'],
      ['/help', '/help/index.html'],
      ['/help/', '/help/index.html'],
      ['/help/backup-and-restore', '/help/backup-and-restore/index.html'],
      ['/help/backup-and-restore/', '/help/backup-and-restore/index.html'],
      ['/assets/x.js', '/assets/x.js'],
      ['/favicon.svg', '/favicon.svg'],
      ['/sitemap.xml', '/sitemap.xml'],
      ['/404.html', '/404.html'],
      ['/help/index.html', '/help/index.html'],
      ['/help/v1.2/guide', '/help/v1.2/guide/index.html'],
      ['/help/v1.2', '/help/v1.2'],
    ])('rewrites apex %s to %s', (uri, expected) => {
      expect(run(uri).uri).toBe(expected);
    });

    it('301s www to the apex first, preserving path and query without rewriting the path', () => {
      const res = run('/help', 'www.example.test', { a: { value: '1' } });
      expect(res.statusCode).toBe(301);
      expect(res.headers.location.value).toBe('https://example.test/help?a=1');
    });

    it('301s www/help/ to the apex without appending index.html', () => {
      const res = run('/help/', 'www.example.test');
      expect(res.statusCode).toBe(301);
      expect(res.headers.location.value).toBe('https://example.test/help/');
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

  it('attaches a custom security-headers policy to the default behavior', () => {
    const {
      policyId,
      csp,
      hsts,
      frameOption,
      contentTypeOptions,
      referrerPolicy,
    } = securityHeaders(template);
    expect(hsts).toMatchObject({
      IncludeSubdomains: true,
      Override: true,
    });
    expect(hsts.AccessControlMaxAgeSec).toBeGreaterThanOrEqual(31536000);
    expect(contentTypeOptions).toEqual({ Override: true });
    expect(frameOption).toEqual({ FrameOption: 'DENY', Override: true });
    expect(referrerPolicy).toBe('strict-origin-when-cross-origin');
    expect(csp).toContain("script-src 'self'");
    expect(csp).toContain("img-src 'self' data:");
    expect(csp).toContain("font-src 'self' data:");
    expect(csp).toContain("connect-src 'self' https://transfer.example.test");
    expect(csp).toContain("frame-ancestors 'none'");
    expect(csp.join(';')).not.toContain('unsafe-eval');
    template.hasResourceProperties('AWS::CloudFront::Distribution', {
      DistributionConfig: Match.objectLike({
        DefaultCacheBehavior: Match.objectLike({
          ResponseHeadersPolicyId: { Ref: policyId },
        }),
      }),
    });
  });
});
