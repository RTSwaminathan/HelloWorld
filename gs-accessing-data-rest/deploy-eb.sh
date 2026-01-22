#!/usr/bin/env bash
set -euo pipefail

# Deploys the Spring Boot jar to AWS Elastic Beanstalk.
# Usage examples:
#  ./deploy-eb.sh --app MyApp --env MyEnv --bucket my-eb-bucket --region us-east-1
#  AWS_PROFILE=default ./deploy-eb.sh --jar path/to/app.jar --app MyApp --env MyEnv --bucket my-eb-bucket

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_JAR="$SCRIPT_DIR/java-hello-world-with-gradle/build/libs/jb-hello-world-0.1.0.jar"

# Defaults (override with flags or environment variables)
APP_NAME=""
ENV_NAME=""
S3_BUCKET=""
REGION="us-west-2"
PLATFORM="64bit Amazon Linux 2 v3.4.12 running Corretto 17"
AWS_PROFILE=""
JAR_PATH="$DEFAULT_JAR"
VERSION_LABEL=""
APP_PORT="5000"

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --app NAME           Elastic Beanstalk application name (required)
  --env NAME           Elastic Beanstalk environment name (required)
  --bucket NAME        S3 bucket to upload source bundle (required)
  --region REGION      AWS region (default: $REGION)
  --platform PLATFORM  EB platform/solution stack name to use when creating an environment (optional)
  --profile PROFILE    AWS CLI profile to use (optional, falls back to default)
  --jar PATH           Path to the jar to deploy (default: $DEFAULT_JAR)
  --version LABEL      Version label for the deployment (default: timestamp)
  -h, --help           Show this help

Examples:
  $0 --app my-app --env my-env --bucket my-eb-bucket
  $0 --app my-app --env my-env --bucket my-eb-bucket --platform "64bit Amazon Linux 2 v3.x running Corretto 17"
  AWS_PROFILE=work $0 --app my-app --env my-env --bucket my-eb-bucket --jar build/libs/app.jar
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_NAME="$2"; shift 2;;
    --env)
      ENV_NAME="$2"; shift 2;;
    --bucket)
      S3_BUCKET="$2"; shift 2;;
    --region)
      REGION="$2"; shift 2;;
    --platform)
      PLATFORM="$2"; shift 2;;
    --profile)
      AWS_PROFILE="$2"; shift 2;;
    --jar)
      JAR_PATH="$2"; shift 2;;
    --version)
      VERSION_LABEL="$2"; shift 2;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "Unknown option: $1" >&2; usage; exit 2;;
  esac
done

# fall back to env var if set
: "${APP_NAME:=${EB_APP_NAME:-}}"
: "${ENV_NAME:=${EB_ENV_NAME:-}}"
: "${S3_BUCKET:=${EB_S3_BUCKET:-}}"
: "${REGION:=${AWS_REGION:-$REGION}}"
: "${AWS_PROFILE:=${AWS_PROFILE:-}}"
: "${PLATFORM:=${EB_PLATFORM:-$PLATFORM}}"
: "${APP_PORT:=${EB_APP_PORT:-$APP_PORT}}"

# Validate bucket name doesn't start with a dash (common user error)
if [[ "$S3_BUCKET" == -* ]]; then
  echo "Invalid bucket name: starts with '-' — use the plain bucket name (no leading dashes)." >&2
  exit 2
fi

if [[ -z "$APP_NAME" || -z "$ENV_NAME" || -z "$S3_BUCKET" ]]; then
  echo "Error: --app, --env and --bucket are required." >&2
  usage
  exit 2
fi

if [[ -z "$VERSION_LABEL" ]]; then
  VERSION_LABEL="v-$(date +%Y%m%d%H%M%S)"
fi

# Helper to run aws with optional profile
aws_cmd() {
  if [[ -n "$AWS_PROFILE" ]]; then
    aws --profile "$AWS_PROFILE" "$@"
  else
    aws "$@"
  fi
}

