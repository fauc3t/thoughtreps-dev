import * as cdk from 'aws-cdk-lib/core';
import * as acm from 'aws-cdk-lib/aws-certificatemanager';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as targets from 'aws-cdk-lib/aws-route53-targets';
import * as s3 from 'aws-cdk-lib/aws-s3';
import { Construct } from 'constructs';
import { ExportApi, OPEN_INDEX_NAME } from './api.js';

export interface ShareStackProps extends cdk.StackProps {
  zone: route53.IHostedZone;
  domainName: string;
  exportLinkSubdomain: string;
  appAttestAppId: string;
  feedbackFromAddress: string;
  feedbackToAddress: string;
  waitlistFromAddress: string;
}

// Every /x/<id> URL serves the same static page; the page reads the id from
// the path and the decryption key from the fragment.
const SPA_REWRITE_CODE = `function handler(event) {
  var request = event.request;
  if (request.uri.indexOf('/x/') === 0) {
    request.uri = '/index.html';
  }
  return request;
}
`;

export class ShareStack extends cdk.Stack {
  public readonly exportBucket: s3.Bucket;
  public readonly table: dynamodb.Table;
  public readonly waitlistTable: dynamodb.TableV2;
  public readonly siteBucket: s3.Bucket;
  public readonly distribution: cloudfront.Distribution;

