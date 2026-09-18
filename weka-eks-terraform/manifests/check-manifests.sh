#!/usr/bin/env bash
#
# Drift check: do the hand-applied manifests agree with Terraform?
#
# WHY THIS EXISTS
#
# Five manifest fields must match Terraform variables, and NOTHING tells you
# when they drift. Kubernetes reports the symptom, never the cause:
#
#   coresNum > HugePages sizing      -> pod Pending, "Insufficient hugepages-2Mi"
#   dataNICsNumber < coresNum        -> pod Pending, "Insufficient weka.io/weka-nics"
#   client image != weka_version     -> client/backend version skew
#   filesystemName does not exist    -> PVC Pending forever
#   maxPods > CNI addressable IPs    -> pods stuck with no IP
#
# Every one of those reads like a capacity problem rather than a mismatch, and
# each costs 10-20 minutes to discover the slow way. This costs two seconds.
#
# Usage, from this directory (needs the Terraform state to be present):
#     ./check-manifests.sh
#
set -uo pipefail

TFDIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$(dirname "$0")"

# `terraform output` needs the input variables to be resolvable.
[ -f "$TFDIR/../.env" ] && { set -a; . "$TFDIR/../.env"; set +a; }

echo "Reading authoritative values from terraform output manifest_values..."
vals=$(cd "$TFDIR" && terraform output -json manifest_values 2>/dev/null)
if [ -z "$vals" ] || [ "$vals" = "null" ]; then
  echo "ERROR: could not read 'terraform output -json manifest_values'." >&2
  echo "       Run this after 'terraform apply', from a shell that can read the state." >&2
  exit 2
fi

get() { printf '%s' "$vals" | python3 -c "import json,sys; print(json.load(sys.stdin).get(sys.argv[1],''))" "$1"; }

fail=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf '  OK    %-44s %s\n' "$1" "$3"
  else
    printf '  DRIFT %-44s manifest=%s  terraform=%s\n' "$1" "$3" "$2"
    fail=1
  fi
}

