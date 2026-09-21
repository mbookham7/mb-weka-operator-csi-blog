#!/usr/bin/env bash
#
# Does the data actually survive the pod, and is it reachable from a DIFFERENT
# node?
#
# WHY THIS IS A SCRIPT AND NOT A MANIFEST
#
# It is a sequence with assertions in the middle, and the interesting part is
# the ORDER: write, lose the pod, lose the node, come back somewhere else, read.
# You cannot express "and now schedule me elsewhere" in a manifest, and a
# manifest that merely mounts a volume twice proves nothing about the second
# mount being on another machine.
#
# WHAT IT PROVES THAT 06 AND 07 DO NOT
#
#   06  one pod writes and reads its own file. Survives nothing.
#   07  three pods on three nodes share a file. All three are alive at once,
#       so it says nothing about what happens when one goes away.
#   08  the pod is destroyed AND its node is taken out of the scheduler's
#       pool. The replacement pod is forced onto different hardware, with a
#       different kernel, a different WEKA client container and a different
#       CSI node plugin instance -- and reads back the same bytes.
#
# That is the failure mode this demo is for: node loss. On EKS it is routine
# (spot interruption, AMI roll, instance refresh, a drain you did yourself),
# and it is the point at which node-local storage quietly becomes data loss.
#
# The cordon is what makes the assertion meaningful. Without it the scheduler
# will usually put the replacement pod straight back on the node it just left,
# because that is the cheapest placement -- and the check passes while having
# tested nothing at all.
#
# Usage, from this directory:
#     ./08-persistence-check.sh
#
# Requires 07-rwx-multiwriter.yaml to have been applied (it uses that PVC).
# Exits non-zero on any failed assertion. Uncordons and deletes the probe pod
# on the way out, including on failure and on Ctrl-C.
#
set -euo pipefail

PVC="${PVC:-weka-rwx-demo-pvc}"
POD="${POD:-weka-persistence-probe}"
NODE_LABEL="${NODE_LABEL:-weka.io/supports-clients=true}"
IMAGE="${IMAGE:-public.ecr.aws/docker/library/busybox:1.36}"

# Same path every run, so repeated runs overwrite rather than accumulate
# files inside a PVC that has a HARD quota on it.
SENTINEL_PATH="/data/persistence-sentinel"

# Seconds to wait for the probe pod to schedule, mount and exit. Generous
# because the mount is the slow part: the CSI node plugin has to stage the
# volume through the WEKA client on a node that may never have mounted this
# directory before.
POD_TIMEOUT="${POD_TIMEOUT:-180}"

CORDONED_NODE=""

