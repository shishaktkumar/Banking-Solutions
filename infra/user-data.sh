#!/bin/bash
set -e # Exit on any error

# 1. System Updates & Core Dependencies
yum update -y
yum install -y jq curl git docker unzip
systemctl enable docker
systemctl start docker
usermod -aG docker ec2-user

# 2. Install AWS CLI v2 (Required for EKS authentication)
curl "https://awscli.amazonaws.com" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install
rm -rf awscliv2.zip aws/

# 3. Install kubectl (Match this version to your EKS cluster version)
K8S_VERSION="1.32.0"
curl -LO "https://dl.k8s.io{K8S_VERSION}/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl

# 4. Install Helm
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com
chmod 700 get_helm.sh
./get_helm.sh
rm get_helm.sh

# 5. Fetch GitHub Token from AWS Secrets Manager
REGION=$(curl -s http://169.254.169.254)
# Architect's Note: Ensure the Secret Name matches your Terraform 'aws_secretsmanager_secret' name
GITHUB_TOKEN=$(aws secretsmanager get-secret-value --secret-id github/runner/token --region $REGION --query SecretString --output text)

# 6. Setup GitHub Runner Directory
mkdir -p /home/ec2-user/actions-runner && cd /home/ec2-user/actions-runner
RUNNER_VERSION="2.311.0"
curl -o actions-runner-linux-x64-$${RUNNER_VERSION}.tar.gz -L https://github.com{RUNNER_VERSION}/actions-runner-linux-x64-$${RUNNER_VERSION}.tar.gz
tar xzf ./actions-runner-linux-x64-$${RUNNER_VERSION}.tar.gz
chown -R ec2-user:ec2-user /home/ec2-user/actions-runner

# 7. Register & Start the Runner as a Background Service
# --unattended: skips prompts
# --replace: cleans up old 'dead' runner entries with the same name
sudo -u ec2-user ./config.sh --url ${github_url} --token $${GITHUB_TOKEN} --unattended --replace
./svc.sh install ec2-user
./svc.sh start
