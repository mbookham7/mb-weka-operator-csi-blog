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
# Usage, from this directory:
#
#     ./check-manifests.sh              needs Terraform state and, ideally, a cluster
#     ./check-manifests.sh --offline    files only -- no Terraform, no kubectl
#
# THE TWO MODES ASK DIFFERENT QUESTIONS, and --offline is not merely a subset.
#
#   default    "is MY WORKING COPY ready to apply?"  Compares the manifests
#              against `terraform output manifest_values`, checks the cluster
#              prerequisites, and insists the placeholders are filled in.
#
#   --offline  "is THE REPO internally consistent as committed?"  Runs every
#              check that needs only the files, and then inverts the two
#              placeholder checks, because in a clean checkout the placeholders
#              are the CORRECT state:
#
#                03-weka-client.yaml MUST still say REPLACE -- real backend IPs
#                in git are live infrastructure detail the next reader inherits
#                and cannot use.
#
#                01-weka-client-secret.yaml and 04-csi-api-secret.yaml MUST NOT
#                EXIST -- they are gitignored, and a checkout that has them is a
#                checkout where somebody committed a WEKA admin password.
#
#              That makes --offline a credential-leak check as well as a
#              consistency check, which is why CI runs it on every push.
#
set -uo pipefail

OFFLINE=0
case "${1:-}" in
  --offline) OFFLINE=1 ;;
  "") ;;
  -h|--help) sed -n '2,/^set -uo/p' "$0" | sed 's/^#\{1,\} \{0,1\}//; s/^#$//' | sed '$d'; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac

TFDIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$(dirname "$0")" || exit 1

vals=""
if [ "$OFFLINE" -eq 0 ]; then
  # `terraform output` needs the input variables to be resolvable.
  # shellcheck source=/dev/null  # .env is gitignored and per-developer
  [ -f "$TFDIR/../.env" ] && { set -a; . "$TFDIR/../.env"; set +a; }

  echo "Reading authoritative values from terraform output manifest_values..."
  vals=$(cd "$TFDIR" && terraform output -json manifest_values 2>/dev/null)
  if [ -z "$vals" ] || [ "$vals" = "null" ]; then
    echo "ERROR: could not read 'terraform output -json manifest_values'." >&2
    echo "       Run this after 'terraform apply', from a shell that can read the state." >&2
    echo "       For the file-only checks that need neither Terraform nor a cluster:" >&2
    echo "           ./check-manifests.sh --offline" >&2
    exit 2
  fi
else
  echo "OFFLINE MODE -- files only. Skipping Terraform state and cluster checks."
fi

get() { printf '%s' "$vals" | python3 -c "import json,sys; print(json.load(sys.stdin).get(sys.argv[1],''))" "$1"; }

fail=0

# --- what does the REPOSITORY say, as opposed to the working tree? -------
#
# Offline mode asks "is the repo internally consistent as committed?", so it
# has to read git rather than the filesystem. Locally these differ in exactly
# the ways that matter: 01/04 exist on disk (correctly, gitignored) and
# 03-weka-client.yaml has your real backend IPs in it (correctly, you edited
# it in place). Neither is committed, and a filesystem check would report both
# as failures on a perfectly clean repo.
#
# Outside a git checkout -- an exported tarball, say -- the filesystem IS the
# committed state, so fall back to it.
in_git() { git -C . rev-parse --is-inside-work-tree >/dev/null 2>&1; }

is_tracked() { # is_tracked <path>
  if in_git; then git ls-files --error-unmatch "$1" >/dev/null 2>&1
  else [ -f "$1" ]; fi
}

committed_content() { # committed_content <path> -- what git would ship
  #
  # HEAD first, then the INDEX. A file that is staged but not yet committed
  # exists as far as `git ls-files` is concerned but has no HEAD blob, and
  # reading an empty one would look identical to "the placeholder was
  # removed" -- which is the wrong answer at exactly the moment someone is
  # about to commit a new file. The index is what they are about to commit,
  # so it is the honest thing to check.
  if in_git; then
    git show "HEAD:./$1" 2>/dev/null || git show ":./$1" 2>/dev/null
  else
    cat "$1" 2>/dev/null
  fi
}

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

