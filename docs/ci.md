## Continuous integration

Everything above is also enforced on every push and pull request by
`.github/workflows/ci.yml`, in three parallel jobs:

| Job | What it runs |
|---|---|
| **Terraform** | `fmt -check -recursive`, `init -backend=false`, `validate`, then `ci/check-runbook.sh` |
| **Shell** | `bash -n` and `shellcheck` on every tracked `*.sh`, plus a check that each is mode `100755` |
| **Manifests** | `kubeconform -strict` against the Kubernetes 1.32 schemas, then `./check-manifests.sh --offline` |

Two things about it are worth knowing.

**It needs no AWS credentials, and must never have any.** `init -backend=false`
plus `validate` is a configuration check, not a dry run — nothing plans,
applies, or contacts an account. This repo stands up ~$20/hour of
infrastructure and CI should not be one bad edit away from doing that.

**Terraform is pinned to `1.5.7`** — the floor declared in `versions.tf`, not
"latest" — so CI proves the floor is real rather than aspirational. If you bump
one, bump the other.

`ci/check-runbook.sh` exists because the runbook Terraform prints has been
wrong twice, and neither case was visible in the source. It lifts the
`next_steps` heredoc into a scratch module, renders it, and asserts that every
manifest is named, that `02` precedes `03`, and that the RWX payoff command
matches this README byte for byte — including the `\$2` escaping, which
renders as valid text and returns a *wrong answer* when it is missing.

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


## `check-manifests.sh --offline`

```bash
./check-manifests.sh              # needs Terraform state, and ideally a cluster
./check-manifests.sh --offline    # files only — what CI runs
```

The two modes ask different questions, and `--offline` is not just a subset.
The default asks *"is my working copy ready to apply?"*. `--offline` asks *"is
the repo internally consistent as committed?"* — which means it **inverts** the
two placeholder checks, because in a clean checkout the placeholders are the
correct state:

- `03-weka-client.yaml` **must** still say `REPLACE` in the committed copy.
  Real backend IPs in git are live infrastructure detail that stops being true
  the moment the ASG heals a node.
- `01-weka-client-secret.yaml` and `04-csi-api-secret.yaml` **must not be
  tracked**. They are gitignored, so a checkout where git knows about one is a
  checkout where somebody force-added a WEKA admin password to a public repo.

Both read git rather than the filesystem, so editing `03` in place and having
the secret files on disk — the documented workflow — does not trip them.

It also verifies `dataNICsNumber >= coresNum` and that the two secret files no
longer contain `REPLACE_ME` placeholders. Two seconds here saves 10–20 minutes
of debugging a Pending pod.

For the demo assets it additionally checks that `07`'s `storageClassName`
matches the StorageClass `05` actually creates, that `09` claims `07`'s PVC,
that every `weka-in-container` tag in *any* manifest matches
`terraform output manifest_values`, that the `busybox` tag is pinned and
identical across `06`/`07`/`08`, that `09`'s fio `size` fits inside `07`'s
quota, that the scripts are executable — and, against the live cluster, that
there are enough schedulable client nodes for `07`'s replica count and for
`08`'s cordon.

## What CI deliberately does not do

It has **no AWS credentials and must never have any.** `init -backend=false`
plus `validate` is a configuration check, not a dry run — nothing plans,
applies, or contacts an account. This repo stands up ~$20/hour of
infrastructure and CI should not be one bad edit away from doing that.

The cost of that choice is that two things cannot be exercised in CI, because
both need to talk to AWS:

- the `data.aws_ec2_instance_type` read in [`preflight.tf`](preflight.md)
- the `aws_budgets_budget` resource in [`cost-controls.tf`](cost-controls.md)

Both are first tested by your first real `terraform plan` / `apply`.

---

*[← back to the README](../README.md)*
