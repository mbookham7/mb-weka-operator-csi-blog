locals {
  # Two AZs. The EKS control plane requires subnets in at least two, and the
  # WEKA module's ALB (if enabled) needs a second AZ as well. The WEKA backends
  # themselves are single-AZ -- see weka.tf.
  azs = length(var.availability_zones) > 0 ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, 2)

  name = "${var.prefix}-${var.cluster_name}"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = "${local.name}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  # /20 per subnet (4091 usable addresses). Deliberately generous: with the AWS
  # VPC CNI every pod consumes a private subnet IP, and a WEKA client node with
  # DPDK also consumes additional secondary IPs on its data-path ENIs.
  private_subnets = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  # NAT is not optional here. The WEKA backends have no public IPs and the very
  # first thing their boot script does is pull the release tarball from
  # get.weka.io. Without egress the instances launch, the userdata fails
  # quietly, the step function times out, and you are left with six running
  # i3en.6xlarge and no cluster. The EKS nodes also need egress to reach
  # quay.io for the operator images and drivers.weka.io for the kernel driver.
  enable_nat_gateway = true
  single_nat_gateway = true

  # Required for the Secrets Manager interface endpoint the WEKA module creates
  # to resolve to its private address. Without private DNS the backends resolve
  # secretsmanager.<region>.amazonaws.com to a public IP, egress over NAT, and
  # the endpoint is dead weight.
  enable_dns_hostnames = true
  enable_dns_support   = true

  # EKS discovers subnets for internal load balancers by this tag. The public
  # counterpart lets it place internet-facing ones.
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  tags = var.tags
}
