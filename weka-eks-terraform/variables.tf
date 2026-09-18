# ---------------------------------------------------------------------------
# Global
# ---------------------------------------------------------------------------

variable "region" {
  description = "AWS region for both clusters. i3en instances are not available in every region -- check before changing this."
  type        = string
  default     = "eu-west-1"
}

variable "prefix" {
  description = "Prefix applied to every resource name. Also used by the WEKA module to name its Secrets Manager entries and DynamoDB state table."
  type        = string
  default     = "weka"
}

variable "cluster_name" {
  description = "WEKA cluster name. Combined with `prefix` this must be unique per region, because the WEKA module derives Secrets Manager paths from it and Secrets Manager keeps deleted names reserved for up to 30 days."
  type        = string
  default     = "poc"
}

variable "tags" {
  description = "Tags applied to everything this repo creates."
  type        = map(string)
  default = {
    Project   = "weka-eks-demo"
    ManagedBy = "terraform"
  }
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR for the shared VPC. Needs room for EKS pod IPs as well as both clusters -- the VPC CNI hands every pod a real subnet address, so a /16 is not overkill."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "AZs to spread the VPC across. Leave empty to take the first two available in `region`. Note that the WEKA backends only ever land in the FIRST of these -- see weka.tf."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# WEKA backend cluster
# ---------------------------------------------------------------------------

variable "get_weka_io_token" {
  description = "Token from get.weka.io. The backends curl the WEKA release tarball from there on first boot, so without a valid token the instances come up and the cluster never forms."
  type        = string
  sensitive   = true
}

variable "weka_cluster_size" {
  description = "Number of WEKA backend instances. The module enforces a minimum of 6 -- that is the smallest cluster that can survive the default protection level of 2 plus a hot spare."
  type        = number
  default     = 6

  validation {
    condition     = var.weka_cluster_size >= 6
    error_message = "WEKA cloud clusters require at least 6 backends."
  }
}

variable "weka_instance_type" {
  description = "Backend instance type. Must be an NVMe-backed type in the WEKA module's containers_config_map (i3en.* / i8ge.*), because the per-instance drive/compute/frontend container layout is looked up from that map."
  type        = string
  default     = "i3en.6xlarge"
}

variable "weka_version" {
  description = "WEKA release to install on the backends. NOT optional: the module has a lifecycle precondition requiring either this or `install_weka_url` to be non-empty, and because preconditions are evaluated at plan time rather than validate time, leaving it empty fails with 'Please provide either install_weka_url or weka_version' only once you run plan. Must also be a release your get.weka.io token is entitled to -- an unentitled version returns HTTP 403 from get.weka.io and the backends boot, fail to download, and never form a cluster."
  type        = string
  default     = "4.4.5"

  validation {
    condition     = length(var.weka_version) > 0
    error_message = "weka_version must be set -- the WEKA module requires it (see the description). Verify your token can fetch the release you pick: curl the URL https://TOKEN@get.weka.io/dist/v1/install/<ver>/<ver>?provider=aws&region=<region> and check the HTTP status -- 200 means good, 403 means your token is not entitled to that release."
  }
}

variable "weka_data_services_number" {
  description = "WEKA data-services instances (m6i.xlarge each). The module defaults to 2; this repo defaults to 0 because they are not needed to serve CSI volumes and they are pure cost for a demo."
  type        = number
  default     = 0
}

variable "create_weka_alb" {
  description = "Create the WEKA module's ALB for the backend UI. Off by default: this repo joins clients via `joinIpPorts` against backend IPs, so the ALB is an extra ~$20/month for a web UI you can reach over SSH port-forward instead."
  type        = bool
  default     = false
}

variable "allow_ssh_cidrs" {
  description = "CIDRs allowed to SSH to the WEKA backends and EKS nodes on port 22. Empty means no SSH ingress at all. Do not put 0.0.0.0/0 here."
  type        = list(string)
  default     = []
}

variable "key_pair_name" {
  description = "Existing EC2 key pair for the WEKA backends. Leave null and the WEKA module generates one and writes the private key to /tmp/<prefix>-<cluster_name>-private-key.pem on the machine running Terraform."
  type        = string
  default     = null
}

variable "weka_filesystem_name" {
  description = "WEKA filesystem the CSI StorageClass provisions directories inside. Must match `filesystemName` in manifests/05-storageclass-dir.yaml. The module creates one for you when set_default_fs is true, but confirm the actual name with `weka fs` on a backend rather than assuming it."
  type        = string
  default     = "default"
}

# ---------------------------------------------------------------------------
# EKS control plane
# ---------------------------------------------------------------------------

variable "eks_kubernetes_version" {
  description = "EKS control plane version. 1.32 is the floor for the `strict-cpu-reservation` CPU manager policy option used in node-userdata.tf -- if you drop below 1.32 you must also remove that option."
  type        = string
  default     = "1.32"
}

variable "eks_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint. Defaults to the world so that `aws eks update-kubeconfig` works from anywhere; narrow this to your office/VPN range for anything real."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ---------------------------------------------------------------------------
# EKS worker nodes (the WEKA clients)
# ---------------------------------------------------------------------------

variable "client_instance_type" {
  description = "Worker node instance type. Needs enough vCPUs to give WEKA its dedicated cores and still run workloads, and enough ENI capacity for the VPC CNI."
  type        = string
  default     = "m6i.8xlarge"
}

variable "client_node_count" {
  description = "Number of worker nodes. Fixed size (min = max = desired) on purpose: every node in this group is a WEKA client, and WEKA clients are not something you want an autoscaler churning."
  type        = number
  default     = 3
}

variable "client_weka_cores" {
  description = "WEKA cores per client node. Must match `spec.coresNum` in manifests/03-weka-client.yaml -- the HugePages reservation in node-userdata.tf is computed from this number, and a mismatch means the client pod either wastes memory or never starts."
  type        = number
  default     = 4
}

variable "client_root_volume_size" {
  description = "Root EBS volume size in GiB. Sized for /opt/k8s-weka -- see the comment in eks.tf for the arithmetic."
  type        = number
  default     = 200
}

variable "client_hugepages_gib_per_core" {
  description = "GiB of HugePages to reserve per WEKA core. WEKA's published guidance is 1.5 GiB per core. This is the BASE figure only -- see client_hugepages_headroom_mib, because the operator's actual pod request exceeds cores x 1.5 GiB and sizing to exactly this number leaves the client pod unschedulable."
  type        = number
  default     = 1.5
}

variable "client_hugepages_headroom_mib" {
  description = <<-EOT
    Extra HugePages MiB on top of `client_weka_cores * client_hugepages_gib_per_core`.

    DO NOT SET THIS TO ZERO. Measured on a real deployment: with
    `coresNum: 4`, the WekaClient pod the operator generates requests

        hugepages-2Mi: 6256Mi

    while 4 cores x 1.5 GiB is only 6144Mi. Sizing HugePages to exactly the
    documented per-core figure therefore leaves the pod short by 112Mi, and it
    sits in Pending with:

        0/1 nodes are available: 1 Insufficient hugepages-2Mi

    which reads like a capacity problem rather than an off-by-a-rounding-margin
    problem. The operator adds per-container overhead on top of the per-core
    figure, so the safe approach is a fixed cushion rather than trying to
    reproduce its arithmetic exactly.

    HugePages are never reclaimable for normal allocations, so the cushion is
    memory permanently removed from everything else on the node -- 1 GiB out of
    128 GiB on an m6i.8xlarge is a reasonable trade for not having to recycle
    every node when the operator's overhead changes.
  EOT
  type        = number
  default     = 1024
}

variable "client_max_pods" {
  description = <<-EOT
    kubelet `maxPods` for the WEKA client nodes.

    MUST be consistent with the `MAX_ENI` setting on the vpc-cni addon in
    eks.tf. That caps the CNI at the primary ENI so WEKA cannot claim a
    CNI-created ENI for DPDK, which means the CNI can only allocate that one
    ENI's secondary IPs: 29 on an m6i.8xlarge (30 IPv4 per ENI, minus the
    node's own address).

    EKS would otherwise advertise maxPods based on the instance's FULL ENI
    capacity -- 234 on m6i.8xlarge. Leaving it there lets the scheduler admit
    far more pods than the CNI can address, and the surplus sit in
    ContainerCreating with no IP. Lower is safe; too high fails confusingly.

    If you change `client_instance_type`, look up "IP addresses per network
    interface per instance type" for the new type and set this to
    (IPv4 per ENI - 1).
  EOT
  type        = number
  default     = 29
}

variable "system_cpu_sibling_index" {
  description = <<-EOT
    The HyperThreading sibling of logical CPU 0, reserved for the system alongside CPU 0.

    On m6i.8xlarge (32 vCPUs, 16 physical cores) Linux enumerates siblings as
    n and n+16, so CPU 0's sibling is 16. This mapping is NOT stable across
    instance types or families. Verify on a running node of the exact type you
    are using:

      cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list

    Reserving only CPU 0 and not its sibling leaves the sibling in the shared
    pool, where a pinned WEKA core can be scheduled onto the same physical core
    as the kubelet and system daemons -- which is precisely the interference
    the static CPU manager policy exists to prevent.
  EOT
  type        = number
  default     = 16
}
