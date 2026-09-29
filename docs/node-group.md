# The client node group: placement and disruption

*[← back to the README](../README.md)*

Two decisions about the `weka_clients` node group that are easy to get wrong
in opposite directions: **where** its nodes live, and **how fast** they are
allowed to be replaced.

Both matter more here than on an ordinary node group, because every node in
this one is a WEKA client. Losing a node is not losing a stateless replica —
it is a cluster membership change on the WEKA side and an unmounted
filesystem for every pod that was on it.

---

## Placement: the same AZ as the backends

`weka.tf` pins the WEKA backends to `private_subnets[0]`, because the module
enforces a single-AZ cluster — a parallel filesystem stripes every write
across its peers, and cross-AZ round-trip time would dominate the latency
budget.

`eks.tf` pins the **node group** to that same subnet.

```hcl
subnet_ids = [module.vpc.private_subnets[0]]
```

### Why not spread them

Spreading the clients across both private subnets is the obvious default, and
it is wrong here for three separate reasons:

| | |
|---|---|
| **It buys no availability** | The storage is already AZ-bound. If the backends' AZ fails, every client loses its filesystem whether or not the client itself is still running. A client that survives in the other zone is a pod waiting on a mount that is never coming back — that is not availability, it is a slower way to fail. |
| **It costs on every byte** | Cross-AZ traffic is charged in both directions, and for a parallel filesystem *every* read and write is on that path. On a storage benchmark that is not a rounding error; it can exceed the NAT gateway charge, which the cost table does itemise. |
| **It makes measurement non-deterministic** | With nodes in two AZs, throughput depended on which AZ the scheduler happened to place a pod in. [`09-fio-job.yaml`](demo.md#performance-numbers) is not reproducible under that, and neither is anything else you might measure. |

### The trade-off, stated plainly

The node group is now a single point of failure at AZ granularity.

That sounds worse than it is: the storage was *already* AZ-bound, so an AZ
outage goes from "the filesystem is gone" to "the filesystem and its clients
are gone" — in practice the same outage. What it does mean in a real way:

- **A single AZ must have capacity** for `client_node_count` instances of
  `client_instance_type`. Large instance types in one zone are the usual
  place this bites.
- If you genuinely need clients to survive the backends' AZ, that is not a
  subnet change — it is a second WEKA cluster.

### The EKS cluster still spans both AZs

Do not "fix" this to match:

```hcl
module "eks" {
  subnet_ids = module.vpc.private_subnets   # both — the control plane requires two AZs
  ...
  eks_managed_node_groups = {
    weka_clients = {
      subnet_ids = [module.vpc.private_subnets[0]]   # one — see above
```

They are separate inputs. The EKS control plane requires subnets in at least
two availability zones; the node group has no such requirement. Collapsing
the cluster-level list to one subnet will fail at apply time.

### Checking it

```bash
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,AZ:'.metadata.labels.topology\.kubernetes\.io/zone'
```

Every client node should report the same zone. To confirm it is the
*backends'* zone, compare against a backend:

```bash
aws ec2 describe-instances \
  --filters "Name=tag:aws:autoscaling:groupName,Values=$(terraform output -raw weka_backends_asg_name)" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].Placement.AvailabilityZone" --output text
```

---

## Disruption: pacing a node-group roll

### Why a roll happens more often than you would think

`node-userdata.tf` is launch-template user data. **Any** change to it produces
a new launch template version, the module moves the LT default version, and
EKS performs a rolling replacement of the entire group on the next
`terraform apply`. You do not have to ask for it.

That is covered in [Node preparation](node-preparation.md) — including why
the prose in that file deliberately lives *outside* the heredocs, so that
editing a comment cannot trigger a roll.

### What paces it — and it is not a PodDisruptionBudget

The obvious answer is a PDB over the client pods. **It was tried against a
real cluster and it is worse than useless.** Measured on operator v1.16.0 /
WEKA 5.1.32.19 / EKS 1.32:

```
kubectl -n weka-operator-system get pdb
NAME              MAX UNAVAILABLE   ALLOWED DISRUPTIONS
weka-client       1                 0
weka-node-agent   1                 0

weka-client:      DisruptionAllowed=False  reason=SyncFailed
                  "wekacontainers.weka.weka.io does not implement
                   the scale subresource"
weka-node-agent:  DisruptionAllowed=False  reason=SyncFailed
                  "daemonsets.apps does not implement the scale subresource"
```

`disruptionsAllowed: 0` never rises, because the disruption controller cannot
work out an expected pod count. An actual eviction attempt:

```
Error from server (TooManyRequests): Cannot evict pod as it would violate
the pod's disruption budget.
```

and after deleting the PDBs the same eviction returned `201 Success`. So the
budget does not slow a node-group roll down — **it stops it.** A managed node
group update would hang until it timed out, on the very cluster the PDB was
added to protect.

This is **not** the integer-versus-percentage problem. Both budgets above used
an integer `maxUnavailable: 1`. The constraint is that the owning controller
must implement the `scale` subresource, and neither a `WekaContainer` CR nor a
`DaemonSet` does.

`manifests/10-poddisruptionbudgets.yaml` therefore defines no objects. It is
kept as a file so the finding is where somebody would otherwise re-add them.

### What actually paces it

The node group's own update config — no PDB, no dependency on any CRD:

```bash
aws eks describe-nodegroup --cluster-name <cluster> --nodegroup-name <ng> \
  --query 'nodegroup.updateConfig'
```
```json
{ "maxUnavailablePercentage": 33 }
```

Measured on this deployment. With three nodes that is **one node at a time**,
which is exactly the pacing the PDB was meant to provide — and it was already
in effect the whole time.

To make it explicit, or to pin it at one node regardless of group size, set
`update_config` on the node group in `eks.tf`:

```hcl
update_config = { max_unavailable = 1 }
```

To stop an ordinary Terraform edit triggering a roll at all, see
[Node preparation](node-preparation.md) and
`update_launch_template_default_version`.

### Where a PDB does still belong

Over **your own workloads** on the WEKA filesystem. Those are ordinary
Deployments, their controller implements `scale`, and they can be rescheduled
onto another node and re-mount the same `ReadWriteMany` claim — which is
exactly what [`08-persistence-check.sh`](demo.md) demonstrates. The WEKA
client containers themselves cannot be protected this way.

`manifests/10-discover-pdb-selector.sh` still works if you need to build a
selector for one of those; the selector was never the problem.

---

*[← back to the README](../README.md)*
