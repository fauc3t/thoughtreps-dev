import { describe, expect, it, vi } from 'vitest';
import type { CognitoUserSession } from 'amazon-cognito-identity-js';

interface FederationParams {
  identityPoolId: string;
  clientConfig: { region: string };
  logins: Record<string, string>;
}

const fromCognitoIdentityPool = vi.fn(
  (opts: FederationParams) =>
    `stub-credentials-provider:${opts.identityPoolId}`,
);

// fromCognitoIdentityPool makes a real network call when actually invoked —
// stub it so this stays a pure unit test of the shape credentialsFromSession
// builds, not an integration test against AWS.
vi.mock('@aws-sdk/credential-provider-cognito-identity', () => ({
  fromCognitoIdentityPool,
}));

vi.mock('./config', () => ({
  AWS_REGION: 'us-east-1',
  COGNITO_USER_POOL_ID: 'us-east-1_TESTPOOL',
  COGNITO_IDENTITY_POOL_ID: 'us-east-1:test-identity-pool',
}));

function fakeSession(): CognitoUserSession {
  return {
    getIdToken: () => ({ getJwtToken: () => 'test-id-token' }),
    getAccessToken: () => ({ getJwtToken: () => 'test-access-token' }),
  } as unknown as CognitoUserSession;
}

describe('credentialsFromSession', () => {
  it('federates using the ID token, not the access token', async () => {
    const { credentialsFromSession } = await import('./credentials');

    credentialsFromSession(fakeSession());

    expect(fromCognitoIdentityPool).toHaveBeenCalledWith(
      expect.objectContaining({
        identityPoolId: 'us-east-1:test-identity-pool',
        logins: {
          'cognito-idp.us-east-1.amazonaws.com/us-east-1_TESTPOOL':
            'test-id-token',
        },
      }),
    );
  });

  it('never passes the access token as the logins value', async () => {
    const { credentialsFromSession } = await import('./credentials');

    credentialsFromSession(fakeSession());

    const call = fromCognitoIdentityPool.mock.calls.at(-1)?.[0];
    const loginsValue =
      call?.logins['cognito-idp.us-east-1.amazonaws.com/us-east-1_TESTPOOL'];
    expect(loginsValue).not.toBe('test-access-token');
  });
});
