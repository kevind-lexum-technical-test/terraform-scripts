#!/bin/bash

# Set default path
defaultPath=$(pwd)
ansiblePath="${defaultPath}/ansible-lexum-app"
javaAppPath="${defaultPath}/lexum-app"
deploymentPath="${defaultPath}/aws-terraform-deployment-lexum"
RDS_INSTANCE_ID="aws-kev-test-lexum-rds"
S3_BUCKET_NAME="aws-kev-test-ansible-source"
ECR_REPO_NAME="aws-kev-test-lexum-app"
REGION="ca-central-1"

# Function to check for empty values in plan.tfvar
check_empty_values() {
  echo "Checking for empty values in plan.tfvar..."

  plan_tfvar="${defaultPath}/plan.tfvar"

  if [ ! -f "${plan_tfvar}" ]; then
    echo "plan.tfvar file not found at ${plan_tfvar}. Please provide a valid file."
    exit 1
  fi

  empty_vars=$(grep '=""' "${plan_tfvar}" | awk -F '=' '{print $1}' | xargs)

  if [ -n "${empty_vars}" ]; then
    echo "The following variables have empty values in plan.tfvar:"
    for var in ${empty_vars}; do
      echo "   - ${var}"
    done
    echo "Please provide values for the above variables before continuing."
    exit 1
  fi

  echo "No empty values found in plan.tfvar."
}

# Function to disable deletion protection for RDS instance
disable_rds_deletion_protection() {
  echo "Disabling deletion protection for RDS instance: ${RDS_INSTANCE_ID}..."

  aws rds modify-db-instance \
    --region "${REGION}" \
    --db-instance-identifier "${RDS_INSTANCE_ID}" \
    --no-deletion-protection \
    --apply-immediately --no-cli-pager

  if [ $? -eq 0 ]; then
    echo "Deletion protection disabled for RDS instance: ${RDS_INSTANCE_ID}."
  else
    echo "Failed to disable deletion protection for RDS instance: ${RDS_INSTANCE_ID}. Check your permissions."
    exit 1
  fi
}
# Function to empty the S3 bucket without jq
empty_s3_bucket() {
  echo "Emptying S3 bucket: ${S3_BUCKET_NAME}..."

  # Delete all object versions
  echo "Deleting all object versions..."
  aws s3api list-object-versions \
    --bucket "${S3_BUCKET_NAME}" \
    --query 'Versions[].{Key: Key, VersionId: VersionId}' \
    --output text --no-cli-pager | while read -r key version; do
      # Check if both key and version are not empty
      if [[ -n "${key}" && -n "${version}" ]]; then
        echo "Deleting Object Version - Key: ${key}, VersionId: ${version}"
        aws s3api delete-object \
          --bucket "${S3_BUCKET_NAME}" \
          --key "${key}" \
          --version-id "${version}" --no-cli-pager
      fi
  done

  # Delete all delete markers
  echo "Deleting all delete markers..."
  aws s3api list-object-versions \
    --bucket "${S3_BUCKET_NAME}" \
    --query 'DeleteMarkers[].{Key: Key, VersionId: VersionId}' \
    --output text --no-cli-pager | while read -r key version; do
      # Check if both key and version are not empty
      if [[ -n "${key}" && -n "${version}" ]]; then
        echo "Deleting Delete Marker - Key: ${key}, VersionId: ${version}"
        aws s3api delete-object \
          --bucket "${S3_BUCKET_NAME}" \
          --key "${key}" \
          --version-id "${version}"
      fi
  done

  echo "S3 bucket ${S3_BUCKET_NAME} is now empty."
}


# Function to empty the ECR repository without jq
empty_ecr_repo() {
  echo "Emptying ECR repository: ${ECR_REPO_NAME}..."

  # List all image digests
  image_digests=$(aws ecr list-images \
    --region "${REGION}" \
    --repository-name "${ECR_REPO_NAME}" \
    --query 'imageIds[].imageDigest' \
    --output text --no-cli-pager)

  # Check if the repository is already empty
  if [ -z "$image_digests" ]; then
    echo "ECR repository ${ECR_REPO_NAME} is already empty."
  else
    # Loop through each image digest and delete
    for digest in $image_digests; do
      echo "Deleting Image Digest: ${digest}"
      aws ecr batch-delete-image \
        --region "${REGION}" \
        --repository-name "${ECR_REPO_NAME}" \
        --image-ids imageDigest="${digest}" --no-cli-pager
    done
    echo "ECR repository ${ECR_REPO_NAME} is now empty."
  fi
}

# Run Checks and Functions
check_empty_values
disable_rds_deletion_protection
empty_s3_bucket
empty_ecr_repo

# Terraform Deployment - Main Branch
echo "Switching to aws-terraform-deployment-lexum main and reapplying Terraform..."
cd "${deploymentPath}" || exit 1
git checkout main || exit 1
terraform init || exit 1
terraform destroy -var-file="${defaultPath}/plan.tfvar" -auto-approve || exit 1

echo "Script completed successfully!"
