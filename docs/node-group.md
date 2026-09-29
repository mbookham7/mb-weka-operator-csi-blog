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

### What paces it

[`10-poddisruptionbudgets.yaml`](../weka-eks-terraform/manifests/10-poddisruptionbudgets.yaml)
sets `maxUnavailable: 1`, so the drain phase of a roll takes one client at a
time and waits.

`maxUnavailable` is an **integer, not a percentage**, and that is deliberate.
A percentage requires the controller owning the pods to expose a scale
subresource so Kubernetes can compute the expected count. The operator's
per-node client containers do not. A percentage against pods it cannot size
does not fail safe — it wedges every drain on the cluster, permanently.

### You have to fill in the selector

The file ships with `app: REPLACE_ME`.

That is not laziness. The WEKA client pods are created by the operator's
controller at runtime, not by the Helm chart, so their labels are not in the
chart and vary by operator version. (Checked: the chart carries selectors
only for `weka-operator`, `weka-node-agent` and `weka-cluster-monitoring` —
even the CSI workloads are created by the operator.) A guessed selector would
produce a PDB that matches nothing, and **a PDB matching nothing is silently
inert**: it exists, `kubectl get pdb` shows it, it reports allowed
disruptions, and it restrains precisely nothing.

Find the real labels on a running cluster:

```bash
kubectl -n weka-operator-system get pods --show-labels

kubectl -n weka-operator-system get pod <client-pod> \
  -o jsonpath='{.metadata.labels}' | python3 -m json.tool
```

Pick one or two labels that match the client pods **and nothing else**. Too
broad is its own failure: a selector that also catches the CSI node plugin
budgets them together and blocks drains for the wrong reason.

`./check-manifests.sh` fails while the placeholder is there, and — against a
live cluster — fails if a selector matches no pods. See
[Continuous integration](ci.md).

The second PDB in the file, for `app: weka-node-agent`, needs no editing:
that label *is* in the chart, as the selector on its `PodMonitor`.

### What a PodDisruptionBudget does not do

This is the part worth reading twice, because a PDB invites more confidence
than it earns:

- **It is only consulted by the eviction API.** A managed node group update
  drains nodes and respects PDBs; so does `kubectl drain`. A hard instance
  termination — spot reclaim, an AZ event, someone clicking Terminate — does
  not evict anything, and no PDB is involved.
- **DaemonSet pods are not evicted during a drain, they are deleted.** A PDB
  does not protect them. If your operator version manages the client
  containers as a DaemonSet rather than as individually-owned pods, this file
  will not restrain a roll at all. Check which you have:

  ```bash
  kubectl -n weka-operator-system get pod <client-pod> \
    -o jsonpath='{.metadata.ownerReferences[*].kind}{"\n"}'
  ```

  `DaemonSet` means the PDB is decorative. `WekaContainer`, or no owner,
  means it applies.
- **It does not make a roll safe, only slower.** One client at a time still
  means each node's pods lose their mount while that node is replaced.
  Workloads that cannot tolerate that need their own PDBs and a
  `ReadWriteMany` claim they can re-mount elsewhere — which is what
  [`08-persistence-check.sh`](demo.md) demonstrates.

---

*[← back to the README](../README.md)*
