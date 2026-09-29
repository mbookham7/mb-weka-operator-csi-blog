# Demo

*[← back to the README](../README.md)*

`06-smoke-test.yaml` proves the plumbing, and that is all it proves — one pod,
one mount, one file, which an EBS volume would have done just as well. Files
`07` to `09` plus `demo.sh` are the part that shows what the backend is for.

```bash
cd manifests
./demo.sh              # paused between beats, for a recording
./demo.sh --no-pause   # straight through
./demo.sh --reset      # back to the pre-demo state, then exit
```

`demo.sh` applies `02` and `03` itself — beat 2 depends on them **not** being
there yet. Everything through `05` has to be in place first.

## The five beats, and what each one proves

| # | Beat | What it proves that the previous one did not |
|---|---|---|
| 1 | **Node prep.** `hugepages-2Mi` per node, and `cpu` allocatable reading 30 against a capacity of 32 | That Terraform's user data ran at first boot and took effect. None of it can be done afterwards: HugePages only allocate reliably while memory is unfragmented, and the kubelet only advertises them if they existed before its first node status update. `30/32` is `strict-cpu-reservation` holding CPU 0 and its HT sibling out of the shared pool |
| 2 | **The negative case.** `03-weka-client.yaml` applied *without* `02-weka-nics-policy.yaml`, Pending on `1 Insufficient weka.io/weka-nics`, then scheduling the moment the policy lands | That a DPDK data path needs dedicated ENIs, that nothing in Terraform can attach them, and that the resulting failure is invisible: a healthy cluster, a healthy node, and a pod that waits forever for an extended resource only an operator CR creates. This is the best teaching moment in the deployment, which is why it is a deliberate, resettable step |
| 3 | **The mount.** `kubectl get pvc`, then `df -hT /data` inside a pod | That the CSI controller created a **directory** inside an existing WEKA filesystem and the quota on it is real. Two things to point at: the filesystem type is `wekafs`, not ext4 on a block device; and the size is the PVC's request, not the cluster's 36 TiB — which is `capacityEnforcement: HARD` doing its job |
| 4 | **Shared writes.** Three replicas, one per node, appending to `/data/shared.log`, counted with one `uniq -c` | That three kernels can hold one file open for append concurrently, with no locking in the workload, and the counts add up. **No block volume does this** — RWX on EBS does not exist, and a block device with a single-writer filesystem on top corrupts. It is also the only beat that exercises the CSI node plugin on *every* node rather than the one the scheduler happened to pick |
| 5 | **Node loss.** `08-persistence-check.sh`: write a sentinel, delete the pod, cordon its node, assert the replacement scheduled elsewhere, read the sentinel back | That the data outlives both the pod and the machine it was written from. On EKS node loss is routine — spot interruption, AMI roll, instance refresh, a drain you did yourself — and it is the point where node-local storage quietly becomes data loss. The cordon is what makes the assertion mean anything: without it the scheduler puts the pod straight back where it was |

The payoff for beat 4 is one command:

```bash
kubectl exec deploy/weka-rwx-demo -- sh -c \
  "awk '{print \$2}' /data/shared.log | sort | uniq -c"
```

## Node count

**Beat 4 needs at least 3 client nodes, and beat 5 needs at least 2.**
`client_node_count` is `3` in both `variables.tf` and
`terraform.tfvars.example`, which is what the cost table, the quota figure and
the demo manifests all assume. Dropping it to `1` is the minimal-smoke-test
option — it still gets you through `00`–`06`, but `07`, `08` and `demo.sh` all
need 3. (The verified deployment above ran with `1`, which is why its table
records `clients: 1 connected`.)

The `podAntiAffinity` in `07` is `required`, so with too few nodes the surplus
replicas do not spread, they sit in Pending on `node(s) didn't match pod
anti-affinity rules`. `check-manifests.sh` compares `07`'s `replicas` against
the labelled client nodes actually present, so you find out before you apply
rather than on camera.

## Rehearsing beat 2

`./demo.sh --reset` deletes the demo workloads, then the `WekaClient`, then the
`WekaPolicy`, and uncordons anything `08` left behind.

It then checks whether the nodes have actually stopped advertising
`weka.io/weka-nics`, and tells you if they have not — because **deleting the
`WekaPolicy` does not detach the data-path ENIs.** They are released when the
node terminates, not when the policy goes away (see [Teardown](deployment.md#teardown)). If
the extended resource is still on the node, the client in beat 2 schedules
immediately and there is no negative case to show; you need to recycle the node
group for a clean take. Everything else in the demo works regardless.

## Performance numbers

`09-fio-job.yaml` ships so that readers can run it on their own cluster. **Its
output is not published here, and must not be published elsewhere without an
approved WEKA Fact Note** — any throughput, IOPS, latency or comparison figure
is a Tier 3 brand review item, which means the comparison methodology has to be
disclosed and product marketing has to sign off.

There is a technical reason as well as a process one: it is one fio process on
one client node, against a directory-backed PVC with a hard quota, on whatever
instance type is in the node group, with a file small enough to finish inside
two minutes. That tells you the data path works and is not pathologically
slow. It does not size anything. The file's header comment says the same thing
at more length.

---

---

*[← back to the README](../README.md)*
