import * as cdk from 'aws-cdk-lib/core';
import * as acm from 'aws-cdk-lib/aws-certificatemanager';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as targets from 'aws-cdk-lib/aws-route53-targets';
import * as s3 from 'aws-cdk-lib/aws-s3';
import { Construct } from 'constructs';

export interface MailWebHostingProps {
  zone: route53.IHostedZone;
  domainName: string;
}

export class MailWebHosting extends Construct {
  public readonly bucket: s3.Bucket;
  public readonly distribution: cloudfront.Distribution;

  constructor(scope: Construct, id: string, props: MailWebHostingProps) {
    super(scope, id);

    const { zone, domainName } = props;
    const hostname = `mail.${domainName}`;

    // Explicit DESTROY — unlike the mail bucket (irreplaceable raw mail),
    // this bucket holds nothing but the built SPA's static output. Losing it
    // just means re-running scripts/deploy-mail-web.sh; there's no data to
    // lose, so RETAIN would only leave an orphaned bucket behind on every
    // replacement.
    this.bucket = new s3.Bucket(this, 'SiteBucket', {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // us-east-1 is this app's only region (see mail-stack.ts for why), which
    // is also the region CloudFront requires its cert to be issued in — so
    // this needs no cross-region cert stack of its own.
    const certificate = new acm.Certificate(this, 'SiteCertificate', {
      domainName: hostname,
      validation: acm.CertificateValidation.fromDns(zone),
    });

    this.distribution = new cloudfront.Distribution(this, 'SiteDistribution', {
      defaultBehavior: {
        origin: origins.S3BucketOrigin.withOriginAccessControl(this.bucket),
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
      },
      domainNames: [hostname],
      certificate,
      defaultRootObject: 'index.html',
      // SPA routing: the bucket is OAC-only with no directory listing, so a
      // client-side route with no matching S3 key comes back as a 403/404
      // from S3. Map both back to index.html with a 200 so the SPA's own
      // router can take over instead of the visitor seeing raw S3 error XML.
      errorResponses: [
        {
          httpStatus: 403,
          responseHttpStatus: 200,
          responsePagePath: '/index.html',
        },
        {
          httpStatus: 404,
          responseHttpStatus: 200,
          responsePagePath: '/index.html',
        },
      ],
    });

    const target = route53.RecordTarget.fromAlias(
      new targets.CloudFrontTarget(this.distribution),
    );
    new route53.ARecord(this, 'SiteAliasA', {
      zone,
      recordName: 'mail',
      target,
    });
    new route53.AaaaRecord(this, 'SiteAliasAAAA', {
      zone,
      recordName: 'mail',
      target,
    });
  }
}
