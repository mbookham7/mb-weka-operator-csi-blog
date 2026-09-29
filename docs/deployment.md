# Deploying

*[← back to the README](../README.md)*

Everything from an empty account to a mounted `ReadWriteMany` PVC, and
back again. Read the [cost warning](../README.md#cost-warning) first.

# Prerequisites

**Accounts and credentials**

- **AWS credentials** with permission to create VPC, EC2, EKS, IAM, Lambda,
  Step Functions, DynamoDB and Secrets Manager resources. The WEKA module
  builds all of those. Two smaller permissions are easy to miss because they
  are not about creating infrastructure:

  | Permission | Needed by | If it is missing |
  |---|---|---|
  | `ec2:DescribeInstanceTypes` | `preflight.tf` | **`plan` fails** — the guards read the real ENI and CPU figures from the EC2 API rather than a hard-coded table |
  | `budgets:*` | `cost-controls.tf` | **`apply` fails**, but only if you set `budget_notification_emails`; with it unset no budget is created and the permission is not needed |

  `ec2:DescribeInstanceTypes` is in most read-only policies already.
  `budgets:*` frequently is not — budgets are account-level, and a role
  scoped to a single project often cannot touch them.
- **A `get.weka.io` token.** Log in at <https://get.weka.io> and copy your
  token. The backends `curl` the WEKA release with it on first boot — see
  [Troubleshooting](troubleshooting.md) for what a bad token looks like.
- **Quay.io credentials** for the operator and client images. These come from
  **WEKA Customer Success**, not from a self-service signup. Ask for the
  credentials *and* for the supported operator / client-image / cluster-release
  combination, because you need all three to line up.

**Service quotas** — check these before applying, not after 20 minutes of
`apply`:

- `Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances` needs to
  cover **240 vCPUs** at the defaults (6 × 24 + 3 × 32). The default account
  limit in a fresh region is often well below that. Request the increase early;
  it is not always instant.
- **Capacity in a single AZ.** Both the WEKA backends and the client node
  group land in one availability zone — see
  [The client node group](node-group.md) — so that zone alone needs room for
  6 × `i3en.6xlarge` plus 3 × `m6i.8xlarge`. A zone that cannot supply them
  fails with `InsufficientInstanceCapacity`, which is an AWS capacity
  message, not a quota one, and no quota increase fixes it. Try another AZ
  by setting `availability_zones`.
- EIP and NAT gateway limits, if you already have several VPCs in the region.

**Local tools**

| Tool | Version | Why |
|---|---|---|
| `terraform` | ≥ 1.5.7 | Floor from the EKS module |
| `awscli` | v2 | `update-kubeconfig`, Secrets Manager, describing the backend ASG |
| `kubectl` | ≥ 1.30 | Client skew against a 1.32 server |
| `helm` | ≥ 3.8 | OCI registry support, for `helm pull oci://…` |
| `jq` | any | Used in the verification steps |

`.terraform.lock.hcl` is committed deliberately — it pins provider versions so
everyone resolves the same ones. It carries checksums for **linux_amd64,
linux_arm64, darwin_amd64, darwin_arm64 and windows_amd64**, so `terraform
init` works as-is on any of those. On any other platform, `init` fails with a
checksum error rather than silently using an unverified provider; add your
platform with:

```bash
terraform providers lock -platform=<os>_<arch>
```

---

# Walkthrough

## 1. Configure

```bash
git clone <this repo> && cd <repo>

cp .env.example .env
cp weka-eks-terraform/terraform.tfvars.example \
   weka-eks-terraform/terraform.tfvars
```

Two files, with a deliberate split:

- **`.env`** *(repo root)* — the secrets: your `get.weka.io` token, your Quay
  credentials, the operator version. Load it into your shell before running
  anything:

  ```bash
  set -a && source .env && set +a       # from the repo root
  set -a && source ../.env && set +a    # from inside weka-eks-terraform/
  ```

  `set -a` matters. Terraform only reads `TF_VAR_*` from the *environment*, and
  `manifests/00-namespace-and-secrets.sh` reads exported `QUAY_*` variables — a
  plain `source` leaves them shell-local and both will look unset.

- **`weka-eks-terraform/terraform.tfvars`** — the non-secret shape of the
  deployment: instance types, counts, versions, CIDRs. It lives beside the
  Terraform because Terraform only auto-loads `terraform.tfvars` from its own
  working directory.

Both are gitignored; both have tracked `.example` templates. Keep it that way.
`TF_VAR_get_weka_io_token` in `.env` covers the only Terraform input with no
default, so you never have to put the token in a `.tfvars` file at all.

Two values must agree with a manifest you will edit later, so decide them now:

- `client_weka_cores` (default `4`) must equal `spec.coresNum` in
  `manifests/03-weka-client.yaml`.
- `system_cpu_sibling_index` (default `16`) is correct for `m6i.8xlarge`. If
  you change `client_instance_type`, verify it on a running node:
  `cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list`.

## 2. Apply

```bash
cd weka-eks-terraform

terraform init
terraform validate
terraform apply
```

The remaining steps assume you stay in `weka-eks-terraform/`.

Roughly 15–20 minutes for Terraform to return.

> **If the first `apply` fails, re-run it before investigating.** The WEKA
> module creates IAM roles and VPC-attached Lambdas close together, and Lambda
> validates the execution role at create time — so a cold apply can lose an IAM
> propagation race and fail with `InsufficientRolePermissions`. A second
> `terraform apply` replaces the failed functions and carries on. See the
> troubleshooting table.

> **`terraform apply` returning does not mean the WEKA cluster is ready.**
> The module hands cluster formation to a Step Function that is still running
> after Terraform is done. Allow another 15–25 minutes. If you race ahead and
> apply the manifests now, the client will fail to join a cluster that does not
> exist yet.

Watch it finish, then confirm on a backend over SSH:

```bash
weka status     # want "status: OK" and 6 backends
weka fs         # confirm the filesystem the StorageClass will use exists
```

Whatever `weka fs` reports is what `filesystemName` in
`manifests/05-storageclass-dir.yaml` must say, and what `weka_filesystem_name`
in `terraform.tfvars` should be set to. The CSI plugin creates *directories*
inside an existing filesystem — it does not create filesystems — so a name
that does not exist gives you PVCs that stay `Pending`.

`terraform output -raw next_steps` prints this whole sequence with your actual
values substituted in.

## 3. Collect the values the manifests need

```bash
# Backend private IPs — you need at least two, ideally three
terraform output -raw weka_backend_ips_command | bash

# WEKA admin password (username is "admin")
aws secretsmanager get-secret-value \
  --region "$(terraform output -raw region)" \
  --secret-id "$(terraform output -raw weka_password_secret_id)" \
  --query SecretString --output text

# A long-lived client join token — run this ON a backend (SSM or SSH)
weka cluster join-token generate --access-token-timeout 52w
```

> **Use `admin`, and do not reach for the `weka-username` secret.** The module
> creates several Secrets Manager entries whose names invite the wrong pairing:
>
> | Username | Password secret | |
> |---|---|---|
> | `admin` | `<prefix>/<cluster>/weka-password` | works |
> | `weka-deployment` | `<prefix>/<cluster>/weka-deployment-password` | works |
> | `admin` | `weka-deployment-password` | **fails** |
> | `weka-deployment` | `weka-password` | **fails** |
>
> The `weka-username` secret contains `weka-deployment`, **not** `admin`. So
> combining it with the adjacent `weka-password` secret — the obvious reading
> of those two names — gives `Authentication Failed` with no hint why.
>
> Note also that the backends' own instance role is **not** authorised to read
> the admin password secret, so you cannot have a backend fetch it for you; it
> has to come from your workstation. Prefer an interactive `weka user login`
> over scripting the password through `aws ssm send-command`, which records
> command parameters in SSM history.
>
> **And it cannot read the deployment password either.** That is the obvious
> next idea — have the backend fetch `weka-deployment-password` itself, since
> the module's own automation uses it — and it was tested on 5.1.32.19:
> `AccessDenied` for both secrets. There is no scripted route that keeps the
> credential out of SSM history, so either accept that exposure on a
> throwaway cluster and rotate afterwards, or log in interactively.
>
> Minor, but it costs a confusing minute: `aws lambda invoke ... /dev/stdout`
> concatenates the invoke metadata onto the payload, so piping it to a JSON
> parser fails with "Extra data". Write it to a file and read that instead.

> **Getting onto a backend.** The backends have no public IPs, so `allow_ssh_cidrs`
> alone will not reach them — you need a bastion, or SSM. The WEKA module already
> attaches an SSM policy to the backend instance role, so the simplest route needs
> no extra infrastructure:
>
> ```bash
> aws ssm start-session --target <instance-id>            # interactive
> aws ssm send-command --instance-ids <id> \
>   --document-name AWS-RunShellScript \
>   --parameters 'commands=["weka status"]'               # scripted
> ```
>
> `start-session` needs the `session-manager-plugin` installed locally;
> `send-command` does not, which makes it the easier option in a script.

## 4. Point `kubectl` at EKS and check the node prep took effect

```bash
aws eks update-kubeconfig \
  --region "$(terraform output -raw region)" \
  --name "$(terraform output -raw eks_cluster_name)"

kubectl get nodes -L weka.io/supports-clients
```

All three nodes must show `supports-clients=true`. Now verify the user data
actually did its job — do this **before** installing anything, because a
missing HugePages reservation is far easier to diagnose here than as a Pending
pod later:

```bash
# Expect ~6Gi per node, not 0
kubectl get nodes -o json \
  | jq -r '.items[] | "\(.metadata.name)  hugepages-2Mi=\(.status.allocatable["hugepages-2Mi"])"'
```

If a node reports `0`, SSH to it and read `/var/log/weka-node-prep.log`.

## 5. Install the operator

```bash
set -a && source ../.env && set +a   # if not already loaded
cd manifests
./00-namespace-and-secrets.sh
```

This creates the `weka-operator-system` namespace, puts the
`quay-io-robot-secret` pull secret in both `weka-operator-system` and
`default`, applies the CRDs with `kubectl` (Helm never *upgrades* CRDs, only
installs them once), and installs the chart with
`csi.installationEnabled=true`.

The operator version comes from `WEKA_OPERATOR_VERSION` in your `.env`
(the script falls back to its own default if it is unset). Set it to whatever
Customer Success told you.

## 6. Apply the manifests, in order

```bash
cp 01-weka-client-secret.yaml.example 01-weka-client-secret.yaml
cp 04-csi-api-secret.yaml.example     04-csi-api-secret.yaml
```

Fill both in. **Every value in both files is base64**, and encode with
`printf`, never `echo`:

```bash
printf '%s' 'the-value' | base64
```

`echo` appends a newline, the newline gets encoded too, and WEKA then tries to
authenticate with a password ending in `\n`. It fails looking exactly like a
wrong password, so you will not suspect the encoding.

**These are two different secrets and they are not interchangeable:**

| | `01-weka-client-secret.yaml` | `04-csi-api-secret.yaml` |
|---|---|---|
| Used by | the `weka-in-container` client process | the CSI controller and node plugins |
| Referenced by | `spec.wekaSecretRef` on the `WekaClient` | the `csi.storage.k8s.io/*-secret-*` StorageClass parameters |
| Job | authenticate and **join** the cluster data path | call the WEKA **REST API** to create/expand/delete directories |
| Distinctive keys | `join-secret` | `endpoints`, `scheme` |
| Organization key | `org` | `organization` |

> **`03-weka-client.yaml` is tracked, not a `.example`.** It ships with obvious
> placeholder `joinIpPorts` that you edit in place. The check fails while they
> are still placeholders, so you cannot forget — but note the reverse hazard
> too: do not commit your real backend IPs back. They are not secret, but they
> are live infrastructure detail, and the next reader inherits addresses that
> no longer exist.
>
> **It cannot check whether your secrets are *current*.** After a destroy and
> redeploy, `01-weka-client-secret.yaml` and `04-csi-api-secret.yaml` still
> hold the **previous** cluster's admin password, join token and backend IPs —
> all now invalid — and the check will report them as "filled in". Regenerate
> both from the `.example` templates on every redeploy. Otherwise the client
> fails to join with an auth error and the CSI plugin times out against
> backend IPs that no longer exist.

Then apply in order, editing `joinIpPorts` in `03-weka-client.yaml` with the
backend IPs from step 3:

```bash
kubectl apply -f 01-weka-client-secret.yaml
kubectl apply -f 02-weka-nics-policy.yaml     # BEFORE the client -- see below
kubectl apply -f 03-weka-client.yaml
kubectl apply -f 04-csi-api-secret.yaml
kubectl apply -f 05-storageclass-dir.yaml
kubectl apply -f 06-smoke-test.yaml

# Recommended: paces future node-group rolls. Derive the selector from the
# running operator first -- the file ships with a REPLACE_ME placeholder.
./10-discover-pdb-selector.sh --write
kubectl apply -f 10-poddisruptionbudgets.yaml
```

Everything above is the deployment. The demo assets are optional and come
after it:

```bash
kubectl apply -f 07-rwx-multiwriter.yaml      # needs >= 3 client nodes
./08-persistence-check.sh                     # needs >= 2 client nodes
kubectl apply -f 09-fio-job.yaml              # read its header comment first
```

Or let `./demo.sh` drive all of it in order — see [Demo](demo.md).

> `02-weka-nics-policy.yaml` is **required on AWS, and the easiest file to
> overlook.** The WEKA client's data path is DPDK: it binds NICs directly from
> userspace and cannot share the node's primary ENI with the kubelet and the
> VPC CNI. That `WekaPolicy` attaches dedicated data-path ENIs and then
> advertises them to the scheduler as the extended resource
> `weka.io/weka-nics`, one of which the client pod requests per core.
>
> Nothing in Terraform can do this — the node group creates an instance with
> one ENI, and the VPC CNI's additional ENIs are for pod IPs, not for WEKA.
> Skip this file and the client pod sits in `Pending` forever with
> `1 Insufficient weka.io/weka-nics`, with a perfectly healthy cluster and node
> either side of it.
>
> Keep `dataNICsNumber` >= the client's `coresNum`.

> `05-storageclass-dir.yaml` is **mandatory here.** The Operator auto-creates
> StorageClasses only for an in-cluster `WekaCluster` custom resource it manages
> itself, because that is where it gets the filesystem name and endpoints from.
> Our backend came from Terraform, so there is no such object and no
> StorageClass appears on its own. Any quickstart that skips this step assumed
> an operator-managed cluster.

## Check for drift before you apply

Five manifest fields must agree with Terraform variables, and **nothing in
Kubernetes tells you when they drift** — you get a Pending pod and a message
about capacity rather than about the mismatch:

| Terraform | Manifest field | Symptom if they disagree |
|---|---|---|
| `client_weka_cores` | `03` `spec.coresNum` | HugePages sized wrong → `Insufficient hugepages-2Mi` |
| `client_weka_cores` | `02` `dataNICsNumber` | `Insufficient weka.io/weka-nics` |
| `weka_version` | `02`/`03` `spec.image` tag | client/backend version skew |
| `weka_filesystem_name` | `05` `filesystemName` | PVC `Pending` forever |
| `client_max_pods` | `MAX_ENI` in `eks.tf` | pods admitted with no IP available |

There is a second kind of drift, entirely inside Terraform — variables that
are only correct for one instance type. `preflight.tf` catches that at plan
time; see **[Plan-time guards](preflight.md)**.

`terraform output manifest_values` is the authoritative list, and there is a
check that compares the files against it:

```bash
./check-manifests.sh              # needs Terraform state, and ideally a cluster
./check-manifests.sh --offline    # files only — what CI runs
```

`--offline` asks a different question from the default and is what CI runs;
see **[Continuous integration](ci.md)**. It also verifies
`dataNICsNumber >= coresNum`, that the secret files no longer contain
`REPLACE_ME`, and a set of consistency checks across the demo manifests.
Two seconds here saves 10–20 minutes of debugging a Pending pod.


## 7. Verify

```bash
kubectl -n weka-operator-system get wekaclient,pods
kubectl get pvc weka-smoke-test-pvc          # want Bound
kubectl logs weka-smoke-test                 # want "SMOKE TEST PASSED"
```

A `Bound` PVC and a pod appending timestamps to it means the whole path works:
CSI controller → WEKA REST API → directory with a quota → CSI node plugin →
WEKA client → mount.

---

# Teardown

```bash
kubectl delete -f manifests/10-poddisruptionbudgets.yaml --ignore-not-found
kubectl delete -f manifests/09-fio-job.yaml --ignore-not-found
kubectl delete -f manifests/07-rwx-multiwriter.yaml --ignore-not-found
kubectl delete -f manifests/06-smoke-test.yaml
kubectl delete -f manifests/05-storageclass-dir.yaml
kubectl delete -f manifests/03-weka-client.yaml
terraform destroy
```

(`manifests/demo.sh --reset` does the first two, plus the `WekaClient` and the
`WekaPolicy`, if you would rather not remember the order.)

Delete the Kubernetes objects **first**. A `Delete` reclaim policy means the CSI
plugin tries to remove the WEKA directories backing your PVCs; if you tear down
the backends first, that call fails and the PVs are left with finalizers you
then have to strip by hand.

> ### `terraform destroy` on the WEKA module can leave resources behind
>
> **Check the console afterwards.** This is not a hypothetical. The WEKA module
> manages the cluster through Lambdas, a Step Function and a DynamoDB state
> table, and cluster formation and healing create things Terraform does not
> have in state. Destroy also races: the healing Lambda can replace a backend
> while Terraform is deleting the autoscaling group.
>
> ### The tagging API will show you ghosts
>
> The obvious way to sweep for orphans is by tag:
>
> ```bash
> aws resourcegroupstaggingapi get-resources \
>   --tag-filters "Key=Project,Values=weka-eks-demo"
> ```
>
> **It lags, badly.** On this run it reported **90 resources still tagged** —
> 51 ENIs, 15 volumes, 9 instances, a NAT gateway — with Terraform state
> empty and everything actually gone. Every single one resolved to
> `terminated`, `deleted` or `PendingDeletion` when queried directly.
>
> So use it to get a candidate list, never as the answer. Confirm with the
> service's own API:
>
> ```bash
> aws ec2 describe-instances --filters "Name=tag:Project,Values=weka-eks-demo" \
>   --query "Reservations[].Instances[].State.Name" --output text | sort | uniq -c
> ```
>
> Terminated instances also linger in `describe-instances` for about an hour.
> They are not billed; filter on `instance-state-name` rather than counting rows.
>
> After `destroy` reports success, go and look at:
>
> - **EC2** — instances, and the **cluster placement group**
> - **Network interfaces** — a leftover ENI blocks VPC and subnet deletion and
>   is the usual reason `destroy` half-fails. Measured on this deployment: the
>   data-path ENIs the `ensure-nics` policy attaches all carry
>   `DeleteOnTermination=True`, so they go away with the instance and are NOT a
>   source of orphans — but note they are **not released when you delete the
>   WekaPolicy**, only when the node terminates, so do not wait for them to
>   disappear before running `destroy`
> - **Secrets Manager** — entries are *scheduled* for deletion, not deleted.
>   They keep the name reserved for up to 30 days, so a re-apply under the
>   same `prefix`/`cluster_name` will fail. `--force-delete-without-recovery`
>   if you need the name back now.
> - **DynamoDB** — the cluster state table
> - **Lambda and Step Functions** — the deploy/scale/status functions
> - **CloudWatch log groups** — cheap, but they accumulate
> - **KMS keys** — the EKS module creates several. On this run 8 were left in
>   `PendingDeletion` with windows spread over the following month. That is
>   the normal outcome, not an orphan, but they are worth a glance because
>   nothing else in the teardown mentions them:
>   `aws kms describe-key --key-id <id> --query 'KeyMetadata.[KeyState,DeletionDate]'`
> - **EBS volumes and snapshots** — anything not marked
>   `delete_on_termination`
> - **Elastic IPs** — a released NAT EIP still bills if it stays allocated
>
> If `destroy` fails partway, re-run it. If it fails twice on the same
> resource, delete that resource in the console and re-run — do not start
> hand-editing state.
>
> ### Do not pipe `terraform destroy` into anything
>
> ```bash
> terraform destroy -auto-approve | tail -40     # exit code is tail's: ALWAYS 0
> ```
>
> A shell pipeline reports the exit status of its **last** command, so this
> reports success even when Terraform failed — and the failure above is one
> you should expect, so you will be told "exit 0" on a teardown that left the
> placement group, a VPC and two subnets behind. It cost a wrong "the destroy
> finished" on this very run.
>
> Redirect instead, and check the code:
>
> ```bash
> terraform destroy -auto-approve -no-color > destroy.log 2>&1; echo "rc=$?"
> ```
>
> (Or set `pipefail`.) The same applies to `| tee`, and the truncation loses
> the log you would want for exactly the failure you just hit.
>
> **Re-verified on 5.1.32.19, 2026-09-29.** The behaviour below is not
> folklore — it reproduced exactly. Measured on that run:
>
> | | |
> |---|---|
> | first pass | **22m43s**, 168 of 173 resources destroyed, then failed |
> | left behind | 5 — the placement group, the VPC, two subnets, and `time_static` |
> | second pass | **~40 seconds**, all 5 gone, exit 0 |
> | slowest single resource | the shared security group, **14m10s** — it is referenced by the backends, the EKS nodes *and* the Secrets Manager endpoint, so it cannot go until all of them have |
>
> **Expect exactly this on the first `destroy`:**
>
> ```
> Error: deleting EC2 Placement Group (weka-poc-placement-group):
>   InvalidPlacementGroup.InUse: The placement group is in use and may not be deleted.
> ```
>
> A placement group cannot be deleted until every instance in it has *finished*
> terminating, not merely entered `shutting-down`. Terraform deletes the
> autoscaling group, does not wait for the instances to reach `terminated`, and
> then fails on the group. Observed on a real teardown: it left 5 resources in
> state (the placement group, the VPC, and two subnets behind it). A second
> `terraform destroy` cleared all of them in seconds. Nothing expensive was
> still running at that point — the instances, NAT gateway and EKS cluster were
> already gone — so this is tidiness, not cost.
>
> ### Do not kill `terraform destroy`
>
> Interrupting it can truncate `terraform.tfstate` to **zero bytes** if the
> kill lands while state is being written. `terraform state list` then returns
> nothing and Terraform believes it owns no resources at all, while the VPC,
> the EKS cluster and the placement group are still very much there.
>
> The fix is easy if you know to look: Terraform keeps the previous state
> alongside it.
>
> ```bash
> ls -l terraform.tfstate terraform.tfstate.backup   # is the first one 0 bytes?
> cp terraform.tfstate.backup terraform.tfstate
> terraform destroy                                  # refreshes, then finishes the job
> ```
>
> Terraform refreshes against reality first, so already-deleted resources are
> dropped quietly and only the genuine remainder is destroyed. Restoring the
> backup and re-running beats deleting a VPC's subnets, route tables and
> security groups by hand.

Because the backends are the expensive part, an easy way to stop the bleeding
without a full teardown is to scale the WEKA autoscaling group to zero — but
note that this **destroys the cluster's data**, and the module's healing Lambda
may scale it back up. A real teardown is `terraform destroy`.

---

---

*[← back to the README](../README.md)*
