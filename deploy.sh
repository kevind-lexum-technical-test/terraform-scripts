#!/bin/bash

# Set default path
defaultPath=$(pwd)
ansiblePath="${defaultPath}/ansible-lexum-app"
javaAppPath="${defaultPath}/lexum-app"
deploymentPath="${defaultPath}/aws-terraform-deployment-lexum"
TAG_NAME="aws-kev-test-java-server"
REGION="ca-central-1"  # Change this to your desired AWS region
ALB_NAME="aws-kev-test-java-server-alb"
REGION="ca-central-1"

rm -rf "${ansiblePath}"
rm -rf "${javaAppPath}"
rm -rf "${deploymentPath}"

# Function to find the Instance ID
find_instance_id() {
  echo "Searching for EC2 instance with tag Name=${TAG_NAME}..."

  INSTANCE_ID=$(aws ec2 describe-instances \
    --region "${REGION}" \
    --filters "Name=tag:Name,Values=${TAG_NAME}" "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text)

  if [ -z "$INSTANCE_ID" ]; then
    echo "No running instance found with tag Name=${TAG_NAME}."
    exit 1
  else
    echo "Found instance with ID: ${INSTANCE_ID}"
  fi
}

# Function to terminate the instance
terminate_instance() {
  echo "Terminating EC2 instance with ID: ${INSTANCE_ID}..."

  aws ec2 terminate-instances \
    --region "${REGION}" \
    --instance-ids "${INSTANCE_ID}" \
    --output json

  if [ $? -eq 0 ]; then
    echo "Instance ${INSTANCE_ID} is terminating."
  else
    echo "Failed to terminate instance ${INSTANCE_ID}. Check your permissions."
    exit 1
  fi
}

# Function to check if AWS CLI is installed and configured
check_aws_cli() {
  echo "Checking if AWS CLI is installed and configured..."

  # Check if AWS CLI is installed
  if ! command -v aws &> /dev/null
  then
    echo "AWS CLI is not installed. Please install it before running this script."
    exit 1
  fi

  # Check if AWS CLI is configured
  if ! aws s3 ls &> /dev/null
  then
    echo "AWS CLI is not configured. Please run 'aws configure' before running this script."
    exit 1
  fi

  echo "AWS CLI is installed and configured."
}

# Function to check if Docker is installed and running
check_docker() {
  echo "Checking if Docker is installed and running..."

  # Check if Docker is installed
  if ! command -v docker &> /dev/null
  then
    echo "Docker is not installed. Please install Docker before running this script."
    exit 1
  fi

  # Check if Docker daemon is running
  if ! docker info &> /dev/null
  then
    echo "Docker daemon is not running. Please start Docker before running this script."
    exit 1
  fi

  echo "Docker is installed and running."
}

# Function to check for empty values in plan.tfvar
check_empty_values() {
  echo "Checking for empty values in plan.tfvar..."

  # Define the path to plan.tfvar
  plan_tfvar="${defaultPath}/plan.tfvar"

  # Check if plan.tfvar exists
  if [ ! -f "${plan_tfvar}" ]; then
    echo "plan.tfvar file not found at ${plan_tfvar}. Please provide a valid file."
    exit 1
  fi

  # Find lines with empty values and store them
  empty_vars=$(grep '=""' "${plan_tfvar}" | awk -F '=' '{print $1}' | xargs)

  # If any empty values are found, print them and exit
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

# Run the checks
check_empty_values
check_aws_cli
check_docker

# Clone repositories
echo "Cloning repositories..."
git clone git@github.com:kevind-lexum-technical-test/aws-terraform-deployment-lexum.git || exit 1
git clone git@github.com:kevind-lexum-technical-test/lexum-app.git || exit 1
git clone git@github.com:kevind-lexum-technical-test/ansible-lexum-app.git || exit 1

# Terraform Deployment - Version 0.0.1
echo "Switching to aws-terraform-deployment-lexum 0.0.1 and applying Terraform..."
cd "${deploymentPath}" || exit 1
git checkout tags/0.0.1 || exit 1
terraform init || exit 1
terraform plan -var-file="${defaultPath}/plan.tfvar" -out="${deploymentPath}/tf.plan" || exit 1
terraform apply "${deploymentPath}/tf.plan" || exit 1
aws s3 cp "${deploymentPath}/terraform.tfstate" s3://aws-kev-test-tfstate/terraform.tfstate || exit 1

# Zip the ansible code
echo "Re-uploading Ansible scripts..."
cd "${ansiblePath}" || exit 1
zip -r "${ansiblePath}/ansible.zip" * || exit 1
aws s3 cp "${ansiblePath}/ansible.zip" s3://aws-kev-test-ansible-source/ansible.zip || exit 1

# Build Docker Image
echo "Building Docker image for lexum-app..."
cd "${javaAppPath}" || exit 1
mvn clean install package || exit 1
docker build -t lexum-app . || exit 1# Push Docker Image to ECR
docker tag lexum-app:latest 615299767641.dkr.ecr.ca-central-1.amazonaws.com/aws-kev-test-lexum-app:0.0.1 || exit 1
aws ecr get-login-password --region ca-central-1 | docker login --username AWS --password-stdin 615299767641.dkr.ecr.ca-central-1.amazonaws.com || exit 1
docker push 615299767641.dkr.ecr.ca-central-1.amazonaws.com/aws-kev-test-lexum-app:0.0.1 || exit 1

# Terraform Deployment - Main Branch
echo "Switching to aws-terraform-deployment-lexum main and reapplying Terraform..."
cd "${deploymentPath}" || exit 1
git checkout main || exit 1
rm -rf "${deploymentPath}/.terraform"
terraform init || exit 1
terraform plan -var-file="${defaultPath}/plan.tfvar" -out="${deploymentPath}/tf.plan" || exit 1
terraform apply "${deploymentPath}/tf.plan" || exit 1

# Run Checks
find_instance_id
terminate_instance

# Get ALB DNS Name
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --region "${REGION}" \
  --names "${ALB_NAME}" \
  --query "LoadBalancers[0].DNSName" \
  --output text)

# Check if DNS Name was found
if [ -z "$ALB_DNS" ]; then
  echo "No ALB found with name ${ALB_NAME}. Please check the ALB name and try again."
  exit 1
fi

# Print and Run the Curl Command
echo "Generated curl command (please wait a few min for ec2 to start and setup):"
echo "curl http://${ALB_DNS}:80/health"
echo "curl http://${ALB_DNS}:80/unhealth"
echo "curl http://${ALB_DNS}:80/data"

echo "Script completed successfully!"
