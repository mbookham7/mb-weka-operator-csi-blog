output "region" {
  description = "Region both clusters were built in."
  value       = var.region
}

output "vpc_id" {
  description = "The shared VPC."
  value       = module.vpc.vpc_id
}

output "weka_security_group_id" {
  description = "The security group shared by WEKA backends and EKS nodes. Anything that needs to talk to WEKA must be a member."
  value       = aws_security_group.weka.id
}

output "eks_cluster_name" {
  description = "EKS cluster name -- feed this to `aws eks update-kubeconfig`."
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "weka_password_secret_id" {
  description = "Secrets Manager id holding the WEKA cluster admin password. The username is `admin`. Retrieve with: aws secretsmanager get-secret-value --secret-id <this> --query SecretString --output text"
  value       = module.weka.weka_cluster_admin_password_secret_id
}

output "weka_backends_asg_name" {
  description = "Autoscaling group holding the WEKA backends. The backends have no stable IPs, so this is how you find them -- see the `weka_backend_ips_command` output."
  value       = module.weka.asg_name
}

# The WEKA backends live in an autoscaling group and are replaced by the
# module's own healing Lambdas, so their private IPs are not known at plan time
# and Terraform cannot output them directly. This emits the command instead.
output "weka_backend_ips_command" {
  description = "Shell command that prints the current WEKA backend private IPs, one per line."
  value       = <<-EOT
    aws ec2 describe-instances \
      --region ${var.region} \
      --filters "Name=tag:aws:autoscaling:groupName,Values=${module.weka.asg_name}" \
                "Name=instance-state-name,Values=running" \
      --query "Reservations[].Instances[].PrivateIpAddress" \
      --output text | tr '\t' '\n'
  EOT
}

output "weka_filesystem_name" {
  description = "WEKA filesystem the CSI StorageClass provisions into. Confirm it exists with `weka fs` on a backend -- the CSI plugin creates directories, not filesystems."
  value       = var.weka_filesystem_name
}

output "weka_cluster_helper_commands" {
  description = "Helper commands emitted by the WEKA module for interacting with the cluster (status, SSH, password retrieval)."
  value       = module.weka.cluster_helper_commands
}

# ---------------------------------------------------------------------------
# The single source of truth for the hand-applied manifests
# ---------------------------------------------------------------------------
# Several manifest fields MUST agree with Terraform variables, and nothing in
# Kubernetes will tell you when they do not -- you get a Pending pod and a
# message that points at capacity rather than at the mismatch. This output
# states the required value for each, derived from the variables, so there is
# one authoritative place to check against.
#
# `manifests/check-manifests.sh` compares the files to these values and fails
# loudly on drift. Run it before you apply anything.
output "manifest_values" {
  description = "Values the hand-applied manifests must use. Derived from the Terraform variables -- treat this as authoritative and run manifests/check-manifests.sh to verify."
  value = {
    "03-weka-client.yaml : spec.coresNum"       = var.client_weka_cores
    "03-weka-client.yaml : spec.image"          = "quay.io/weka.io/weka-in-container:${var.weka_version}"
    "02-weka-nics-policy.yaml : dataNICsNumber" = var.client_weka_cores
    "02-weka-nics-policy.yaml : spec.image"     = "quay.io/weka.io/weka-in-container:${var.weka_version}"
    "05-storageclass-dir.yaml : filesystemName" = var.weka_filesystem_name
    "_derived: nr_hugepages"                    = local.weka_hugepages
    "_derived: reservedSystemCPUs"              = local.weka_reserved_cpus
    "_derived: kubelet maxPods"                 = var.client_max_pods
  }
}

# THIS OUTPUT MIRRORS README STEP 6 ("Apply the manifests, in order"). THE TWO
# MUST BE CHANGED TOGETHER.
#
# They drifted once already and it was worse than having no runbook at all:
# this output omitted 02-weka-nics-policy.yaml, so anyone who followed what
# Terraform printed -- rather than the README -- walked straight into
# `1 Insufficient weka.io/weka-nics` on a healthy cluster and a healthy node.
# A printed runbook is trusted precisely because it came out of the thing that
# built the infrastructure, which is what makes a wrong one expensive.
#
# If you add, remove or reorder a manifest, edit both places in the same
# commit.
output "next_steps" {
  description = "Ordered follow-up commands, mirroring README step 6. `terraform output -raw next_steps` to read it without escaping."
  value       = <<-EOT

    ============================================================================
     NEXT STEPS
    ============================================================================

     terraform apply returning does NOT mean the WEKA cluster is ready. A Step
     Function is still forming it. Allow 15-25 minutes.

    ----------------------------------------------------------------------------
     1. Wait for the WEKA cluster to finish forming
    ----------------------------------------------------------------------------

       aws stepfunctions list-executions \
         --region ${var.region} \
         --state-machine-arn "$(aws stepfunctions list-state-machines --region ${var.region} \
             --query "stateMachines[?contains(name, '${var.prefix}-${var.cluster_name}')].stateMachineArn | [0]" \
             --output text)" \
         --max-items 1

       Then SSH to any backend (see weka_cluster_helper_commands) and run:

         weka status

       You want "status: OK" and ${var.weka_cluster_size} backends.

       While you are on the backend, confirm the filesystem the StorageClass
       expects actually exists, and that its name matches
       `filesystemName` in manifests/05-storageclass-dir.yaml
       (currently "${var.weka_filesystem_name}"):

         weka fs

    ----------------------------------------------------------------------------
     2. Collect the values the manifests need
    ----------------------------------------------------------------------------

       Backend IPs (you need at least two for the CSI secret):

         terraform output -raw weka_backend_ips_command | bash

       WEKA admin password (username is "admin"):

         aws secretsmanager get-secret-value \
           --region ${var.region} \
           --secret-id "${module.weka.weka_cluster_admin_password_secret_id}" \
           --query SecretString --output text

       A client join token, generated ON a backend over SSH:

         weka cluster join-token generate --access-token-timeout 52w

    ----------------------------------------------------------------------------
     3. Point kubectl at the EKS cluster
    ----------------------------------------------------------------------------

       aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}
       kubectl get nodes -L weka.io/supports-clients

       All ${var.client_node_count} nodes must show supports-clients=true.

       Confirm the user-data actually took effect before going further:

         kubectl get nodes -o json | jq '.items[].status.allocatable["hugepages-2Mi"]'

       Each node should report roughly ${local.weka_hugepages_gib}Gi. If it
       reports 0, the HugePages reservation did not apply -- check
       /var/log/weka-node-prep.log on the node.

    ----------------------------------------------------------------------------
     4. Install the operator and apply the manifests, in order
    ----------------------------------------------------------------------------

       QUAY_USERNAME / QUAY_PASSWORD and WEKA_OPERATOR_VERSION come from
       .env at the REPO ROOT, one level above this directory:

         set -a && source ../.env && set +a

       cd manifests
       ./00-namespace-and-secrets.sh

       cp 01-weka-client-secret.yaml.example 01-weka-client-secret.yaml
       cp 04-csi-api-secret.yaml.example     04-csi-api-secret.yaml
       # edit both: every value is base64. `printf '%s' 'value' | base64`

       Check the manifests against Terraform before applying anything:

         ./check-manifests.sh

       kubectl apply -f 01-weka-client-secret.yaml
       kubectl apply -f 02-weka-nics-policy.yaml     # BEFORE the client -- attaches data-path ENIs
       kubectl apply -f 03-weka-client.yaml          # edit joinIpPorts first
       kubectl apply -f 04-csi-api-secret.yaml
       kubectl apply -f 05-storageclass-dir.yaml
       kubectl apply -f 06-smoke-test.yaml

       # Optional demo (needs 3 client nodes):
       kubectl apply -f 07-rwx-multiwriter.yaml
       ./08-persistence-check.sh
       kubectl apply -f 09-fio-job.yaml              # read its header comment first

    ----------------------------------------------------------------------------
     5. Verify
    ----------------------------------------------------------------------------

       kubectl -n weka-operator-system get wekaclient,pods
       kubectl get pvc weka-smoke-test-pvc
       kubectl logs weka-smoke-test

       A Bound PVC and a pod appending timestamps means the whole path works.

       If you applied the demo, this is the payoff -- three distinct hostnames
       counted out of one shared file:

         kubectl exec deploy/weka-rwx-demo -- sh -c \
           "awk '{print \$2}' /data/shared.log | sort | uniq -c"

    ============================================================================
     COST: ${var.weka_cluster_size} x ${var.weka_instance_type} +
     ${var.client_node_count} x ${var.client_instance_type} + a NAT gateway.
     Destroy this when you are done, and then check the console -- see the
     README teardown section.
    ============================================================================

  EOT
}
