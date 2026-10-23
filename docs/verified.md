# Verified end to end

*[← back to the README](../README.md)*

This is not a sketch. It was deployed in `eu-west-1` and taken all the way to a
mounted `ReadWriteMany` PVC, and every number below was observed rather than
assumed.

> ### Re-verified on WEKA 5.1.32.19 — **five times**: twice 2026-09-29, 2026-10-22, and twice 2026-10-23.
>
> This table was previously a 4.4.37 run carrying a warning that 5.1 was
> unmeasured. It has now been deployed from empty **three times** on
> **WEKA 5.1.32.19, operator v1.16.0, EKS 1.32**, with
> `client_node_count = 3` and the node group pinned to the backends' AZ.
>
> Runs 1 and 2 were the same day; **run 3 was three weeks later, 2026-10-22**,
> from a clean account and following the docs as written. Every figure below
> reproduced on run 3 — no state differences across three weeks and three
> deployments. Where runs differ the row says so, and the differences remain
> *timing*, never state.
>
> Run 3 also corrected two things this page and its siblings had wrong, both
> recorded in their own rows below: the **Secrets Manager naming**, and the
> claim that a reserved secret name blocks a re-apply.
>
> **Run 4 existed to exercise what runs 1–3 had only inspected**, and it
> closed every open item on this page: beat 2 ran for real *and* took its skip
> path in the same session, the live-mode failure footer and
> `fill-secrets.sh` were driven end to end, and `weka alerts` finally
> explained the alert count. It also produced a fresh mistake worth keeping —
> see the two gaps at the end.
>
> **Run 5 closed those gaps' fixes and the last open question.** The three
> code paths run 4 had to ship untested were each exercised against a live
> cluster, beat 2 ran for real again (9m24s end to end, five beats, exit 0),
> and the `NoCgroupsConfigured` alert was finally traced to its cause rather
> than left as a guess. **There is now nothing on this page resting on
> inspection alone.**
>
> What did **not** change from 4.4.37 either: the HugePages figure, the CPU
> pinning, the `weka-nics` count, the quota enforcement and the PV
> auto-delete.

