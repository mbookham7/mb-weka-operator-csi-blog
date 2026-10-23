#!/usr/bin/env bash
#
# Fills the WEKA admin password and the client join token into
# 01-weka-client-secret.yaml and 04-csi-api-secret.yaml.
#
#     ./fill-secrets.sh
#
# WHY THIS EXISTS
#
# Both files want base64 of a credential, and the two obvious ways to get it
# there are both traps:
#
#   echo 'pw' | base64            encodes the trailing newline too, and WEKA
#                                 then fails auth looking exactly like a wrong
#                                 password -- so you suspect the password
#   aws ssm send-command ... 'pw' records the credential in SSM command history
#
# This script does neither. The password goes from Secrets Manager into a
# shell variable and never reaches argv, a log, or the terminal; the token is
# read with `read -rs` so it is not echoed and not in shell history; both are
# encoded with printf rather than echo.
#
# The secret id comes from Terraform rather than being reconstructed by hand.
# The module's naming is <prefix>/<prefix>-<cluster_name>/weka-password -- the
# prefix appears TWICE -- and a hand-built id that gets that wrong returns
# ResourceNotFoundException, which is indistinguishable from "already gone".
# See docs/deployment.md.
#
set -euo pipefail
cd "$(dirname "$0")"

command -v aws >/dev/null || { echo "FAILED: aws CLI not found"; exit 1; }

echo "==> Resolving the password secret id from Terraform"
# `terraform output -raw <name>` EXITS 0 when the state has no outputs at all,
# and prints its "No outputs found" warning on stdout -- so neither the exit
# code nor emptiness is a reliable guard. Without validating the shape, that
# warning text ends up as the --secret-id and --region, and the script dies
# with "Provided region_name '... Warning: No outputs found ...' doesn't match
# a supported format" instead of saying what is actually wrong.
SECRET_ARN=$(terraform -chdir=.. output -raw weka_password_secret_id 2>/dev/null || true)
case "$SECRET_ARN" in
  arn:aws:secretsmanager:*) ;;
  *)
    echo "FAILED: no usable weka_password_secret_id from Terraform."
    echo "        Run this from manifests/ with the deployment applied."
    echo "        ('terraform output -raw weka_password_secret_id' must print an ARN.)"
    exit 1
    ;;
esac

REGION=$(terraform -chdir=.. output -raw region 2>/dev/null || true)
case "$REGION" in
  [a-z][a-z]-[a-z]*-[0-9]) REGION_ARG=(--region "$REGION") ;;
  *) REGION_ARG=() ;;            # fall back to the caller's configured region
esac
echo "    $SECRET_ARN"

echo "==> Reading the admin password (username is 'admin')"
PW=$(aws secretsmanager get-secret-value "${REGION_ARG[@]}" \
       --secret-id "$SECRET_ARN" --query SecretString --output text)
[ -n "$PW" ] || { echo "FAILED: empty password"; exit 1; }
echo "    got it (${#PW} chars, not printed)"

# printf, never echo -- see the header.
PW_B64=$(printf '%s' "$PW" | base64)

# -----------------------------------------------------------------------------
# 04's endpoints
# -----------------------------------------------------------------------------
# Filling the password and the token but not this is how you end up with a
# credential file that is complete, consistent, and wrong: `endpoints` keeps
# whatever the .example ships (10.0.1.10:14000 and friends), pointing the CSI
# controller at addresses that do not exist. check-manifests.sh will not catch
# it either -- it looks for REPLACE_ME, and placeholder endpoints are
# valid-looking base64 of a plausible address.
#
# Backend IPs are not a Terraform output: the backends sit in an autoscaling
# group the module's healing Lambdas can replace, so the addresses are not
# known at plan time. weka_backend_ips_command emits the lookup instead.
echo "==> Resolving backend IPs for 04's endpoints"
IPS_CMD=$(terraform -chdir=.. output -raw weka_backend_ips_command 2>/dev/null || true)
[ -n "$IPS_CMD" ] || { echo "FAILED: no weka_backend_ips_command output"; exit 1; }

# grep the addresses out rather than trusting the command's formatting, so a
# change from --output text to json upstream does not silently produce an
# endpoints string made of JSON punctuation.
IPS=$(printf '%s\n' "$IPS_CMD" | bash 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -3)
COUNT=$(printf '%s\n' "$IPS" | grep -c . || true)
[ "$COUNT" -ge 2 ] || {
  echo "FAILED: found $COUNT backend IP(s); the CSI secret wants at least 2."
  echo "        Is the cluster up? Try: terraform output -raw weka_backend_ips_command | bash"
  exit 1
}
ENDPOINTS=$(printf '%s\n' "$IPS" | sed 's/$/:14000/' | paste -sd, -)
echo "    $ENDPOINTS"
ENDPOINTS_B64=$(printf '%s' "$ENDPOINTS" | base64)

echo "==> The join token is generated ON a backend, authenticated:"
echo "      weka cluster join-token generate --access-token-timeout 52w"
printf '    Paste it here (not echoed): '
read -rs TOKEN; echo
[ -n "$TOKEN" ] || { echo "FAILED: empty token"; exit 1; }
TOKEN_B64=$(printf '%s' "$TOKEN" | base64)

for f in 01-weka-client-secret.yaml 04-csi-api-secret.yaml; do
  [ -f "$f" ] || { echo "FAILED: $f missing -- copy it from its .example first"; exit 1; }
  sed -i.bak "s#^  password: .*#  password: ${PW_B64}#" "$f" && rm -f "$f.bak"
  echo "    filled password in $f"
done

sed -i.bak "s#^  join-secret: .*#  join-secret: ${TOKEN_B64}#" 01-weka-client-secret.yaml
rm -f 01-weka-client-secret.yaml.bak
echo "    filled join-secret in 01-weka-client-secret.yaml"

sed -i.bak "s#^  endpoints: .*#  endpoints: ${ENDPOINTS_B64}#" 04-csi-api-secret.yaml
rm -f 04-csi-api-secret.yaml.bak
echo "    filled endpoints in 04-csi-api-secret.yaml"

echo "==> Verifying no placeholders remain"
if grep -l "REPLACE_ME\|UkVQTEFDRV" 01-weka-client-secret.yaml 04-csi-api-secret.yaml 2>/dev/null; then
  echo "    WARNING: placeholders still present in the files listed above"
  exit 1
fi
echo "    clean."
echo
echo "Next: ./check-manifests.sh"