command -v aws >/dev/null 2>&1 || { echo "aws CLI not found. Install and configure it first." >&2; exit 3; }

# Ensure the S3 bucket exists; create it if it doesn't
ensure_bucket_exists() {
  local bucket="$1"

  # Quick validation
  if [[ -z "$bucket" ]]; then
    echo "No bucket name provided to ensure_bucket_exists" >&2
    return 2
  fi

  if aws_cmd s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    echo "S3 bucket '$bucket' exists and is accessible."
    return 0
  fi

  echo "S3 bucket '$bucket' does not exist or is not accessible. Attempting to create it in region '$REGION'..."

  if [[ "$REGION" == "us-east-1" ]]; then
    aws_cmd s3api create-bucket --bucket "$bucket" --region "$REGION" || { echo "Failed to create bucket '$bucket'" >&2; return 1; }
  else
    aws_cmd s3api create-bucket --bucket "$bucket" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION" || { echo "Failed to create bucket '$bucket'" >&2; return 1; }
  fi

  echo "Waiting until bucket '$bucket' exists..."
  aws_cmd s3api wait bucket-exists --bucket "$bucket" --region "$REGION"
  echo "Bucket '$bucket' is ready."
}

if [[ ! -f "$JAR_PATH" ]]; then
  echo "Jar not found at: $JAR_PATH" >&2
  echo "Run a Gradle build first, e.g. from project folder: ./gradlew bootJar" >&2
  exit 4
fi

# Ensure S3 bucket exists before uploading
ensure_bucket_exists "$S3_BUCKET"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

ZIP_NAME="${APP_NAME}-${VERSION_LABEL}.zip"
ZIP_PATH="$TMPDIR/$ZIP_NAME"

# Put the jar into the zip (no folders) - Elastic Beanstalk Java platforms accept a single .jar in the root
cp "$JAR_PATH" "$TMPDIR/$(basename "$JAR_PATH")"
( cd "$TMPDIR" && zip -q "$ZIP_NAME" "$(basename "$JAR_PATH")" )

S3_KEY="$APP_NAME/$VERSION_LABEL/$ZIP_NAME"

echo "Uploading $ZIP_NAME to s3://$S3_BUCKET/$S3_KEY (region: $REGION)"
aws_cmd s3 cp "$ZIP_PATH" "s3://$S3_BUCKET/$S3_KEY" --region "$REGION"

echo "Creating application version: $VERSION_LABEL"
# Ensure application exists before creating an application version
ensure_app_exists() {
  if aws_cmd elasticbeanstalk describe-applications --application-names "$APP_NAME" --region "$REGION" --query "Applications[?ApplicationName=='$APP_NAME'] | [0].ApplicationName" --output text 2>/dev/null | grep -q "^$APP_NAME$"; then
    echo "Application '$APP_NAME' already exists."
    return 0
  fi

  echo "Creating application '$APP_NAME'..."
  aws_cmd elasticbeanstalk create-application --application-name "$APP_NAME" --region "$REGION" || { echo "Failed to create application '$APP_NAME'" >&2; return 1; }
  echo "Application '$APP_NAME' created."
}

ensure_app_exists || { echo "Cannot proceed without application." >&2; exit 1; }

aws_cmd elasticbeanstalk create-application-version \
  --application-name "$APP_NAME" \
  --version-label "$VERSION_LABEL" \
  --source-bundle S3Bucket="$S3_BUCKET",S3Key="$S3_KEY" \
  --region "$REGION" \
  --auto-create-application >/dev/null

