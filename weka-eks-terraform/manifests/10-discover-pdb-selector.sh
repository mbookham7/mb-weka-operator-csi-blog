#!/usr/bin/env bash
#
# Work out a pod selector that matches exactly the pods you mean, and nothing
# else.
#
# WHY THIS IS NOT JUST `kubectl get pods --show-labels`
#
# The WEKA client pods are created by the operator's controller at runtime,
# not by the Helm chart, so their labels are not knowable in advance and vary
# by operator version. That much you can see by eye. The part that is easy to
# get wrong is picking WHICH label:
#
#   too narrow  -> the selector matches nothing, and a PodDisruptionBudget
#                  matching nothing is SILENTLY INERT. It exists, `kubectl get
#                  pdb` lists it, it reports allowed disruptions, and it
#                  restrains precisely nothing.
#
#   too broad   -> it also catches the CSI node plugin or the node agent, so
#                  those get budgeted together with the clients and drains
#                  block for the wrong reason.
#
# So this script does not just print labels. It finds the client pods, then
# tests candidate selectors against the live cluster and keeps only those that
# select EXACTLY the client pods and nothing else.
#
# WHAT THIS IS FOR NOW
#
# It was written to fill in a selector for 10-poddisruptionbudgets.yaml. That
# file no longer defines any budgets, because a PDB over the WEKA client pods
# was measured to block every eviction rather than pace a roll -- read its
# header. So this script no longer patches anything.
#
# It is kept because the logic is still the right way to build a selector for
# a PDB over YOUR OWN workloads on the filesystem, which is where a PDB does
# belong: those are ordinary Deployments whose controller implements `scale`.
# Point NS/LABEL at them and it will find a selector that matches exactly
# those pods and nothing else.
#
# Usage, from this directory, against a cluster with the operator running and
# at least one WekaClient scheduled:
#
#     ./10-discover-pdb-selector.sh
#
set -euo pipefail

cd "$(dirname "$0")"

NS="${NS:-weka-operator-system}"
PDB_FILE="10-poddisruptionbudgets.yaml"
WRITE=0
case "${1:-}" in
  "") ;;
  --write) echo "--write is gone: $PDB_FILE deliberately defines no budgets now." >&2
           echo "Read its header. This script reports a selector; paste it where you need it." >&2
           exit 2 ;;
  *)       echo "unknown argument: $1 (this script takes none)" >&2; exit 2 ;;
esac

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
kubectl version --request-timeout=8s >/dev/null 2>&1 \
  || { echo "kubectl cannot reach a cluster -- this needs the operator running" >&2; exit 1; }

echo "==> Looking for WEKA client pods in namespace ${NS}"

kubectl -n "$NS" get pods -o json > /tmp/.weka-pdb-pods.$$ 2>/dev/null
trap 'rm -f /tmp/.weka-pdb-pods.$$' EXIT

python3 - "/tmp/.weka-pdb-pods.$$" "$NS" "$WRITE" "$PDB_FILE" <<'PY'
import json, subprocess, sys, itertools, re

pods_json, ns, write, pdb_file = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4]
pods = json.load(open(pods_json))["items"]
if not pods:
    sys.exit(f"no pods at all in {ns} -- is the operator installed?")

# --- which pods are the clients? ---------------------------------------
#
# Identified by the image they run rather than by any label, because the
# labels are the unknown we are trying to discover. `weka-in-container` is the
# client image; Running-only excludes the short-lived ensure-nics policy pods,
# which use the same image but complete.
def is_client(p):
    if p.get("status", {}).get("phase") != "Running":
        return False
    containers = p["spec"].get("containers", []) + p["spec"].get("initContainers", [])
    return any("weka-in-container" in c.get("image", "") for c in containers)

clients = [p for p in pods if is_client(p)]
others  = [p for p in pods if not is_client(p)]

if not clients:
    print("  no Running pod in this namespace uses a weka-in-container image.")
    print("  Either the WekaClient has not been applied yet, or its pods are not")
    print("  Running. Check: kubectl -n %s get wekaclient,pods" % ns)
    sys.exit(1)

names = sorted(p["metadata"]["name"] for p in clients)
print(f"  found {len(clients)} client pod(s): {', '.join(names)}")
print(f"  and {len(others)} other pod(s) in the namespace that must NOT be matched")

# --- candidate selectors ------------------------------------------------
#
# Only labels present on EVERY client pod with the SAME value can work; a
# label that varies per pod (a hash, a node name) would select a subset.
common = None
for p in clients:
    labs = set(p["metadata"].get("labels", {}).items())
    common = labs if common is None else (common & labs)
common = sorted(common or [])

if not common:
    sys.exit("  the client pods share no label with a common value -- cannot build a selector")

print(f"\n==> {len(common)} label(s) common to every client pod:")
for k, v in common:
    print(f"     {k}={v}")

target = set(names)

def selects_exactly(pairs):
    sel = ",".join(f"{k}={v}" for k, v in pairs)
    out = subprocess.run(["kubectl", "-n", ns, "get", "pods", "-l", sel,
                          "-o", "jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end}"],
                         capture_output=True, text=True)
    got = {x for x in out.stdout.split("\n") if x}
    return sel, got == target, got

# Prefer the simplest selector that is exact: one label, then two.
print("\n==> Testing candidates against the live cluster")
winners = []
for size in (1, 2):
    for combo in itertools.combinations(common, size):
        sel, exact, got = selects_exactly(combo)
        mark = "EXACT" if exact else f"matches {len(got)}"
        print(f"     {mark:<12} {sel}")
        if exact:
            winners.append(combo)
    if winners:
        break

if not winners:
    sys.exit("\n  no combination of up to two common labels selects exactly the client\n"
             "  pods. Look at the full label sets by hand:\n"
             f"    kubectl -n {ns} get pods --show-labels")

# --- choosing between several exact selectors ---------------------------
#
# Usually more than one is exact TODAY. They are not equally durable, so the
# tie is broken deliberately rather than alphabetically:
#
#   1. Prefer the operator's own `weka.io/` labels over generic `app=` /
#      `app.kubernetes.io/` ones. A bare `app=weka` is exact only because
#      this repo's backends are EXTERNAL -- run an operator-managed
#      WekaCluster in the same namespace and it would match the backend
#      containers too, budgeting them together with the clients.
#
#   2. Among those, prefer a label that does NOT embed a resource name.
#      `weka.io/client-name=<your WekaClient>` is exact but breaks the day
#      somebody renames the CR; `weka.io/mode=client` describes the role.
def rank(pairs):
    keys = [k for k, _ in pairs]
    weka_ns   = all(k.startswith("weka.io/") for k in keys)
    names_a_cr = any(k.endswith("-name") for k in keys)
    return (0 if weka_ns else 1, 1 if names_a_cr else 0, len(pairs), keys)

winners.sort(key=rank)
if len(winners) > 1:
    print("\n==> Several selectors are exact today. Preferring the operator's own")
    print("    weka.io/ labels, and avoiding ones that embed a resource name:")
    for w in winners:
        print("      " + ",".join(f"{k}={v}" for k, v in w))

best = winners[0]
sel_yaml = "\n".join(f"      {k}: {v}" for k, v in best)
print(f"\n==> Use this selector:\n\n    matchLabels:\n{sel_yaml}\n")

print("Paste that into a PodDisruptionBudget over your own workloads.")
print("NOT over the WEKA client pods -- see %s for why that does not work." % pdb_file)
sys.exit(0)

PY
