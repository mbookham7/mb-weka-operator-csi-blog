# Verified end to end

*[← back to the README](../README.md)*

This is not a sketch. It was deployed in `eu-west-1` and taken all the way to a
mounted `ReadWriteMany` PVC, and every number below was observed rather than
assumed.

> ### ⚠️ Observed on WEKA 4.4.37. Not yet re-verified on 5.1.
>
> The repo now targets **5.1.32.19** (see [The WEKA release itself is not a
> module version](versions.md#the-weka-release-itself-is-not-a-module-version)). The table
> below is the **4.4.37** run, reproduced verbatim, and is left that way on
> purpose: re-stating a 4.4 measurement as though it had been taken on 5.1
> would make the most valuable thing in this repo untrue.
>
> What is expected to change on 5.1, and is therefore **unmeasured** here:
>
> - the `WekaIO v…` version string, obviously
> - the client pod's HugePages request, and with it the
>   `client_hugepages_headroom_mib` default — the `6256Mi`-for-4-cores figure
>   below is a 4.4 operator/client observation and the arithmetic is not
>   documented anywhere, so it has to be re-measured rather than predicted
> - the port count the client allocates from `basePort`, which drops to 260
>   from 500 with Operator 1.10 + WEKA 5.1.0 (the reserved range is wide enough
>   for both — see the comment in `node-userdata.tf`)
> - timings, since the `weka-in-container` image is a different size
>
> Separately from the release change, **the topology has moved since this run
> too**: the client node group is now pinned to the backends' availability
> zone (see [The client node group](node-group.md)). The verified deployment
> used `client_node_count = 1`, so it had one node and no cross-AZ path to
> speak of — but any figure you take from a multi-node run today is on a
> different network layout from the one above.
>
> Everything else in the table is a property of the VPC, the node prep and the
> CSI plumbing rather than of the WEKA release, so it is expected to hold. That
> is an expectation, not a measurement. **Re-run the deployment on 5.1 and
> replace this block with the observed values before publishing anything off
> this table.**

| Check | Observed (4.4.37) |
|---|---|
| WEKA cluster | `WekaIO v4.4.37` · `status: OK (12 backend containers UP, 12 drives UP)` · protection `3+2 (Fully protected)` · 36.82 TiB |
| Client joined | `clients: 1 connected`; `weka cluster container` shows the EKS node `UP`, 4 cores, 6.35 GB |
| HugePages | node `hugepages-2Mi` allocatable `7Gi`, `HugePages_Total: 3584` |
| CPU pinning | node `cpu` allocatable **30 of 32** — CPU 0 and its sibling excluded from the shared pool, which is `strict-cpu-reservation` doing its job |
| HT sibling | `/sys/devices/system/cpu/cpu0/topology/thread_siblings_list` = `0,16` on `m6i.8xlarge`, confirming the `system_cpu_sibling_index` default |
| Data NICs | `weka.io/weka-nics: 4` advertised after the `ensure-nics` policy reached `Done` |
| ENI ownership | all 4 data NICs tagged `weka_reason=ensure_nics`; **zero** CNI-created secondary ENIs, so nothing for WEKA to poach |
| PVC | `Bound`, `RWX`, 1Gi on `weka-dir`; `df -hT` inside the pod reports `default wekafs 1.0G` |
| Quota | the mount shows 1.0G, so `capacityEnforcement: HARD` is applying a real quota |
| Teardown | PV auto-deleted, i.e. the CSI plugin removed the backing WEKA directory |

Timings, for planning, also measured on the 4.4.37 run: ~20 min for
`terraform apply`, a further ~7 min for the WEKA cluster to clusterize, ~90 s
for a node to register, and a few minutes for the multi-GiB
`weka-in-container` pull. Budget an hour from nothing to a mounted PVC.

Every row in the table was re-verified on a second, independent 4.4.37
deployment from an empty state — including the 3584-page HugePages
reservation from a cold boot, and the addon ordering in a single `apply` pass.
Neither run was on 5.1.

---

*[← back to the README](../README.md)*
