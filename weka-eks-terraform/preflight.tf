# ---------------------------------------------------------------------------
# Plan-time guards: values that are only correct for one instance type
# ---------------------------------------------------------------------------
# This repo checks drift between Terraform and Kubernetes rigorously
# (manifests/check-manifests.sh) and, until this file existed, checked drift
# WITHIN Terraform not at all. Three variables are silently correct for
# `m6i.8xlarge` and for nothing else:
#
#   client_max_pods           29   = the primary ENI's IPv4 capacity, less the
#                                    node's own address, because eks.tf caps
#                                    vpc-cni at MAX_ENI=1
#   system_cpu_sibling_index  16   = the HyperThreading sibling of CPU 0
#   client_weka_cores          4   = needs cores+1 ENIs once ensure-nics runs
#
# Change `client_instance_type` to something cheaper and every one of those
# stays at its old value. Nothing complains. You find out later, as a Pending
# pod whose message points at capacity rather than at the mismatch -- which is
# the exact failure class the rest of this repo works so hard to prevent.
#
# WHY THIS ASKS AWS RATHER THAN CARRYING A TABLE
#
# The obvious implementation is a lookup map of instance type to
# {ipv4_per_eni, sibling_index}. It would also be a table of numbers typed
# from memory into a repo whose entire credibility rests on its numbers being
# observed rather than assumed -- and it would silently not cover whatever
# instance type you actually picked.
#
# `aws_ec2_instance_type` is authoritative, self-maintaining, and works for
# every instance type including ones nobody thought about. It needs
# ec2:DescribeInstanceTypes and is read at PLAN time, so these guards fail
# before anything is created. `terraform validate` does not read data sources,
# which is why CI can run validate with no credentials and still be useful.

data "aws_ec2_instance_type" "client" {
  instance_type = var.client_instance_type
}

locals {
  # --- What the CNI can actually address ---------------------------------
  #
  # eks.tf sets MAX_ENI=1 on vpc-cni so WEKA cannot poach a CNI-created ENI
  # for DPDK. That leaves the primary ENI as the only source of pod
  # addresses, and one of its addresses is the node's own.
  client_addressable_pod_ips = data.aws_ec2_instance_type.client.maximum_ipv4_addresses_per_interface - 1

  # --- The HyperThreading sibling of CPU 0 -------------------------------
  #
  # Linux enumerates vCPUs on AWS with the physical cores first and their
  # siblings second, so the sibling of CPU 0 is at index `default_cores`.
  # On m6i.8xlarge that is 16, which matches the value observed on a running
  # node in the README:
  #
  #   /sys/devices/system/cpu/cpu0/topology/thread_siblings_list = 0,16
  #
  # Only meaningful when there are two threads per core. See the precondition.
  client_expected_sibling_index = data.aws_ec2_instance_type.client.default_cores

  # --- ENIs the ensure-nics WekaPolicy needs -----------------------------
  #
  # One data-path ENI per WEKA core, on top of the primary. 02-weka-nics-
  # policy.yaml warns about this in prose; this makes it fail at plan time.
  client_required_enis = var.client_weka_cores + 1
}

