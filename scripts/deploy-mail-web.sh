#!/usr/bin/env bash
# Builds the mail web UI (infra/mail-web) with the deployed Mail stack's
# outputs baked in as VITE_* values, syncs it to the stack's site bucket,
# then invalidates the CloudFront distribution.
#
# Usage: scripts/deploy-mail-web.sh
set -euo pipefail

STACK_NAME="ThoughtReps-prod-Mail"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$REPO_ROOT/infra/mail-web/dist"
AWS_ARGS=(--profile "${AWS_PROFILE:-thoughtreps-dev}" --region us-east-1)

get_output() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    "${AWS_ARGS[@]}" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text
}

echo "==> Resolving ${STACK_NAME} outputs"
MAIL_WEB_BUCKET=$(get_output MailWebBucketName)
MAIL_WEB_DISTRIBUTION_ID=$(get_output MailWebDistributionId)
USER_POOL_ID=$(get_output UserPoolId)
USER_POOL_CLIENT_ID=$(get_output UserPoolClientId)
IDENTITY_POOL_ID=$(get_output IdentityPoolId)
MAIL_BUCKET=$(get_output MailBucketName)
MAILBOX_ADDRESSES=$(get_output MailboxAddresses)
API_URL=$(get_output ApiUrl)

# `get_output` exits 0 with an empty string when a key is absent. For the
# VITE_* values that is worse than a failed command: vite happily bakes an
# empty string into the bundle, so the deploy "succeeds" and ships a UI whose
# login or S3 reads are silently broken. Guard everything before the build.
: "${MAIL_WEB_BUCKET:?MailWebBucketName not found on $STACK_NAME — deploy infra first}"
: "${MAIL_WEB_DISTRIBUTION_ID:?MailWebDistributionId not found on $STACK_NAME — deploy infra first}"
: "${USER_POOL_ID:?UserPoolId not found on $STACK_NAME — deploy infra first}"
: "${USER_POOL_CLIENT_ID:?UserPoolClientId not found on $STACK_NAME — deploy infra first}"
: "${IDENTITY_POOL_ID:?IdentityPoolId not found on $STACK_NAME — deploy infra first}"
: "${MAIL_BUCKET:?MailBucketName not found on $STACK_NAME — deploy infra first}"
: "${MAILBOX_ADDRESSES:?MailboxAddresses not found on $STACK_NAME — deploy infra first}"
: "${API_URL:?ApiUrl not found on $STACK_NAME — deploy infra first}"

export VITE_COGNITO_USER_POOL_ID="$USER_POOL_ID"
export VITE_COGNITO_CLIENT_ID="$USER_POOL_CLIENT_ID"
export VITE_COGNITO_IDENTITY_POOL_ID="$IDENTITY_POOL_ID"
export VITE_MAIL_BUCKET_NAME="$MAIL_BUCKET"
export VITE_AWS_REGION="us-east-1"
export VITE_MAILBOX_ADDRESSES="$MAILBOX_ADDRESSES"
export VITE_API_URL="$API_URL"

echo "==> Building @thoughtreps/mail-web"
pnpm --filter @thoughtreps/mail-web build

[[ -f "$DIST/index.html" ]] || { echo "$DIST/index.html missing after build" >&2; exit 1; }

echo "==> Syncing built UI to s3://${MAIL_WEB_BUCKET}/"
# Same cache split as scripts/deploy-landing.sh: content-hashed dist/assets/
# is immutable, everything else must revalidate. --delete is scoped per sync
# so the two never delete each other's files.
aws s3 sync "$DIST/assets" "s3://${MAIL_WEB_BUCKET}/assets/" "${AWS_ARGS[@]}" \
  --delete --cache-control 'public, max-age=31536000, immutable'
aws s3 sync "$DIST" "s3://${MAIL_WEB_BUCKET}/" "${AWS_ARGS[@]}" \
  --delete --exclude 'assets/*' --cache-control 'no-cache'

echo "==> Invalidating CloudFront distribution ${MAIL_WEB_DISTRIBUTION_ID}"
aws cloudfront create-invalidation \
  --distribution-id "$MAIL_WEB_DISTRIBUTION_ID" \
  --paths '/*' \
  "${AWS_ARGS[@]}" >/dev/null

echo "==> Done"
