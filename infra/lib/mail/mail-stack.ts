import * as cdk from 'aws-cdk-lib/core';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import { NodejsFunction } from 'aws-cdk-lib/aws-lambda-nodejs';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as ses from 'aws-cdk-lib/aws-ses';
import * as actions from 'aws-cdk-lib/aws-ses-actions';
import { Construct } from 'constructs';
import { fileURLToPath } from 'node:url';
import * as path from 'node:path';
import type { EnvName } from '../env-config.js';
import { MailApi } from './api.js';
import { MailAuth } from './auth.js';
import { inboxPrefix } from './inbox.js';
import { MailWebHosting } from './web-hosting.js';

// Not named __dirname: same NodeNext-ESM-vs-@swc/jest-CJS-shim reasoning
// api.ts's own moduleDir constant documents.
const moduleDir = path.dirname(fileURLToPath(import.meta.url));

export interface MailStackProps extends cdk.StackProps {
  zone: route53.IHostedZone;
  domainName: string;
  mailboxAddresses: string[];
  alertEmail: string;
  envName: EnvName;
  // See EnvConfig.sharedReceiptRuleSetName (env-config.ts).
  sharedReceiptRuleSetName: string;
  // See EnvConfig.forwardTo (env-config.ts) — skipped entirely when
  // unset/empty, so no ForwardFn-related resources are synthesized.
  forwardTo?: Record<string, string>;
}

// Everything mail-related in one stack: receiving (SES identity, MX, rules,
// bucket, forwarding), sign-in (Cognito), the reply/delete API, and the
// mail.{domainName} web UI hosting.
export class MailStack extends cdk.Stack {
  public readonly bucket: s3.Bucket;

