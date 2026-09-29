# Verified end to end

*[← back to the README](../README.md)*

This is not a sketch. It was deployed in `eu-west-1` and taken all the way to a
mounted `ReadWriteMany` PVC, and every number below was observed rather than
assumed.

> ### Re-verified on WEKA 5.1.32.19 — **twice**, 2026-09-29.
>
> This table was previously a 4.4.37 run carrying a warning that 5.1 was
> unmeasured. It has now been deployed from empty **twice** on the same day,
> on **WEKA 5.1.32.19, operator v1.16.0, EKS 1.32**, with
> `client_node_count = 3` and the node group pinned to the backends' AZ.
>
> The second run existed to test the repo's own fixes rather than the
> product, and it followed `terraform output -raw next_steps` verbatim
> instead of improvising. Every figure below reproduced. Where the two runs
> differ the row says so — and the differences are all *timing*, never state.
>
> What did **not** change from 4.4.37 either: the HugePages figure, the CPU
> pinning, the `weka-nics` count, the quota enforcement and the PV
> auto-delete.

| Check | Observed (5.1.32.19) |
|---|---|
| WEKA cluster | `WekaIO v5.1.32.19` · `status: OK (12 backend containers UP, 12 drives UP)` · protection `3+2 (fully protected)` · hot spare 7.36 TiB · 36.82 TiB |
| Clients joined | **`clients: 3 connected`** — read off the cluster on run 2 after the clients came up. `weka cluster container` showed all three `UP`, 4 cores and 6.36 GB each, release `5.1.32.19`, one per node. (On run 1 this figure was *not* read; the table briefly claimed it anyway, which was wrong and is the reason it is now quoted with its source.) |
| AZ placement | all 6 backends **and** all 3 clients in `eu-west-1a`; no cross-AZ storage path |
| HugePages | node `hugepages-2Mi` allocatable `7Gi` on all three nodes |
| CPU pinning | node `cpu` allocatable **30 of 32** on all three — `strict-cpu-reservation` doing its job |
| maxPods | `29`, matching the CNI's addressable IPs with `MAX_ENI=1` |
| Instance facts (EC2 API) | `m6i.8xlarge`: 32 vCPU, 16 cores, 2 threads/core, 8 ENIs, 30 IPv4/ENI — so 29 addressable pods and sibling index 16. All five `preflight.tf` preconditions passed at plan time |
| Data NICs | `weka.io/weka-nics: 4` on all three nodes after the `ensure-nics` policy reached `Done`. **Timing depends on what the operator already knows**: 40 s on run 1, where the policy was applied *after* the client had been through discovery, but **180 s on run 2** applying it cold in the documented order. Expect three minutes, not forty seconds |
| Beat 2 (negative case) | **reproduces**, but later than expected: `0/3 nodes are available: 1 Insufficient weka.io/weka-nics`. ~8 min after applying `03`, because a discovery-mode pod pulls the image first. Policy applied → weka-nics on all 3 nodes at 40 s → 0 unschedulable at 50 s |
| PVC | `Bound`, `RWX`, 1Gi on `weka-dir`; `df -hT` reports `default wekafs 10.0G` for the 10Gi demo claim |
| Quota | the mount reports the PVC's size, not the cluster's — `capacityEnforcement: HARD` applying a real quota |
| RWX multi-writer | 3 replicas, one per node. Single snapshot, run 1: **100 lines, 100 summed across 3 hostnames, 0 malformed**. Run 2: **85 / 85 / 3 / 0**. Concurrent `O_APPEND` with no lost or torn writes, twice |
| Persistence across node loss | sentinel written on one node, pod deleted, node cordoned, pod rescheduled elsewhere, sentinel read back intact |
| fio job | ran to completion: `fio-3.39` from Alpine community, all three stanzas as separate run groups, 0 ENOSPC inside the quota. **No figures recorded here — see the Fact Note requirement** |
| PodDisruptionBudget | **does not work for the client pods.** `disruptionsAllowed: 0` permanently, `wekacontainers.weka.weka.io does not implement the scale subresource`; every eviction refused. The node group's own `maxUnavailablePercentage: 33` already paces rolls |
| Teardown: PVs | both PVs auto-deleted on PVC delete, i.e. the CSI plugin removed the backing WEKA directories |
| Teardown: first pass | fails on `InvalidPlacementGroup.InUse`, both runs. **22m43s** and **22m52s** — nine seconds apart, so treat ~23 minutes as the figure. 168 of 173 resources; the shared security group alone took 14m10s. Exit code **1**, which a `\| tail` pipeline will hide from you |
| Teardown: second pass | **~40s** / **15s**, the remaining 5 (placement group, VPC, two subnets, `time_static`), exit 0, state empty. Both runs |
| Teardown: budget | destroyed with the stack on both runs — `describe-budgets` returns nothing afterwards. So it cannot warn you about a teardown that failed |
| Teardown: orphans | none billing. Instances `terminated`, volumes and ENIs gone, NAT gateway `deleted`, budget destroyed with the stack. 8 KMS keys left `PendingDeletion` (normal). 4 secrets left scheduled for deletion — **their values stay restorable and readable for the whole 30-day window**, so they were purged by hand afterwards; see the two rows below |
| Teardown: tag sweep | the Resource Groups Tagging API still listed **90 resources** tagged `Project=weka-eks-demo` with state empty and everything gone — all of them terminated or pending deletion. Do not trust it as an orphan check |
| Teardown: purging a secret | `delete-secret --force-delete-without-recovery` against an already-scheduled secret is **intermittent**. Run 1: 3 of 4 survived it, returning success while only re-stamping `DeletedDate`; the 4th deleted. Run 2: the one tested deleted on the first call. So it works often enough to look reliable and fails often enough to leave a name reserved — always use `restore-secret` then force-delete, and confirm with `describe-secret` |
| Teardown: `list-secrets` lag | reported **4 secrets remaining when 3 were already gone**. `describe-secret` returning `ResourceNotFoundException` is the only reliable confirmation — the same "trust the service API, not the aggregate view" lesson as the tag sweep above |

Timings measured on this 5.1.32.19 run: **~13 min** for `terraform apply`
(first attempt clean — no `InsufficientRolePermissions` race this time),
**~3 min** for the WEKA cluster to clusterize after that, ~2 min for nodes to
register, and **~5 min** for the multi-GiB `weka-in-container` pull on a cold
node. From `apply` to a mounted RWX PVC: about **50 minutes**, most of it
waiting on image pulls and the client join.

That is faster than the hour the 4.4.37 run suggested, but budget the hour
anyway — the pull dominates and it comes over a single NAT gateway.

**Teardown takes longer than you would expect: about 23 minutes for the first
pass plus a second one.** Total lifetime of this deployment, first `apply` to
an empty state, was **1h18m**, with the six `i3en.6xlarge` up for roughly an
hour. Budget the teardown time when you plan the spend — it is not free
minutes at the end.

---

*[← back to the README](../README.md)*
