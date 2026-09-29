# Verified end to end

*[← back to the README](../README.md)*

This is not a sketch. It was deployed in `eu-west-1` and taken all the way to a
mounted `ReadWriteMany` PVC, and every number below was observed rather than
assumed.

> ### Re-verified on WEKA 5.1.32.19, 2026-09-29.
>
> This table was previously a 4.4.37 run carrying a warning that 5.1 was
> unmeasured. It has now been re-deployed from empty on **WEKA 5.1.32.19,
> operator v1.16.0, EKS 1.32**, with `client_node_count = 3` and the node
> group pinned to the backends' AZ, and every row below re-observed.
>
> Two rows changed and are noted inline. What did **not** change is worth
> saying: the HugePages figure, the CPU pinning, the `weka-nics` count, the
> quota enforcement and the PV auto-delete are all identical to 4.4.37.

| Check | Observed (5.1.32.19) |
|---|---|
| WEKA cluster | `WekaIO v5.1.32.19` · `status: OK (12 backend containers UP, 12 drives UP)` · protection `3+2 (fully protected)` · hot spare 7.36 TiB · 36.82 TiB |
| Clients joined | 3 client pods `Running`/`Ready` on 3 distinct nodes, and all three served `wekafs` mounts — the RWX test wrote through `/data` from a pod on each node, which a client that had not joined could not do. **The cluster-side `clients: N connected` figure was not re-read after the clients came up**, so it is not quoted here. The only `weka status` capture from this run predates the client pods and says `clients: 0 connected` |
| AZ placement | all 6 backends **and** all 3 clients in `eu-west-1a`; no cross-AZ storage path |
| HugePages | node `hugepages-2Mi` allocatable `7Gi` on all three nodes |
| CPU pinning | node `cpu` allocatable **30 of 32** on all three — `strict-cpu-reservation` doing its job |
| maxPods | `29`, matching the CNI's addressable IPs with `MAX_ENI=1` |
| Instance facts (EC2 API) | `m6i.8xlarge`: 32 vCPU, 16 cores, 2 threads/core, 8 ENIs, 30 IPv4/ENI — so 29 addressable pods and sibling index 16. All five `preflight.tf` preconditions passed at plan time |
| Data NICs | `weka.io/weka-nics: 4` on all three nodes after the `ensure-nics` policy reached `Done` |
| Beat 2 (negative case) | **reproduces**, but later than expected: `0/3 nodes are available: 1 Insufficient weka.io/weka-nics`. ~8 min after applying `03`, because a discovery-mode pod pulls the image first. Policy applied → weka-nics on all 3 nodes at 40 s → 0 unschedulable at 50 s |
| PVC | `Bound`, `RWX`, 1Gi on `weka-dir`; `df -hT` reports `default wekafs 10.0G` for the 10Gi demo claim |
| Quota | the mount reports the PVC's size, not the cluster's — `capacityEnforcement: HARD` applying a real quota |
| RWX multi-writer | 3 replicas, one per node. Single snapshot: **100 lines, 100 summed across 3 distinct hostnames, 0 malformed** — concurrent `O_APPEND` with no lost or torn writes |
| Persistence across node loss | sentinel written on one node, pod deleted, node cordoned, pod rescheduled elsewhere, sentinel read back intact |
| fio job | ran to completion: `fio-3.39` from Alpine community, all three stanzas as separate run groups, 0 ENOSPC inside the quota. **No figures recorded here — see the Fact Note requirement** |
| PodDisruptionBudget | **does not work for the client pods.** `disruptionsAllowed: 0` permanently, `wekacontainers.weka.weka.io does not implement the scale subresource`; every eviction refused. The node group's own `maxUnavailablePercentage: 33` already paces rolls |
| Teardown | both PVs auto-deleted on PVC delete, i.e. the CSI plugin removed the backing WEKA directories |

Timings measured on this 5.1.32.19 run: **~13 min** for `terraform apply`
(first attempt clean — no `InsufficientRolePermissions` race this time),
**~3 min** for the WEKA cluster to clusterize after that, ~2 min for nodes to
register, and **~5 min** for the multi-GiB `weka-in-container` pull on a cold
node. From `apply` to a mounted RWX PVC: about **50 minutes**, most of it
waiting on image pulls and the client join.

That is faster than the hour the 4.4.37 run suggested, but budget the hour
anyway — the pull dominates and it comes over a single NAT gateway.

---

*[← back to the README](../README.md)*
