############################################
# BOOTSTRAP: cicd-runner-account
#
# Applied once, directly in cicd-runner-account (111194324950), using your
# own admin credentials for that account. Nothing here is ever destroyed by
# any pipeline run.
#
# This layer's ONLY job is to bridge GitHub Actions into workload accounts:
#   GitHub OIDC --> hub role (here) --> AssumeRole --> workload account role
#
# The hub role has NO permissions of its own beyond assuming the next role
# in the chain — it can't touch S3, ECS, or anything else directly. If this
# role's credentials ever leaked, the blast radius is "can assume the same
# role a legitimate deploy would" — not "can do anything in any account."
############################################

terraform {
  required_version = ">= 1.7"

  backend "s3" {
    # terraform init -backend-config=cicd-runner.tfbackend
    # State for THIS bootstrap layer only. Created via one-time AWS CLI
    # commands in cicd-runner-account — see BOOTSTRAP.md step 0.
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "amster2k2x"
      ManagedBy = "terraform"
      Layer     = "bootstrap-cicd-runner"
    }
  }
}

# ---------------------------------------------------------------------------
# OIDC — GitHub Actions authenticates here, and only here. Every workload
# account trusts THIS role, never GitHub directly.
# ---------------------------------------------------------------------------
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

data "aws_iam_policy_document" "github_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # GitHub-Environment-scoped trust, not branch-scoped — matches "I'll set
    # up GitHub Environments manually": create an Environment named "test"
    # in the repo, and this condition only accepts tokens minted for a
    # workflow run tied to that Environment.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.github_trusted_subs
    }
  }
}

resource "aws_iam_role" "hub" {
  name               = "amster2k2x-cicd-hub"
  assume_role_policy = data.aws_iam_policy_document.github_trust.json

  tags = {
    Purpose = "Bridges GitHub OIDC into workload-account cross-account roles. No direct permissions."
  }
}

# The ONLY permission this role has: assume a role in a workload account.
# Each workload account gets one entry here. Right now, just test-account —
# adding prod later is one more ARN in this list, nothing else changes here.
data "aws_iam_policy_document" "assume_workload_roles" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    resources = [
      "arn:aws:iam::${var.test_account_id}:role/amster2k2x-test-deploy",
      # "arn:aws:iam::${var.prod_account_id}:role/amster2k2x-prod-deploy",  # add when prod-account exists
    ]
  }
}

resource "aws_iam_role_policy" "assume_workload_roles" {
  name   = "assume-workload-account-roles"
  role   = aws_iam_role.hub.id
  policy = data.aws_iam_policy_document.assume_workload_roles.json
}
