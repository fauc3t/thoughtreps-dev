// None of these are secrets — a Cognito User/Identity Pool ID, an S3 bucket
// name, a region, and a static list of mailbox addresses are all safe to
// embed in a client bundle. The
// Identity Pool's federated IAM role is scoped to read-only access on the
// mail bucket specifically — see this app's own top-level comment in
// lib/credentials.ts.
export const AWS_REGION = import.meta.env.VITE_AWS_REGION;
export const COGNITO_USER_POOL_ID = import.meta.env.VITE_COGNITO_USER_POOL_ID;
export const COGNITO_CLIENT_ID = import.meta.env.VITE_COGNITO_CLIENT_ID;
export const COGNITO_IDENTITY_POOL_ID = import.meta.env
  .VITE_COGNITO_IDENTITY_POOL_ID;
export const MAIL_BUCKET_NAME = import.meta.env.VITE_MAIL_BUCKET_NAME;
// Static, build-time list — there is no runtime API to fetch this, it
// mirrors a literal list also baked into the CDK app (infra/).
export const MAILBOX_ADDRESSES: string[] =
  import.meta.env.VITE_MAILBOX_ADDRESSES.split(',').map((a: string) =>
    a.trim(),
  );
// The reply-send backend (Lambda behind API Gateway + Cognito JWT auth) —
// unlike everything else in this file, this isn't a Cognito/S3 identifier
// the browser talks to directly; it's the base URL lib/api.ts calls with a
// Bearer ID token attached.
export const API_URL = import.meta.env.VITE_API_URL;
