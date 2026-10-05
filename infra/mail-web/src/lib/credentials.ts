// Imported from the leaf package, not the '@aws-sdk/credential-providers'
// aggregate — that barrel re-exports every credential provider (SSO,
// process, login, container, ...), several of which are Node-only and pull
// in bare 'node:fs'/'node:os'/etc. imports that break a browser production
// build (`vite build` fails on them even though `tsc`/Vitest never notice,
// since both run under Node — this only surfaces in an actual bundle).
// Importing straight from the package that actually implements
// fromCognitoIdentityPool avoids bundling any of that.
import { fromCognitoIdentityPool } from '@aws-sdk/credential-provider-cognito-identity';
import type { CognitoUserSession } from 'amazon-cognito-identity-js';
import {
  AWS_REGION,
  COGNITO_IDENTITY_POOL_ID,
  COGNITO_USER_POOL_ID,
} from './config';

// Beyond a User Pool JWT (which is all the API Gateway authorizer needs),
// this app needs one more hop: federate that session into the Identity Pool to get actual
// temporary AWS credentials for calling S3 directly from the browser.
//
// Critical, easy-to-get-wrong detail: the `logins` map value must be the
// session's ID token, not its access token — Cognito Identity Pool
// federation authenticates the *identity* (who the user is), which is what
// the ID token asserts; the access token instead asserts *what the bearer
// is authorized to call* against the User Pool's own API and is not
// accepted here. Passing the access token here fails identity federation
// with an opaque, hard-to-debug error rather than a clear "wrong token
// type" message — see credentials.test.ts for a regression guard on this.
// Return type is inferred from fromCognitoIdentityPool's own signature
// (AwsCredentialIdentityProvider, from '@smithy/types') rather than named
// explicitly here — that type isn't a direct dependency of this package,
// and this repo's pnpm workspace doesn't hoist transitive deps into reach
// for direct import.
export function credentialsFromSession(session: CognitoUserSession) {
  return fromCognitoIdentityPool({
    identityPoolId: COGNITO_IDENTITY_POOL_ID,
    clientConfig: { region: AWS_REGION },
    logins: {
      [`cognito-idp.${AWS_REGION}.amazonaws.com/${COGNITO_USER_POOL_ID}`]:
        session.getIdToken().getJwtToken(),
    },
  });
}
