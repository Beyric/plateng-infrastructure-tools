terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }

  backend "s3" {
    bucket       = "beyric-tfstate-767397877316"
    key          = "weysure/infrastructure/terraform.tfstate"
    region       = "us-east-1"
    profile      = "beyric-admin"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region  = var.region
  profile = "beyric-admin"

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "Beyric/plateng-infrastructure-tools"
    }
  }
}
