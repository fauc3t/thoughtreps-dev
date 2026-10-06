#!/usr/bin/env bash
# Builds the one-time export download page (transfer-web), syncs it to the
# Share stack's site bucket, then invalidates the CloudFront distribution.
#
# Usage: scripts/deploy-transfer-web.sh
set -euo pipefail

STACK_NAME="ThoughtReps-prod-Share"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$REPO_ROOT/transfer-web/dist"
AWS_ARGS=(--profile "${AWS_PROFILE:-thoughtreps-dev}" --region us-east-1)

get_output() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    "${AWS_ARGS[@]}" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text
}

echo "==> Resolving ${STACK_NAME} outputs"
SITE_BUCKET=$(get_output TransferSiteBucketName)
DISTRIBUTION_ID=$(get_output TransferDistributionId)

# `get_output` exits 0 with an empty string when a key is absent; guard before
# syncing so a missing output can't turn into a sync to a bogus bucket.
: "${SITE_BUCKET:?TransferSiteBucketName not found on $STACK_NAME — deploy infra first}"
: "${DISTRIBUTION_ID:?TransferDistributionId not found on $STACK_NAME — deploy infra first}"

echo "==> Building @thoughtreps/transfer-web"
pnpm --filter @thoughtreps/transfer-web build

[[ -f "$DIST/index.html" ]] || { echo "$DIST/index.html missing after build" >&2; exit 1; }
[[ -f "$DIST/.well-known/apple-app-site-association" ]] || { echo "$DIST/.well-known/apple-app-site-association missing after build" >&2; exit 1; }

echo "==> Syncing built page to s3://${SITE_BUCKET}/"
# Content-hashed dist/assets/ is immutable and never pruned: old hashes are
# harmless and keep in-flight visitors working. Everything else (index.html is
# served for every /x/<id>) must revalidate, and is pruned.
aws s3 sync "$DIST/assets" "s3://${SITE_BUCKET}/assets/" "${AWS_ARGS[@]}" \
  --cache-control 'public, max-age=31536000, immutable'
aws s3 sync "$DIST" "s3://${SITE_BUCKET}/" "${AWS_ARGS[@]}" \
  --delete --exclude 'assets/*' --exclude '.well-known/*' \
  --cache-control 'no-cache'
# The AASA file has no extension, so S3 can't infer its type; Apple requires
# application/json, a 200 and no redirect. Short cache so edits propagate.
aws s3 cp "$DIST/.well-known/apple-app-site-association" \
  "s3://${SITE_BUCKET}/.well-known/apple-app-site-association" "${AWS_ARGS[@]}" \
  --content-type 'application/json' --cache-control 'public, max-age=300'

echo "==> Invalidating CloudFront distribution ${DISTRIBUTION_ID}"
aws cloudfront create-invalidation \
  --distribution-id "$DISTRIBUTION_ID" \
  --paths '/*' \
  "${AWS_ARGS[@]}" >/dev/null

echo "==> Done"
