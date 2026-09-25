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
# ---------------------------------------------------------------------------
# PAYLOAD VS COMMENTARY -- READ THIS BEFORE ADDING A COMMENT BELOW
# ---------------------------------------------------------------------------
# The two heredocs in this file are not source code. They are STRINGS that
# become the launch template's user data, and every byte inside them -- comments
# included -- is part of that string.
#
# So a comment written INSIDE a heredoc is not documentation. It is payload:
#
#   edit a comment inside <<-SCRIPT or <<-NODECONFIG
#     -> the rendered user data changes
#       -> Terraform creates a new launch template version
#         -> the module moves the LT default version, because
#            `update_launch_template_default_version` defaults to true
#           -> aws_eks_node_group.launch_template.version changes
#             -> EKS ROLLS EVERY NODE IN THE GROUP
#
# Every node in this group is a WEKA client, there is no PodDisruptionBudget,
# and there is no drain handling for the client containers. A typo fix should
# not be able to cycle the storage clients of a live cluster, and before this
# split it could: one 37-line comment added to the sysctl block grew the
# rendered script from 3302 to 5332 bytes.
#
# THE RULE:
#
#   * Reasoning, arithmetic, provenance, war stories  -> Terraform `#` comments
#     out here, where they cost nothing and change nothing.
#
#   * Inside a heredoc -> only what someone SSH'd into a node needs in order
#     not to break it, kept short, plus a pointer back to this file.
#
# Interpolated values (${...}) are a different matter: those SHOULD churn the
# user data, because a changed core count or maxPods is a real configuration
# change that the nodes genuinely need to be replaced to pick up.
#
# ---------------------------------------------------------------------------
# Changing a real value here: what actually happens
# ---------------------------------------------------------------------------
# These are launch-template properties, so a running node never re-reads them
# -- the script executes once, at first boot. But you do NOT have to trigger
# the replacement yourself: because the module updates the LT default version
# and the node group references it, `terraform apply` hands EKS a new LT
# version and EKS performs a rolling node-group update on its own.
#
# Plan accordingly. `terraform plan` showing a launch-template change means
# every node in the group is about to be replaced, one at a time, with no
# disruption budget protecting the WEKA clients on them. If you want that to
# be an explicit decision rather than a side effect, set
# `update_launch_template_default_version = false` on the node group in eks.tf
# and move the version forward deliberately.

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
  # The script itself is deliberately terse. Everything it does and why is
  # here instead, for the reason given under "Payload vs commentary" above.
  #
  # WHY /etc/sysctl.d/ RATHER THAN `sysctl -w`
  #
  # The settings have to survive a reboot. A node that loses its hugepages on
  # reboot comes back into the cluster looking perfectly healthy and then
  # cannot host a WEKA client, which is a miserable thing to debug -- the node
  # is Ready, nothing is in a crash loop, and the only evidence is a Pending
  # pod complaining about a resource the node has the memory for.
  #
  # WHY THE PORT RESERVATIONS EXIST
  #
  # Without them, any process that opens an outbound socket early in boot --
  # the CNI, kube-proxy, an agent, anything -- can be handed a port WEKA is
  # about to want. WEKA then fails to bind, and the failure surfaces much
  # later as a client that will not start, with nothing in any log pointing at
  # a port conflict.
  #
  # These are reservations, not firewall rules: the kernel simply will not
  # auto-assign from these ranges. WEKA can still bind them explicitly.
  #
  # THE ARITHMETIC, and why the range is not narrowed for WEKA 5.1
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
  # move to 5.1 does not require a change here, and the range is left as it is
  # rather than narrowed to 46000-46259.
  #
  # Left deliberately wide because the cost of over-reserving is small and the
  # cost of under-reserving is the bug the block exists to prevent. The default
  # ephemeral range on AL2023 is 32768-60999, i.e. 28232 ports; the two
  # reservations remove 4602 of them, about 16%. Nothing on these nodes opens
  # outbound sockets at anything like that scale. Whereas narrowing to exactly
  # the block the client currently wants means that raising `coresNum`,
  # changing `basePort`, or an operator release that allocates differently
  # reintroduces the race -- and the race does not fail loudly.
  #
  # If you do narrow it, narrow it here and change basePort in the manifest in
  # the same commit.
  #
  # The 35000-37600 block (2601 ports) predates this repo's notes and is NOT
  # explained by the client portRange above. It is carried forward unchanged
  # because it is harmless and because nothing here establishes what binds it
  # -- do not remove it on the assumption that it is dead, and if you need to
  # justify it in a security review, get the answer from WEKA rather than from
  # this comment.
  #
  # WHY THE KERNEL HEADER INSTALL IS ALLOWED TO FAIL
  #
  # The WEKA client builds a kernel module (wekafsio / wekafsgw). The build
  # needs headers for the EXACT running kernel -- not "the latest available",
  # which is what a bare `dnf install kernel-devel` gives you. On AL2023 the
  # repo is versioned, so if the AMI's kernel is older than what the mirror
  # currently serves, the pinned version genuinely may not resolve; that is why
  # the step is tolerant of failure rather than fatal.
  #
  # If it does fail the client falls back to fetching a prebuilt driver from
  # driversDistService (https://drivers.weka.io), which is why that field is
  # set in 03-weka-client.yaml. Having both paths available is the point.
  #
  # WHY /opt/k8s-weka MUST BE LOCAL DISK
  #
  # The operator's node agent keeps per-container state there: the compiled
  # driver, the WEKA container's data directory, and its cores' state.
  #
  # Not NFS, not EFS, not a network-attached volume of any kind -- including
  # the WEKA filesystem itself. The WEKA container writes there while it is
  # the thing providing network storage, so backing it with network storage is
  # a circular dependency that deadlocks on restart. See eks.tf for how the
  # root volume is sized for it.
  weka_node_prep_script = <<-SCRIPT
    #!/usr/bin/env bash
    # Rendered by Terraform from weka-eks-terraform/node-userdata.tf.
    # The reasoning for every step below lives in that file, on purpose.
    set -euo pipefail
    exec > >(tee /var/log/weka-node-prep.log) 2>&1

    echo "=== WEKA node preparation starting at $(date -Is) ==="

    # sysctl.d rather than `sysctl -w`: these have to survive a reboot.
    cat > /etc/sysctl.d/90-weka.conf <<'SYSCTL'
    # Managed by Terraform (weka-eks-terraform/node-userdata.tf).
    # Editing this file on the node works until the node is replaced, and then
    # silently stops working. Change it in Terraform.

    # WEKA DPDK data path: ${local.weka_hugepages_gib} GiB across ${local.weka_hugepages} x 2 MiB pages
    # (${var.client_weka_cores} WEKA cores x ${var.client_hugepages_gib_per_core} GiB/core, plus headroom)
    vm.nr_hugepages = ${local.weka_hugepages}

    # Keep the kernel's ephemeral port allocator off the ranges WEKA binds.
    # Removing either range reintroduces a bind race whose only symptom is a
    # client that will not start, with no log naming a port conflict.
    # Arithmetic and provenance: node-userdata.tf.
    net.ipv4.ip_local_reserved_ports = 35000-37600,45000-47000
    SYSCTL

    sysctl --system

    # Fail loudly here rather than letting the node join and break a client
    # pod later.
    allocated=$(cat /proc/sys/vm/nr_hugepages)
    echo "HugePages requested: ${local.weka_hugepages}, allocated: $allocated"
    if [ "$allocated" -lt "${local.weka_hugepages}" ]; then
      echo "WARNING: kernel allocated fewer hugepages than requested." >&2
      echo "WARNING: the WekaClient pod will not schedule on this node." >&2
    fi

    # Headers for the EXACT running kernel, for the wekafsio/wekafsgw build.
    # Allowed to fail: the client falls back to driversDistService.
    dnf install -y --allowerasing \
      "kernel-devel-$(uname -r)" \
      "kernel-headers-$(uname -r)" \
      || echo "WARNING: no headers for $(uname -r); relying on driversDistService for a prebuilt driver" >&2

    # Operator node-agent state. MUST stay on local disk -- never NFS, EFS or
    # wekafs itself. See node-userdata.tf.
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
  #
  # As with Part 1, the YAML below is payload, so the reasoning for each field
  # is here rather than inline.
  #
  # cpuManagerPolicy: static
  #
  # Pins containers that request whole CPUs to exclusive cores. WEKA's cores
  # spin at 100% by design -- they poll their NIC queues rather than taking
  # interrupts -- so leaving them on the shared CFS pool means they fight the
  # kubelet, the CNI and every other pod for runtime, and the cores they are
  # supposed to own get migrated between physical CPUs. Latency becomes
  # unpredictable.
  #
  # Changing this value later requires deleting
  # /var/lib/kubelet/cpu_manager_state on the node; the kubelet will not start
  # if the persisted policy disagrees. In practice: recycle the nodes.
  #
  # maxPods
  #
  # Must match the CNI's addressable capacity, not the instance's ENI capacity.
  # eks.tf caps vpc-cni at MAX_ENI=1 so WEKA cannot poach a CNI ENI for DPDK;
  # that leaves only the primary ENI's secondary IPs available for pods.
  # nodeadm would otherwise compute this from the full ENI limit (234 on
  # m6i.8xlarge) and the scheduler would admit pods the CNI cannot give an
  # address to. See client_max_pods in variables.tf.
  #
  # reservedSystemCPUs
  #
  # CPU 0 and its HyperThreading sibling, kept for the kubelet, container
  # runtime and system daemons. Everything else becomes assignable to pinned
  # containers.
  #
  # THE TWO EMPTY STRINGS ARE LOAD-BEARING. DO NOT DELETE THEM.
  #
  # EKS's nodeadm unconditionally sets cgroup-based reservation in the kubelet
  # config it generates (amazon-eks-ami, nodeadm internal/kubelet/config.go,
  # withDefaultReservedResources -- whose comment is literally "Override the
  # kubelet config with reserved cgroup values on behalf of the user"):
  #
  #     systemReservedCgroup = "/system"
  #     kubeReservedCgroup   = "/runtime"
  #
  # The kubelet REFUSES to start when either of those is set together with
  # reservedSystemCPUs. From Kubernetes 1.32
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
  # The failure is brutal to diagnose: config validation happens before the
  # kubelet does anything, so it exits immediately, the node NEVER REGISTERS,
  # `kubectl get nodes` stays empty, and the managed node group sits in
  # CREATING for ~20 minutes with `health.issues: []` before finally reporting
  # NodeCreationFailure. Nothing in the EC2 serial console mentions it either
  # -- the kubelet's complaint only goes to journald, which you cannot read
  # without shelling in.
  #
  # nodeadm writes its own config to /etc/kubernetes/kubelet/config.json and
  # writes THIS block to /etc/kubernetes/kubelet/config.json.d/40-nodeadm.conf
  # -- a drop-in, which the kubelet merges on top. Explicitly setting these to
  # empty overrides nodeadm's values and satisfies the validation.
  #
  # featureGates
  #
  # CPUManagerPolicyOptions is required to pass any cpuManagerPolicyOptions at
  # all. strict-cpu-reservation is still an alpha option, so
  # CPUManagerPolicyAlphaOptions is needed on top of the beta one.
  #
  # cpuManagerPolicyOptions: strict-cpu-reservation
  #
  # Without it, reservedSystemCPUs is only honoured as a floor for the
  # *exclusive* pool: burstable and best-effort pods are still free to run on
  # CPU 0 and its sibling, which is exactly the noise we are reserving them to
  # avoid. Setting it strictly excludes the reserved set from the shared pool
  # too.
  #
  # KUBERNETES 1.32+ ONLY. On 1.31 and earlier the option does not exist and
  # the kubelet refuses to start with "unsupported CPU Manager policy option".
  # If you pin eks_kubernetes_version below 1.32, delete the whole
  # cpuManagerPolicyOptions block.
  weka_nodeadm_config = <<-NODECONFIG
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      kubelet:
        config:
          # Every field here is explained in node-userdata.tf, not inline.
          cpuManagerPolicy: static
          maxPods: ${var.client_max_pods}
          reservedSystemCPUs: "${local.weka_reserved_cpus}"

          # LOAD-BEARING. Removing these two stops the kubelet starting, and
          # the node then never registers at all. See node-userdata.tf.
          systemReservedCgroup: ""
          kubeReservedCgroup: ""

          featureGates:
            CPUManagerPolicyOptions: true
            CPUManagerPolicyAlphaOptions: true

          cpuManagerPolicyOptions:
            # Kubernetes 1.32+ only.
            strict-cpu-reservation: "true"
  NODECONFIG
}
