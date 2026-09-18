# ---------------------------------------------------------------------------
# Version pinning
# ---------------------------------------------------------------------------
# Every constraint here is a floor imposed by a child module, not a preference.
# The chain is worth understanding before you relax anything:
#
#   weka/weka/aws 2.0.1                 requires aws >= 6.0.0
#     -> so the AWS 5.x provider line is not an option at all
#   terraform-aws-modules/eks 21.x      requires aws >= 6.59  and tf >= 1.5.7
#   terraform-aws-modules/vpc 6.x       requires aws >= 6.28
#
# terraform-aws-modules/eks 20.x pins `aws >= 5.95, < 6.0.0`, which is flatly
# incompatible with the WEKA module. See README, "Module versions", for why
# this repo runs eks 21.x / vpc 6.x rather than the 20.x / 5.x generation.
terraform {
  required_version = ">= 1.5.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.59"
    }
  }
}
