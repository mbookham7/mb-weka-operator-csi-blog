#!/usr/bin/env bash
#
# Drives the demo, in order, for a recording session.
#
# Five beats, each one proving something the previous one did not:
#
#   1  Node prep        the HugePages reservation and the CPU pinning that
#                       Terraform's user data did at first boot, read back off
#                       the live nodes
#   2  THE NEGATIVE     the WekaClient Pending on `1 Insufficient
#      CASE             weka.io/weka-nics`, then scheduling the moment the NIC
#                       policy is applied
#   3  The mount        a Bound PVC and `wekafs` with an enforced quota inside
#                       a pod
#   4  Shared writes    three pods on three nodes, one file, three hostnames
#   5  Node loss        data read back from a different node after the writer's
#                       node is cordoned out
#
# WHY BEAT 2 IS A DELIBERATE STEP AND NOT AN ACCIDENT
#
# Applying 03-weka-client.yaml without 02-weka-nics-policy.yaml is the single
# most instructive failure in this whole deployment: a perfectly healthy WEKA
# cluster, a perfectly healthy node, and a pod that will sit in Pending
# forever because an extended resource that only an operator CR can create
# does not exist yet. Everyone hits it once. It teaches what a DPDK data path
# actually needs from the cloud provider, and it is invisible in any
# quickstart that lists the files in the right order.
#
# It is also the beat most likely to be fumbled on camera, because getting
# back to the "before" state means deleting two custom resources in the right
# order. Hence --reset.
#
# Usage, from this directory:
#     ./demo.sh                 # paused between beats, for recording
#     ./demo.sh --no-pause      # straight through, unattended
#     ./demo.sh --reset         # back to the pre-demo state, then exit
#     ./demo.sh --help
#
# Prerequisites: everything through 05-storageclass-dir.yaml applied, i.e.
# 00-namespace-and-secrets.sh, both secret files, and the StorageClass.
# 02 and 03 are applied BY this script -- beat 2 is the whole point.
#
set -euo pipefail

cd "$(dirname "$0")"

NS="${NS:-weka-operator-system}"
DEPLOY="${DEPLOY:-weka-rwx-demo}"
PVC="${PVC:-weka-rwx-demo-pvc}"
NODE_LABEL="${NODE_LABEL:-weka.io/supports-clients=true}"

PAUSE=1
RESET_ONLY=0

# Beat 2 waits on an ENI attach, a driver load and a multi-GiB image pull, so
# it is the slow one by a wide margin. The README measures the pull in
# minutes on a cold node over a single NAT gateway.
CLIENT_TIMEOUT="${CLIENT_TIMEOUT:-900}"
PENDING_TIMEOUT="${PENDING_TIMEOUT:-180}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300}"

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed 's/^#\{1,\} \{0,1\}//; s/^#$//' | sed '$d'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --no-pause) PAUSE=0 ;;
    --reset)    RESET_ONLY=1 ;;
    -h|--help)  usage 0 ;;
    *)          printf 'unknown argument: %s\n\n' "$1" >&2; usage 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Presentation helpers
# ---------------------------------------------------------------------------
# Every command is echoed before it runs, so the recording shows what is being
# typed rather than just its output. `eval` because several of these are
# pipelines, and the string that gets echoed has to be the string that runs --
# an argv-based helper would print something subtly different from what
# executed, which is exactly the kind of thing a viewer spots.
banner() {
  printf '\n'
  printf '===========================================================================\n'
  printf ' %s\n' "$1"
  printf '===========================================================================\n'
}

explain() { printf '\n%s\n' "$1"; }

run() {
  printf '\n  $ %s\n\n' "$1"
  # shellcheck disable=SC2294  # the echoed string must be the string that runs
  eval "$1" || true
}

# Same as run(), but a non-zero exit is a real failure rather than expected
# demo output (beat 2 deliberately runs commands that fail).
run_strict() {
  printf '\n  $ %s\n\n' "$1"
  # shellcheck disable=SC2294
  eval "$1"
}

