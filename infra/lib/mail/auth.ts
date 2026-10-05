import * as cdk from 'aws-cdk-lib/core';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import {
  IdentityPool,
  UserPoolAuthenticationProvider,
} from 'aws-cdk-lib/aws-cognito-identitypool';
import * as s3 from 'aws-cdk-lib/aws-s3';
import { Construct } from 'constructs';
import type { EnvName } from '../env-config.js';

export interface MailAuthProps {
  mailBucket: s3.IBucket;
  envName: EnvName;
}

export class MailAuth extends Construct {
  public readonly userPool: cognito.UserPool;
  public readonly userPoolClient: cognito.UserPoolClient;
  public readonly identityPool: IdentityPool;

  constructor(scope: Construct, id: string, props: MailAuthProps) {
    super(scope, id);

    const { mailBucket, envName } = props;

    // Explicit RETAIN — UserPool already defaults to this, but stated here
    // so every stateful resource says so.
    //
    // selfSignUpEnabled: false is deliberate: this is a single-tenant
    // personal tool, not a product with a public signup funnel. The
    // user(s) get provisioned out-of-band (`aws cognito-idp
    // admin-create-user` or the console), not via self-service signup.
    this.userPool = new cognito.UserPool(this, 'UserPool', {
      removalPolicy: cdk.RemovalPolicy.RETAIN,
      selfSignUpEnabled: false,
      signInAliases: { email: true },
    });

    // SRP only — no adminUserPassword auth flow, the tighter posture a real
    // client never needs more than.
    this.userPoolClient = this.userPool.addClient('WebClient', {
      authFlows: { userSrp: true },
    });

    // Pass userPoolClient explicitly. Omitting it would make
    // UserPoolAuthenticationProvider silently provision its own separate
    // default client instead of federating the one the web app actually
    // authenticates against — the web app would mint tokens against
    // WebClient above, but the identity pool would only trust a different,
    // auto-created client's tokens, breaking auth in a confusing way that
    // has nothing to do with credentials being wrong.
    //
    // allowUnauthenticatedIdentities left at its default (false) —
    // unauthenticated guest access has no purpose for this tool.
    this.identityPool = new IdentityPool(this, 'IdentityPool', {
      identityPoolName: `thoughtreps-${envName}`,
      authenticationProviders: {
        userPools: [
          new UserPoolAuthenticationProvider({
            userPool: this.userPool,
            userPoolClient: this.userPoolClient,
          }),
        ],
      },
    });

    // grantRead grants BUCKET_READ_ACTIONS (aws-s3/lib/perms.ts) —
    // s3:GetObject*/s3:GetBucket*/s3:List* on this bucket and its contents
    // (wildcarded action patterns, nothing broader than grantRead's
    // documented read-only surface) — the full and only access this role
    // should ever have. Single flat authenticated role, no per-user/
    // per-address IAM partitioning: a locked decision for this
    // single-tenant tool, not a placeholder for finer-grained access later.
    mailBucket.grantRead(this.identityPool.authenticatedRole);
  }
}
