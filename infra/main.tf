# main.tf - EC2 instance for GitHub Runner with Bastion functionality

terraform {
    required_version = ">= 1.0"
    required_providers {
        aws = {
            source  = "hashicorp/aws"
            version = "~> 5.0"
        }
    }

    backend "s3" {
        bucket         = "your-terraform-state-bucket"
        key            = "github-runner/terraform.tfstate"
        region         = "us-east-1"
        encrypt        = true
        dynamodb_table = "terraform-locks"
    }
}

provider "aws" {
    region = var.aws_region
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "payment-infra-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "${var.aws_region}a"
  tags              = { Name = "runner-private-subnet" }
}

resource "aws_eip" "nat_eip" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat_gw" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_subnet.id # NAT sits in Public, routes for Private
  tags          = { Name = "runner-nat-gw" }

  # To ensure proper ordering, it is recommended to add an explicit dependency
  depends_on = [aws_internet_gateway.igw]
}

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gw.id
  }
}

resource "aws_route_table_association" "private_assoc" {
  subnet_id      = aws_subnet.private_subnet.id
  route_table_id = aws_route_table.private_rt.id
}

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}a"
  tags = { Name = "runner-public-subnet" }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}


# IAM Role for EC2 to access AWS resources
resource "aws_iam_role" "github_runner_role" {
    name = "github-runner-role"

    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
            {
                Action = "sts:AssumeRole"
                Effect = "Allow"
                Principal = {
                    Service = "ec2.amazonaws.com"
                }
            }
        ]
    })
}

resource "aws_iam_role_policy_attachment" "runner_policy" {
    role       = aws_iam_role.github_runner_role.name
    policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_policy" "eks_deploy_policy" {
  name        = "github-runner-eks-deploy"
  description = "Minimal permissions for GitHub Runner to deploy to EKS"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Allow the runner to find the EKS cluster and get auth tokens
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
          "sts:GetCallerIdentity"
        ]
        Effect   = "Allow"
        Resource = "*" # You can scope this to your EKS Cluster ARN for max security
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_ecr_deploy" {
  role       = aws_iam_role.github_runner_role.name
  policy_arn = aws_iam_policy.ecr_deploy_policy.arn
}

resource "aws_iam_role_policy_attachment" "attach_ssm_core" {
  role       = aws_iam_role.github_runner_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "attach_eks_deploy" {
  role       = aws_iam_role.github_runner_role.name
  policy_arn = aws_iam_policy.eks_deploy_policy.arn
}

resource "aws_eks_access_entry" "runner_access" {
  cluster_name      = var.eks_cluster_name
  principal_arn     = aws_iam_role.github_runner_role.arn
  kubernetes_groups = ["system:masters"] # Or a custom 'deployer' group
  type              = "STANDARD"
}


/*resource "aws_iam_policy" "secrets_policy" {
  name        = "github-runner-secrets-policy"
  description = "Allows runner to fetch GitHub token"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = "secretsmanager:GetSecretValue"
        Effect   = "Allow"
        Resource = "arn:aws:secretsmanager:${var.aws_region}:YOUR_ACCOUNT_ID:secret:github/runner/token-*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_secrets" {
  role       = aws_iam_role.github_runner_role.name
  policy_arn = aws_iam_policy.secrets_policy.arn
} */

resource "aws_iam_policy" "secrets_policy" {
  name        = "github-runner-secrets-policy"
  description = "Allows runner to fetch GitHub token"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = "secretsmanager:GetSecretValue"
        Effect   = "Allow"
        Resource = aws_secretsmanager_secret.github_token.arn # Linked dynamically
      }
    ]
  })
}

