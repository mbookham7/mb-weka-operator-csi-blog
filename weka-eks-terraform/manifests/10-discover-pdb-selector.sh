#!/usr/bin/env bash
#
# Work out the right selector for 10-poddisruptionbudgets.yaml, and optionally
# write it in.
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
# Usage, from this directory, against a cluster with the operator running and
# at least one WekaClient scheduled:
#
#     ./10-discover-pdb-selector.sh            # report only
#     ./10-discover-pdb-selector.sh --write    # also patch the PDB manifest
#
set -euo pipefail

cd "$(dirname "$0")"

NS="${NS:-weka-operator-system}"
PDB_FILE="10-poddisruptionbudgets.yaml"
WRITE=0
[ "${1:-}" = "--write" ] && WRITE=1
[ -n "${1:-}" ] && [ "${1:-}" != "--write" ] && { echo "unknown argument: $1 (only --write)" >&2; exit 2; }

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

best = winners[0]
sel_yaml = "\n".join(f"      {k}: {v}" for k, v in best)
print(f"\n==> Use this selector:\n\n    matchLabels:\n{sel_yaml}\n")

if not write:
    print("Re-run with --write to patch %s in place." % pdb_file)
    sys.exit(0)

# --- patch the manifest -------------------------------------------------
src = open(pdb_file).read()
if "REPLACE_ME" not in src:
    sys.exit(f"{pdb_file} has no REPLACE_ME placeholder -- already filled in. "
             "Edit it by hand if you need to change the selector.")

# Replace the placeholder block: the commented guidance plus `app: REPLACE_ME`.
pattern = re.compile(
    r"[ \t]*# REPLACE_ME -- see the header\.[^\n]*\n(?:[ \t]*#[^\n]*\n)*[ \t]*app: REPLACE_ME\n")
replacement = ("      # Discovered by 10-discover-pdb-selector.sh against a live\n"
               "      # cluster. Operator-version specific -- re-run that script\n"
               "      # after an operator upgrade.\n"
               + sel_yaml + "\n")
new, n = pattern.subn(replacement, src, count=1)
if n != 1:
    sys.exit(f"could not locate the placeholder block in {pdb_file} -- patch it by hand")
open(pdb_file, "w").write(new)
print(f"Wrote the selector into {pdb_file}.")
print("Verify with:  ./check-manifests.sh")
PY
