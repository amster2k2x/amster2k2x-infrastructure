terraform {
  required_version = ">= 1.7"

  backend "s3" {
    # terraform init -backend-config=build.tfbackend
    # bucket/key come from bootstrap/workload-account's outputs — see
    # BOOTSTRAP.md and the GH Actions workflow, which passes these at init time.
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# No explicit assume_role block: by the time Terraform runs, the ambient AWS
# credentials already ARE the workload account's deploy role — GitHub Actions
# did the OIDC -> hub role -> cross-account role chain before this ever runs.
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "amster2k2x"
      Environment = var.environment
      ManagedBy   = "terraform"
      Ephemeral   = "true"
    }
  }
}
