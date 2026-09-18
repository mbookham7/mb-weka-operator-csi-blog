# ---------------------------------------------------------------------------
# The shared WEKA security group
# ---------------------------------------------------------------------------
# One security group is attached to BOTH the WEKA backend instances and the EKS
# worker nodes. That is the whole trick that makes this topology work: the
# rules below are self-referencing, so "backend <-> backend", "client <-> client"
# and "backend <-> client" are all covered by the same three rules, and adding a
# node to the group is all it takes to make it eligible to be a WEKA client.
#
# Why security groups and not NetworkPolicy: the WekaClient container runs with
# hostNetwork: true. Its traffic never traverses the CNI's pod network, so
# Kubernetes NetworkPolicy has no visibility into it and cannot allow or deny
# any of it. Security groups are the only enforcement point. See README,
# "Networking notes".

resource "aws_security_group" "weka" {
  name_prefix = "${local.name}-weka-"
  description = "Shared by WEKA backends and EKS worker nodes: WEKA data path, control path, and Secrets Manager endpoint access"
  vpc_id      = module.vpc.vpc_id

  tags = merge(var.tags, {
    Name = "${local.name}-weka-shared"
  })

  # The EKS launch template references this group. Replacing it in place would
  # deadlock against the running node group.
  lifecycle {
    create_before_destroy = true
  }
}

# --- WEKA traffic: TCP -----------------------------------------------------
#
# 14000-16059 is the union of every port range a WEKA container binds in a
# cloud deployment (drives 14000-14059, compute 15000-15059, frontend
# 16000-16059). One wide range keeps the demo readable; the narrow production
# form is at the bottom of this file.
#
# WEKA traffic is BIDIRECTIONAL. A backend does not merely answer a client --
# it originates connections back to the client's frontend container. So the
# rule has to be symmetric, which self-referencing ingress gives you for free.
resource "aws_vpc_security_group_ingress_rule" "weka_tcp" {
  security_group_id            = aws_security_group.weka.id
  referenced_security_group_id = aws_security_group.weka.id
  ip_protocol                  = "tcp"
  from_port                    = 14000
  to_port                      = 16059
  description                  = "WEKA control and data path (TCP)"
}

# --- WEKA traffic: UDP -----------------------------------------------------
#
# READ THIS BEFORE YOU DELETE IT.
#
# UDP is the WEKA data path. TCP carries cluster management, the RESTful API on
# 14000, and the join handshake. If you open TCP only, everything you look at
# during setup works: the client joins, `weka status` is green, `weka cluster
# container` lists your client, the CSI plugin provisions a PVC. And then I/O
# runs at a small fraction of the expected throughput, with no error anywhere,
# because the data path is silently falling back or retransmitting.
#
# A WEKA cluster that "joins and then performs terribly" is almost always this
# rule missing. It is the single most common misconfiguration in this topology.
resource "aws_vpc_security_group_ingress_rule" "weka_udp" {
  security_group_id            = aws_security_group.weka.id
  referenced_security_group_id = aws_security_group.weka.id
  ip_protocol                  = "udp"
  from_port                    = 14000
  to_port                      = 16059
  description                  = "WEKA data path (UDP) -- omitting this yields a cluster that joins and then performs terribly"
}

# --- Secrets Manager interface endpoint ------------------------------------
#
# Because we pass `sg_ids` to the WEKA module, the module skips creating its own
# security group and attaches THIS group to everything it builds -- including
# the Secrets Manager interface VPC endpoint it creates to hand the backends
# their admin password and join secret. An interface endpoint is an ENI in our
# subnets, and it needs 443 ingress from its clients. The backends are in this
# same group, so a self-referencing 443 rule is what makes that work.
#
# Without it, cluster formation hangs waiting on a secret it cannot fetch.
resource "aws_vpc_security_group_ingress_rule" "weka_https_endpoint" {
  security_group_id            = aws_security_group.weka.id
  referenced_security_group_id = aws_security_group.weka.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "HTTPS to the Secrets Manager interface endpoint attached to this same group"
}

# --- SSH -------------------------------------------------------------------
#
# We have to add this ourselves. The WEKA module's `allow_ssh_cidrs` variable
# is only wired into the security group the module creates, and passing `sg_ids`
# suppresses that module entirely -- so `allow_ssh_cidrs` is a no-op on the
# module side in this configuration. Defaults to no rule at all.
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = toset(var.allow_ssh_cidrs)

  security_group_id = aws_security_group.weka.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  description       = "SSH from ${each.value}"
}

# --- Egress ----------------------------------------------------------------
#
# Wide open, and it has to be: get.weka.io for the release, drivers.weka.io for
# the prebuilt kernel driver, quay.io for the operator and client images, plus
# the usual EKS control plane and ECR traffic.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.weka.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "All egress -- get.weka.io, drivers.weka.io, quay.io, EKS API"
}

# ---------------------------------------------------------------------------
# Production form: narrow, per-role rules
# ---------------------------------------------------------------------------
# The single 14000-16059 range above also covers ~1900 ports nothing listens
# on. For anything you have to get through a security review, replace the
# weka_tcp / weka_udp rules with these six. Each range still needs both TCP and
# UDP, and each still needs to be self-referencing.
#
# These are the CLOUD port assignments. Bare-metal WEKA deployments use a
# different layout -- frontend 14200-14259 and compute 14300-14359, all inside
# the 14000-14999 band -- so a rule set copied from a bare-metal runbook will
# not match a cloud cluster and vice versa. Check `weka cluster container` for
# the ports your containers actually bound before committing to a range.
#
# locals {
#   weka_port_ranges = {
#     drives   = { from = 14000, to = 14059 }
#     compute  = { from = 15000, to = 15059 }
#     frontend = { from = 16000, to = 16059 }
#   }
#
#   weka_rules = merge([
#     for role, r in local.weka_port_ranges : {
#       for proto in ["tcp", "udp"] :
#       "${role}-${proto}" => { role = role, proto = proto, from = r.from, to = r.to }
#     }
#   ]...)
# }
#
# resource "aws_vpc_security_group_ingress_rule" "weka_narrow" {
#   for_each = local.weka_rules
#
#   security_group_id            = aws_security_group.weka.id
#   referenced_security_group_id = aws_security_group.weka.id
#   ip_protocol                  = each.value.proto
#   from_port                    = each.value.from
#   to_port                      = each.value.to
#   description                  = "WEKA ${each.value.role} (${upper(each.value.proto)})"
# }
