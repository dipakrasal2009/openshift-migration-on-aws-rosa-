variable "aws_region" {
  description = "AWS region for the OpenShift cluster"
  type        = string
  default     = "ap-south-1"
}

variable "cluster_name" {
  description = "Name of the OpenShift cluster"
  type        = string
  default     = "ocp4-prod"
}

variable "environment" {
  description = "Deployment environment (dev/staging/prod)"
  type        = string
  default     = "prod"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones"
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
}

variable "base_domain" {
  description = "Base domain for OpenShift cluster"
  type        = string
  default     = "example.com"
}

variable "allowed_admin_cidrs" {
  description = "CIDRs allowed to reach OpenShift API (port 6443)"
  type        = list(string)
  default     = ["10.0.0.0/8"]
}