| Check | Observed (5.1.32.19) |
|---|---|
| WEKA cluster | `WekaIO v5.1.32.19` · `status: OK (12 backend containers UP, 12 drives UP)` · protection `3+2 (fully protected)` · hot spare 7.36 TiB · 36.82 TiB. Run 3 identical, read from the status Lambda: `status: OK`, `io_status: STARTED`, `stripe_data_drives: 3` + `stripe_protection_drives: 2`, hot spare 1, drives 12/12, io nodes 42/42, 40.49 TB raw |
| Clients joined | **`clients: 3 connected`** — read off the cluster on run 2 after the clients came up. Run 3 confirmed it from the module's own status Lambda instead, which needs no WEKA credentials: `hosts.clients.active = 3`, `backends.active = 12`, `total_count = 15`. `weka cluster container` showed all three `UP`, 4 cores and 6.36 GB each, release `5.1.32.19`, one per node. (On run 1 this figure was *not* read; the table briefly claimed it anyway, which was wrong and is the reason it is now quoted with its source.) |
| AZ placement | all 6 backends **and** all 3 clients in `eu-west-1a`; no cross-AZ storage path |
| HugePages | node `hugepages-2Mi` allocatable `7Gi` on all three nodes |
| CPU pinning | node `cpu` allocatable **30 of 32** on all three — `strict-cpu-reservation` doing its job |
| maxPods | `29`, matching the CNI's addressable IPs with `MAX_ENI=1` |
| Instance facts (EC2 API) | `m6i.8xlarge`: 32 vCPU, 16 cores, 2 threads/core, 8 ENIs, 30 IPv4/ENI — so 29 addressable pods and sibling index 16. All five `preflight.tf` preconditions passed at plan time |
| Data NICs | `weka.io/weka-nics: 4` on all three nodes after the `ensure-nics` policy reached `Done`. **Timing depends on what the operator already knows**: 40 s on run 1, where the policy was applied *after* the client had been through discovery, but **180 s on run 2** applying it cold in the documented order. Expect three minutes, not forty seconds. **Run 3 took ~7 minutes** — longest yet, and for a third reason again: the policy's `weka-dsc` pods were pulling the multi-GiB client image onto cold nodes. The variable is never the policy, it is what the node has already pulled |
| Beat 2 (negative case) | **reproduces**, but later than expected: `0/3 nodes are available: 1 Insufficient weka.io/weka-nics`. ~8 min after applying `03`, because a discovery-mode pod pulls the image first. Policy applied → weka-nics on all 3 nodes at 40 s → 0 unschedulable at 50 s |
| PVC | `Bound`, `RWX`, 1Gi on `weka-dir`; `df -hT` reports `default wekafs 10.0G` for the 10Gi demo claim. Run 3: the smoke-test PVC bound in **under 16 s** and the pod completed ~30 s later, `default wekafs 1.0G` inside |
| Quota | the mount reports the PVC's size, not the cluster's — `capacityEnforcement: HARD` applying a real quota |
| RWX multi-writer | 3 replicas, one per node. Single snapshot, run 1: **100 lines, 100 summed across 3 hostnames, 0 malformed**. Run 2: **85 / 85 / 3 / 0**. Run 3: **38 lines, 13 / 13 / 12 across 3 hostnames, 0 malformed**. Concurrent `O_APPEND` with no lost or torn writes, three times |
| Persistence across node loss | sentinel written on one node, pod deleted, node cordoned, pod rescheduled elsewhere, sentinel read back intact |
| fio job | ran to completion: `fio-3.39` from Alpine community, all three stanzas as separate run groups, 0 ENOSPC inside the quota. **No figures recorded here — see the Fact Note requirement** |
| PodDisruptionBudget | **does not work for the client pods.** `disruptionsAllowed: 0` permanently, `wekacontainers.weka.weka.io does not implement the scale subresource`; every eviction refused. The node group's own `maxUnavailablePercentage: 33` already paces rolls |
| Teardown: PVs | both PVs auto-deleted on PVC delete, i.e. the CSI plugin removed the backing WEKA directories |
| Teardown: first pass | fails on `InvalidPlacementGroup.InUse`, **all five runs** — completely reliable. The duration is **bimodal**, and the swing factor is the shared security group: **22m43s / 22m52s / 22m33s** on runs 1-3, **11m12s / 10m46s** on runs 4-5. `aws_security_group.weka` took **14m10s** and **13m50s** on the slow runs and **1 second** on both fast ones, which accounts for the gap almost exactly. The EKS node group is a near-constant ~8m (8m21s, 8m11s, 8m11s) and never the decider. The security group cannot go until every ENI referencing it has gone — backends, EKS nodes *and* the Secrets Manager endpoint — so the plausible mechanism is simply whether Terraform attempts it before or after the node group has finished releasing them; that is a scheduling race, not a property of the deployment. Budget 25 minutes. Resources destroyed: 168 of 173 on runs 1-2, 145 of 150 on runs 3-5. Exit code **1**, which a `\| tail` pipeline will hide from you |
| Teardown: second pass | **~40s / 15s / 14s / 14s / 14s**, the remaining 5 (placement group, VPC, two subnets, `time_static`), exit 0, state empty. All five runs, identical leftover set — the genuinely stable part of the teardown |
| Budget alerts | **work, with no confirmation step.** No confirmation email is sent for an `EMAIL` subscriber and none is needed. Proven with a throwaway $0.01 daily budget against $31.81 of spend: `NotificationState` went to `ALARM` on creation and the mail arrived from `no-reply@budgets.alerts.amazonaws.com`. The real budget stayed at `OK` through both runs because $31.81 never neared $600/day — quiet because nothing was wrong |
| Teardown: budget | destroyed with the stack on both runs — `describe-budgets` returns nothing afterwards. So it cannot warn you about a teardown that failed |
| Teardown: orphan sweep | Clean on every run that was swept. After run 5: 9 instances `terminated`, and nothing left for EKS clusters, NAT gateways, the VPC, unassociated EIPs, DynamoDB tables, Step Functions, available EBS volumes or ENIs in the VPC CIDR. The budget goes with the stack. Only the 4 scheduled secrets remain, as designed |
| Teardown: secrets purged | After run 4 the account held **12** scheduled secrets — three complete sets from three teardowns (`-OBm9`, `-s7gV`, `-Oi84`). All 12 purged cleanly, confirming both that they accumulate exactly as described (5 per teardown, minus the self-signed-cert one this deployment does not create) and that nothing about the accumulation is harmful. See the two rows above for what the purge corrected about its own documented procedure |
| Teardown: orphans | none billing. Instances `terminated`, volumes and ENIs gone, NAT gateway `deleted`, budget destroyed with the stack. 8 KMS keys left `PendingDeletion` (normal). 4 secrets left scheduled for deletion — **their values stay restorable and readable for the whole 30-day window**, so they were purged by hand afterwards; see the two rows below. **Run 3 found that purge had not fully taken**: four 2026-09-29 secrets were still sitting in their deletion window 23 days later, which is exactly the intermittent-force-delete behaviour two rows down, caught in the wild |
| Teardown: tag sweep | the Resource Groups Tagging API still listed **90 resources** tagged `Project=weka-eks-demo` with state empty and everything gone — all of them terminated or pending deletion. Do not trust it as an orphan check |
| Teardown: purging a secret | **Corrected on 2026-10-23 by purging 12 at once.** This row used to say force-delete was intermittent and that `restore-secret` first made it deterministic. Neither half survived the larger sample. `delete-secret --force-delete-without-recovery` **worked on all 12, first call** — each returned the ARN and a fresh `DeletionDate`, and each was genuinely gone. `restore-secret` against an already-scheduled secret **fails** with `ResourceNotFoundException` every time, so the step that was supposed to add determinism is a no-op that merely errors — and under `set -e` it aborts before the delete runs. The earlier observation (run 1: 3 of 4 survived) stays on the record as possibly a different condition, but the procedure is now the single force-delete |
| Teardown: verifying a purge | Both views lag, and `describe-secret` is not the reliable oracle this page once claimed. `list-secrets` reported **4 secrets remaining when 3 were already gone**. `describe-secret` run *immediately* after each force-delete reported the secret **still present for all 12**, every one of which was already gone — a false negative 12 times out of 12. **And the settling time is not constant.** A later purge of 4 secrets still reported all four present after a **5-second** pause, and they had cleared a few seconds later; the 12 before them settled faster. So a fixed `sleep` cannot be right — poll until `describe-secret` returns `ResourceNotFoundException`, and never conclude a purge failed from one immediate check |
| Secrets Manager naming | **The names cannot be constructed by hand.** Two traps, both measured on run 3: the middle path segment is `<prefix>-<cluster_name>` (the prefix appears **twice** — `weka/weka-poc/…`, not `weka/poc/…`), and every name carries a **random 4-character suffix** from `random_password.suffix` in the module's `secrets.tf`. A hand-built id returns `ResourceNotFoundException` — *the same answer a genuinely deleted secret gives* — so it reports "all clear" regardless of reality. This page's own preflight fell for it. Get the id from `terraform output -raw weka_password_secret_id`, or list by substring |
| Secret names do **not** block a re-apply (confirmed 3x) | The docs claimed the 30-day reservation meant you could not re-apply under the same `prefix`/`cluster_name` inside the window. **False, and disproved directly on run 3**: four secrets from the 2026-09-29 teardown were still in their deletion window when run 3 applied under the *same* prefix and cluster name, created its own set with a different suffix, and succeeded. Both sets coexisted in the account. **Run 4 made it three**: `-OBm9` (2026-09-29), `-s7gV` (2026-10-22) and `-Oi84` (2026-10-23) were all sitting in the account together afterwards, from three deployments under identical `prefix` and `cluster_name`. The random suffix makes collisions impossible, so purge for tidiness, not necessity |
| Beat 2 needs a **recycled** node group | The negative case cannot be shown on a node group that has already run the NIC policy. The data-path ENIs are released only when the node **terminates**, not when the `WekaPolicy` is deleted, so the nodes keep advertising `weka.io/weka-nics` and the client schedules immediately. Run 3 hit this: `demo.sh` correctly detected it, then waited the full 900 s anyway and asserted the beat had proved its point. Both defects fixed — the wait is now skipped and the summary reports `NOT DEMONSTRATED` |
| Account-level `AutoStop` | Not this repo's doing, and worth checking before you deploy anywhere shared. The account used for run 3 runs an `AutoTag` Lambda (every 15 min) that stamps `AllowStop=6` on any instance lacking `AllowStop`/`PreventStop`, and an `AutoStop` Lambda (every 10 min) that stops anything past that deadline. All 9 instances were tagged within 15 minutes of launch. **Tighter than `ttl_hours = 8`**, and because the backends are `i3en` instance-store, a stop is **data loss, not a pause**. See [Cost controls](cost-controls.md) |
| Cluster alerts | **Explained on run 4 — all five are expected, none indicate a fault.** `active_alerts_count` is **2** on a freshly formed cluster and **5** once three clients join; both figures reproduced exactly across runs 3 and 4, so the pattern is systematic. Reading `weka alerts` finally identified them: the baseline two are `NoClusterLicense` and `SystemDefinedTLS`, both timestamped at cluster formation and both correct for an unlicensed POC with an auto-generated certificate. The other three are **one `NoCgroupsConfigured` per client node**, timestamped at client join and naming the EKS workers by host id. 2 + 3 = 5. (`weka alerts` also shows a COUNT column — 6 for the cgroups alert — which counts occurrences, not distinct alerts, and does not line up with `active_alerts_count`.) |
| `NoCgroupsConfigured` on the client nodes | **Examined on run 5. The alert is not about the node, and the CPU pinning does work.** The node runs **cgroup v2** (`stat -fc %T /sys/fs/cgroup` = `cgroup2fs`), kubelet's CPU manager is `static`, and the client container is confined by a real cpuset cgroup under `/sys/fs/cgroup/kubepods.slice/…/cpuset.cpus.effective`. `cpu_manager_state` on the node shows `"weka-container":"1-5,17-20"` against a `defaultCpuSet` of `6-15,21-31` — so CPUs **0 and 16 appear in neither**, which is `reservedSystemCPUs` working exactly as `node-userdata.tf` intends (`cpu0` reports siblings `0,16`, confirming `system_cpu_sibling_index = 16`). What WEKA is reporting is the absence of **its own** cgroup configuration, not the host's |
| Client CPUs are only **partly** HT-isolated | A real gap, found while checking the above, and not something any run would have surfaced on its own. The container holds 9 CPUs — `1-5,17-20` — and the sibling pairs are `(1,17) (2,18) (3,19) (4,20)`: four complete physical cores, plus **CPU 5 on its own**. CPU 5's sibling is **21**, which sits in `defaultCpuSet` and is therefore available to general workloads. So one WEKA thread shares a physical core, and its L1 and L2, with whatever the scheduler puts on CPU 21. That is precisely the interference `preflight.tf` describes when it guards the CPU 0/16 pair — the repo prevents it for the kubelet and an odd-sized allocation reintroduces it elsewhere. Nothing measured slower because of it, and no figure on this page moved; it is recorded as a real property of the current sizing, not a fault |

