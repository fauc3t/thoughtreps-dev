import {
  AuthenticationDetails,
  CognitoUser,
  CognitoUserPool,
  type CognitoUserSession,
} from 'amazon-cognito-identity-js';
import { COGNITO_CLIENT_ID, COGNITO_USER_POOL_ID } from './config';

const userPool = new CognitoUserPool({
  UserPoolId: COGNITO_USER_POOL_ID,
  ClientId: COGNITO_CLIENT_ID,
});

// No signUp/confirmSignUp here — self-service signup is off for this
// template. Users are provisioned out-of-band (e.g. via the Cognito
// console/CLI), so there's no client-facing account-creation flow to build.

export function signIn(
  email: string,
  password: string,
): Promise<CognitoUserSession> {
  return new Promise((resolve, reject) => {
    const user = new CognitoUser({ Username: email, Pool: userPool });
    const authDetails = new AuthenticationDetails({
      Username: email,
      Password: password,
    });
    user.authenticateUser(authDetails, {
      onSuccess: (session) => resolve(session),
      onFailure: (err) => reject(err),
    });
  });
}

// amazon-cognito-identity-js persists tokens to localStorage itself —
// getCurrentUser() + getSession() recovers a still-valid session across
// reloads, refreshing via the stored refresh token if the ID token has
// expired. Resolves null if there's no signed-in user or the refresh token
// itself is gone/expired.
export function getCurrentSession(): Promise<CognitoUserSession | null> {
  return new Promise((resolve) => {
    const user = userPool.getCurrentUser();
    if (!user) {
      resolve(null);
      return;
    }
    user.getSession((err: Error | null, session: CognitoUserSession | null) => {
      resolve(!err && session && session.isValid() ? session : null);
    });
  });
}

export function signOut(): void {
  userPool.getCurrentUser()?.signOut();
}
