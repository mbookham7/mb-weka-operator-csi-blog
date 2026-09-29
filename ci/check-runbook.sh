#!/usr/bin/env bash
#
# Does the runbook Terraform PRINTS still match the runbook the README
# documents?
#
# WHY THIS EXISTS
#
# `output "next_steps"` in outputs.tf is the most trusted text in the repo,
# precisely because it comes out of the thing that built the infrastructure.
# That makes a wrong one worse than no runbook at all, and it has been wrong
# twice:
#
#   1. It omitted 02-weka-nics-policy.yaml, so anyone following the printed
#      output rather than the README walked into
#      "1 Insufficient weka.io/weka-nics" against a healthy cluster and a
#      healthy node -- the exact failure demo.sh beat 2 exists to teach.
#
#   2. The RWX payoff command rendered `$2` instead of `\$2`. Terraform leaves
#      a bare $ followed by a digit alone, so the source looked fine; bash then
#      expanded it to empty inside the outer double quotes, awk received
#      '{print }' and printed whole lines with a count of 1 each. A WRONG
#      ANSWER that looks like a working command -- no error, no exit code.
#
# Neither is catchable by reading the source. Both require RENDERING the
# heredoc and looking at the bytes, which is what this does.
#
# HOW
#
# next_steps is an output, and `terraform console` cannot evaluate outputs, and
# `terraform output` needs state this repo will not have in CI. So the heredoc
# is lifted into a scratch module as a local, with its interpolations stubbed,
# and rendered there. The stubs only replace ${...} references -- the template
# syntax under test (the escaping, the backslash continuations) is untouched.
#
# Usage:  ./ci/check-runbook.sh
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUTS="$REPO/weka-eks-terraform/outputs.tf"
README="$REPO/README.md"

command -v terraform >/dev/null || { echo "terraform not found" >&2; exit 1; }
for f in "$OUTPUTS" "$README"; do
  [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> Lifting the next_steps heredoc into a scratch module"
python3 - "$OUTPUTS" "$tmp" <<'PY'
import re, sys
outputs, tmp = sys.argv[1], sys.argv[2]
src = open(outputs).read()

m = re.search(r'output "next_steps" \{.*?value\s*=\s*<<-EOT\n(.*?)\n  EOT\n\}', src, re.S)
if not m:
    sys.exit("could not find the next_steps heredoc in outputs.tf")
body = m.group(1)

# Values only. Anything that is not a plain var/local/module reference is left
# alone so that a stray ${...} shows up as an error rather than being papered
# over.
stubs = {
    '${var.region}': 'eu-west-1',
    '${var.prefix}': 'weka',
    '${var.cluster_name}': 'poc',
    '${var.weka_cluster_size}': '6',
    '${var.weka_filesystem_name}': 'default',
    '${var.weka_instance_type}': 'i3en.6xlarge',
    '${var.client_instance_type}': 'm6i.8xlarge',
    '${var.client_node_count}': '3',
    '${module.weka.weka_cluster_admin_password_secret_id}': 'weka/poc/weka-password',
    '${module.eks.cluster_name}': 'weka-poc-eks',
    '${local.weka_hugepages_gib}': '7',
    '${local.ttl_expires_at}': '2026-01-01T12:00:00Z',
    '${var.ttl_hours}': '8',
}
for k, v in stubs.items():
    body = body.replace(k, v)

left = re.findall(r'\$\{[^}]*\}', body)
if left:
    sys.exit(f"unstubbed interpolation(s) in next_steps: {sorted(set(left))}\n"
             f"add them to the stub table in ci/check-runbook.sh")

open(f'{tmp}/main.tf', 'w').write('locals {\n  rendered = <<-EOT\n' + body + '\n  EOT\n}\n')
PY

echo "==> Rendering it with terraform console"
terraform -chdir="$tmp" init -backend=false -input=false >/dev/null
echo 'local.rendered' | terraform -chdir="$tmp" console > "$tmp/raw" 2>&1

# terraform console prints a multi-line string wrapped in <<EOT / EOT, so what
# sits between them is the rendered value verbatim -- no unescaping needed.
python3 - "$tmp/raw" "$README" <<'PY'
import re, sys
raw_path, readme_path = sys.argv[1], sys.argv[2]
lines = open(raw_path).read().split('\n')
if not lines or lines[0].strip() != '<<EOT':
    sys.exit("terraform console did not return a heredoc:\n" + '\n'.join(lines[:10]))
end = max(i for i, l in enumerate(lines) if l.strip() == 'EOT')
text = '\n'.join(lines[1:end])

fails = []

def ok(msg):   print(f"  OK    {msg}")
def bad(msg):  fails.append(msg); print(f"  FAIL  {msg}")

# 1. Every manifest is named, and 02 comes before 03.
for f in ['01-weka-client-secret.yaml', '02-weka-nics-policy.yaml',
          '03-weka-client.yaml', '04-csi-api-secret.yaml',
          '05-storageclass-dir.yaml', '06-smoke-test.yaml',
          '07-rwx-multiwriter.yaml', '08-persistence-check.sh',
          '09-fio-job.yaml']:
    if f in text:
        ok(f"runbook names {f}")
    else:
        bad(f"runbook never mentions {f}")

if '02-weka-nics-policy.yaml' in text and '03-weka-client.yaml' in text:
    if text.index('02-weka-nics-policy.yaml') < text.index('03-weka-client.yaml'):
        ok("02 is applied before 03")
    else:
        bad("02 appears AFTER 03 -- the client will be unschedulable")

# 2. The drift check is advertised.
if './check-manifests.sh' in text:
    ok("runbook points at ./check-manifests.sh")
else:
    bad("runbook does not mention ./check-manifests.sh")

# 3. The RWX payoff command matches the README byte for byte. This is the
#    check that catches the $2-vs-\$2 class of bug.
def payoff(s):
    return [l.strip() for l in s.splitlines()
            if 'kubectl exec deploy/weka-rwx-demo' in l
            or 'shared.log | sort | uniq -c' in l]

rendered_cmd = payoff(text)
readme_cmd = payoff(open(readme_path).read())

if not rendered_cmd:
    bad("the RWX payoff command is missing from the runbook")
elif not readme_cmd:
    bad("the RWX payoff command is missing from the README")
elif rendered_cmd == readme_cmd:
    ok("RWX payoff command matches the README byte for byte")
else:
    bad("RWX payoff command differs between the runbook and the README")
    print(f"        runbook: {rendered_cmd}")
    print(f"        README : {readme_cmd}")

# 4. The awk field reference must survive the shell it gets pasted into.
#    Unescaped, bash expands $2 to empty and awk silently prints whole lines.
awk_lines = [l for l in rendered_cmd if 'awk' in l]
if awk_lines and all('\\$2' in l for l in awk_lines):
    ok(r"awk field reference is escaped (\$2), so bash will not eat it")
elif awk_lines:
    bad(r"awk field reference is NOT escaped -- rendered $2 instead of \$2; "
        "bash expands it to empty and awk prints whole lines")

print()
if fails:
    print(f"RUNBOOK CHECK FAILED ({len(fails)} problem(s)).")
    print("outputs.tf mirrors README step 6 -- fix both together.")
    sys.exit(1)
print("Runbook check passed -- what Terraform prints matches what the README documents.")
PY