# ---------------------------------------------------------------------------
# Output helpers -- same shapes as check-manifests.sh so the two read as a pair
# ---------------------------------------------------------------------------
ok()   { printf '  OK    %-44s %s\n' "$1" "${2:-}"; }
note() { printf '  NOTE  %-44s %s\n' "$1" "${2:-}"; }
step() { printf '\n%s\n' "$1"; }
fail() {
  printf '  FAIL  %-44s %s\n' "$1" "${2:-}" >&2
  printf '\nPERSISTENCE CHECK FAILED: %s\n' "$1" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Cleanup -- runs on success, on failure and on Ctrl-C
# ---------------------------------------------------------------------------
# The cordon is the dangerous leftover. A node left unschedulable after a
# failed run looks exactly like a capacity problem to whoever next tries to
# schedule anything, and nothing in Kubernetes will connect it back to this
# script. Uncordon unconditionally.
cleanup() {
  local rc=$?
  set +e
  if [ -n "$CORDONED_NODE" ]; then
    printf '\n==> Cleanup: uncordoning %s\n' "$CORDONED_NODE"
    kubectl uncordon "$CORDONED_NODE" >/dev/null 2>&1 \
      || printf '  WARNING: could not uncordon %s -- do it by hand: kubectl uncordon %s\n' \
           "$CORDONED_NODE" "$CORDONED_NODE" >&2
  fi
  kubectl delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1
  exit "$rc"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Probe pod: one command, two modes
# ---------------------------------------------------------------------------
# Applied twice with different arguments. Kept as a function rather than two
# near-identical heredocs so the two pods cannot drift apart in some way that
# invalidates the comparison -- same image, same PVC, same mount path, same
# everything except the shell command.
apply_probe() { # apply_probe <shell-command>
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: ${IMAGE}
      command: ["/bin/sh", "-c", "$1"]
      volumeMounts:
        - name: weka
          mountPath: /data
  volumes:
    - name: weka
      persistentVolumeClaim:
        claimName: ${PVC}
EOF
}

# Wait for a terminal phase rather than `kubectl wait --for=condition=Ready`:
# this pod is expected to run briefly and exit, so it may never be observed
# Ready at all, and a Ready wait can time out on a pod that already succeeded.
wait_for_pod() {
  local waited=0 phase=""
  while [ "$waited" -lt "$POD_TIMEOUT" ]; do
    phase=$(kubectl get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    case "$phase" in
      Succeeded|Failed) printf '%s' "$phase"; return 0 ;;
    esac
    sleep 3
    waited=$((waited + 3))
  done
  printf 'Timeout'
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
step "Preflight:"

command -v kubectl >/dev/null || fail "kubectl not found"
kubectl version --request-timeout=8s >/dev/null 2>&1 \
  || fail "kubectl cannot reach a cluster" "check your kubeconfig context"
ok "kubectl reachable" "$(kubectl config current-context)"

# The PVC comes from 07. Checking it explicitly because the alternative
# symptom is a pod that sits in Pending on "persistentvolumeclaim not found",
# which reads like a storage problem rather than a missing prerequisite.
pvc_phase=$(kubectl get pvc "$PVC" -o jsonpath='{.status.phase}' 2>/dev/null || true)
[ -n "$pvc_phase" ] || fail "PVC $PVC not found" "apply 07-rwx-multiwriter.yaml first"
[ "$pvc_phase" = "Bound" ] || fail "PVC $PVC is $pvc_phase, not Bound" \
  "see the PVC Pending rows in the README troubleshooting table"
ok "PVC $PVC" "$pvc_phase"

# At least two SCHEDULABLE client nodes, or the whole premise collapses: cordon
# the only node and the replacement pod can never be placed, and the script
# would report a scheduling failure as if it were a storage failure.
#
# This is the common case rather than an edge case -- terraform.tfvars.example
# ships client_node_count = 1 to keep the demo cheap.
#
# `set -- $(...)` rather than `mapfile`, which is bash 4 only -- macOS still
# ships bash 3.2 as /bin/bash and this script has to run there. Node names
# never contain whitespace, so word splitting is safe here.
# shellcheck disable=SC2046  # deliberate word splitting on node names
set -- $(
  kubectl get nodes -l "$NODE_LABEL" \
    -o jsonpath='{range .items[?(@.spec.unschedulable!=true)]}{.metadata.name}{"\n"}{end}' 2>/dev/null
)
client_node_count=$#
if [ "$client_node_count" -lt 2 ]; then
  fail "need >= 2 schedulable nodes labelled $NODE_LABEL, found $client_node_count" \
    "raise client_node_count in terraform.tfvars (default is 3; the example sets 1) and re-apply"
fi
ok "schedulable client nodes" "$client_node_count ($*)"

# ---------------------------------------------------------------------------
# 1. Write a sentinel, and record which node wrote it
# ---------------------------------------------------------------------------
step "1. Writing sentinel from a short-lived pod:"

# Unique per run. A fixed string would pass against a sentinel left behind by
# an earlier run, which is exactly the false pass this check exists to avoid.
SENTINEL="persistence-$(date +%s)-$$-${RANDOM}"

kubectl delete pod "$POD" --ignore-not-found >/dev/null 2>&1

echo "  + kubectl apply -f - (writer pod)"
apply_probe "set -e; printf '%s\\n' '${SENTINEL}' > ${SENTINEL_PATH}; sync; echo wrote; cat ${SENTINEL_PATH}"

phase=$(wait_for_pod)
write_node=$(kubectl get pod "$POD" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
[ "$phase" = "Succeeded" ] || fail "writer pod ended in phase '$phase'" \
  "kubectl describe pod $POD  /  kubectl logs $POD"
[ -n "$write_node" ] || fail "writer pod never recorded a nodeName"

ok "sentinel written" "$SENTINEL"
ok "written on node" "$write_node"

# ---------------------------------------------------------------------------
# 2. Destroy the pod, and take its node out of the pool
# ---------------------------------------------------------------------------
step "2. Deleting the pod and cordoning its node:"

echo "  + kubectl delete pod $POD"
kubectl delete pod "$POD" --wait=true >/dev/null

echo "  + kubectl cordon $write_node"
kubectl cordon "$write_node" >/dev/null
CORDONED_NODE="$write_node"
ok "cordoned" "$write_node (will be uncordoned on exit)"

# ---------------------------------------------------------------------------
# 3. Recreate it, assert it landed elsewhere, and read the sentinel back
# ---------------------------------------------------------------------------
step "3. Recreating the pod -- it must land on a different node:"

echo "  + kubectl apply -f - (reader pod)"
apply_probe "set -e; cat ${SENTINEL_PATH}; rm -f ${SENTINEL_PATH}"

phase=$(wait_for_pod)
read_node=$(kubectl get pod "$POD" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)

if [ "$phase" != "Succeeded" ]; then
  # Distinguish "could not schedule" from "could not mount". They look
  # similar from the outside and have nothing to do with each other.
  if [ -z "$read_node" ]; then
    kubectl describe pod "$POD" 2>/dev/null | sed -n '/^Events:/,$p' | sed 's/^/      /' >&2 || true
    fail "reader pod was never scheduled" \
      "no other node would take it -- events above"
  fi
  kubectl describe pod "$POD" 2>/dev/null | sed -n '/^Events:/,$p' | sed 's/^/      /' >&2 || true
  fail "reader pod ended in phase '$phase' on $read_node" \
    "if this is MountVolume.SetUp ... DeadlineExceeded, read the poached-ENI row in the README"
fi

[ -n "$read_node" ] || fail "reader pod never recorded a nodeName"

# THE assertion. If these are equal the cordon did not take effect and the
# result is meaningless -- report it as a failure rather than a pass, because
# a check that silently stops checking is worse than no check.
if [ "$read_node" = "$write_node" ]; then
  fail "reader landed on the SAME node ($read_node)" \
    "the cordon did not take -- nothing about cross-node persistence was tested"
fi
ok "rescheduled onto a different node" "$write_node -> $read_node"

read_back=$(kubectl logs "$POD" 2>/dev/null | tr -d '\r' | sed -n '1p')
[ -n "$read_back" ] || fail "reader pod produced no output" "kubectl logs $POD"

if [ "$read_back" != "$SENTINEL" ]; then
  fail "sentinel mismatch" "wrote '$SENTINEL', read '$read_back'"
fi
ok "sentinel read back intact" "$read_back"

# ---------------------------------------------------------------------------
step "Result:"
echo "  PERSISTENCE CHECK PASSED"
echo
echo "  Wrote on  $write_node"
echo "  Read on   $read_node  (after the first node was cordoned out)"
echo
echo "  The data outlived the pod and the node it was written from. Node-local"
echo "  storage does not do that, and neither does a block volume that is"
echo "  still attached to an instance the scheduler can no longer use."
echo
echo "  Cleanup (uncordon + pod delete) runs next, on the way out."