  constructor(scope: Construct, id: string, props: MailStackProps) {
    super(scope, id, props);

    const {
      zone,
      domainName,
      mailboxAddresses,
      alertEmail,
      envName,
      sharedReceiptRuleSetName,
      forwardTo,
    } = props;

    // Verifies `domainName` as an SES identity — writes the DKIM CNAMEs plus
    // the verification record straight into the zone (publicHostedZone
    // knows how to write both). IMPORTANT: this does NOT create the inbound
    // receiving MX record. The MX records EmailIdentity is capable of
    // creating are only for the *sending*-side custom MAIL FROM domain —
    // inbound receiving still needs its own hand-written MX record, below,
    // since that's a separate record on the bare apex, not this subdomain.
    //
    // No other stack owns an SES identity for thoughtreps.com, so this
    // stack always creates it (SES allows only one identity per domain per
    // account).
    //
    // mailFromDomain deliberately isn't `mail.${domainName}` — that hostname
    // is already claimed by MailWebHosting for the web app's own URL.
    // Reusing it here would put the human-facing webmail URL and this
    // invisible technical bounce-domain on the same subdomain.
    //
    // Combined with Identity.publicHostedZone, this single prop also writes
    // the MAIL FROM domain's required MX record (to
    // feedback-smtp.{region}.amazonses.com) and SPF TXT record
    // (`v=spf1 include:amazonses.com ~all`) into the same zone automatically
    // — no hand-written MX or TXT record needed for this one, unlike
    // inbound receiving below.
    new ses.EmailIdentity(this, 'MailIdentity', {
      identity: ses.Identity.publicHostedZone(zone),
      mailFromDomain: `bounce.${domainName}`,
    });

    // SES email *receiving* (as opposed to sending) is only available in a
    // specific region allow-list, not every region SES itself supports.
    // us-east-1 is deliberately this app's only region: it's on that
    // receiving allow-list, and it's also the one region a CloudFront ACM
    // cert must live in (see web-hosting.ts and landing-stack.ts) — so a
    // single-region deployment covers both needs with no cross-region
    // certificate juggling.
    new route53.MxRecord(this, 'InboundMx', {
      zone,
      values: [
        {
          priority: 10,
          hostName: `inbound-smtp.${this.region}.amazonaws.com`,
        },
      ],
    });

    // p=none (monitor-only) is deliberate, not a placeholder left too
    // permissive: starting in enforcement mode (p=quarantine) risks the
    // domain's own legitimate replies getting quarantined if anything about
    // SPF/DKIM/mailFromDomain is misconfigured on day one. Flipping to
    // p=quarantine is an intended follow-up once aggregate DMARC reports
    // (sent to alertEmail via the rua= address below) confirm clean
    // delivery.
    new route53.TxtRecord(this, 'DmarcRecord', {
      zone,
      recordName: `_dmarc.${domainName}`,
      values: [`v=DMARC1; p=none; rua=mailto:${alertEmail}`],
    });

    // Holds every configured address's raw received mail — irreplaceable
    // once delivered (SES doesn't re-deliver a message after accepting it),
    // so this gets an explicit RETAIN even though Bucket already defaults to
    // it: self-documenting, not redundant.
    this.bucket = new s3.Bucket(this, 'MailBucket', {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      // The safety net for DeleteFn: with versioning on, s3:DeleteObject
      // creates a delete marker instead of permanently destroying the
      // object, so an accidental delete is recoverable (remove the delete
      // marker / restore the prior version) rather than unrecoverable.
      // Costs nothing, purely additive — doesn't interact with the
      // receipt-rule S3 action, the bucket policy, or the CORS config below
      // in any way.
      versioned: true,
      // mail-web reads this bucket directly from the browser (locked
      // decision: no backend read API) — a correct, scoped IAM policy on
      // the Cognito authenticated role is not sufficient on its own for
      // that to work. S3 does not send CORS headers by default, and the
      // browser enforces CORS before IAM's answer ever matters: a
      // cross-origin GET with SigV4 headers (Authorization,
      // x-amz-content-sha256, x-amz-date, x-amz-security-token — all
      // non-"simple" headers) triggers a preflight OPTIONS request, and
      // with no CorsConfiguration here that preflight has no
      // Access-Control-Allow-Origin to respond with, so the browser blocks
      // the real request before it's ever sent — this looks identical to
      // an IAM AccessDenied in the Network tab's response preview, but
      // isn't one.
      cors: [
        {
          allowedOrigins: [
            // Any local Vite dev port (S3 allows exactly one '*' per
            // origin string) — Vite tries 5173, then increments if taken.
            'http://localhost:*',
            `https://mail.${domainName}`,
          ],
          allowedMethods: [s3.HttpMethods.GET, s3.HttpMethods.HEAD],
          allowedHeaders: ['*'],
          maxAge: 3600,
        },
      ],
    });

    // SES delivers against exactly one *active* receipt rule set per
    // region, and that slot is already taken by a rule set this app doesn't
    // own (see EnvConfig.sharedReceiptRuleSetName). So this stack imports
    // the set by name and only adds rules to it: it must never create an
    // AWS::SES::ReceiptRuleSet, and must never call SetActiveReceiptRuleSet
    // (that would silently switch off the other app's receiving).
    const ruleSet = ses.ReceiptRuleSet.fromReceiptRuleSetName(
      this,
      'SharedReceiptRuleSet',
      sharedReceiptRuleSetName,
    );

    // Optional forwarding, built before the rule loop so each forwarded
    // address's rule can get a second action (see below).
    //
    // DO NOT replace this with an S3 ObjectCreated event notification: SES's
    // S3 action does not reliably trigger S3 event notifications (confirmed
    // broken in prod in an earlier version). A second "Invoke Lambda" action
    // on the same receipt rule runs after the S3 action, so the object is
    // already in S3 when ForwardFn reads it.
    let forwardFn: NodejsFunction | undefined;
    if (forwardTo && Object.keys(forwardTo).length > 0) {
      forwardFn = new NodejsFunction(this, 'ForwardFn', {
        runtime: lambda.Runtime.NODEJS_24_X,
        entry: path.join(moduleDir, '../../lambda/mail/forward/index.ts'),
        environment: {
          MAIL_BUCKET_NAME: this.bucket.bucketName,
          FORWARD_MAP: JSON.stringify(forwardTo),
        },
      });

      // NOT bucket.grantRead() — that grants a bundled action set
      // (s3:GetObject*, s3:GetBucket*, s3:List*) as one statement with two
      // resources, the object-prefix ARN *and* the bare bucket ARN. Only
      // the s3:GetObject* half of that ends up prefix-scoped; the
      // s3:GetBucket*/s3:List* actions apply account-wide across the whole
      // bucket regardless of the prefix passed in, silently granting
      // ForwardFn list/enumerate access to every configured mailbox, not
      // just the forwarded ones. A hand-rolled statement granting exactly
      // s3:GetObject against each forwarded address's own inbox-prefix
      // object ARN is the tightest scoping actually available — same
      // pattern as DeleteFn's grant in api.ts.
      forwardFn.addToRolePolicy(
        new iam.PolicyStatement({
          actions: ['s3:GetObject'],
          resources: Object.keys(forwardTo).map((address) =>
            this.bucket.arnForObjects(`${inboxPrefix(address)}*`),
          ),
        }),
      );

      // ses:SendRawEmail is not resource-ARN-scopable (same as ReplyFn's
      // grant — see api.ts on why resources: ['*'] is correct here, not a
      // shortcut), but the ses:FromAddress condition key scopes it to
      // exactly the forwarded addresses, StringEquals against an array
      // being an OR match. For this condition to evaluate
      // deterministically, forward/index.ts sets Source explicitly on
      // SendRawEmailCommand rather than relying on SES inferring it from
      // the raw message's From: header.
      forwardFn.addToRolePolicy(
        new iam.PolicyStatement({
          actions: ['ses:SendRawEmail'],
          resources: ['*'],
          conditions: {
            StringEquals: { 'ses:FromAddress': Object.keys(forwardTo) },
          },
        }),
      );
    }

    // One rule per configured address, each routing straight to its own
    // inbox prefix. inboxPrefix is the same helper mail-web reads its
    // ListObjectsV2 Prefix from, so the two sides can never drift out of
    // sync on what an "inbox" key looks like. Adding this S3 action
    // auto-grants SES the bucket policy statement it needs to write here —
    // no manual bucket policy required. The final object key SES writes is
    // `{objectKeyPrefix}{ses-message-id}` — the message-id suffix is
    // appended by SES itself at delivery time, not by CDK at synth time.
    //
    // When an address is a forwardTo key, its rule gets a second action —
    // actions.Lambda({ function: forwardFn }) — appended *after* the S3
    // action. SES executes a rule's actions in the order they're listed, so
    // the S3 write is guaranteed to have already happened by the time this
    // Lambda action runs and ForwardFn tries to read the object back out.
    // Adding this Lambda action auto-grants SES the lambda:InvokeFunction
    // permission it needs on forwardFn — same "adding the action grants
    // what it needs" pattern as the S3 action above.
    for (const address of mailboxAddresses) {
      const ruleActions: (actions.S3 | actions.Lambda)[] = [
        new actions.S3({
          bucket: this.bucket,
          objectKeyPrefix: inboxPrefix(address),
        }),
      ];
      if (forwardFn && forwardTo && address in forwardTo) {
        ruleActions.push(new actions.Lambda({ function: forwardFn }));
      }
      ruleSet.addRule(`Rule-${address}`, {
        recipients: [address],
        actions: ruleActions,
      });
    }

    const auth = new MailAuth(this, 'Auth', {
      mailBucket: this.bucket,
      envName,
    });

    const api = new MailApi(this, 'Api', {
      userPool: auth.userPool,
      userPoolClient: auth.userPoolClient,
      mailBucket: this.bucket,
      mailboxAddresses,
    });

    const web = new MailWebHosting(this, 'Web', { zone, domainName });

    // Outputs live on the stack, not the constructs above, so their keys
    // stay exactly these names for scripts/deploy-mail-web.sh to read.
    new cdk.CfnOutput(this, 'UserPoolId', { value: auth.userPool.userPoolId });
    new cdk.CfnOutput(this, 'UserPoolClientId', {
      value: auth.userPoolClient.userPoolClientId,
    });
    new cdk.CfnOutput(this, 'IdentityPoolId', {
      value: auth.identityPool.identityPoolId,
    });
    new cdk.CfnOutput(this, 'MailBucketName', {
      value: this.bucket.bucketName,
    });
    new cdk.CfnOutput(this, 'ApiUrl', { value: api.apiUrl });
    new cdk.CfnOutput(this, 'MailboxAddresses', {
      value: mailboxAddresses.join(','),
    });
    new cdk.CfnOutput(this, 'MailWebBucketName', {
      value: web.bucket.bucketName,
    });
    new cdk.CfnOutput(this, 'MailWebDistributionId', {
      value: web.distribution.distributionId,
    });
    new cdk.CfnOutput(this, 'MailWebUrl', {
      value: `https://mail.${domainName}`,
    });
  }
}