# Attempt to ensure required IAM roles/instance profile exist; create them if missing
ensure_iam_roles() {
  # Defaults if not provided
  local ip_name="${INSTANCE_PROFILE:-aws-elasticbeanstalk-ec2-role}"
  local sr_name="${SERVICE_ROLE:-aws-elasticbeanstalk-service-role}"

  echo "Ensuring IAM instance profile '$ip_name' and service role '$sr_name' exist (may require IAM permissions)..."

  # Instance profile / role for EC2
  if aws_cmd iam get-instance-profile --instance-profile-name "$ip_name" >/dev/null 2>&1; then
    echo "Instance profile '$ip_name' exists."
  else
    echo "Creating IAM role and instance profile '$ip_name'..."
    local trust_policy
    trust_policy='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
    aws_cmd iam create-role --role-name "$ip_name" --assume-role-policy-document "$trust_policy" >/dev/null 2>&1 || { echo "Failed to create role '$ip_name' or it already exists." >&2; }
    aws_cmd iam attach-role-policy --role-name "$ip_name" --policy-arn arn:aws:iam::aws:policy/AWSElasticBeanstalkWebTier >/dev/null 2>&1 || true
    aws_cmd iam create-instance-profile --instance-profile-name "$ip_name" >/dev/null 2>&1 || true
    aws_cmd iam add-role-to-instance-profile --instance-profile-name "$ip_name" --role-name "$ip_name" >/dev/null 2>&1 || true
    echo "Waiting for IAM propagation..."
    sleep 10
  fi

  # Service role for Elastic Beanstalk
  if aws_cmd iam get-role --role-name "$sr_name" >/dev/null 2>&1; then
    echo "Service role '$sr_name' exists."
  else
    echo "Creating service role '$sr_name'..."
    local service_trust
    service_trust='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"elasticbeanstalk.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
    aws_cmd iam create-role --role-name "$sr_name" --assume-role-policy-document "$service_trust" >/dev/null 2>&1 || { echo "Failed to create service role '$sr_name' or it already exists." >&2; }
    aws_cmd iam attach-role-policy --role-name "$sr_name" --policy-arn arn:aws:iam::aws:policy/service-role/AWSElasticBeanstalkService >/dev/null 2>&1 || true
    echo "Waiting for IAM propagation..."
    sleep 5
  fi

  # Export chosen names for later use
  INSTANCE_PROFILE="$ip_name"
  SERVICE_ROLE="$sr_name"
  return 0
}

# Ensure instance profile and service role variables fallback from environment if provided
: "${INSTANCE_PROFILE:=${EB_INSTANCE_PROFILE:-}}"
: "${SERVICE_ROLE:=${EB_SERVICE_ROLE:-}}"

# Try to create roles if not present (requires permissions)
if ! ensure_iam_roles; then
  echo "Warning: automatic IAM role creation failed or was incomplete. You may need to create instance profile and service role manually." >&2
fi

# Helper: try to find a suitable solution stack (prefer Corretto 17 on Amazon Linux 2/2023)
find_solution_stack() {
  echo "Looking up available Elastic Beanstalk solution stacks in region '$REGION'..."
  local stacks candidate
  stacks=$(aws_cmd elasticbeanstalk list-available-solution-stacks --region "$REGION" --output text 2>/dev/null | tr '\t' '\n') || stacks=""

  # Prefer exact Corretto 17 entries
  candidate=$(printf "%s\n" "$stacks" | grep -i 'Corretto 17' | head -n1 || true)
  # Fallback: any Corretto on Amazon Linux 2/2023
  if [[ -z "$candidate" ]]; then
    candidate=$(printf "%s\n" "$stacks" | grep -i 'Corretto' | grep -i 'Amazon Linux 2\|Amazon Linux 2023' | head -n1 || true)
  fi
  # Last resort: any Corretto
  if [[ -z "$candidate" ]]; then
    candidate=$(printf "%s\n" "$stacks" | grep -i 'Corretto' | head -n1 || true)
  fi

  if [[ -n "$candidate" ]]; then
    PLATFORM="$candidate"
    echo "Auto-selected solution stack: $PLATFORM"
    return 0
  fi

  echo "No matching solution stack found in region '$REGION'."
  return 1
}

