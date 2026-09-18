provider "aws" {
  region = var.region
}

# Used to build IAM policy ARNs without hard-coding the "aws" partition, so
# this still works in GovCloud / China regions.
data "aws_partition" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}
