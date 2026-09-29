# Module versions

*[← back to the README](../README.md)*

The versions here are **not** the ones you may have seen in earlier write-ups,
and the difference is forced rather than chosen:

| Module | Pinned | Note |
|---|---|---|
| `weka/weka/aws` | **2.0.1** | Latest at time of writing. Requires `aws >= 6.0.0`. |
| `terraform-aws-modules/vpc/aws` | **~> 6.7** | |
| `terraform-aws-modules/eks/aws` | **~> 21.25** | |
| `hashicorp/aws` | **>= 6.59** | Floor imposed by the EKS module |
| Terraform | **>= 1.5.7** | Floor imposed by the EKS module |

**Changes from a `weka 1.0.1` / `vpc ~> 5.0` / `eks ~> 20.0` starting point:**

- **`weka/weka/aws` 1.0.1 → 2.0.1.** 1.0.1 is many releases stale. Somewhere in
  the `1.0.x` line the module moved its provider floor to `aws >= 6.0.0`.
- **This forces everything else up.** `terraform-aws-modules/eks` v20.x pins
  `aws >= 5.95, < 6.0.0`, which is *flatly incompatible* with the WEKA module —
  there is no provider version that satisfies both, and `terraform init` fails
  outright. So the EKS module has to be 21.x, and once the provider is on 6.x
  the VPC module has to be 6.x too.
- **EKS module v21 renamed inputs.** `cluster_name` → `name`,
  `cluster_version` → `kubernetes_version`, `cluster_addons` → `addons`, and
  `eks_managed_node_groups` is now a typed object rather than a free-form map.
  Copy-pasting a v20 node group definition in here will not validate.

If you must stay on the AWS 5.x provider line, you have to pin
`weka/weka/aws` at `1.0.1` and accept a module that predates the current WEKA
deployment flow. Not recommended.

## The WEKA release itself is not a module version

`weka/weka/aws` 2.0.1 has **no default** for `weka_version` (it defaults to
`""`), does not gate on it, and does not parse it. The only thing it does with
the value is interpolate it into the download URL twice:

```
https://$TOKEN@get.weka.io/dist/v1/install/<version>/<version>?provider=aws&region=<r>
```

So the module imposes no floor and no ceiling, and the only question is whether
your `get.weka.io` token is entitled to the release. This repo targets:

| | Pinned | Note |
|---|---|---|
| WEKA release | **5.1.32.19** | `weka_version` in `terraform.tfvars.example`. Newest public GA on the 5.1 line as of 2026-09-21 |
| `weka-in-container` | **5.1.32.19** | `spec.image` in manifests `02` and `03` — must equal the release |
| Operator chart | **variable** | `WEKA_OPERATOR_VERSION` in `.env`. The supported triple comes from WEKA Customer Success, not from a docs page — **ask for all three together** |

4.4 is past its end of proactive updates (1 June 2026) and is in
critical-updates-only until 1 June 2027; 5.1 has proactive updates to 1 June
2027 and support to 1 June 2028. Still confirm the exact release with Customer
Success — the supported triple above comes from them, not from a docs page.

`terraform.tfvars.example` carries the `curl` that checks entitlement and the
one that lists what your token can actually have.

## `weka_version` has no default, on purpose

`variables.tf` declares `weka_version` with **no default** and a validation
that rejects anything outside the 5.1 line:

```hcl
validation {
  condition = can(regex("^5\\.1\\.", var.weka_version))
}
```

Both halves matter, and neither is tidiness:

- **No default**, because whether a release works depends on what *your* token
  is entitled to, which Terraform cannot know. An unentitled release does not
  fail the plan and does not fail the apply — the backends launch, fail the
  download during cloud-init, and never form a cluster. That is six
  `i3en.6xlarge` at ~$20/hour on a failure whose only symptom is a cluster that
  never appears, which reads as a networking problem and sends you to the
  security group instead of to a 403. A *missing* value fails immediately and
  for free.
- **The 5.1 regex**, because the node prep, the reserved-port arithmetic in
  `node-userdata.tf` and the operator floor in `.env.example` are all written
  for 5.1. A 4.4 backend is no longer a supported target here, and it should
  not be reachable by editing one line of `terraform.tfvars`.

Note that **`terraform validate` does not evaluate variable validations** — it
is a configuration check and does not resolve variable values. The pin bites at
`plan` time. `terraform console` is the quick way to test it:

```bash
echo 'var.weka_version' | terraform console
```

---

---

*[← back to the README](../README.md)*
