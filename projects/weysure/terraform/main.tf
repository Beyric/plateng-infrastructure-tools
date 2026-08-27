locals {
  cluster_name = "${var.project}-cluster"
}

module "vpc" {
  source = "../../../modules/vpc"

  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  availability_zones   = var.availability_zones
  cluster_name         = local.cluster_name
}

module "eks" {
  source = "../../../modules/eks"

  cluster_name       = local.cluster_name
  environment        = var.environment
  public_subnet_ids  = module.vpc.public_subnet_ids
  private_subnet_ids = module.vpc.private_subnet_ids
  node_instance_type = var.eks_node_instance_type
  node_min           = var.eks_node_min
  node_max           = var.eks_node_max
  node_desired       = var.eks_node_desired
}

module "rds" {
  source = "../../../modules/rds"

  project            = var.project
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  vpc_cidr           = var.vpc_cidr
  private_subnet_ids = module.vpc.private_subnet_ids
  instance_class     = var.db_instance_class
  db_name            = var.db_name
  db_username        = var.db_username
}

# Create ECR repository
resource "aws_ecr_repository" "api" {
  name                 = "weysure-api"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Environment = var.environment
  }
}