  constructor(scope: Construct, id: string, props: ShareStackProps) {
    super(scope, id, props);

    const {
      zone,
      domainName,
      exportLinkSubdomain,
      appAttestAppId,
      feedbackFromAddress,
      feedbackToAddress,
      waitlistFromAddress,
    } = props;
    const hostname = `${exportLinkSubdomain}.${domainName}`;

    // Deliberately NOT versioned, unlike the (versioned) mail bucket: a
    // delete here must really remove the ciphertext. With versioning a
    // delete would leave a recoverable noncurrent version behind and break
    // the one-time promise. DESTROY is fine: only transient ciphertext.
    this.exportBucket = new s3.Bucket(this, 'ExportBucket', {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      encryption: s3.BucketEncryption.S3_MANAGED,
      versioned: false,
      // Backstop only; the sweeper is the primary deleter. A link expires 24h
      // after /complete (up to 10 min after the object is created), so 2 days
      // keeps this from ever deleting an object while its link is still live.
      lifecycleRules: [
        {
          expiration: cdk.Duration.days(2),
          abortIncompleteMultipartUploadAfter: cdk.Duration.days(1),
        },
      ],
      // Only the download page's presigned GET.
      cors: [
        {
          allowedMethods: [s3.HttpMethods.GET],
          allowedOrigins: [`https://${hostname}`],
          allowedHeaders: ['*'],
        },
      ],
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    this.table = new dynamodb.Table(this, 'ExportLinkTable', {
      partitionKey: { name: 'pk', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      timeToLiveAttribute: 'ttl',
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });
    // Sparse: only records whose object may still exist carry `sweep`.
    this.table.addGlobalSecondaryIndex({
      indexName: OPEN_INDEX_NAME,
      partitionKey: { name: 'sweep', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'sweepAt', type: dynamodb.AttributeType.NUMBER },
      projectionType: dynamodb.ProjectionType.ALL,
    });

    this.waitlistTable = new dynamodb.TableV2(this, 'WaitlistTable', {
      partitionKey: { name: 'email', type: dynamodb.AttributeType.STRING },
      billing: dynamodb.Billing.onDemand(),
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: true },
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    const api = new ExportApi(this, 'Api', {
      exportBucket: this.exportBucket,
      table: this.table,
      appAttestAppId,
      feedbackFromAddress,
      feedbackToAddress,
      waitlistTable: this.waitlistTable,
      waitlistFromAddress,
    });

    this.siteBucket = new s3.Bucket(this, 'TransferSiteBucket', {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // CloudFront requires its cert in us-east-1, which is this app's only
    // region.
    const certificate = new acm.Certificate(this, 'TransferCertificate', {
      domainName: hostname,
      validation: acm.CertificateValidation.fromDns(zone),
    });

    const spaRewrite = new cloudfront.Function(this, 'SpaRewriteFunction', {
      runtime: cloudfront.FunctionRuntime.JS_2_0,
      code: cloudfront.FunctionCode.fromInline(SPA_REWRITE_CODE),
    });

    // The page decrypts in memory with a key from the URL fragment, so nothing
    // beyond its own bundle may run or be contacted:
    //  connect-src 'self'     the /api/v1 status, claim and done calls
    //  connect-src <bucket>   the presigned GET of the encrypted export
    //                         (virtual-hosted regional form, as the SDK signs it)
    const contentSecurityPolicy = [
      "default-src 'self'",
      "script-src 'self'",
      "style-src 'self'",
      "img-src 'self'",
      "font-src 'self'",
      `connect-src 'self' https://${this.exportBucket.bucketName}.s3.${this.region}.amazonaws.com`,
      "base-uri 'none'",
      "form-action 'none'",
      "object-src 'none'",
      "frame-ancestors 'none'",
    ].join('; ');

    const responseHeadersPolicy = new cloudfront.ResponseHeadersPolicy(
      this,
      'TransferHeadersPolicy',
      {
        securityHeadersBehavior: {
          contentSecurityPolicy: { contentSecurityPolicy, override: true },
          strictTransportSecurity: {
            accessControlMaxAge: cdk.Duration.days(730),
            includeSubdomains: true,
            override: true,
          },
          contentTypeOptions: { override: true },
          frameOptions: {
            frameOption: cloudfront.HeadersFrameOption.DENY,
            override: true,
          },
          referrerPolicy: {
            referrerPolicy: cloudfront.HeadersReferrerPolicy.NO_REFERRER,
            override: true,
          },
        },
      },
    );

    this.distribution = new cloudfront.Distribution(
      this,
      'TransferDistribution',
      {
        defaultBehavior: {
          origin: origins.S3BucketOrigin.withOriginAccessControl(
            this.siteBucket,
          ),
          viewerProtocolPolicy:
            cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
          responseHeadersPolicy,
          functionAssociations: [
            {
              function: spaRewrite,
              eventType: cloudfront.FunctionEventType.VIEWER_REQUEST,
            },
          ],
        },
        additionalBehaviors: {
          '/api/*': {
            origin: new origins.HttpOrigin(
              `${api.httpApi.apiId}.execute-api.${this.region}.${this.urlSuffix}`,
            ),
            viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.HTTPS_ONLY,
            allowedMethods: cloudfront.AllowedMethods.ALLOW_ALL,
            cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,
            // Forwards x-tr-* headers, Origin (for the waitlist's CORS) and
            // the body untouched; the API origin needs its own Host, so that
            // one is excluded. ALLOW_ALL lets OPTIONS preflights through.
            originRequestPolicy:
              cloudfront.OriginRequestPolicy.ALL_VIEWER_EXCEPT_HOST_HEADER,
          },
        },
        domainNames: [hostname],
        certificate,
        defaultRootObject: 'index.html',
      },
    );

    const target = route53.RecordTarget.fromAlias(
      new targets.CloudFrontTarget(this.distribution),
    );
    new route53.ARecord(this, 'TransferAliasA', {
      zone,
      recordName: exportLinkSubdomain,
      target,
    });
    new route53.AaaaRecord(this, 'TransferAliasAAAA', {
      zone,
      recordName: exportLinkSubdomain,
      target,
    });

    new cdk.CfnOutput(this, 'ExportBucketName', {
      value: this.exportBucket.bucketName,
    });
    new cdk.CfnOutput(this, 'ExportLinkTableName', {
      value: this.table.tableName,
    });
    new cdk.CfnOutput(this, 'WaitlistTableName', {
      value: this.waitlistTable.tableName,
    });
    new cdk.CfnOutput(this, 'TransferSiteBucketName', {
      value: this.siteBucket.bucketName,
    });
    new cdk.CfnOutput(this, 'TransferDistributionId', {
      value: this.distribution.distributionId,
    });
    new cdk.CfnOutput(this, 'TransferUrl', { value: `https://${hostname}` });
    new cdk.CfnOutput(this, 'ExportApiUrl', {
      value: `https://${hostname}/api/v1`,
    });
  }
}
