#!/usr/bin/env bash
set -euo pipefail

# Cleanup resources created by deploy-eb.sh
# Usage example:
#   ./cleanup-eb.sh --app aarth-app-1 --env aarthi-env-1 --bucket aarthi-bucket-2 --region us-west-2 --profile aarthi-aws
# Options:
#   --app NAME            Elastic Beanstalk application name (required)
#   --env NAME            Elastic Beanstalk environment name (optional)
#   --bucket NAME         S3 bucket used for source bundles (optional)
#   --region REGION       AWS region (default: us-west-2)
#   --profile PROFILE     AWS CLI profile (optional)
#   --delete-bucket       Delete the S3 bucket after removing objects (DANGEROUS)
#   --delete-app          Delete the Elastic Beanstalk application (DANGEROUS)
#   --yes                 Skip confirmation prompts

APP_NAME=""
ENV_NAME=""
S3_BUCKET=""
REGION="us-west-2"
AWS_PROFILE=""
DELETE_BUCKET=false
DELETE_APP=false
ASSUME_YES=false

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --app NAME            Elastic Beanstalk application name (required)
  --env NAME            Elastic Beanstalk environment name (optional)
  --bucket NAME         S3 bucket used for source bundles (optional)
  --region REGION       AWS region (default: $REGION)
  --profile PROFILE     AWS CLI profile to use (optional)
  --delete-bucket       Delete the S3 bucket after removing objects (DANGEROUS)
  --delete-app          Delete the Elastic Beanstalk application (DANGEROUS)
  --yes                 Skip confirmation prompts
  -h, --help            Show this help

Example:
  $0 --app aarth-app-1 --env aarthi-env-1 --bucket aarthi-bucket-2 --region us-west-2 --profile aarthi-aws
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP_NAME="$2"; shift 2;;
    --env) ENV_NAME="$2"; shift 2;;
    --bucket) S3_BUCKET="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    --profile) AWS_PROFILE="$2"; shift 2;;
    --delete-bucket) DELETE_BUCKET=true; shift 1;;
    --delete-app) DELETE_APP=true; shift 1;;
    --yes) ASSUME_YES=true; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 2;;
  esac
done

: "${APP_NAME:=${EB_APP_NAME:-}}"
: "${ENV_NAME:=${EB_ENV_NAME:-}}"
: "${S3_BUCKET:=${EB_S3_BUCKET:-}}"
: "${REGION:=${AWS_REGION:-$REGION}}"
: "${AWS_PROFILE:=${AWS_PROFILE:-}}"

if [[ -z "$APP_NAME" ]]; then
  echo "Error: --app is required." >&2
  usage
  exit 2
fi

aws_cmd() {
  if [[ -n "$AWS_PROFILE" ]]; then
    aws --profile "$AWS_PROFILE" "$@"
  else
    aws "$@"
  fi
}

command -v aws >/dev/null 2>&1 || { echo "aws CLI not found. Install and configure it first." >&2; exit 3; }

confirm_or_abort() {
  local msg="$1"
  if $ASSUME_YES; then
    return 0
  fi
  read -r -p "$msg [y/N]: " ans
  case "$ans" in
    [Yy]|[Yy][Ee][Ss]) return 0;;
    *) echo "Aborting."; exit 1;;
  esac
}

echo "Planned cleanup:
  Application: $APP_NAME
  Environment: ${ENV_NAME:-<none>}
  S3 bucket: ${S3_BUCKET:-<none>}
  Region: $REGION
  Delete S3 bucket: $DELETE_BUCKET
  Delete application: $DELETE_APP
"

confirm_or_abort "Proceed with cleanup?"

# 1) Terminate environment if provided and exists
if [[ -n "$ENV_NAME" ]]; then
  env_count=$(aws_cmd elasticbeanstalk describe-environments --application-name "$APP_NAME" --environment-names "$ENV_NAME" --region "$REGION" --query "length(Environments)" --output text 2>/dev/null || echo 0)
  if [[ "$env_count" -gt 0 ]]; then
    echo "Terminating environment: $ENV_NAME"
    term_output=$(aws_cmd elasticbeanstalk terminate-environment --environment-name "$ENV_NAME" --region "$REGION" 2>&1) || term_rc=$?

    # If the error indicates the environment doesn't exist, treat as success and continue.
    if [[ ${term_rc:-0} -ne 0 ]]; then
      if printf "%s" "$term_output" | grep -qi "No Environment found"; then
        echo "Environment '$ENV_NAME' not found or already terminated; skipping wait."
      else
        echo "terminate-environment failed: $term_output" >&2
        echo "Proceeding with cleanup; you may need to inspect the environment manually." >&2
      fi
    else
      echo "Waiting for environment termination (timeout 600s)..."
      start=$(date +%s)
      while true; do
        sleep 6
        env_count=$(aws_cmd elasticbeanstalk describe-environments --application-name "$APP_NAME" --environment-names "$ENV_NAME" --region "$REGION" --query "length(Environments)" --output text 2>/dev/null || echo 0)
        if [[ "$env_count" -eq 0 ]]; then
          echo "Environment terminated."
          break
        fi
        if (( $(date +%s) - start > 600 )); then
          echo "Timeout waiting for environment termination." >&2
          break
        fi
      done
    fi
  else
    echo "Environment '$ENV_NAME' not found; skipping termination."
  fi
fi

# 2) Delete application versions (and source bundles) for the application
echo "Deleting application versions for $APP_NAME (this will attempt to delete associated source bundles)..."
versions=$(aws_cmd elasticbeanstalk list-application-versions --application-name "$APP_NAME" --region "$REGION" --query "ApplicationVersions[].VersionLabel" --output text 2>/dev/null || true)
if [[ -n "$versions" ]]; then
  for ver in $versions; do
    echo "Deleting application version: $ver"
    # --delete-source-bundle removes the S3 object when supported
    aws_cmd elasticbeanstalk delete-application-version --application-name "$APP_NAME" --version-label "$ver" --region "$REGION" --delete-source-bundle >/dev/null 2>&1 || echo "Warning: could not delete version $ver or its source bundle"
  done
else
  echo "No application versions found or unable to list them."
fi

# 3) Remove S3 objects under app prefix if bucket provided
if [[ -n "$S3_BUCKET" ]]; then
  echo "Removing S3 objects under s3://$S3_BUCKET/$APP_NAME/"
  aws_cmd s3 rm "s3://$S3_BUCKET/$APP_NAME/" --recursive --region "$REGION" || echo "Warning: failed to remove s3 objects under prefix"

  if $DELETE_BUCKET; then
    echo "Deleting S3 bucket: $S3_BUCKET"
    # Attempt to empty again then delete
    aws_cmd s3 rm "s3://$S3_BUCKET/" --recursive --region "$REGION" || true
    aws_cmd s3api delete-bucket --bucket "$S3_BUCKET" --region "$REGION" || echo "Warning: failed to delete bucket $S3_BUCKET"
  fi
fi

# 4) Delete application if requested
if $DELETE_APP; then
  echo "Deleting Elastic Beanstalk application: $APP_NAME"
  aws_cmd elasticbeanstalk delete-application --application-name "$APP_NAME" --region "$REGION" --terminate-env-by-force >/dev/null 2>&1 || echo "Warning: failed to delete application $APP_NAME"
fi

echo "Cleanup complete."
