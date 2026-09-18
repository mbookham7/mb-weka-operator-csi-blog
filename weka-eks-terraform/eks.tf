# ---------------------------------------------------------------------------
# EKS control plane + the WEKA client node group
# ---------------------------------------------------------------------------

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.25"

  name               = "${local.name}-eks"
  kubernetes_version = var.eks_kubernetes_version

  # Same VPC as the WEKA cluster. Nodes go in both private subnets; the WEKA
  # backends are in private_subnets[0] only (see weka.tf).
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_private_access      = true
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.eks_endpoint_public_access_cidrs

  # Grants the identity running `terraform apply` cluster-admin via an EKS
  # access entry, so `kubectl` works immediately after
  # `aws eks update-kubeconfig` without a separate aws-auth edit.
  enable_cluster_creator_admin_permissions = true

  # ---------------------------------------------------------------------
  # `before_compute` on the networking addons is NOT optional
  # ---------------------------------------------------------------------
  # This module sets `bootstrap_self_managed_addons = false` on the cluster,
  # so EKS installs NOTHING by itself -- whatever is not declared here simply
  # does not exist. And the module has two addon resources:
  #
  #   aws_eks_addon.this            depends_on = [module.eks_managed_node_group,
  #                                               module.self_managed_node_group,
  #                                               module.fargate_profile]
  #   aws_eks_addon.before_compute  no such dependency
  #
  # `before_compute` defaults to FALSE, so declaring vpc-cni without it puts
  # the CNI behind the node group in the dependency graph -- and that is a
  # deadlock, not merely slow ordering:
  #
  #   the node group waits for a node to become Ready
  #     -> the kubelet reports "cni plugin not initialized" and stays NotReady
  #       -> because the vpc-cni addon is not installed
  #         -> because it is waiting for the node group
  #
  # Terraform sits on that for the provider's full 60-minute node-group create
  # timeout, with `aws eks list-addons` returning [] and kube-system totally
  # empty, which looks nothing like a dependency-ordering bug.
  addons = {
    # DaemonSets required for a node to reach Ready. Created concurrently with
    # the node group rather than after it.
    #
    # MAX_ENI = "1" IS LOAD-BEARING. Without it, WEKA and the VPC CNI fight
    # over the node's network interfaces and you get pods with no network at
    # all.
    #
    # What happens: the `ensure-nics` WekaPolicy needs `dataNICsNumber`
    # interfaces for the DPDK data path. It counts the NON-PRIMARY ENIs already
    # attached to the instance as candidates -- and it does not distinguish
    # ENIs the VPC CNI created for pod IPs (tagged `aws-K8S-<instance>`,
    # `node.k8s.amazonaws.com/createdAt`) from ones it attached itself
    # (`weka_reason`, `weka_instance`). So if the CNI has already attached a
    # secondary ENI for pod capacity, WEKA claims it as a data NIC and unbinds
    # it from the kernel for DPDK.
    #
    # The result is brutal to diagnose. Observed on a real run:
    #
    #   ip rule:  32765: from <CNI ENI ip>  lookup 2   <-- WEKA claimed it
    #             1536:  from <a pod ip>    lookup 2
    #   ip route show table 2:  (empty)
    #
    # The per-ENI route table is empty because no kernel device exists for that
    # ENI any more, so every pod the CNI assigns an address from it is
    # blackholed -- while pods that happened to land on the PRIMARY ENI work
    # perfectly. You get one CSI pod that can reach the WEKA API and another,
    # on the same node, that times out against every endpoint. It is also
    # timing-dependent: schedule the pod before the CNI grows a second ENI and
    # everything works, which makes it look intermittent.
    #
    # Capping the CNI at one ENI removes the race entirely: the CNI never
    # attaches a secondary ENI, so there is nothing for WEKA to poach, and
    # every pod address comes from the kernel-managed primary interface.
    #
    # THE TRADE-OFF: pod density. With one ENI the CNI can only hand out that
    # ENI's secondary IPs -- 29 on an m6i.8xlarge (30 IPv4 per ENI, less the
    # node's own). `client_max_pods` must agree; see node-userdata.tf.
    "vpc-cni" = {
      before_compute       = true
      configuration_values = jsonencode({ env = { MAX_ENI = "1" } })
    }
    "kube-proxy" = { before_compute = true }

    # CoreDNS is a Deployment with no nodes to schedule on until compute
    # exists, so it must stay AFTER compute. Marking this before_compute
    # instead gets you an addon stuck DEGRADED on unschedulable pods.
    coredns = {}

    # Not needed for node readiness; after compute is fine.
    "eks-pod-identity-agent" = {}
  }

  eks_managed_node_groups = {
    weka_clients = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.client_instance_type]

      # Fixed size. Every node here is a WEKA client, and a client joining or
      # leaving is a cluster membership change on the WEKA side -- not
      # something to hand to an autoscaler.
      min_size     = var.client_node_count
      max_size     = var.client_node_count
      desired_size = var.client_node_count

      subnet_ids = module.vpc.private_subnets

      # The WekaClient CR and the CSI node plugin both select on this label.
      # If they disagree -- or if this is missing -- the client containers never
      # land and PVCs hang in Pending with no obvious cause.
      labels = {
        "weka.io/supports-clients" = "true"
      }

      # The shared WEKA security group. This is ADDITIVE: the module composes
      # `[node_security_group_id] + vpc_security_group_ids`, so the node group
      # keeps the EKS-managed node SG (kubelet, CNI, control plane traffic) and
      # gains WEKA's ports on top. Being in this group is what makes a node
      # able to talk to the backends at all.
      vpc_security_group_ids = [aws_security_group.weka.id]

      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            # /opt/k8s-weka is the operator's node-agent persistence path, and
            # it is the reason this volume is 200 GB rather than the 20 GB
            # default. Budget roughly:
            #
            #     ~20 GiB per WEKA container on the node
            #   + ~10 GiB per allocated WEKA core
            #
            # so one container with 4 cores is ~60 GiB before you have counted
            # the AL2023 root filesystem, the container images (the
            # weka-in-container image alone is multi-GiB), or the compiled
            # kernel driver.
            #
            # gp3 rather than gp2: the driver build and image pulls are
            # bursty, and gp3's baseline 3000 IOPS / 125 MB/s is not tied to
            # volume size the way gp2's is.
            #
            # This must stay on LOCAL DISK. Never point /opt/k8s-weka at NFS,
            # EFS, or the WEKA filesystem itself -- the WEKA container writes
            # its own state there while being the thing that serves network
            # storage, so network-backing it is a restart deadlock.
            volume_size           = var.client_root_volume_size
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      # The VPC CNI needs this on the node role to manage ENIs and secondary
      # IPs. (If you later move the CNI to a Pod Identity association or IRSA,
      # this can come off the node role -- but the node role is where the
      # default EKS setup expects it.)
      iam_role_additional_policies = {
        AmazonEKS_CNI_Policy = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"

        # SSM, so you can actually get a shell on a node that fails to join.
        # Not a nicety: when the kubelet dies during config validation the node
        # never registers, so `kubectl debug node/...` is not available, and the
        # kubelet's reason for dying is in journald only -- the EC2 serial
        # console stops at early boot. Without this your only diagnostic is
        # guesswork. Earned the hard way; see node-userdata.tf.
        AmazonSSMManagedInstanceCore = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      # Both user-data parts, in order, injected BEFORE nodeadm runs. That
      # ordering is the whole point: the sysctl work and the kernel headers
      # have to be in place before the kubelet starts, and the NodeConfig has
      # to be merged into the kubelet's configuration before it is read. See
      # node-userdata.tf for why none of this can be a DaemonSet.
      cloudinit_pre_nodeadm = [
        {
          content_type = "text/x-shellscript"
          content      = local.weka_node_prep_script
        },
        {
          content_type = "application/node.eks.aws"
          content      = local.weka_nodeadm_config
        },
      ]

      tags = var.tags
    }
  }

  tags = var.tags
}
