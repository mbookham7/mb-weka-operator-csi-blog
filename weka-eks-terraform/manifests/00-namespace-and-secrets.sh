#!/usr/bin/env bash
#
# Installs the WEKA Operator (with the embedded CSI plugin) onto the EKS
# cluster built by the Terraform in the parent directory.
#
# Run this FIRST, before any of the numbered YAML files. It creates the
# namespace and image pull secrets those manifests assume, and installs the
# CRDs that 03-weka-client.yaml is an instance of.
#
# Prerequisites:
#   - kubectl pointing at the EKS cluster
#       aws eks update-kubeconfig --region <region> --name <cluster>
#   - helm 3.8+ (OCI registry support)
#   - QUAY_USERNAME / QUAY_PASSWORD in the environment
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# Pin the operator version. Get the version to use from WEKA Customer Success
# along with your Quay credentials -- the operator, the weka-in-container
# image in 03-weka-client.yaml, and your backend cluster's WEKA release all
# have to be a supported combination. Do not just take "latest".
WEKA_OPERATOR_VERSION="${WEKA_OPERATOR_VERSION:-v1.16.0}"

OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-weka-operator-system}"
PULL_SECRET_NAME="${PULL_SECRET_NAME:-quay-io-robot-secret}"
CHART_REF="oci://quay.io/weka.io/helm/weka-operator"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
: "${QUAY_USERNAME:?set QUAY_USERNAME -- Quay robot account from WEKA Customer Success}"
: "${QUAY_PASSWORD:?set QUAY_PASSWORD -- Quay robot account from WEKA Customer Success}"

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
command -v helm    >/dev/null || { echo "helm not found" >&2; exit 1; }

echo "==> Target cluster: $(kubectl config current-context)"

# ---------------------------------------------------------------------------
# 1. Namespace
# ---------------------------------------------------------------------------
# `create --dry-run=client | apply` instead of plain `create` so this script is
# idempotent -- you will run it again after bumping WEKA_OPERATOR_VERSION.
echo "==> Creating namespace ${OPERATOR_NAMESPACE}"
kubectl create namespace "${OPERATOR_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -

# ---------------------------------------------------------------------------
# 2. Image pull secret, in BOTH namespaces
# ---------------------------------------------------------------------------
# The secret is needed in two places and Kubernetes does not share secrets
# across namespaces:
#
#   weka-operator-system  the operator, the CSI controller and node plugins,
#                         and the node agent all pull from quay.io
#   default               anything you schedule that references the WEKA
#                         images directly -- and it is where most people put
#                         their first WekaClient before moving it
#
# If you put your WekaClient or workloads in a third namespace, copy the
# secret there too.
for ns in "${OPERATOR_NAMESPACE}" default; do
  echo "==> Creating ${PULL_SECRET_NAME} in namespace ${ns}"
  kubectl create secret docker-registry "${PULL_SECRET_NAME}" \
    --namespace "${ns}" \
    --docker-server=quay.io \
    --docker-username="${QUAY_USERNAME}" \
    --docker-password="${QUAY_PASSWORD}" \
    --docker-email="${QUAY_USERNAME}" \
    --dry-run=client -o yaml | kubectl apply -f -
done

# ---------------------------------------------------------------------------
# 3. CRDs, applied separately from the chart
# ---------------------------------------------------------------------------
# Helm only installs CRDs from a chart's crds/ directory on FIRST install and
# never updates them on upgrade. Pulling the chart and applying the CRDs with
# kubectl means an operator upgrade that adds or changes CRD fields actually
# takes effect, instead of leaving the new operator talking to an old schema.
echo "==> Logging in to quay.io"
echo "${QUAY_PASSWORD}" | helm registry login quay.io \
  --username "${QUAY_USERNAME}" --password-stdin

echo "==> Pulling chart ${WEKA_OPERATOR_VERSION} and applying CRDs"
rm -rf weka-operator
helm pull "${CHART_REF}" --version "${WEKA_OPERATOR_VERSION}" --untar

# --server-side because the WEKA CRDs carry large schemas that can exceed the
# annotation size limit used by client-side apply.
kubectl apply --server-side -f weka-operator/crds

# ---------------------------------------------------------------------------
# 4. The operator
# ---------------------------------------------------------------------------
#   csi.installationEnabled=true   Install the CSI plugin as part of the
#                                  operator. This is what makes
#                                  provisioner: csi.weka.io resolvable. Without
#                                  it you get a working WekaClient and PVCs
#                                  that sit in Pending forever.
#
#   imagePullSecret=...            Chart-wide pull secret for the operator's
#                                  own pods. Note this is separate from
#                                  spec.imagePullSecret on the WekaClient CR --
#                                  that one governs the client container image.
#
#   cleanupRemovedNodes=true       When a node disappears, deregister its WEKA
#                                  client container from the backend cluster.
#                                  On EKS nodes are cattle -- spot
#                                  interruptions, AMI rolls, instance refreshes
#                                  -- and without this the backend accumulates
#                                  stale client entries that count against
#                                  cluster limits and clutter `weka status`.
echo "==> Installing weka-operator ${WEKA_OPERATOR_VERSION}"
helm upgrade --install weka-operator ./weka-operator \
  --namespace "${OPERATOR_NAMESPACE}" \
  --version "${WEKA_OPERATOR_VERSION}" \
  --set csi.installationEnabled=true \
  --set imagePullSecret="${PULL_SECRET_NAME}" \
  --set cleanupRemovedNodes=true \
  --wait --timeout 10m

# ---------------------------------------------------------------------------
echo
echo "==> Done. Verify with:"
echo "      kubectl -n ${OPERATOR_NAMESPACE} get pods"
echo "      kubectl get crd | grep weka"
echo
echo "    Next: 01-weka-client-secret.yaml (copy the .example and fill it in)"
