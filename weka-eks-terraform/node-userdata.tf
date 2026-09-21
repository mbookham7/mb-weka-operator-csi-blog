# ---------------------------------------------------------------------------
# Why any of this is in user data
# ---------------------------------------------------------------------------
# Everything in this file configures the node BEFORE the kubelet starts, and
# none of it can be done afterwards from a manifest. That is the entire reason
# it lives here rather than in a privileged DaemonSet.
#
#   HugePages          A DaemonSet can write vm.nr_hugepages, but the kernel can
#                      only satisfy a large hugepage request while physical
#                      memory is still unfragmented -- i.e. at boot. Ask an hour
#                      into a node's life and you get a partial allocation, or
#                      none. Worse, the kubelet only reports
#                      `hugepages-2Mi` as an allocatable resource if the pages
#                      exist when it starts its first node status update. Set
#                      them later and the WekaClient pod stays Pending on a
#                      resource the node genuinely has.
#
#   CPU manager        `cpuManagerPolicy` and `reservedSystemCPUs` are kubelet
#                      configuration, read once at kubelet startup. Changing the
#                      policy also requires deleting
#                      /var/lib/kubelet/cpu_manager_state, because the kubelet
#                      refuses to start when the persisted policy on disk
#                      disagrees with its configuration. Not something a pod can
#                      do to the kubelet that is running it.
#
#   Kernel headers     The WEKA driver is compiled against the running kernel.
#                      Installing headers is ordinary package work, but doing it
#                      before the kubelet starts means the driver build cannot
#                      race the client pod that needs it.
#
# The practical consequence: these are launch-template properties. Changing any
# value in this file produces a new launch template version, and the existing
# nodes do NOT pick it up. You have to recycle every node in the group --
# `terraform apply` followed by an instance refresh, or just scale the group to
# zero and back. Budget for that before you tune the core count.

