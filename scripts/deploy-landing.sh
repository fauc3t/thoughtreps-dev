#!/usr/bin/env bash
# Builds site-landing and syncs it to the Landing stack's bucket, then
# invalidates the CloudFront distribution. The one and only thing that puts
# site content in that bucket — cdk deploy only manages infra.
#
# Usage: scripts/deploy-landing.sh
set -euo pipefail

STACK_NAME="ThoughtReps-prod-Landing"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$REPO_ROOT/site-landing/dist"
AWS_ARGS=(--profile "${AWS_PROFILE:-thoughtreps-dev}" --region us-east-1)

get_output() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    "${AWS_ARGS[@]}" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text
}

echo "==> Resolving ${STACK_NAME} outputs"
LANDING_BUCKET=$(get_output LandingBucketName)
LANDING_DISTRIBUTION_ID=$(get_output LandingDistributionId)

# `get_output` exits 0 with an empty string when a key is absent, and `set -u`
# doesn't catch a set-but-empty variable — without these guards a missing
# output would only surface after the sync, as an AWS CLI parameter error
# naming neither the stack nor the output.
: "${LANDING_BUCKET:?LandingBucketName not found on $STACK_NAME — deploy infra first}"
: "${LANDING_DISTRIBUTION_ID:?LandingDistributionId not found on $STACK_NAME — deploy infra first}"

echo "==> Building @thoughtreps/site-landing"
pnpm --filter @thoughtreps/site-landing build

[[ -f "$DIST/index.html" ]] || { echo "$DIST/index.html missing after build" >&2; exit 1; }
[[ -f "$DIST/404.html" ]] || { echo "$DIST/404.html missing after build" >&2; exit 1; }

echo "==> Syncing built site to s3://${LANDING_BUCKET}/"
# Cache-Control matters here, not just the invalidation below: an
# invalidation only refreshes the CDN's edge cache, not a client's own HTTP
# cache, and S3 sends no Cache-Control by default. Split in two: dist/assets/
# is content-hashed, so a change always produces a new URL and it is safe to
# cache forever; everything else (index.html, 404.html, public files at the
# root) has a stable name and must revalidate every time.
#
# --delete is scoped per sync so the two never delete each other's files: the
# assets sync only manages the assets/ prefix, and the root sync excludes
# assets/* so it neither uploads nor deletes anything under it.
aws s3 sync "$DIST/assets" "s3://${LANDING_BUCKET}/assets/" "${AWS_ARGS[@]}" \
  --delete --cache-control 'public, max-age=31536000, immutable'
aws s3 sync "$DIST" "s3://${LANDING_BUCKET}/" "${AWS_ARGS[@]}" \
  --delete --exclude 'assets/*' --cache-control 'no-cache'

echo "==> Invalidating CloudFront distribution ${LANDING_DISTRIBUTION_ID}"
aws cloudfront create-invalidation \
  --distribution-id "$LANDING_DISTRIBUTION_ID" \
  --paths '/*' \
  "${AWS_ARGS[@]}" >/dev/null

echo "==> Done"
