#!/usr/bin/env bash
# Deploy the stack and, if DNS failover is enabled, upload the maintenance page.
# Usage: ./scripts/deploy.sh [stack-name] [region] [Param=Value ...]
#   e.g. ./scripts/deploy.sh medicarehub eu-west-2
#        ./scripts/deploy.sh medicarehub eu-west-2 DomainName=app.example.com HostedZoneId=Z0123456789
set -euo pipefail
STACK="${1:-medicarehub}"
REGION="${2:-$(aws configure get region)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
shift $(( $# < 2 ? $# : 2 ))
OVERRIDES=()
if [ $# -gt 0 ]; then OVERRIDES=(--parameter-overrides "$@"); fi

echo "==> Deploying $STACK to $REGION (RDS Multi-AZ takes ~15 minutes)"
aws cloudformation deploy --region "$REGION" --stack-name "$STACK" \
  --template-file "$ROOT/infrastructure/template.yaml" \
  --capabilities CAPABILITY_IAM \
  ${OVERRIDES[@]+"${OVERRIDES[@]}"}

BUCKET=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='FailoverBucketName'].OutputValue" --output text)
if [ -n "$BUCKET" ] && [ "$BUCKET" != "None" ]; then
  echo "==> Uploading maintenance page to s3://$BUCKET"
  aws s3 cp "$ROOT/app/maintenance.html" "s3://$BUCKET/index.html" --region "$REGION" --content-type text/html
fi

aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs" --output table