Timings measured on this 5.1.32.19 run: **~13 min** for `terraform apply`
(first attempt clean — no `InsufficientRolePermissions` race this time),
**~3 min** for the WEKA cluster to clusterize after that, ~2 min for nodes to
register, and **~5 min** for the multi-GiB `weka-in-container` pull on a cold
node. From `apply` to a mounted RWX PVC: about **50 minutes**, most of it
waiting on image pulls and the client join.

Run 3 (2026-10-22) matched that shape. **150 resources, first attempt clean
again** — two clean cold applies in a row, so the `InsufficientRolePermissions`
race is worth keeping documented but is clearly not the common case. The
longest single resource was the EKS control plane at **7m53s**. Clusterization
finished **9m47s after the backends launched** (12:17:05 → 12:26:52 UTC),
comfortably inside the 15–25 minutes this repo tells you to allow — that
window is conservative, not typical. The slow parts were, again, entirely
image pulls: ~7 minutes for the NIC policy's pods and ~12 minutes for the
client containers to come back during the demo.

That is faster than the hour the 4.4.37 run suggested, but budget the hour
anyway — the pull dominates and it comes over a single NAT gateway.

**Teardown takes longer than you would expect: about 23 minutes for the first
pass plus a second one.** Total lifetime of this deployment, first `apply` to
an empty state, was **1h18m**, with the six `i3en.6xlarge` up for roughly an
hour. Budget the teardown time when you plan the spend — it is not free
minutes at the end.

