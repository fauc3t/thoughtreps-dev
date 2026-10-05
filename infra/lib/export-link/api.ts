import * as cdk from 'aws-cdk-lib/core';
import * as apigwv2 from 'aws-cdk-lib/aws-apigatewayv2';
import { HttpLambdaIntegration } from 'aws-cdk-lib/aws-apigatewayv2-integrations';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as events from 'aws-cdk-lib/aws-events';
import * as targets from 'aws-cdk-lib/aws-events-targets';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import { NodejsFunction } from 'aws-cdk-lib/aws-lambda-nodejs';
import * as s3 from 'aws-cdk-lib/aws-s3';
import { Construct } from 'constructs';
import { fileURLToPath } from 'node:url';
import * as path from 'node:path';

// Not named __dirname: @swc/jest's CJS transform of `import.meta.url` injects
// its own `__dirname` shim, so declaring one here is a duplicate identifier.
const moduleDir = path.dirname(fileURLToPath(import.meta.url));

export const OBJECT_KEY_PREFIX = 'exports/';
export const OPEN_INDEX_NAME = 'openIndex';

export interface ExportApiProps {
  exportBucket: s3.IBucket;
  table: dynamodb.ITable;
  appAttestAppId: string;
}

// Routes carry the full /api/v1 path: CloudFront forwards /api/* to this API
// unchanged, so there is no prefix stripping anywhere.
export class ExportApi extends Construct {
  public readonly httpApi: apigwv2.HttpApi;

  constructor(scope: Construct, id: string, props: ExportApiProps) {
    super(scope, id);

    const { exportBucket, table, appAttestAppId } = props;

    const environment = {
      TABLE_NAME: table.tableName,
      BUCKET_NAME: exportBucket.bucketName,
      APP_ATTEST_APP_ID: appAttestAppId,
    };
    const fn = (name: string, dir: string) =>
      new NodejsFunction(this, name, {
        runtime: lambda.Runtime.NODEJS_24_X,
        entry: path.join(moduleDir, `../../lambda/export-link/${dir}/index.ts`),
        environment,
        timeout: cdk.Duration.seconds(15),
      });

    // Every grant below is a hand-written statement: bucket.grantRead() would
    // also hand out bucket-wide s3:GetBucket*/s3:List*, and these functions
    // only ever touch exports/* objects.
    const objects = (...actions: string[]) =>
      new iam.PolicyStatement({
        actions,
        resources: [exportBucket.arnForObjects(`${OBJECT_KEY_PREFIX}*`)],
      });
    const items = (...actions: string[]) =>
      new iam.PolicyStatement({ actions, resources: [table.tableArn] });

    // Challenges and device registration: no S3.
    const deviceFn = fn('DeviceFn', 'device');
    deviceFn.addToRolePolicy(items('dynamodb:PutItem', 'dynamodb:DeleteItem'));

    // Reads the device (GetItem), advances its counter (UpdateItem),
    // consumes challenges (DeleteItem). s3:GetObject covers HeadObject when
    // verifying an upload on complete; the presigned PUT is signed with this
    // role's s3:PutObject.
    const exportLinkFn = fn('ExportLinkFn', 'export-link');
    exportLinkFn.addToRolePolicy(
      items(
        'dynamodb:GetItem',
        'dynamodb:PutItem',
        'dynamodb:UpdateItem',
        'dynamodb:DeleteItem',
      ),
    );
    exportLinkFn.addToRolePolicy(
      objects('s3:PutObject', 's3:GetObject', 's3:DeleteObject'),
    );

    // Unauthenticated: the link id is the only credential. s3:GetObject is
    // only used to sign the download URL.
    const publicFn = fn('PublicFn', 'public');
    publicFn.addToRolePolicy(items('dynamodb:GetItem', 'dynamodb:UpdateItem'));
    publicFn.addToRolePolicy(objects('s3:GetObject', 's3:DeleteObject'));

    const sweepFn = fn('SweepFn', 'sweep');
    sweepFn.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ['dynamodb:Query'],
        resources: [`${table.tableArn}/index/${OPEN_INDEX_NAME}`],
      }),
    );
    sweepFn.addToRolePolicy(items('dynamodb:UpdateItem'));
    sweepFn.addToRolePolicy(objects('s3:DeleteObject'));

    new events.Rule(this, 'SweepSchedule', {
      schedule: events.Schedule.rate(cdk.Duration.minutes(15)),
      targets: [new targets.LambdaFunction(sweepFn)],
    });

    // No CORS: the page and the API share one CloudFront origin.
    this.httpApi = new apigwv2.HttpApi(this, 'HttpApi', {
      createDefaultStage: false,
    });
    new apigwv2.HttpStage(this, 'DefaultStage', {
      httpApi: this.httpApi,
      stageName: '$default',
      autoDeploy: true,
      throttle: { rateLimit: 10, burstLimit: 20 },
    });

    const route = (
      method: apigwv2.HttpMethod,
      routePath: string,
      name: string,
      handler: lambda.IFunction,
    ) =>
      this.httpApi.addRoutes({
        path: routePath,
        methods: [method],
        integration: new HttpLambdaIntegration(name, handler),
      });
    const { POST, GET } = apigwv2.HttpMethod;

    route(POST, '/api/v1/challenge', 'ChallengeIntegration', deviceFn);
    route(POST, '/api/v1/devices', 'DevicesIntegration', deviceFn);

    route(POST, '/api/v1/export-links', 'CreateIntegration', exportLinkFn);
    route(
      POST,
      '/api/v1/export-links/complete',
      'CompleteIntegration',
      exportLinkFn,
    );
    route(
      POST,
      '/api/v1/export-links/current',
      'CurrentIntegration',
      exportLinkFn,
    );
    route(
      POST,
      '/api/v1/export-links/revoke',
      'RevokeIntegration',
      exportLinkFn,
    );

    route(GET, '/api/v1/export-links/{id}', 'StatusIntegration', publicFn);
    route(
      POST,
      '/api/v1/export-links/{id}/claim',
      'ClaimIntegration',
      publicFn,
    );
    route(POST, '/api/v1/export-links/{id}/done', 'DoneIntegration', publicFn);
  }
}
