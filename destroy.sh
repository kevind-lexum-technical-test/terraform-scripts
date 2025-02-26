#!/bin/bash

# Set default path
defaultPath=$(pwd)
ansiblePath="${defaultPath}/ansible-lexum-app"
javaAppPath="${defaultPath}/lexum-app"
deploymentPath="${defaultPath}/aws-terraform-deployment-lexum"
rds_instance_id="aws-kev-test-lexum-rds"
s3_bucket_name="aws-kev-test-ansible-source"
tfstate_name="aws-kev-test-tfstate"
ecr_repo_name="aws-kev-test-lexum-app"
region="ca-central-1"

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
  echo "Disabling deletion protection for RDS instance: ${rds_instance_id}..."

  aws rds modify-db-instance \
    --region "${region}" \
    --db-instance-identifier "${rds_instance_id}" \
    --no-deletion-protection \
    --apply-immediately --no-cli-pager

  if [ $? -eq 0 ]; then
    echo "Deletion protection disabled for RDS instance: ${rds_instance_id}."
  else
    echo "Failed to disable deletion protection for RDS instance: ${rds_instance_id}. Check your permissions."
    exit 1
  fi
}
# Function to empty the S3 bucket without jq
empty_s3_bucket() {
  local bucket_name="$1"
  echo "Emptying S3 bucket: ${bucket_name}..."

  # Delete all object versions
  echo "Deleting all object versions..."
  aws s3api list-object-versions \
    --bucket "${bucket_name}" \
    --query 'Versions[].{Key: Key, VersionId: VersionId}' \
    --output text --no-cli-pager | while read -r key version; do
      # Check if both key and version are not empty
      if [[ -n "${key}" && -n "${version}" ]]; then
        echo "Deleting Object Version - Key: ${key}, VersionId: ${version}"
        aws s3api delete-object \
          --bucket "${bucket_name}" \
          --key "${key}" \
          --version-id "${version}" --no-cli-pager
      fi
  done

  # Delete all delete markers
  echo "Deleting all delete markers..."
  aws s3api list-object-versions \
    --bucket "${bucket_name}" \
    --query 'DeleteMarkers[].{Key: Key, VersionId: VersionId}' \
    --output text --no-cli-pager | while read -r key version; do
      # Check if both key and version are not empty
      if [[ -n "${key}" && -n "${version}" ]]; then
        echo "Deleting Delete Marker - Key: ${key}, VersionId: ${version}"
        aws s3api delete-object \
          --bucket "${bucket_name}" \
          --key "${key}" \
          --version-id "${version}"
      fi
  done

  echo "S3 bucket ${bucket_name} is now empty."
}

delete_s3_bucket() {
  local bucket_name="$1"
  
  # Check if bucket name is provided
  if [[ -z "${bucket_name}" ]]; then
    echo "Bucket name not provided. Usage: delete_s3_bucket <bucket-name>"
    return 1
  fi

  echo "🗑️ Deleting S3 bucket: ${bucket_name}..."

  # Check if the bucket exists
  if ! aws s3api head-bucket --bucket "${bucket_name}" --no-cli-pager 2>/dev/null; then
    echo "Bucket ${bucket_name} does not exist or you don't have access."
    return 1
  fi

  # Empty all object versions
  echo "Deleting all object versions..."
  aws s3api list-object-versions \
    --bucket "${bucket_name}" \
    --query 'Versions[].{Key: Key, VersionId: VersionId}' \
    --output text --no-cli-pager | while read -r key version; do
      # Check if both key and version are not empty
      if [[ -n "${key}" && -n "${version}" ]]; then
        echo "Deleting Object Version - Key: ${key}, VersionId: ${version}"
        aws s3api delete-object \
          --bucket "${bucket_name}" \
          --key "${key}" \
          --version-id "${version}" --no-cli-pager
      fi
  done

  # Empty all delete markers
  echo "🧹 Deleting all delete markers..."
  aws s3api list-object-versions \
    --bucket "${bucket_name}" \
    --query 'DeleteMarkers[].{Key: Key, VersionId: VersionId}' \
    --output text --no-cli-pager | while read -r key version; do
      # Check if both key and version are not empty
      if [[ -n "${key}" && -n "${version}" ]]; then
        echo "Deleting Delete Marker - Key: ${key}, VersionId: ${version}"
        aws s3api delete-object \
          --bucket "${bucket_name}" \
          --key "${key}" \
          --version-id "${version}" --no-cli-pager
      fi
  done

  # Delete all remaining unversioned objects
  echo "Deleting unversioned objects..."
  aws s3 rm "s3://${bucket_name}" --recursive --no-cli-pager

  # Delete the bucket
  echo "Deleting the bucket..."
  aws s3api delete-bucket --bucket "${bucket_name}" --no-cli-pager

  if [ $? -eq 0 ]; then
    echo "S3 bucket ${bucket_name} has been deleted."
  else
    echo "Failed to delete S3 bucket ${bucket_name}. Check your permissions or if the bucket is empty."
    return 1
  fi
}

# Function to empty the ECR repository without jq
empty_ecr_repo() {
  echo "Emptying ECR repository: ${ecr_repo_name}..."

  # List all image digests
  image_digests=$(aws ecr list-images \
    --region "${region}" \
    --repository-name "${ecr_repo_name}" \
    --query 'imageIds[].imageDigest' \
    --output text --no-cli-pager)

  # Check if the repository is already empty
  if [ -z "$image_digests" ]; then
    echo "ECR repository ${ecr_repo_name} is already empty."
  else
    # Loop through each image digest and delete
    for digest in $image_digests; do
      echo "Deleting Image Digest: ${digest}"
      aws ecr batch-delete-image \
        --region "${region}" \
        --repository-name "${ecr_repo_name}" \
        --image-ids imageDigest="${digest}" --no-cli-pager
    done
    echo "ECR repository ${ecr_repo_name} is now empty."
  fi
}

Run Checks and Functions
check_empty_values
disable_rds_deletion_protection
empty_s3_bucket "${s3_bucket_name}"
empty_ecr_repo

# Terraform Deployment - Main Branch
echo "Switching to aws-terraform-deployment-lexum main and reapplying Terraform..."
cd "${deploymentPath}" || exit 1
git checkout main || exit 1
terraform init || exit 1
terraform destroy -var-file="${defaultPath}/plan.tfvar" -auto-approve || exit 1

empty_s3_bucket "${tfstate_name}"
delete_s3_bucket "${tfstate_name}"

echo "Script completed successfully!"