pause() {
  [ "$PAUSE" -eq 1 ] || return 0
  printf '\n'
  # -r so a backslash in whatever gets typed does not vanish; the value is
  # discarded anyway, this is just a gate.
  read -r -p "  [Enter] next: $1 " _ || true
}

die() { printf '\nERROR: %s\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Reset -- back to the pre-demo state so beat 2 can be rehearsed
# ---------------------------------------------------------------------------
# Order matters. The demo workloads hold the PVC, the PVC's mount is served by
# the WekaClient, and the WekaClient's pod needs the NIC policy's extended
# resource to have been scheduled in the first place. Tear down in the reverse
# of that.
#
# What this does NOT remove, on purpose: the operator, the CRDs, the pull
# secret, the two credential secrets, and the StorageClass. Those are the
# prerequisites the demo assumes, and re-installing the operator between takes
# would add ten minutes for no teaching value.
reset_state() {
  banner "RESET -- returning to the pre-demo state"

  explain "Removing the demo workloads first: they hold the PVC open, and a PVC
with a running pod on it does not delete."
  run "kubectl delete -f 09-fio-job.yaml --ignore-not-found"
  run "kubectl delete pod weka-persistence-probe --ignore-not-found"
  run "kubectl delete -f 07-rwx-multiwriter.yaml --ignore-not-found"

  explain "Now the client, then the policy. Deleting the WekaClient first means
the operator tears its pod down cleanly instead of losing the extended
resource out from under a running container."
  run "kubectl delete -f 03-weka-client.yaml --ignore-not-found"
  run "kubectl delete -f 02-weka-nics-policy.yaml --ignore-not-found"

  explain "Uncordoning anything 08-persistence-check.sh may have left cordoned
after an interrupted run."
  run "kubectl get nodes -l '$NODE_LABEL' -o name | xargs -r -n1 kubectl uncordon"

  # ---------------------------------------------------------------------
  # The part that decides whether beat 2 can actually be rehearsed
  # ---------------------------------------------------------------------
  # Deleting the WekaPolicy does NOT detach the data-path ENIs -- the README
  # teardown section records that they are released only when the node
  # terminates. If the node is still advertising weka.io/weka-nics after the
  # policy is gone, the WekaClient in beat 2 will schedule IMMEDIATELY and
  # there is no negative case to show.
  #
  # So check, and say so plainly rather than letting the take fail on camera.
  explain "Waiting for the nodes to stop advertising weka.io/weka-nics.
This is what makes beat 2 reproducible -- if the resource is still there, the
client pod will schedule straight away and there is nothing to demonstrate."

  local waited=0 remaining
  while [ "$waited" -lt 120 ]; do
    remaining=$(kubectl get nodes -l "$NODE_LABEL" -o json 2>/dev/null \
      | jq -r '[.items[] | select(.status.allocatable["weka.io/weka-nics"] != null)] | length')
    [ "${remaining:-0}" -eq 0 ] && break
    sleep 5
    waited=$((waited + 5))
  done

  run "kubectl get nodes -l '$NODE_LABEL' -o json | jq -r '.items[] | \"\\(.metadata.name)  weka-nics=\\(.status.allocatable[\"weka.io/weka-nics\"] // \"<absent>\")\"'"

  if [ "${remaining:-0}" -ne 0 ]; then
    printf '\n'
    printf '  WARNING: %s node(s) still advertise weka.io/weka-nics.\n' "$remaining"
    printf '\n'
    printf '  Beat 2 will NOT show a Pending pod in this state -- the client will\n'
    printf '  schedule immediately, because the extended resource it is waiting for\n'
    printf '  is still there.\n'
    printf '\n'
    printf '  The data-path ENIs the ensure-nics policy attached are not released\n'
    printf '  when the WekaPolicy is deleted, only when the node terminates. To get a\n'
    printf '  clean "before" state you have to recycle the node group:\n'
    printf '\n'
    printf '    aws eks update-nodegroup-version --force ...   # or scale to 0 and back\n'
    printf '\n'
    printf '  Everything else in the demo works fine as-is; it is only beat 2 that\n'
    printf '  depends on the resource being genuinely absent.\n'
  else
    printf '\n  Ready: no node advertises weka.io/weka-nics. Beat 2 will reproduce.\n'
  fi
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
command -v kubectl >/dev/null || die "kubectl not found"
command -v jq      >/dev/null || die "jq not found -- beat 1 and the reset check use it"
kubectl version --request-timeout=8s >/dev/null 2>&1 \
  || die "kubectl cannot reach a cluster -- check your kubeconfig context"

if [ "$RESET_ONLY" -eq 1 ]; then
  reset_state
  exit 0
fi

kubectl get namespace "$NS" >/dev/null 2>&1 \
  || die "namespace $NS not found -- run ./00-namespace-and-secrets.sh first"
kubectl get storageclass weka-dir >/dev/null 2>&1 \
  || die "storageclass weka-dir not found -- apply 05-storageclass-dir.yaml first"

printf '\nContext: %s\n' "$(kubectl config current-context)"
[ "$PAUSE" -eq 1 ] && printf 'Paused between beats. --no-pause to run straight through.\n'

# ===========================================================================
# Beat 1 -- node prep
# ===========================================================================
banner "BEAT 1 of 5 -- node prep, done by Terraform's user data at first boot"

explain "None of this can be done after the kubelet starts. HugePages can only
be reserved while physical memory is still unfragmented, and the kubelet only
reports hugepages-2Mi as allocatable if the pages already existed when it
made its first node status update. So it happens in user data, at first boot,
and this is us reading it back off the live nodes."

run "kubectl get nodes -L weka.io/supports-clients"

explain "HugePages, per node. Anything reporting 0 here means the reservation
did not apply, and the WekaClient pod will stay Pending on a resource the
node genuinely has the memory for. The fix is on the node, in
/var/log/weka-node-prep.log -- not in any manifest."

run "kubectl get nodes -o json | jq -r '.items[] | \"\\(.metadata.name)  hugepages-2Mi=\\(.status.allocatable[\"hugepages-2Mi\"])\"'"

explain "And the CPU pinning. On an m6i.8xlarge -- 32 vCPUs -- allocatable cpu
should read 30, not 32. CPU 0 and its HyperThreading sibling (CPU 16) are
reserved out of the shared pool by reservedSystemCPUs, so the WEKA cores and
the system daemons are not sharing execution units and L1/L2 with each other.
30 of 32 is strict-cpu-reservation doing its job; 32 of 32 means it is not."

run "kubectl get nodes -o json | jq -r '.items[] | \"\\(.metadata.name)  cpu=\\(.status.allocatable.cpu)  (capacity \\(.status.capacity.cpu))\"'"

pause "beat 2, the negative case"

# ===========================================================================
# Beat 2 -- THE negative case
# ===========================================================================
banner "BEAT 2 of 5 -- WekaClient with no NIC policy: 1 Insufficient weka.io/weka-nics"

explain "This is the most instructive failure in the deployment, so we are going
to cause it on purpose.

The WEKA client's data path is DPDK: it binds NICs directly from userspace and
cannot share the node's primary ENI with the kubelet and the VPC CNI. It needs
dedicated ENIs. Nothing in Terraform can attach them -- the node group creates
an instance with one ENI, and the CNI's extra ENIs are for pod IPs. Only the
ensure-nics WekaPolicy does it, and it then advertises them to the scheduler
as the extended resource weka.io/weka-nics.

So we apply the client WITHOUT the policy first."

explain "Starting from a clean slate, so the resource is genuinely absent."
run "kubectl delete -f 03-weka-client.yaml --ignore-not-found"
run "kubectl delete -f 02-weka-nics-policy.yaml --ignore-not-found"

run "kubectl get nodes -l '$NODE_LABEL' -o json | jq -r '.items[] | \"\\(.metadata.name)  weka-nics=\\(.status.allocatable[\"weka.io/weka-nics\"] // \"<absent>\")\"'"

if kubectl get nodes -l "$NODE_LABEL" -o json \
   | jq -e '[.items[] | select(.status.allocatable["weka.io/weka-nics"] != null)] | length > 0' >/dev/null 2>&1; then
  printf '\n'
  printf '  NOTE: a node still advertises weka.io/weka-nics, left over from a\n'
  printf '  previous run -- the ENIs are released only when the node terminates,\n'
  printf '  not when the WekaPolicy is deleted. The client below will schedule\n'
  printf '  immediately and there will be no Pending pod to show.\n'
  printf '  Recycle the node group for a clean take. Carrying on.\n'
fi

pause "apply the WekaClient with no NIC policy"

run_strict "kubectl apply -f 03-weka-client.yaml"

explain "Now wait for the operator to generate the client pod and for the
scheduler to refuse it."

printf '\n  waiting up to %ss for a Pending client pod...\n' "$PENDING_TIMEOUT"
waited=0
while [ "$waited" -lt "$PENDING_TIMEOUT" ]; do
  if kubectl -n "$NS" get pods --field-selector=status.phase=Pending \
       -o name 2>/dev/null | grep -q .; then
    break
  fi
  sleep 5
  waited=$((waited + 5))
done

run "kubectl -n '$NS' get pods -o wide"

explain "And the reason, straight from the scheduler. THIS is the line to read
out loud:"

run "kubectl -n '$NS' get events --field-selector reason=FailedScheduling --sort-by=.lastTimestamp | tail -5"

explain "A perfectly healthy WEKA cluster. A perfectly healthy node. A pod that
will sit there forever, because the resource it is asking for is created by a
custom resource nobody applied.

Now apply the policy -- and change nothing else."

pause "apply the NIC policy and watch it schedule"

run_strict "kubectl apply -f 02-weka-nics-policy.yaml"

explain "The operator attaches the data-path ENIs, the node starts advertising
weka.io/weka-nics, and the pod the scheduler had already rejected becomes
schedulable with no intervention at all."

printf '\n  waiting up to %ss for the WekaPolicy and the client...\n' "$CLIENT_TIMEOUT"
printf '  (first run on a cold node includes a multi-GiB weka-in-container pull)\n'

waited=0
while [ "$waited" -lt "$CLIENT_TIMEOUT" ]; do
  nics=$(kubectl get nodes -l "$NODE_LABEL" -o json 2>/dev/null \
    | jq -r '[.items[] | select(.status.allocatable["weka.io/weka-nics"] != null)] | length')
  # Deliberately label-agnostic: "no Pending pods left in the namespace"
  # rather than a selector on the client pod. The labels the operator puts on
  # the pods it generates are its business and have changed between releases,
  # and a wait loop keyed to a label that no longer matches does not fail --
  # it silently burns the whole timeout, which on camera is worse.
  pending=$(kubectl -n "$NS" get pods --field-selector=status.phase=Pending \
    -o name 2>/dev/null | grep -c . || true)
  if [ "${nics:-0}" -gt 0 ] && [ "${pending:-0}" -eq 0 ]; then
    break
  fi
  # No spinner: this is a recording, and a scrolling progress line is worse
  # than a quiet wait. Print a heartbeat every 30s instead.
  [ $((waited % 30)) -eq 0 ] && printf '    %ss: weka-nics on %s node(s)\n' "$waited" "${nics:-0}"
  sleep 5
  waited=$((waited + 5))
done

run "kubectl -n '$NS' get wekapolicy,wekaclient"
run "kubectl get nodes -l '$NODE_LABEL' -o json | jq -r '.items[] | \"\\(.metadata.name)  weka-nics=\\(.status.allocatable[\"weka.io/weka-nics\"] // \"<absent>\")\"'"
run "kubectl -n '$NS' get pods -o wide"

explain "The extended resource is the whole story: it did not exist, so the pod
could not be placed; it exists, so the pod runs. Nothing else changed."

pause "beat 3, the mount"

# ===========================================================================
# Beat 3 -- the mount, and the quota
# ===========================================================================
banner "BEAT 3 of 5 -- a Bound PVC, and wekafs with a real quota inside the pod"

explain "The CSI controller called the WEKA REST API on 14000, created a
directory inside the existing filesystem, and applied a quota to it. The CSI
node plugin then staged that directory through the WEKA client on whichever
node the pod landed on."

run_strict "kubectl apply -f 07-rwx-multiwriter.yaml"

printf '\n  waiting for the rollout...\n'
run "kubectl rollout status deploy/$DEPLOY --timeout=${ROLLOUT_TIMEOUT}s"

run "kubectl get pvc"
run "kubectl get pv -o custom-columns=NAME:.metadata.name,CAPACITY:.spec.capacity.storage,RECLAIM:.spec.persistentVolumeReclaimPolicy,CLAIM:.spec.claimRef.name,STORAGECLASS:.spec.storageClassName"

explain "Now from inside a pod. Two things to point at: the filesystem TYPE is
wekafs -- not ext4 on a block device, an actual parallel filesystem client --
and the SIZE is the PVC's request, not the WEKA cluster's 36 TiB.

That second one is capacityEnforcement: HARD on the StorageClass. The quota is
real: a write past it fails with ENOSPC. With SOFT the write succeeds and the
cluster raises an event nobody is watching, and a PVC's declared capacity
means nothing."

run "kubectl exec deploy/$DEPLOY -- df -hT /data"

pause "beat 4, three writers one file"

# ===========================================================================
# Beat 4 -- the RWX payoff
# ===========================================================================
banner "BEAT 4 of 5 -- three pods, three nodes, one file"

explain "Three replicas, podAntiAffinity on kubernetes.io/hostname, so exactly
one lands per node. Each appends a timestamp and its hostname to
/data/shared.log every two seconds -- concurrently, from three different
kernels, with no locking and no coordination in the workload."

run "kubectl get pods -l app=$DEPLOY -o wide"

explain "Letting them accumulate a few lines each."
sleep 20

explain "One command. Count the hostnames in the file, from a pod that wrote
only a third of the lines in it:"

run "kubectl exec deploy/$DEPLOY -- sh -c \"awk '{print \\\$2}' /data/shared.log | sort | uniq -c\""

explain "Three distinct hostnames, counted out of one file.

A block volume cannot do this. RWX on EBS does not exist, and a block device
with a single-writer filesystem on top corrupts if you force it. The counts
adding up exactly is POSIX append semantics being enforced across nodes by the
filesystem -- which is the entire reason to put WEKA behind a PVC rather than
a CSI driver for block storage.

It is also the only beat that exercises the CSI node plugin on EVERY node in
the group, rather than the one node the scheduler happened to pick for the
smoke test."

pause "beat 5, node loss"

# ===========================================================================
# Beat 5 -- node loss
# ===========================================================================
banner "BEAT 5 of 5 -- the data outlives the pod AND its node"

explain "Everything so far had all three writers alive at once, so none of it
says anything about what happens when a node goes away. On EKS that is
routine: spot interruption, AMI roll, instance refresh, a drain you did
yourself. It is also the moment node-local storage quietly becomes data loss.

08-persistence-check.sh writes a sentinel, records the node, deletes the pod,
cordons that node so it cannot come back to the same place, recreates the pod,
asserts it scheduled somewhere else, and reads the sentinel back. It uncordons
and cleans up on the way out, including on failure."

run_strict "./08-persistence-check.sh"

# ===========================================================================
banner "DONE"
cat <<'EOT'
  What each beat proved:

    1  The node prep in Terraform's user data is real and readable off the
       live node -- HugePages reserved at first boot, CPU 0 and its sibling
       pinned out of the shared pool.
    2  A DPDK data path needs dedicated NICs that only the ensure-nics
       WekaPolicy can attach, and without it the client is unschedulable
       against a cluster and a node that are both perfectly healthy.
    3  The CSI plugin provisions a directory inside an existing WEKA
       filesystem and the quota on it is enforced, not advisory.
    4  Three pods on three nodes append to one file concurrently, correctly.
       No block volume does this.
    5  The data survives the loss of both the pod and the node it was written
       from, and is readable from different hardware.

  Not shown, deliberately: any performance number. 09-fio-job.yaml is in the
  repo so you can run it on your own cluster -- see the header comment in that
  file for why none of its output is published here.

  Re-run beat 2 from a clean state with:   ./demo.sh --reset
EOT