# If the environment exists, update it; otherwise try to auto-detect platform and create it
env_count=$(aws_cmd elasticbeanstalk describe-environments --application-name "$APP_NAME" --environment-names "$ENV_NAME" --region "$REGION" --query "length(Environments)" --output text 2>/dev/null || echo 0)
if [[ "$env_count" -gt 0 ]]; then
  echo "Updating environment $ENV_NAME to version $VERSION_LABEL"

  # Attempt update and capture output/status
  update_output=$(aws_cmd elasticbeanstalk update-environment \
    --environment-name "$ENV_NAME" \
    --version-label "$VERSION_LABEL" \
    --option-settings Namespace=aws:autoscaling:launchconfiguration,OptionName=IamInstanceProfile,Value="$INSTANCE_PROFILE" Namespace=aws:elasticbeanstalk:environment,OptionName=ServiceRole,Value="$SERVICE_ROLE" Namespace=aws:elasticbeanstalk:application:environment,OptionName=PORT,Value="$APP_PORT" \
    --region "$REGION" 2>&1) || update_status=$?

  if [[ ${update_status:-0} -eq 0 ]]; then
    echo "Update started successfully."
  else
    echo "Update failed: $update_output"
    # If the error indicates the environment truly doesn't exist, fall back to creating it
    if printf "%s" "$update_output" | grep -qi "No Environment found"; then
      echo "Detected missing environment during update. Falling back to create-environment."
      if find_solution_stack; then
        echo "Creating environment '$ENV_NAME' with auto-detected platform: $PLATFORM"
      else
        echo "Proceeding with configured platform: $PLATFORM (may fail if invalid in region)."
      fi

      aws_cmd elasticbeanstalk create-environment \
        --application-name "$APP_NAME" \
        --environment-name "$ENV_NAME" \
        --solution-stack-name "$PLATFORM" \
        --version-label "$VERSION_LABEL" \
        --option-settings Namespace=aws:autoscaling:launchconfiguration,OptionName=IamInstanceProfile,Value="$INSTANCE_PROFILE" Namespace=aws:elasticbeanstalk:environment,OptionName=ServiceRole,Value="$SERVICE_ROLE" Namespace=aws:elasticbeanstalk:application:environment,OptionName=PORT,Value="$APP_PORT" \
        --region "$REGION" || { echo "Failed to create environment '$ENV_NAME'" >&2; exit 1; }

      echo "Environment creation started. It may take several minutes to become available."
    else
      echo "Update failed for an unexpected reason; aborting." >&2
      exit ${update_status:-1}
    fi
  fi
else
  echo "Environment '$ENV_NAME' not found; attempting to create it."
  # Try to auto-detect a matching solution stack; if detection fails, fall back to configured PLATFORM
  if find_solution_stack; then
    echo "Creating environment '$ENV_NAME' with auto-detected platform: $PLATFORM"
  else
    echo "Proceeding with configured platform: $PLATFORM (may fail if invalid in region)."
  fi

  aws_cmd elasticbeanstalk create-environment \
    --application-name "$APP_NAME" \
    --environment-name "$ENV_NAME" \
    --solution-stack-name "$PLATFORM" \
    --version-label "$VERSION_LABEL" \
    --option-settings Namespace=aws:autoscaling:launchconfiguration,OptionName=IamInstanceProfile,Value="$INSTANCE_PROFILE" Namespace=aws:elasticbeanstalk:environment,OptionName=ServiceRole,Value="$SERVICE_ROLE" Namespace=aws:elasticbeanstalk:application:environment,OptionName=PORT,Value="$APP_PORT" \
    --region "$REGION" || { echo "Failed to create environment '$ENV_NAME'" >&2; exit 1; }

  echo "Environment creation started. It may take several minutes to become available."
fi

echo "Deployment started. Use 'aws elasticbeanstalk describe-environments --environment-names $ENV_NAME --region $REGION' to check status."