# --- pull the actual values out of the YAML (ruby ships with macOS) --------
y() { ruby -ryaml -e '
  d = YAML.load_file(ARGV[0])
  path = ARGV[1].split(".")
  v = d
  path.each { |k| v = v.nil? ? nil : v[k] }
  puts v.nil? ? "" : v
' "$1" "$2" 2>/dev/null; }

# --- cluster prerequisites -------------------------------------------------
#
# Caught the author out on a rebuild: after a destroy/redeploy it is very easy
# to jump straight to 01 and forget that 00-namespace-and-secrets.sh creates
# the namespace AND installs the CRDs. You then get a wall of
#
#   namespaces "weka-operator-system" not found
#   no matches for kind "WekaPolicy" in version "weka.weka.io/v1alpha1"
#
# and, confusingly, 05-storageclass-dir.yaml applies FINE anyway, because a
# StorageClass is cluster-scoped and a built-in kind. A partial success makes
# it look like something subtler is wrong.
echo
echo "Cluster prerequisites:"
if kubectl version --request-timeout=8s >/dev/null 2>&1; then
  printf '  OK    %-44s %s\n' "kubectl reachable" "$(kubectl config current-context 2>/dev/null)"
  if kubectl get namespace weka-operator-system >/dev/null 2>&1; then
    printf '  OK    %-44s exists\n' "namespace weka-operator-system"
  else
    printf '  MISSING %-42s run ./00-namespace-and-secrets.sh first\n' "namespace weka-operator-system"; fail=1
  fi
  for crd in wekaclients.weka.weka.io wekapolicies.weka.weka.io; do
    if kubectl get crd "$crd" >/dev/null 2>&1; then
      printf '  OK    %-44s installed\n' "crd $crd"
    else
      printf '  MISSING %-42s run ./00-namespace-and-secrets.sh first\n' "crd $crd"; fail=1
    fi
  done
else
  printf '  NOTE  %-44s skipping cluster checks\n' "kubectl not reachable"
fi

echo
echo "Comparing manifests against Terraform:"
check "03 spec.coresNum"              "$(get '03-weka-client.yaml : spec.coresNum')"        "$(y 03-weka-client.yaml 'spec.coresNum')"
check "03 spec.image"                 "$(get '03-weka-client.yaml : spec.image')"           "$(y 03-weka-client.yaml 'spec.image')"
check "02 dataNICsNumber"             "$(get '02-weka-nics-policy.yaml : dataNICsNumber')"  "$(y 02-weka-nics-policy.yaml 'spec.payload.ensureNICsPayload.dataNICsNumber')"
check "02 spec.image"                 "$(get '02-weka-nics-policy.yaml : spec.image')"      "$(y 02-weka-nics-policy.yaml 'spec.image')"
check "05 filesystemName"             "$(get '05-storageclass-dir.yaml : filesystemName')"  "$(y 05-storageclass-dir.yaml 'parameters.filesystemName')"

# --- dataNICsNumber must be >= coresNum, not merely equal -----------------
cn=$(y 03-weka-client.yaml 'spec.coresNum'); dn=$(y 02-weka-nics-policy.yaml 'spec.payload.ensureNICsPayload.dataNICsNumber')
if [ -n "$cn" ] && [ -n "$dn" ]; then
  if [ "$dn" -ge "$cn" ]; then
    printf '  OK    %-44s dataNICsNumber(%s) >= coresNum(%s)\n' "02/03 NIC-per-core rule" "$dn" "$cn"
  else
    printf '  DRIFT %-44s dataNICsNumber(%s) < coresNum(%s) -- client will stay Pending\n' "02/03 NIC-per-core rule" "$dn" "$cn"; fail=1
  fi
fi

# --- joinIpPorts must have been replaced with real backend IPs ------------
#
# 03-weka-client.yaml is a TRACKED file (not a .example), so it ships with
# obvious placeholder IPs and you edit it in place. Two failure directions:
#   forgot to edit  -> the client cannot reach any backend and never joins
#   committed real IPs -> live infrastructure detail in git, and the next
#                         reader inherits addresses that do not exist
if grep -q 'REPLACE' 03-weka-client.yaml; then
  printf '  TODO  %-44s joinIpPorts still placeholders -- set real backend IPs\n' "03-weka-client.yaml"
  fail=1
else
  printf '  OK    %-44s joinIpPorts edited\n' "03-weka-client.yaml"
fi

# --- the two secret templates must not still hold placeholders ------------
#
# LIMITATION, worth knowing: this only proves the REPLACE_ME placeholders are
# gone. It CANNOT tell whether the credentials are current. If you destroy and
# redeploy, these files keep the PREVIOUS cluster's admin password, join token
# and backend IPs -- every one of which is now invalid -- and this check will
# happily report "filled in". After any redeploy, regenerate both files from
# the .example templates. Symptom of getting this wrong: the WekaClient fails
# to join with an authentication error, and the CSI plugin times out against
# backend IPs that no longer exist.
for f in 01-weka-client-secret.yaml 04-csi-api-secret.yaml; do
  if [ -f "$f" ]; then
    if grep -qE 'UkVQTEFDRV9XSVRI|UkVQTEFDRV9NRQ==' "$f"; then
      printf '  DRIFT %-44s still contains REPLACE_ME placeholders\n' "$f"; fail=1
    else
      printf '  OK    %-44s filled in\n' "$f"
    fi
  else
    printf '  NOTE  %-44s not created yet (cp from the .example)\n' "$f"
  fi
done

echo
if [ "$fail" -eq 0 ]; then
  echo "All checks passed -- prerequisites present and manifests agree with Terraform."
else
  echo "CHECKS FAILED. Fix these before applying, or you will spend the next"
  echo "20 minutes debugging a Pending pod instead:"
  echo "  - MISSING prerequisite -> run ./00-namespace-and-secrets.sh first"
  echo "  - DRIFT on a value     -> 'terraform output manifest_values' is authoritative"
fi
exit "$fail"