locals {
  # --- HugePages sizing ---------------------------------------------------
  #
  # WEKA's DPDK data path allocates its packet buffers, ring buffers and
  # per-core state from hugepages, and WEKA's guidance is ~1.5 GiB per
  # allocated core. AL2023 on x86_64 uses a 2 MiB default hugepage size:
  #
  #     base MiB     = cores x 1.5 GiB x 1024        = 4 x 1536  = 6144 MiB
  #     total MiB    = base + headroom               = 6144 + 1024 = 7168 MiB
  #     nr_hugepages = total MiB / 2 MiB per page     = 7168 / 2  = 3584
  #
  # THE HEADROOM IS NOT PADDING -- IT IS REQUIRED. The pod the operator
  # generates for `coresNum: 4` requests hugepages-2Mi: 6256Mi, which is
  # 112Mi MORE than 4 x 1.5 GiB. Size to the documented per-core figure alone
  # and the client pod never schedules:
  #
  #     0/1 nodes are available: 1 Insufficient hugepages-2Mi
  #
  # See client_hugepages_headroom_mib in variables.tf for the full story.
  #
  # Computed rather than hard-coded so changing client_weka_cores cannot leave
  # a stale page count behind. This and `spec.coresNum` in the WekaClient
  # manifest are two halves of one decision: too few pages and the pod is
  # unschedulable; too many and you have permanently removed memory from
  # everything else on the node, since hugepages are never reclaimed for
  # normal allocations.
  weka_hugepages_base_mib = var.client_weka_cores * var.client_hugepages_gib_per_core * 1024
  weka_hugepages_mib      = local.weka_hugepages_base_mib + var.client_hugepages_headroom_mib
  weka_hugepages_gib      = local.weka_hugepages_mib / 1024
  weka_hugepages          = ceil(local.weka_hugepages_mib / 2)

  # --- Reserved system CPUs -----------------------------------------------
  #
  # CPU 0 plus its HyperThreading sibling. Both halves of a physical core have
  # to be reserved together, or the static CPU manager will hand a WEKA core
  # one sibling while the kubelet and system daemons keep the other -- sharing
  # execution units, L1 and L2 with the exact workload we are trying to
  # isolate. See the `system_cpu_sibling_index` variable for how to verify the
  # index on your instance type.
  weka_reserved_cpus = "0,${var.system_cpu_sibling_index}"

  # -------------------------------------------------------------------------
  # Part 1: node preparation shell script
  # -------------------------------------------------------------------------
  weka_node_prep_script = <<-SCRIPT
    #!/usr/bin/env bash
    set -euo pipefail
    exec > >(tee /var/log/weka-node-prep.log) 2>&1

    echo "=== WEKA node preparation starting at $(date -Is) ==="

    # --- HugePages and reserved ports -----------------------------------
    #
    # Written to /etc/sysctl.d/ rather than applied with a bare `sysctl -w` so
    # the setting survives a reboot. A node that loses its hugepages on reboot
    # comes back into the cluster looking healthy and then cannot host a WEKA
    # client, which is a miserable thing to debug.
    cat > /etc/sysctl.d/90-weka.conf <<'SYSCTL'
    # WEKA DPDK data path: ${local.weka_hugepages_gib} GiB across ${local.weka_hugepages} x 2 MiB pages
    # (${var.client_weka_cores} WEKA cores x ${var.client_hugepages_gib_per_core} GiB/core)
    vm.nr_hugepages = ${local.weka_hugepages}

    # Keep the kernel's ephemeral port allocator away from the ranges WEKA
    # binds. Without this, any process that opens an outbound socket early in
    # boot -- the CNI, kube-proxy, an agent, anything -- can be handed a port
    # WEKA is about to want. WEKA then fails to bind, and the failure surfaces
    # much later as a client that will not start, with nothing in the logs
    # pointing at a port conflict.
    #
    # These are reservations, not firewall rules: the kernel simply will not
    # auto-assign from these ranges. WEKA can still bind them explicitly.
    #
    # THE ARITHMETIC, and why this is not being narrowed for WEKA 5.1
    #
    # The client allocates a contiguous block of ports from `portRange.basePort`
    # in manifests/03-weka-client.yaml, which is 46000. How many ports it wants
    # depends on the operator/release combination:
    #
    #   before Operator 1.10 + WEKA 5.1.0   500 ports   46000-46499
    #   Operator 1.10 + WEKA 5.1.0 onward   260 ports   46000-46259
    #
    # 45000-47000 is 2001 ports. It contains both cases with room either side --
    # 1000 ports below basePort and 501 above even the 500-port case -- so the
    # move to 5.1 does not require a change here, and the range is left as it
    # is rather than narrowed to 46000-46259.
    #
    # Left deliberately wide because the cost of over-reserving is small and
    # the cost of under-reserving is the bug this whole block exists to prevent.
    # The default ephemeral range on AL2023 is 32768-60999, i.e. 28232 ports;
    # the two reservations below remove 4602 of them, about 16%. Nothing on
    # these nodes opens outbound sockets at anything like that scale. Whereas
    # narrowing to exactly the block the client currently wants means that
    # raising `coresNum`, changing `basePort`, or an operator release that
    # allocates differently reintroduces the race -- and the race does not fail
    # loudly. WEKA fails to bind, and you find out much later as a client that
    # will not start, with nothing in any log pointing at a port conflict.
    #
    # If you do narrow it, narrow it in Terraform and change basePort in the
    # manifest in the same commit, and remember that user data only runs at
    # FIRST BOOT: existing nodes keep the old sysctl until the group is
    # recycled.
    #
    # The 35000-37600 block (2601 ports) predates this repo's notes and is NOT
    # explained by the client portRange above. It is carried forward unchanged
    # because it is harmless and because nothing here establishes what binds
    # it -- do not remove it on the assumption that it is dead, and if you need
    # to justify it in a security review, get the answer from WEKA rather than
    # from this comment.
    net.ipv4.ip_local_reserved_ports = 35000-37600,45000-47000
    SYSCTL

    sysctl --system

    # Fail fast and loudly if the kernel could not satisfy the request, rather
    # than letting the node join and break a client pod later.
    allocated=$(cat /proc/sys/vm/nr_hugepages)
    echo "HugePages requested: ${local.weka_hugepages}, allocated: $allocated"
    if [ "$allocated" -lt "${local.weka_hugepages}" ]; then
      echo "WARNING: kernel allocated fewer hugepages than requested." >&2
      echo "WARNING: the WekaClient pod will not schedule on this node." >&2
    fi

    # --- Kernel headers --------------------------------------------------
    #
    # The WEKA client builds a kernel module (wekafsio / wekafsgw). The build
    # needs headers for the EXACT running kernel -- not "the latest available",
    # which is what a bare `dnf install kernel-devel` gives you. On AL2023 the
    # repo is versioned, so if the AMI's kernel is older than what the mirror
    # currently serves, the pinned version genuinely may not resolve; that is
    # why this is tolerant of failure rather than fatal.
    #
    # If this step fails the client falls back to fetching a prebuilt driver
    # from driversDistService (https://drivers.weka.io), which is why that field
    # is set in 03-weka-client.yaml. Having both paths available is the point.
    dnf install -y --allowerasing \
      "kernel-devel-$(uname -r)" \
      "kernel-headers-$(uname -r)" \
      || echo "WARNING: no headers for $(uname -r); relying on driversDistService for a prebuilt driver" >&2

    # --- Persistence directory -------------------------------------------
    #
    # The operator's node agent keeps per-container state here: the compiled
    # driver, the WEKA container's data directory, and its cores' state.
    #
    # This MUST be local disk. Not NFS, not EFS, not a network-attached volume
    # of any kind -- including the WEKA filesystem itself. The WEKA container
    # writes here while it is the thing providing network storage, so backing
    # it with network storage is a circular dependency that deadlocks on
    # restart. See eks.tf for how the root volume is sized for it.
    mkdir -p /opt/k8s-weka
    chmod 755 /opt/k8s-weka

    echo "=== WEKA node preparation complete at $(date -Is) ==="
  SCRIPT

  # -------------------------------------------------------------------------
  # Part 2: nodeadm NodeConfig
  # -------------------------------------------------------------------------
  # AL2023 nodes are configured by nodeadm, which reads this YAML out of the
  # MIME-multipart user data and merges spec.kubelet.config into the
  # KubeletConfiguration it writes before starting the kubelet.
  weka_nodeadm_config = <<-NODECONFIG
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      kubelet:
        config:
          # Pin containers that request whole CPUs to exclusive cores. WEKA's
          # cores spin at 100% by design -- they poll their NIC queues rather
          # than taking interrupts -- so leaving them on the shared CFS pool
          # means they fight the kubelet, the CNI and every other pod for
          # runtime, and the cores they are supposed to own get migrated
          # between physical CPUs. Latency becomes unpredictable.
          #
          # Changing this value later requires deleting
          # /var/lib/kubelet/cpu_manager_state on the node; the kubelet will
          # not start if the persisted policy disagrees. In practice: recycle
          # the nodes.
          cpuManagerPolicy: static

          # Must match the CNI's addressable capacity, not the instance's ENI
          # capacity. eks.tf caps vpc-cni at MAX_ENI=1 so WEKA cannot poach a
          # CNI ENI for DPDK; that leaves only the primary ENI's secondary IPs
          # available for pods. nodeadm would otherwise compute this from the
          # full ENI limit (234 on m6i.8xlarge) and the scheduler would admit
          # pods the CNI cannot give an address to.
          maxPods: ${var.client_max_pods}

          # CPU 0 and its HyperThreading sibling, kept for the kubelet,
          # container runtime and system daemons. Everything else becomes
          # assignable to pinned containers.
          reservedSystemCPUs: "${local.weka_reserved_cpus}"

          # ---------------------------------------------------------------
          # THESE TWO EMPTY STRINGS ARE LOAD-BEARING. DO NOT DELETE THEM.
          # ---------------------------------------------------------------
          # EKS's nodeadm unconditionally sets cgroup-based reservation in the
          # kubelet config it generates (amazon-eks-ami, nodeadm
          # internal/kubelet/config.go, withDefaultReservedResources -- whose
          # comment is literally "Override the kubelet config with reserved
          # cgroup values on behalf of the user"):
          #
          #     systemReservedCgroup = "/system"
          #     kubeReservedCgroup   = "/runtime"
          #
          # The kubelet REFUSES to start when either of those is set together
          # with reservedSystemCPUs. From Kubernetes 1.32
          # pkg/kubelet/apis/config/validation/validation.go:
          #
          #     if kc.ReservedSystemCPUs != "" {
          #       // --reserved-cpus does not support --system-reserved-cgroup
          #       // or --kube-reserved-cgroup
          #       if kc.SystemReservedCgroup != "" || kc.KubeReservedCgroup != "" {
          #         ... "can't use reservedSystemCPUs (--reserved-cpus) with
          #              systemReservedCgroup (--system-reserved-cgroup) or
          #              kubeReservedCgroup (--kube-reserved-cgroup)"
          #
          # The failure is brutal to diagnose: config validation happens before
          # the kubelet does anything, so it exits immediately, the node NEVER
          # REGISTERS, `kubectl get nodes` stays empty, and the managed node
          # group sits in CREATING for ~20 minutes with `health.issues: []`
          # before finally reporting NodeCreationFailure. Nothing in the EC2
          # serial console mentions it either -- the kubelet's complaint only
          # goes to journald, which you cannot read without shelling in.
          #
          # nodeadm writes its own config to
          # /etc/kubernetes/kubelet/config.json and writes THIS block to
          # /etc/kubernetes/kubelet/config.json.d/40-nodeadm.conf -- a drop-in,
          # which the kubelet merges on top. Explicitly setting these to empty
          # overrides nodeadm's values and satisfies the validation.
          systemReservedCgroup: ""
          kubeReservedCgroup: ""

          featureGates:
            # Required to pass any cpuManagerPolicyOptions at all.
            CPUManagerPolicyOptions: true
            # strict-cpu-reservation is still an alpha option, so the alpha
            # gate is needed on top of the beta one.
            CPUManagerPolicyAlphaOptions: true

          cpuManagerPolicyOptions:
            # Without this, reservedSystemCPUs is only honoured as a floor for
            # the *exclusive* pool: burstable and best-effort pods are still
            # free to run on CPUs 0 and ${var.system_cpu_sibling_index}, which
            # is exactly the noise we are reserving them to avoid. Setting it
            # strictly excludes the reserved set from the shared pool too.
            #
            # Kubernetes 1.32+ ONLY. On 1.31 and earlier the option does not
            # exist and the kubelet refuses to start with
            # "unsupported CPU Manager policy option". If you pin
            # eks_kubernetes_version below 1.32, delete this whole
            # cpuManagerPolicyOptions block.
            strict-cpu-reservation: "true"
  NODECONFIG
}
