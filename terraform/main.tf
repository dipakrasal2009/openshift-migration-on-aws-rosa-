###############################################################
# OpenShift 4.x Cluster Migration - AWS Infrastructure
# File: main.tf
# Purpose: Provisions all AWS resources required to host the
#          target OpenShift 4.x (ROSA) cluster on AWS
###############################################################

terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket = "openshift-migration-tfstate"
    key    = "openshift/terraform.tfstate"
    region = "ap-south-1"
  }
}

provider "aws" {
  region = var.aws_region
}

# ------------------------------------------------------------------
# VPC
# ------------------------------------------------------------------
resource "aws_vpc" "openshift_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "${var.cluster_name}-vpc"
    Environment = var.environment
    Project     = "OpenShift-Migration"
  }
}

# ------------------------------------------------------------------
# Public Subnets (for Load Balancers)
# ------------------------------------------------------------------
resource "aws_subnet" "public" {
  count                   = length(var.availability_zones)
  vpc_id                  = aws_vpc.openshift_vpc.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                          = "${var.cluster_name}-public-${count.index + 1}"
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${var.cluster_name}"   = "owned"
  }
}

# ------------------------------------------------------------------
# Private Subnets (for Worker Nodes)
# ------------------------------------------------------------------
resource "aws_subnet" "private" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.openshift_vpc.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 3)
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name                                          = "${var.cluster_name}-private-${count.index + 1}"
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${var.cluster_name}"   = "owned"
  }
}

# ------------------------------------------------------------------
# Internet Gateway & NAT Gateway
# ------------------------------------------------------------------
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.openshift_vpc.id
  tags   = { Name = "${var.cluster_name}-igw" }
}

resource "aws_eip" "nat" {
  count  = length(var.availability_zones)
  domain = "vpc"
  tags   = { Name = "${var.cluster_name}-nat-eip-${count.index + 1}" }
}

resource "aws_nat_gateway" "nat" {
  count         = length(var.availability_zones)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = { Name = "${var.cluster_name}-nat-${count.index + 1}" }
  depends_on    = [aws_internet_gateway.igw]
}

# ------------------------------------------------------------------
# Route Tables
# ------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.openshift_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${var.cluster_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  count  = length(var.availability_zones)
  vpc_id = aws_vpc.openshift_vpc.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat[count.index].id
  }
  tags = { Name = "${var.cluster_name}-private-rt-${count.index + 1}" }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ------------------------------------------------------------------
# Security Group for OpenShift Nodes
# ------------------------------------------------------------------
resource "aws_security_group" "openshift_nodes" {
  name        = "${var.cluster_name}-nodes-sg"
  description = "Security group for OpenShift worker nodes"
  vpc_id      = aws_vpc.openshift_vpc.id

  ingress {
    description = "Allow all within cluster"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }
  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
  ingress {
    description = "OpenShift API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = var.allowed_admin_cidrs
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.cluster_name}-nodes-sg" }
}

# ------------------------------------------------------------------
# IAM Role for OpenShift Worker Nodes
# ------------------------------------------------------------------
resource "aws_iam_role" "openshift_worker" {
  name = "${var.cluster_name}-worker-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "worker_ecr" {
  role       = aws_iam_role.openshift_worker.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "openshift_worker" {
  name = "${var.cluster_name}-worker-profile"
  role = aws_iam_role.openshift_worker.name
}

# ------------------------------------------------------------------
# S3 Bucket for Velero Backups
# ------------------------------------------------------------------
resource "aws_s3_bucket" "velero_backup" {
  bucket        = "${var.cluster_name}-velero-backup-${var.environment}"
  force_destroy = false
  tags = {
    Name    = "Velero Backup"
    Project = "OpenShift-Migration"
  }
}

resource "aws_s3_bucket_versioning" "velero" {
  bucket = aws_s3_bucket.velero_backup.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero" {
  bucket = aws_s3_bucket.velero_backup.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ------------------------------------------------------------------
# Route53 Private Hosted Zone for Cluster
# ------------------------------------------------------------------
resource "aws_route53_zone" "openshift_private" {
  name = "${var.cluster_name}.${var.base_domain}"
  vpc {
    vpc_id = aws_vpc.openshift_vpc.id
  }
  tags = { Name = "${var.cluster_name}-private-zone" }
}

# ------------------------------------------------------------------
# Outputs
# ------------------------------------------------------------------
output "vpc_id" {
  value = aws_vpc.openshift_vpc.id
}
output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}
output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}
output "velero_s3_bucket" {
  value = aws_s3_bucket.velero_backup.bucket
}
output "route53_zone_id" {
  value = aws_route53_zone.openshift_private.zone_id
}
