## Continuous integration

Everything above is also enforced on every push and pull request by
`.github/workflows/ci.yml`, in four parallel jobs:

| Job | What it runs |
|---|---|
| **Terraform** | `fmt -check -recursive`, `init -backend=false`, `validate`, then `ci/check-runbook.sh` |
| **Shell** | `bash -n` and `shellcheck` on every tracked `*.sh`, plus a check that each is mode `100755` |
| **Docs** | every relative link resolves, and no page under `docs/` is orphaned from the README |
| **Manifests** | `kubeconform -strict` against the Kubernetes 1.32 schemas, then `./check-manifests.sh --offline` |

**Terraform is pinned to `1.5.7`** — the floor declared in `versions.tf`, not
"latest" — so CI proves the floor is real rather than aspirational. If you
bump one, bump the other.

`ci/check-runbook.sh` exists because the runbook Terraform prints has been
wrong twice, and neither case was visible in the source. It lifts the
`next_steps` heredoc into a scratch module, renders it, and asserts that every
manifest is named, that `02` precedes `03`, and that the RWX payoff command
matches every documentation page that carries it, byte for byte — including the `\$2` escaping, which
renders as valid text and returns a *wrong answer* when it is missing.

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