# Names of every document of a given kind in a multi-doc file.
ym_list() { ruby -ryaml -e '
  f = File.read(ARGV[0])
  docs = (Psych::VERSION.split(".")[0].to_i >= 4 ? YAML.load_stream(f, aliases: true) : YAML.load_stream(f)).compact
  docs.each { |d| puts d["metadata"]["name"] if d.is_a?(Hash) && d["kind"] == ARGV[1] }
' "$1" "$2" 2>/dev/null; }

# A PDB's matchLabels rendered as the k=v,k=v that `kubectl -l` wants.
ym_pdb_selector() { ruby -ryaml -e '
  f = File.read(ARGV[0])
  docs = (Psych::VERSION.split(".")[0].to_i >= 4 ? YAML.load_stream(f, aliases: true) : YAML.load_stream(f)).compact
  d = docs.find { |x| x.is_a?(Hash) && x["kind"] == "PodDisruptionBudget" && x["metadata"]["name"] == ARGV[1] }
  exit if d.nil?
  m = d.dig("spec", "selector", "matchLabels") || {}
  puts m.map { |k, v| "#{k}=#{v}" }.join(",")
' "$1" "$2" 2>/dev/null; }

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
if [ "$OFFLINE" -eq 1 ]; then
  printf '  SKIP  %-44s offline mode\n' "cluster checks"
elif kubectl version --request-timeout=8s >/dev/null 2>&1; then
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
if [ "$OFFLINE" -eq 1 ]; then
  echo "Comparing manifests against Terraform: SKIPPED (offline)"
else
echo "Comparing manifests against Terraform:"
check "03 spec.coresNum"              "$(get '03-weka-client.yaml : spec.coresNum')"        "$(y 03-weka-client.yaml 'spec.coresNum')"
check "03 spec.image"                 "$(get '03-weka-client.yaml : spec.image')"           "$(y 03-weka-client.yaml 'spec.image')"
check "02 dataNICsNumber"             "$(get '02-weka-nics-policy.yaml : dataNICsNumber')"  "$(y 02-weka-nics-policy.yaml 'spec.payload.ensureNICsPayload.dataNICsNumber')"
check "02 spec.image"                 "$(get '02-weka-nics-policy.yaml : spec.image')"      "$(y 02-weka-nics-policy.yaml 'spec.image')"
check "05 filesystemName"             "$(get '05-storageclass-dir.yaml : filesystemName')"  "$(y 05-storageclass-dir.yaml 'parameters.filesystemName')"
fi

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
want_image=""
[ "$OFFLINE" -eq 0 ] && want_image=$(get '03-weka-client.yaml : spec.image')
if [ "$OFFLINE" -eq 1 ]; then
  # Terraform is the authority on the tag, so offline cannot say whether the
  # tag is RIGHT -- only that every manifest agrees with every other. A
  # disagreement is a bug either way, and it is the half CI can prove.
  swept=$(grep -hoE 'quay\.io/weka\.io/weka-in-container:[A-Za-z0-9._-]+' ./*.yaml 2>/dev/null | sort -u)
  n=$(printf '%s\n' "$swept" | sed '/^$/d' | wc -l | tr -d ' ')
  if [ "$n" = "1" ]; then
    printf '  OK    %-44s %s\n' "weka image tags agree across manifests" "$swept"
  else
    printf '  DRIFT %-44s %s\n' "weka image tags disagree" "$(printf '%s' "$swept" | tr '\n' ' ')"; fail=1
  fi
elif [ -n "$want_image" ]; then
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

# --- PodDisruptionBudgets: the selector has to match something -----------
#
# A PDB whose selector matches no pods is SILENTLY INERT. It exists, it shows
# ALLOWED DISRUPTIONS, `kubectl get pdb` looks healthy, and it restrains
# nothing -- the same "looks like protection, provides none" shape as a budget
# with no subscribers.
#
# The client pod labels come from the operator's controller at runtime, not
# from the Helm chart, so 10-poddisruptionbudgets.yaml ships with a
# REPLACE_ME selector you fill in per operator version -- the same convention
# as joinIpPorts in 03. Offline inverts it, for the same reason: in a clean
# checkout the placeholder is the correct committed state.
if [ -f 10-poddisruptionbudgets.yaml ]; then
  if [ "$OFFLINE" -eq 1 ]; then
    # An untracked file has no committed copy, and reading one returns empty
    # -- which would otherwise look identical to "the placeholder was
    # removed". Say which it is.
    if ! is_tracked 10-poddisruptionbudgets.yaml; then
      printf '  NOTE  %-44s not committed yet -- nothing to check\n' "10-poddisruptionbudgets.yaml"
    elif committed_content 10-poddisruptionbudgets.yaml | grep -q 'REPLACE_ME'; then
      printf '  OK    %-44s committed copy still has its placeholder\n' "10-poddisruptionbudgets.yaml"
    else
      printf '  NOTE  %-44s placeholder filled in the committed copy\n' "10-poddisruptionbudgets.yaml"
      printf '        %s\n' "harmless if the label is generic, but it is operator-version specific --"
      printf '        %s\n' "check it is not just your cluster's labels baked into the repo"
    fi
  elif grep -q 'REPLACE_ME' 10-poddisruptionbudgets.yaml; then
    printf '  TODO  %-44s selector still REPLACE_ME -- the PDB will match nothing\n' "10-poddisruptionbudgets.yaml"
    printf '        %s\n' "kubectl -n weka-operator-system get pods --show-labels"
    fail=1
  else
    printf '  OK    %-44s selector filled in\n' "10-poddisruptionbudgets.yaml"
  fi

  # Against a live cluster, prove each selector actually matches pods.
  if [ "$OFFLINE" -eq 0 ] && kubectl version --request-timeout=8s >/dev/null 2>&1; then
    for pdb in $(ym_list 10-poddisruptionbudgets.yaml PodDisruptionBudget); do
      sel=$(ym_pdb_selector 10-poddisruptionbudgets.yaml "$pdb")
      if [ -z "$sel" ] || printf '%s' "$sel" | grep -q 'REPLACE_ME'; then
        continue
      fi
      n=$(kubectl -n weka-operator-system get pods -l "$sel" -o name 2>/dev/null | grep -c . || true)
      if [ "${n:-0}" -gt 0 ]; then
        printf '  OK    %-44s %s matches %s pod(s)\n' "pdb/$pdb selector" "$sel" "$n"
      else
        printf '  DRIFT %-44s %s matches NO pods -- the PDB protects nothing\n' "pdb/$pdb selector" "$sel"
        fail=1
      fi
    done
  fi
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
# but terraform.tfvars.example sets 1, and the deployment in docs/verified.md was
# verified with 1.
#
# podAntiAffinity on kubernetes.io/hostname is `required`, so surplus replicas
# do not spread -- they sit in Pending with "node(s) didn't match pod
# anti-affinity rules", which reads like a scheduling bug rather than a node
# count.
replicas=$(ym 07-rwx-multiwriter.yaml Deployment 'spec.replicas')
if [ "$OFFLINE" -eq 1 ]; then
  printf '  SKIP  %-44s offline mode (needs a cluster)\n' "07/08 node-count checks"
elif kubectl version --request-timeout=8s >/dev/null 2>&1; then
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
#
# OFFLINE INVERTS THIS. In a clean checkout the placeholders are the correct
# state and their ABSENCE is the bug: it means someone committed live backend
# IPs. Those are not secret, but they are infrastructure detail that stops
# being true the moment the ASG heals a node, and the next reader inherits
# addresses that route nowhere.
if [ "$OFFLINE" -eq 1 ]; then
  # The COMMITTED blob, not your working copy -- editing it locally is the
  # documented workflow, committing the result is the mistake.
  if committed_content 03-weka-client.yaml | grep -q 'REPLACE'; then
    printf '  OK    %-44s committed copy still has placeholders\n' "03-weka-client.yaml"
  else
    printf '  FAIL  %-44s committed copy has NO placeholders -- real backend IPs in git?\n' "03-weka-client.yaml"
    printf '        %s\n' "edit joinIpPorts locally; do not commit the edit"
    fail=1
  fi
elif grep -q 'REPLACE' 03-weka-client.yaml; then
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
#
# OFFLINE INVERTS THIS TOO, and this is the one that matters most. Both files
# are gitignored. A CI checkout that CONTAINS one is a checkout where somebody
# force-added a file holding the WEKA admin password, the join token and the
# CSI API credentials -- in a public repo. Fail loudly and early.
for f in 01-weka-client-secret.yaml 04-csi-api-secret.yaml; do
  if [ "$OFFLINE" -eq 1 ]; then
    # TRACKED, not merely present. Having these on disk is normal and correct;
    # having them in git means a WEKA admin password is in a public repo.
    if is_tracked "$f"; then
      printf '  FAIL  %-44s TRACKED IN GIT -- credentials committed\n' "$f"
      printf '        %s\n' "this file is gitignored, so it took a force-add. Rotate the WEKA admin"
      printf '        %s\n' "password and the join token, then purge it from history."
      fail=1
    else
      printf '  OK    %-44s untracked, as it should be\n' "$f"
    fi
  elif [ -f "$f" ]; then
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
  if [ "$OFFLINE" -eq 1 ]; then
    echo "All offline checks passed -- the repo is internally consistent and no"
    echo "credentials or live backend IPs are committed. Run without --offline"
    echo "against a real deployment to also check the manifests against Terraform."
  else
    echo "All checks passed -- prerequisites present and manifests agree with Terraform."
  fi
else
  if [ "$OFFLINE" -eq 1 ]; then
    echo "CHECKS FAILED. The repository is not internally consistent:"
    echo "  - DRIFT on a value -> two files that must agree do not"
    echo "  - FAIL on 03       -> real backend IPs look committed; restore the placeholders"
    echo "  - FAIL on 01 / 04  -> a gitignored credential file is in the checkout. Rotate"
    echo "                        the WEKA admin password and join token, then purge it."
  else
    echo "CHECKS FAILED. Fix these before applying, or you will spend the next"
    echo "20 minutes debugging a Pending pod instead:"
    echo "  - MISSING prerequisite -> run ./00-namespace-and-secrets.sh first"
    echo "  - DRIFT on a value     -> 'terraform output manifest_values' is authoritative"
  fi
fi
exit "$fail"