---

# What run 4 settled, and the two gaps it opened

Everything this section previously listed as unverified was exercised on
2026-10-23 and is now folded into the table above. For the record, because
"we ran it" is worth less than what the run actually showed:

| Was open | Outcome |
|---|---|
| `weka alerts` | Read. All five alerts identified and expected — see the two alert rows above |
| Beat 2's 2026-10-22 fixes | **Both paths exercised in one session.** On a pristine node group it produced the real refusal, `0/3 nodes are available: 1 Insufficient weka.io/weka-nics`. On the rerun, with the ENIs now attached, it took the skip path and the summary said `NOT DEMONSTRATED`. A fix that only ever skipped would have looked identical on the second run alone; running both is what proves it discriminates |
| `fill-secrets.sh` success path | Drove both files correctly, password never displayed |
| Live-mode failure footer | Printed the `MISSING prerequisite` line alone, with no `DRIFT` line, because no drift had occurred |

The skip is worth real time: the same demo took **26m14s** when beat 2 waited
out its 900-second timeout, and **2m17s** when it skipped.

> **Both gaps below were fixed on 2026-10-23 and the fixes were verified on
> run 5 the same day.** They shipped untested because the cluster was already
> being destroyed; run 5 existed to close that, and did. Each path was
> exercised in the only state that can exercise it:
>
> | Path | How it was proven |
> |---|---|
> | Applied-object checks | All three branches: `no 01-…yaml yet` with the file absent, `not applied yet (kubectl apply -f …)` with it filled but unapplied, `applied` once applied |
> | `demo.sh` secret preflight | Refused **twice**, exit 1 — first naming `weka-client-secret`, then after applying it, naming `csi-wekafs-api-secret`. Under a second each, against the 26 minutes the same missing secret cost on run 4 |
> | `fill-secrets.sh` endpoints | Wrote the live cluster's own three backend addresses, `<ip>:14000` each, verified by decoding the base64 back out of `04` and diffing against `terraform output -raw weka_backend_ips_command \| bash` — in place of the template's `10.0.1.10`. (Deliberately not quoting the addresses here: they belonged to a cluster that no longer exists, and this page should not hand the next reader dead infrastructure detail.) |
>
> The preflight also earned its place unprompted: it found `01` and `04` left
> on disk from run 4, with `endpoints` still pointing at that destroyed
> cluster's backends — the stale-credential trap
> [Deploying](deployment.md) warns about, surfaced without being looked for.

