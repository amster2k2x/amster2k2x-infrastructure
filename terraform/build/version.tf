terraform {
  required_version = ">= 1.7"

  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "amster2k2x"
      Environment = var.environment
      ManagedBy   = "terraform"
      Layer       = "build"
    }
  }
}