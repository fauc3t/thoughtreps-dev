import * as cdk from 'aws-cdk-lib/core';
import * as acm from 'aws-cdk-lib/aws-certificatemanager';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as targets from 'aws-cdk-lib/aws-route53-targets';
import * as s3 from 'aws-cdk-lib/aws-s3';
import { Construct } from 'constructs';

export interface LandingStackProps extends cdk.StackProps {
  zone: route53.IHostedZone;
  domainName: string;
}

export class LandingStack extends cdk.Stack {
  public readonly bucket: s3.Bucket;
  public readonly distribution: cloudfront.Distribution;

  constructor(scope: Construct, id: string, props: LandingStackProps) {
    super(scope, id, props);

    const { zone, domainName } = props;
    const wwwDomainName = `www.${domainName}`;

    // DESTROY: holds nothing but the landing site's build output, which
    // scripts/deploy-landing.sh regenerates. RETAIN would only leave an
    // orphaned bucket behind on every replacement.
    this.bucket = new s3.Bucket(this, 'LandingBucket', {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // CloudFront requires its cert in us-east-1, which is this app's only
    // region, so no cross-region cert stack is needed.
    const certificate = new acm.Certificate(this, 'LandingCertificate', {
      domainName,
      subjectAlternativeNames: [wwwDomainName],
      validation: acm.CertificateValidation.fromDns(zone),
    });

    const wwwRedirect = new cloudfront.Function(this, 'WwwRedirectFunction', {
      runtime: cloudfront.FunctionRuntime.JS_2_0,
      code: cloudfront.FunctionCode.fromInline(`function handler(event) {
  var request = event.request;
  var host = request.headers.host && request.headers.host.value;
  if (host !== '${wwwDomainName}') {
    return request;
  }
  var query = Object.keys(request.querystring)
    .map(function (key) {
      var param = request.querystring[key];
      var values = param.multiValue
        ? param.multiValue.map(function (entry) { return entry.value; })
        : [param.value];
      return values
        .map(function (value) { return value ? key + '=' + value : key; })
        .join('&');
    })
    .join('&');
  return {
    statusCode: 301,
    statusDescription: 'Moved Permanently',
    headers: {
      location: { value: 'https://${domainName}' + request.uri + (query ? '?' + query : '') },
    },
  };
}
`),
    });

    // Static site, not an SPA: a missing key (S3 returns 403 on an OAC
    // bucket without list permission, 404 otherwise) shows the site's own
    // 404 page with a real 404 status.
    this.distribution = new cloudfront.Distribution(
      this,
      'LandingDistribution',
      {
        defaultBehavior: {
          origin: origins.S3BucketOrigin.withOriginAccessControl(this.bucket),
          viewerProtocolPolicy:
            cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
          functionAssociations: [
            {
              function: wwwRedirect,
              eventType: cloudfront.FunctionEventType.VIEWER_REQUEST,
            },
          ],
        },
        domainNames: [domainName, wwwDomainName],
        certificate,
        defaultRootObject: 'index.html',
        errorResponses: [
          {
            httpStatus: 403,
            responseHttpStatus: 404,
            responsePagePath: '/404.html',
          },
          {
            httpStatus: 404,
            responseHttpStatus: 404,
            responsePagePath: '/404.html',
          },
        ],
      },
    );

    const target = route53.RecordTarget.fromAlias(
      new targets.CloudFrontTarget(this.distribution),
    );
    new route53.ARecord(this, 'ApexAliasA', { zone, target });
    new route53.AaaaRecord(this, 'ApexAliasAAAA', { zone, target });
    new route53.ARecord(this, 'WwwAliasA', {
      zone,
      recordName: 'www',
      target,
    });
    new route53.AaaaRecord(this, 'WwwAliasAAAA', {
      zone,
      recordName: 'www',
      target,
    });

    new cdk.CfnOutput(this, 'LandingBucketName', {
      value: this.bucket.bucketName,
    });
    new cdk.CfnOutput(this, 'LandingDistributionId', {
      value: this.distribution.distributionId,
    });
    new cdk.CfnOutput(this, 'LandingUrl', { value: `https://${domainName}` });
  }
}
