variable "aws_region" {
    description = "AWS region to deploy resources"
    type        = string
    default     = "us-east-1"
}

variable "env" {
    description = "Deployment environment (e.g., dev, staging, prod)"
    type        = string
    default     = "dev"
}
variable "github_token" {
    description = "GitHub personal access token"
    type        = string
}

variable "github_url" {
    description = "GitHub URL"
    type        = string
}

variable "runner_group" {
    description = "GitHub Runner Group"
    type        = string
    default     = "Default"
}

variable "runner_count" {
    description = "Number of GitHub runners to create"
    type        = number
    default     = 1
}

variable "instance_type" {
    description = "EC2 instance type"
    type        = string
    default     = var.env == "prod" ? "t3.medium" : "t3.micro"
}