## Gap 1: nothing checks that the manifests are actually APPLIED

Run 4 deliberately skipped `02` and `03` so that beat 2 would have a clean
node group — `demo.sh` applies both itself. It also skipped `01` and `04`,
which was simply wrong: `demo.sh`'s header says "everything **through**
`05-storageclass-dir.yaml` applied", and that includes the two secrets.

The cost of that one-line mistake was about 25 minutes, and almost none of it
looked like a missing secret:

- client pods sat in `ContainerCreating` for 24 minutes
- the CSI controller and all three node plugins went `CrashLoopBackOff`
- the only honest message was buried in the CSI log: `No frontends found in
  driver interface, client software may not be running`
- the visible symptom was a `Pending` PVC and a failed persistence check,
  three beats downstream

The actual cause was one event on the client pod: `MountVolume.SetUp failed
for volume "weka-credentials" : secret "weka-client-secret" not found`.

**`./check-manifests.sh` passed, fully green, immediately before this.** That
is not a bug in it — it compares manifest *files* against Terraform and has
no notion of cluster state — but it does mean a green check reads as "ready
to go" when it cannot see the thing that was wrong. `demo.sh` checked only
for the StorageClass. A preflight asserting the objects it needs are
*present* would have failed in a second instead of twenty minutes.

**Fixed both ends.** `check-manifests.sh` now reports whether
`weka-client-secret`, `csi-wekafs-api-secret` and the `weka-dir` StorageClass
are actually applied, as `NOTE` rather than `MISSING` — a filled-in file that
has not been applied yet is a legitimate mid-walkthrough state, not an error.
`demo.sh` makes the same check a hard `die`, because by the time it runs it is
not legitimate: it names the file to apply and says what the failure would
otherwise have looked like three beats later.

## Gap 2: `fill-secrets.sh` does not set `04`'s `endpoints`

It fills the password in both files and the join token in `01`, and stops
there. `endpoints` in `04-csi-api-secret.yaml` keeps whatever the `.example`
ships — `10.0.1.10:14000` and friends — which points the CSI plugin at
addresses that do not exist.

It was set by hand on runs 3 and 4, so neither run caught it as a failure.
Nothing would have: `check-manifests.sh` looks for `REPLACE_ME`, and the
placeholder endpoints are valid-looking base64 of a plausible address. The
two tools together let you ship a credential file that was complete,
consistent, and wrong.

**Fixed.** `fill-secrets.sh` now resolves the backend IPs via
`weka_backend_ips_command` and writes `endpoints` itself. It greps the
addresses out of that command's output rather than trusting its formatting,
so a future change from `--output text` to JSON upstream cannot quietly
produce an endpoints string made of punctuation, and it refuses to write
fewer than two endpoints.

---

*[← back to the README](../README.md)*
