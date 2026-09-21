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
cd "$(dirname "$0")" || exit 1

# `terraform output` needs the input variables to be resolvable.
# shellcheck source=/dev/null  # .env is gitignored and per-developer
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
#
# `aliases: true` where the Psych version supports it. 05-storageclass-dir.yaml
# uses YAML anchors (&secretName / *secretName) on purpose, and Psych 4 --
# Ruby 3.1 and later -- refuses to resolve aliases unless asked. Without the
# guard this check reports an empty value on any modern Ruby and calls it
# DRIFT. macOS still ships Ruby 2.6, where the keyword does not exist.
y() { ruby -ryaml -e '
  f = File.read(ARGV[0])
  d = Psych::VERSION.split(".")[0].to_i >= 4 ? YAML.load(f, aliases: true) : YAML.load(f)
  path = ARGV[1].split(".")
  v = d
  path.each { |k| v = v.nil? ? nil : v[k] }
  puts v.nil? ? "" : v
' "$1" "$2" 2>/dev/null; }

# Multi-document variant, selecting the document by `kind`. 07 and 09 each
# carry several objects in one file and YAML.load only returns the first, so a
# dotted path alone is ambiguous -- asking for `spec.replicas` in 07 without
# naming the kind silently reads the PersistentVolumeClaim and returns nothing.
ym() { ruby -ryaml -e '
  f = File.read(ARGV[0])
  docs = (Psych::VERSION.split(".")[0].to_i >= 4 ? YAML.load_stream(f, aliases: true) : YAML.load_stream(f)).compact
  d = docs.find { |x| x.is_a?(Hash) && x["kind"] == ARGV[1] }
  v = d
  # An all-digits segment indexes a list, so a path can reach into
  # spec.template.spec.volumes.0.… -- Array#[] raises on a String key, which
  # would otherwise come back as an empty value and read as DRIFT.
  ARGV[2].split(".").each do |k|
    break if v.nil?
    v = v.is_a?(Array) ? (k =~ /\A\d+\z/ ? v[k.to_i] : nil) : v[k]
  end
  puts v.nil? ? "" : v
' "$1" "$2" "$3" 2>/dev/null; }

# Kubernetes/fio quantity -> bytes, so sizes written in different units can be
# compared. Ki/Mi/Gi/Ti are powers of 1024, and so are fio's k/m/g. awk rather
# than shell arithmetic because the units have to be parsed off the end of the
# string, and awk is already a dependency of the checks below.
to_bytes() { # to_bytes <quantity>   e.g. 10Gi, 512m, 1024
  awk -v q="$1" 'BEGIN{
    if (match(q, /^[0-9]+/) == 0) { print ""; exit }
    n = substr(q, RSTART, RLENGTH) + 0
    u = tolower(substr(q, RSTART + RLENGTH))
    sub(/b$/, "", u); sub(/i$/, "", u)
    if      (u == "")  m = 1
    else if (u == "k") m = 1024
    else if (u == "m") m = 1024^2
    else if (u == "g") m = 1024^3
    else if (u == "t") m = 1024^4
    else { print ""; exit }
    printf "%d\n", n * m
  }'
}

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

# --- demo manifests: 07 / 08 / 09 ----------------------------------------
#
# These four files (07, 08, 09 and demo.sh) are the blog demo rather than the
# deployment, but they drift against the deployment in exactly the same silent
# ways, and each one costs a re-take on a recording rather than a quick fix.
echo
echo "Demo manifests (07 / 08 / 09):"

# The StorageClass name is a plain string in two files and nothing joins them.
# Get it wrong and the PVC sits in Pending with `storageclass ... not found`,
# which reads like the StorageClass was never applied.
sc_name=$(ym 05-storageclass-dir.yaml StorageClass 'metadata.name')
check "07 storageClassName -> 05 StorageClass" "$sc_name" \
      "$(ym 07-rwx-multiwriter.yaml PersistentVolumeClaim 'spec.storageClassName')"

# 09 runs against 07's volume. A typo here gives you a Job whose pod is
# Pending on a claim that does not exist.
pvc_name=$(ym 07-rwx-multiwriter.yaml PersistentVolumeClaim 'metadata.name')
check "09 claimName -> 07 PVC" "$pvc_name" \
      "$(ym 09-fio-job.yaml Job 'spec.template.spec.volumes.0.persistentVolumeClaim.claimName' 2>/dev/null || true)"

# --- every weka-in-container tag must match terraform ---------------------
#
# A sweep rather than a per-file path, so a tag added to a NEW manifest is
# covered without anyone remembering to extend this script. The per-file checks
# above still run, because they name the field and give a better message.
want_image=$(get '03-weka-client.yaml : spec.image')
if [ -n "$want_image" ]; then
  found_images=$(grep -hoE 'quay\.io/weka\.io/weka-in-container:[A-Za-z0-9._-]+' ./*.yaml 2>/dev/null | sort -u)
  bad=0
  for img in $found_images; do
    [ "$img" = "$want_image" ] || { printf '  DRIFT %-44s %s  terraform=%s\n' "weka image tag sweep" "$img" "$want_image"; bad=1; fail=1; }
  done
  [ "$bad" -eq 0 ] && printf '  OK    %-44s %s\n' "weka image tag sweep (all *.yaml)" "$want_image"
fi

# --- the demo images must be pinned, and pinned to the SAME tag -----------
#
# 06, 07 and 08 all run busybox. Different tags across them is not a failure
# you would ever see -- it just quietly means the demo is no longer showing
# three replicas of the same thing -- and `:latest` anywhere means the demo is
# not reproducible on camera next month.
bb=$( { grep -hoE 'public\.ecr\.aws/docker/library/busybox:[A-Za-z0-9._-]+' ./*.yaml 2>/dev/null
        grep -hoE 'public\.ecr\.aws/docker/library/busybox:[A-Za-z0-9._-]+' ./*.sh   2>/dev/null; } | sort -u)
bb_count=$(printf '%s\n' "$bb" | sed '/^$/d' | wc -l | tr -d ' ')
if [ "$bb_count" = "1" ]; then
  printf '  OK    %-44s %s\n' "busybox tag consistent (06/07/08)" "$bb"
else
  printf '  DRIFT %-44s %s\n' "busybox tags disagree" "$(printf '%s' "$bb" | tr '\n' ' ')"; fail=1
fi
if printf '%s' "$bb" | grep -q ':latest'; then
  printf '  DRIFT %-44s pin a version\n' "busybox pinned to :latest"; fail=1
fi

# --- the fio file must fit inside the PVC quota ---------------------------
#
# capacityEnforcement: HARD makes the PVC request a real WEKA directory quota.
# An fio `size` larger than the quota does NOT fail at submission -- it fails
# partway through the write phase with ENOSPC, which reads as an IO error on
# the storage rather than as a sizing mistake in the job file.
pvc_req=$(ym 07-rwx-multiwriter.yaml PersistentVolumeClaim 'spec.resources.requests.storage')
fio_size=$(sed -n 's/^[[:space:]]*size=\([0-9A-Za-z]*\).*/\1/p' 09-fio-job.yaml | head -1)
pvc_b=$(to_bytes "$pvc_req"); fio_b=$(to_bytes "$fio_size")
if [ -n "$pvc_b" ] && [ -n "$fio_b" ] && [ "$pvc_b" -gt 0 ] 2>/dev/null; then
  if [ "$fio_b" -lt "$pvc_b" ]; then
    printf '  OK    %-44s fio size=%s inside PVC %s\n' "09 fio size vs 07 PVC quota" "$fio_size" "$pvc_req"
  else
    printf '  DRIFT %-44s fio size=%s >= PVC %s -- ENOSPC mid-run\n' "09 fio size vs 07 PVC quota" "$fio_size" "$pvc_req"; fail=1
  fi
else
  printf '  NOTE  %-44s could not parse (fio=%s pvc=%s)\n' "09 fio size vs 07 PVC quota" "$fio_size" "$pvc_req"
fi

# --- the new scripts have to be executable -------------------------------
#
# demo.sh runs 08 directly. A non-executable 08 fails mid-demo, at beat 5,
# after everything expensive has already been set up.
for f in 08-persistence-check.sh demo.sh check-manifests.sh 00-namespace-and-secrets.sh; do
  if [ -x "$f" ]; then
    printf '  OK    %-44s executable\n' "$f"
  else
    printf '  DRIFT %-44s not executable -- chmod +x %s\n' "$f" "$f"; fail=1
  fi
done

# --- 07 needs one schedulable client node per replica --------------------
#
# The ONLY check here that is against the live cluster rather than against
# Terraform, because the live node count is what actually decides it -- and
# because the two disagree by default: client_node_count is 3 in variables.tf
# but terraform.tfvars.example sets 1, and the deployment in the README was
# verified with 1.
#
# podAntiAffinity on kubernetes.io/hostname is `required`, so surplus replicas
# do not spread -- they sit in Pending with "node(s) didn't match pod
# anti-affinity rules", which reads like a scheduling bug rather than a node
# count.
replicas=$(ym 07-rwx-multiwriter.yaml Deployment 'spec.replicas')
if kubectl version --request-timeout=8s >/dev/null 2>&1; then
  # shellcheck disable=SC2046  # node names never contain whitespace
  set -- $(kubectl get nodes -l weka.io/supports-clients=true \
             -o jsonpath='{range .items[?(@.spec.unschedulable!=true)]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
  nodes=$#
  if [ -n "$replicas" ] && [ "$nodes" -ge "$replicas" ]; then
    printf '  OK    %-44s %s replicas <= %s schedulable client nodes\n' "07 replicas vs client nodes" "$replicas" "$nodes"
  else
    printf '  DRIFT %-44s %s replicas > %s schedulable client nodes\n' "07 replicas vs client nodes" "$replicas" "$nodes"
    printf '        %s\n' "raise client_node_count (variables.tf default 3; the example sets 1) or lower replicas in 07"
    fail=1
  fi
  # 08 cordons the writer's node, so it needs somewhere else to go.
  if [ "$nodes" -ge 2 ]; then
    printf '  OK    %-44s %s schedulable client nodes\n' "08 needs >= 2 nodes" "$nodes"
  else
    printf '  DRIFT %-44s only %s -- 08 cannot reschedule after the cordon\n' "08 needs >= 2 nodes" "$nodes"; fail=1
  fi
else
  printf '  NOTE  %-44s skipping (kubectl not reachable)\n' "07/08 node-count checks"
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
