#!/usr/bin/env bash
# Tear down the repro: delete the kind cluster and remove the cache dir.

set -euo pipefail

CLUSTER="${CLUSTER:-ambient-repro}"
WORK_DIR="${WORK_DIR:-$HOME/.cache/istio-hbone-wedge-repro}"

kind delete cluster --name "${CLUSTER}" 2>/dev/null || echo "cluster ${CLUSTER} not present"
rm -rf "${WORK_DIR}"
echo "cleaned up: cluster '${CLUSTER}' and ${WORK_DIR}"
echo
echo "Note: if you ran 'export KUBECONFIG=${WORK_DIR}/kubeconfig' in this shell,"
echo "      run 'unset KUBECONFIG' or 'export KUBECONFIG=~/.kube/config' now —"
echo "      otherwise kubectl will keep pointing at the deleted cluster."
