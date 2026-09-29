# Plan-time guards (`preflight.tf`)

*[← back to the README](../README.md)*

Some Terraform variables in this repo are only correct for one instance type.
`preflight.tf` makes that a plan-time failure instead of a Pending pod.

Those five are drift **between Terraform and Kubernetes**. There is a second
kind, entirely inside Terraform, and `preflight.tf` catches it at plan time:

| Variable | Default | Only correct because… |
|---|---|---|
| `client_max_pods` | 29 | the primary ENI on `m6i.8xlarge` carries 30 IPv4 addresses, one of them the node's own |
| `system_cpu_sibling_index` | 16 | `m6i.8xlarge` has 16 physical cores, so CPU 0's HyperThreading sibling is CPU 16 |
| `client_weka_cores` | 4 | `ensure-nics` needs one ENI per core plus the primary, and `m6i.8xlarge` allows 8 |

Change `client_instance_type` and none of those follow. `preflight.tf` reads
the real numbers from the EC2 API (`aws_ec2_instance_type`) rather than
carrying a table of specs typed from memory, and fails the plan with the
correct value in the message — including the case where the instance type has
no HyperThreading at all, so CPU 0 has no sibling to reserve.

It costs nothing to run and needs only `ec2:DescribeInstanceTypes`. Because it
is a data source, `terraform validate` does not read it, which is why CI can
validate with no AWS credentials.

`terraform output instance_type_facts` prints what AWS says about your chosen
type — worth a look *before* changing it.

## What it checks

Five preconditions, all evaluated at plan time, all reading the real figures
from `data.aws_ec2_instance_type`:

| Guard | Fails when | Symptom it prevents |
|---|---|---|
| `client_max_pods <= ipv4_per_eni - 1` | maxPods exceeds what the CNI can address | pods admitted with no IP, stuck in `ContainerCreating` |
| sibling index `== default_cores` | the reserved sibling is the wrong CPU | a WEKA core shares a physical core, and its L1/L2, with the kubelet |
| one thread per core ⟹ sibling `== 0` | HyperThreading is absent but a sibling is still set | an unrelated CPU is reserved — wasted, and isolating nothing |
| `weka_cores + 1 <= max ENIs` | the instance type has too few ENI slots | client pod `Pending` on `1 Insufficient weka.io/weka-nics` |
| `weka_cores + 2 < vCPUs` | pinning leaves nothing for anything else | a node with no capacity for workloads |

The `<=` on the first one is deliberate: lowering `client_max_pods` below the
ceiling is safe and sometimes sensible, so only exceeding it is an error.

## Why it asks AWS instead of carrying a table

The obvious implementation is a lookup map of instance type to
`{ipv4_per_eni, sibling_index}`. It would also be a table of hardware specs
typed from memory into a repo whose credibility rests on its numbers being
*observed* rather than assumed — and it would not cover whatever instance type
you actually picked.

`data.aws_ec2_instance_type` is authoritative, self-maintaining, and works for
every instance type including ones nobody anticipated. It costs nothing and
needs only `ec2:DescribeInstanceTypes`.

## Where the preconditions live

On a `terraform_data` resource, which creates nothing. They cannot go on the
variables themselves: variable `validation` could not reference *another*
variable until Terraform 1.9, and `versions.tf` declares a floor of 1.5.7. A
`check` block would only emit a warning, and a warning about a node that will
never schedule is not worth having.

## Caveat

Because these are data-source reads, `terraform validate` does not evaluate
them — which is exactly why [CI](ci.md) can validate with no AWS credentials.
It also means the guards are first exercised by your first real `terraform
plan`.

---

*[← back to the README](../README.md)*