resource "aws_iam_policy" "ecr_deploy_policy" {
  name        = "github-runner-ecr-deploy"
  description = "Minimal permissions to push/pull banking app images"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # REQUIRED: To get the temporary Docker login password
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        # SCOPED: Only allow push/pull on your specific application repositories
        Sid      = "ECRPushPull"
        Effect   = "Allow"
        Action   = [
          "ecr:CompleteLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:InitiateLayerUpload",
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer"
        ]
        # REPLACE with your actual repository ARNs for maximum security
        Resource = ["arn:aws:ecr:${var.aws_region}:YOUR_ACCOUNT_ID:repository/banking-app-*"]
      }
    ]
  })
}

resource "aws_secretsmanager_secret" "github_token" {
  name        = "github/runner/token"
  description = "Registration token for GitHub Self-Hosted Runner"
  
  # Best Practice: Force delete without recovery for dev/testing, 
  # but remove 'recovery_window_in_days = 0' for Production.
  recovery_window_in_days = 0 

  tags = {
    Environment = "Production"
    Service     = "GitHub-Runner"
  }
}

# The Secret Value (The actual token)
resource "aws_secretsmanager_secret_version" "github_token_val" {
  secret_id     = aws_secretsmanager_secret.github_token.id
  secret_string = var.github_token # This comes from your tfvars or environment variable
}

resource "aws_security_group" "vpc_endpoints_sg" {
  name        = "vpc-endpoints-sg"
  vpc_id      = aws_vpc.main.id
  description = "Allow private traffic to AWS services"

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }
}

resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  security_group_ids  = [aws_security_group.vpc_endpoints_sg.id]
  subnet_ids          = [aws_subnet.private_subnet.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type   = "Interface"
  security_group_ids  = [aws_security_group.vpc_endpoints_sg.id]
  subnet_ids          = [aws_subnet.public_subnet.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  security_group_ids  = [aws_security_group.vpc_endpoints_sg.id]
  subnet_ids          = [aws_subnet.public_subnet.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  security_group_ids  = [aws_security_group.vpc_endpoints_sg.id]
  subnet_ids          = [aws_subnet.public_subnet.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  security_group_ids  = [aws_security_group.vpc_endpoints_sg.id]
  subnet_ids          = [aws_subnet.private_subnet.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  security_group_ids  = [aws_security_group.vpc_endpoints_sg.id]
  subnet_ids          = [aws_subnet.private_subnet.id]
  private_dns_enabled = true
}

resource "aws_iam_instance_profile" "runner_profile" {
    name = "github-runner-profile"
    role = aws_iam_role.github_runner_role.name
}

# Security Group - allows SSH inbound and all outbound
resource "aws_security_group" "github_runner_sg" {
    name = "github-runner-sg"
    description = "Security group for GitHub Runner Bastion, No inbound SSH needed for private instances"
    vpc_id = aws_vpc.main.id

    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
        description = "All outbound traffic"
    }

    tags = {
        Name = "github-runner-bastion-sg"
    }
}

# EC2 Instance - Bastion/Runner
resource "aws_instance" "github_runner" {
    ami                    = data.aws_ami.amazon_linux.id
    instance_type          = var.instance_type
    iam_instance_profile   = aws_iam_instance_profile.runner_profile.name
    vpc_security_group_ids = [aws_security_group.github_runner_sg.id]
    subnet_id              = aws_subnet.private_subnet.id

    user_data = base64encode(templatefile("${path.module}/user_data.sh", {
        github_token = var.github_token
        github_url   = var.github_url
    }))
    metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    encrypted = true
  }

    tags = {
        Name = "github-runner-bastion"
    }
}

# Data source for Amazon Linux 2 AMI (cost-effective)
data "aws_ami" "amazon_linux" {
    most_recent = true
    owners      = ["137112412989"]

    filter {
        name   = "name"
        values = ["amzn2-ami-hvm-*-x86_64-gp2"]
    }
}

output "bastion_instance_ip" {
    value       = aws_instance.github_runner.public_ip
    description = "Public IP of the Bastion/GitHub Runner instance"
}

output "bastion_security_group_id" {
    value       = aws_security_group.github_runner_sg.id
    description = "Security Group ID for reference in private instance configurations"
}