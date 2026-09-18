# ---------------------------------------------------------------------------
# The WEKA backend cluster
# ---------------------------------------------------------------------------
# This module does a lot more than launch instances: it creates an autoscaling
# group, a DynamoDB table for cluster state, Secrets Manager entries, a set of
# Lambdas and a Step Function that drive cluster formation, and the IAM to tie
# them together. `terraform apply` returning does NOT mean the cluster is
# ready -- the Step Function is still running. Expect 15-25 minutes before
# `weka status` reports a healthy cluster.

module "weka" {
  source  = "weka/weka/aws"
  version = "2.0.1"

  prefix       = var.prefix
  cluster_name = var.cluster_name

  # --- Shared network ----------------------------------------------------
  #
  # There is no `vpc_id` input on this module. It derives the VPC by reading
  # the subnet we hand it (data.aws_subnet.this[0].vpc_id internally), so
  # passing our subnet is what puts WEKA and EKS in the same VPC.
  #
  # EXACTLY ONE SUBNET. The module validates `length(subnet_ids) <= 1` and
  # fails with "Multiple subnets are not supported" otherwise. This is not an
  # oversight: a WEKA cloud cluster is single-AZ by design. The backends sit in
  # a cluster placement group for the lowest possible inter-node latency, and
  # cross-AZ RTT would dominate the latency budget of a distributed filesystem
  # that stripes every write across peers. Durability comes from WEKA's own
  # protection level and hot spare within the AZ, not from AZ spread.
  #
  # The EKS worker nodes span both private subnets. Clients being in a
  # different AZ from the backends is fine -- that is a normal client access
  # path -- it just costs cross-AZ data transfer.
  subnet_ids = [module.vpc.private_subnets[0]]

  # The shared security group from security-groups.tf. Passing this suppresses
  # the module's own security_group submodule entirely, which is why
  # `allow_ssh_cidrs` and `allow_weka_api_cidrs` below are effectively inert
  # and the equivalent rules live in security-groups.tf instead.
  sg_ids = [aws_security_group.weka.id]

  # Our VPC already has a NAT gateway (network.tf). Letting the module build a
  # second one would be a duplicate charge and a second default route.
  create_nat_gateway = false

  # No public IPs: the backends are reached from inside the VPC only, and they
  # egress via our NAT. ("auto" would infer this, but being explicit means the
  # behaviour does not change if someone later removes `subnet_ids`.)
  assign_public_ip = "false"

  # --- Cluster shape -----------------------------------------------------
  cluster_size  = var.weka_cluster_size
  instance_type = var.weka_instance_type
  weka_version  = var.weka_version

  # The backends pull the release from get.weka.io on first boot using this.
  get_weka_io_token = var.get_weka_io_token

  # --- Things we deliberately turn off -----------------------------------
  #
  # The module can launch its own plain-EC2 WEKA clients. We do not want any:
  # the EKS worker nodes are the clients, and the WEKA Operator manages the
  # client containers on them.
  clients_number = 0

  # Data-services instances (2x m6i.xlarge by default) handle background jobs.
  # Not required to serve CSI volumes; off by default to keep the demo cheap.
  data_services_number = var.weka_data_services_number

  # --- ALB ---------------------------------------------------------------
  #
  # `alb_additional_subnet_id` is passed UNCONDITIONALLY even though the ALB is
  # off by default. Inside the module the additional-subnet expression is:
  #
  #   var.create_alb ? var.alb_additional_subnet_id == ""
  #     ? module.network[0].additional_subnet_id : var.alb_additional_subnet_id : ""
  #
  # `module.network` has count 0 whenever you supply your own `subnet_ids`, so
  # enabling the ALB without also supplying this value crashes on an index out
  # of range rather than telling you what is wrong. Supplying it always means
  # flipping `create_weka_alb` to true just works.
  create_alb               = var.create_weka_alb
  alb_additional_subnet_id = module.vpc.private_subnets[1]

  # --- SSH ---------------------------------------------------------------
  #
  # Kept here for documentation and so the value is in one place, but see the
  # note above: with `sg_ids` set, the module never builds the security group
  # these would have applied to. The rules that actually take effect are in
  # security-groups.tf.
  allow_ssh_cidrs = var.allow_ssh_cidrs

  # null => the module generates a key pair and writes the private key to
  # /tmp/<prefix>-<cluster_name>-private-key.pem locally.
  key_pair_name = var.key_pair_name

  tags_map = var.tags
}
