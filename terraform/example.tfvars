# Example Terraform variable values
# Copy this to terraform.tfvars and fill in your values
# DO NOT commit terraform.tfvars to git (it's in .gitignore)

aws_region          = "ap-south-1"
cluster_name        = "ocp4-prod"
environment         = "prod"
vpc_cidr            = "10.0.0.0/16"
availability_zones  = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
base_domain         = "example.com"
allowed_admin_cidrs = ["10.0.0.0/8"]