# `terraform_data` purely as somewhere to hang preconditions. They cannot go
# on a variable: variable validation could not reference another variable
# until Terraform 1.9, and versions.tf declares a floor of 1.5.7. A `check`
# block would only warn, and a warning about a node that will not schedule is
# not worth the paper. This resource creates nothing.
resource "terraform_data" "instance_type_guard" {
  input = {
    instance_type    = var.client_instance_type
    vcpus            = data.aws_ec2_instance_type.client.default_vcpus
    cores            = data.aws_ec2_instance_type.client.default_cores
    threads_per_core = data.aws_ec2_instance_type.client.default_threads_per_core
    max_enis         = data.aws_ec2_instance_type.client.maximum_network_interfaces
    ipv4_per_eni     = data.aws_ec2_instance_type.client.maximum_ipv4_addresses_per_interface
    addressable_pods = local.client_addressable_pod_ips
    expected_sibling = local.client_expected_sibling_index
    required_enis    = local.client_required_enis
  }

  # --- maxPods must not exceed what the CNI can address ------------------
  #
  # `<=` not `==`: lowering it deliberately is safe and sometimes sensible.
  # Only exceeding it is the bug, and the symptom is pods admitted by the
  # scheduler that then sit in ContainerCreating with no IP.
  lifecycle {
    precondition {
      condition     = var.client_max_pods <= local.client_addressable_pod_ips
      error_message = "client_max_pods (${var.client_max_pods}) exceeds what the VPC CNI can address on ${var.client_instance_type}. With MAX_ENI=1 in eks.tf the CNI has only the primary ENI, which carries ${data.aws_ec2_instance_type.client.maximum_ipv4_addresses_per_interface} IPv4 addresses, one of which is the node's own -- so the ceiling is ${local.client_addressable_pod_ips}. Set client_max_pods to ${local.client_addressable_pod_ips} or lower. Leaving it too high does not fail the apply: the scheduler admits pods the CNI cannot give an address to, and they sit in ContainerCreating."
    }

    # --- the sibling index must be a real sibling ------------------------
    precondition {
      condition     = data.aws_ec2_instance_type.client.default_threads_per_core != 2 || var.system_cpu_sibling_index == local.client_expected_sibling_index
      error_message = "system_cpu_sibling_index is ${var.system_cpu_sibling_index}, but on ${var.client_instance_type} the HyperThreading sibling of CPU 0 is ${local.client_expected_sibling_index} (${data.aws_ec2_instance_type.client.default_cores} physical cores, ${data.aws_ec2_instance_type.client.default_threads_per_core} threads each). Reserving the wrong index leaves a WEKA core sharing a physical core -- and its L1 and L2 -- with the kubelet, which is the exact interference reservedSystemCPUs exists to prevent. Verify on a running node: cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list"
    }

    # --- ...and HyperThreading has to exist at all -----------------------
    #
    # Graviton, and x86 instances with HT disabled, report 1 thread per core.
    # There is no sibling to reserve, so "0,N" reserves CPU 0 plus an
    # unrelated core -- silently wasting it and not isolating anything.
    precondition {
      condition     = data.aws_ec2_instance_type.client.default_threads_per_core == 2 || var.system_cpu_sibling_index == 0
      error_message = "${var.client_instance_type} reports ${data.aws_ec2_instance_type.client.default_threads_per_core} thread(s) per core, so CPU 0 has no HyperThreading sibling and system_cpu_sibling_index (${var.system_cpu_sibling_index}) reserves an unrelated CPU -- wasting it without isolating anything. Set system_cpu_sibling_index = 0 to reserve CPU 0 alone -- node-userdata.tf handles that case and emits reservedSystemCPUs = \"0\"."
    }

    # --- enough ENI slots for the DPDK data path -------------------------
    precondition {
      condition     = local.client_required_enis <= data.aws_ec2_instance_type.client.maximum_network_interfaces
      error_message = "client_weka_cores (${var.client_weka_cores}) needs ${local.client_required_enis} ENIs on each node -- one data-path ENI per WEKA core plus the primary -- but ${var.client_instance_type} supports only ${data.aws_ec2_instance_type.client.maximum_network_interfaces}. The ensure-nics WekaPolicy will leave interfaces unattached and the client pod stays Pending on '1 Insufficient weka.io/weka-nics', which reads identically to having forgotten to apply 02-weka-nics-policy.yaml."
    }

    # --- the node has to have CPUs left over -----------------------------
    #
    # WEKA's cores are pinned and poll at 100%, and CPU 0 plus its sibling are
    # reserved. Anything left is what the rest of the cluster runs on.
    precondition {
      condition     = var.client_weka_cores + 2 < data.aws_ec2_instance_type.client.default_vcpus
      error_message = "client_weka_cores (${var.client_weka_cores}) plus the 2 reserved system vCPUs leaves nothing for workloads on ${var.client_instance_type} (${data.aws_ec2_instance_type.client.default_vcpus} vCPUs). WEKA's cores are pinned and spin at 100%, so they are not shared -- pick a larger instance type or fewer cores."
    }
  }
}

# What AWS says about the chosen instance type. Handy when a precondition
# above fires and you want the numbers behind it, and worth a look before
# changing client_instance_type.
output "instance_type_facts" {
  description = "Facts about client_instance_type, read from the EC2 API, that the node sizing variables are derived from."
  value       = terraform_data.instance_type_guard.input
}
