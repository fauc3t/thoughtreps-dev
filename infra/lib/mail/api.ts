import * as apigwv2 from 'aws-cdk-lib/aws-apigatewayv2';
import { HttpUserPoolAuthorizer } from 'aws-cdk-lib/aws-apigatewayv2-authorizers';
import { HttpLambdaIntegration } from 'aws-cdk-lib/aws-apigatewayv2-integrations';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import { NodejsFunction } from 'aws-cdk-lib/aws-lambda-nodejs';
import * as s3 from 'aws-cdk-lib/aws-s3';
import { Construct } from 'constructs';
import { fileURLToPath } from 'node:url';
import * as path from 'node:path';
import { inboxPrefix } from './inbox.js';

// Not named __dirname: @swc/jest's CJS transform of `import.meta.url` injects
// its own `__dirname` shim, so declaring one here is a duplicate identifier.
const moduleDir = path.dirname(fileURLToPath(import.meta.url));

export interface MailApiProps {
  userPool: cognito.IUserPool;
  userPoolClient: cognito.IUserPoolClient;
  mailBucket: s3.IBucket;
  mailboxAddresses: string[];
}

export class MailApi extends Construct {
  public readonly apiUrl: string;

  constructor(scope: Construct, id: string, props: MailApiProps) {
    super(scope, id);

    const { userPool, userPoolClient, mailBucket, mailboxAddresses } = props;

    // Sends an email as one of mailboxAddresses, threaded as a reply — the
    // one real authorization boundary this app needs. Reading is 100%
    // browser-to-S3 (see MailAuth's identity pool), but sending must go
    // through a real backend so it can be validated server-side rather than
    // handing the browser send credentials directly.
    const replyFn = new NodejsFunction(this, 'ReplyFn', {
      runtime: lambda.Runtime.NODEJS_24_X,
      entry: path.join(moduleDir, '../../lambda/mail/reply/index.ts'),
      environment: {
        MAIL_BUCKET_NAME: mailBucket.bucketName,
        MAILBOX_ADDRESSES: mailboxAddresses.join(','),
      },
    });

    // Read-only — the reply Lambda only needs to re-read the original
    // message it's threading a reply onto, never to write/delete anything
    // in the mail bucket.
    mailBucket.grantRead(replyFn);

    // ses:SendRawEmail is not resource-ARN-scopable, so resources: ['*'] is
    // correct, not a shortcut — but it *does* have an IAM condition key:
    // ses:FromAddress. StringEquals against an array is an OR match, so this
    // scopes the grant to exactly the configured mailbox addresses —
    // replyFn can never be used to send as an arbitrary address. For this
    // condition to evaluate deterministically, index.ts sets Source
    // explicitly on SendRawEmailCommand rather than relying on SES
    // inferring it from the raw message's From: header.
    replyFn.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ['ses:SendRawEmail'],
        resources: ['*'],
        conditions: {
          StringEquals: { 'ses:FromAddress': mailboxAddresses },
        },
      }),
    );

    // Deletes a received message from the mail bucket — the second
    // destructive, irreversible mutation (alongside ReplyFn's send) that
    // goes through a real backend rather than expanding the browser's
    // Identity Pool role to hold s3:DeleteObject directly. Reading stays
    // 100% browser-to-S3 via that read-only role.
    const deleteFn = new NodejsFunction(this, 'DeleteFn', {
      runtime: lambda.Runtime.NODEJS_24_X,
      entry: path.join(moduleDir, '../../lambda/mail/delete/index.ts'),
      environment: {
        MAIL_BUCKET_NAME: mailBucket.bucketName,
        MAILBOX_ADDRESSES: mailboxAddresses.join(','),
      },
    });

    // Unlike ses:SendRawEmail above, s3:DeleteObject *does* support
    // resource-level ARN scoping, so this grant is scoped to exactly the
    // configured mailbox addresses' own inbox prefixes rather than a
    // blanket mailBucket.arnForObjects('*') — deleteFn can never be used to
    // delete an object outside a configured mailbox's own inbox, even one
    // belonging to a different configured address.
    deleteFn.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ['s3:DeleteObject'],
        resources: mailboxAddresses.map((address) =>
          mailBucket.arnForObjects(`${inboxPrefix(address)}*`),
        ),
      }),
    );

    // Pass userPoolClients explicitly. Omitting it would make
    // HttpUserPoolAuthorizer.bind() silently provision its own separate
    // app client (this.pool.addClient('UserPoolAuthorizerClient')) instead
    // of trusting tokens issued by the existing WebClient the web app
    // actually signs in against — the same "pass it explicitly or get
    // silent client drift" trap MailAuth's own
    // UserPoolAuthenticationProvider comment documents.
    const authorizer = new HttpUserPoolAuthorizer('ReplyAuthorizer', userPool, {
      userPoolClients: [userPoolClient],
    });

    const httpApi = new apigwv2.HttpApi(this, 'HttpApi', {
      corsPreflight: {
        // API Gateway v2 rejects wildcards inside an origin ('http://localhost:*'
        // fails the deploy), and enumerating Vite dev ports is brittle. A bare
        // '*' is safe because the real auth boundary is the JWT authorizer
        // (Bearer token, no cookies), so allowCredentials stays false.
        allowOrigins: ['*'],
        allowMethods: [
          apigwv2.CorsHttpMethod.POST,
          apigwv2.CorsHttpMethod.OPTIONS,
        ],
        allowHeaders: ['Authorization', 'Content-Type'],
      },
    });

    httpApi.addRoutes({
      path: '/reply',
      methods: [apigwv2.HttpMethod.POST],
      integration: new HttpLambdaIntegration('ReplyIntegration', replyFn),
      authorizer,
    });

    httpApi.addRoutes({
      path: '/delete',
      methods: [apigwv2.HttpMethod.POST],
      integration: new HttpLambdaIntegration('DeleteIntegration', deleteFn),
      authorizer,
    });

    this.apiUrl = httpApi.apiEndpoint;
  }
}
