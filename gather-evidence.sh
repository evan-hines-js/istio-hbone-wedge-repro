#!/usr/bin/env bash
# Gather all relevant logs / configs / stats into ./evidence/.
#
# Run this WHILE THE GATEWAY IS WEDGED — i.e. immediately after watch-stats.sh
# shows rq_success frozen and rq_active pinned, BEFORE restarting the gateway
# pod. Once the gateway restarts, the live evidence is lost. (ztunnel logs
# persist across the gateway pod lifecycle, but envoy stats and access logs
# reset.)

set -euo pipefail

CLUSTER="${CLUSTER:-ambient-repro}"
WORK_DIR="${WORK_DIR:-$HOME/.cache/istio-hbone-wedge-repro}"
export KUBECONFIG="${WORK_DIR}/kubeconfig"

OUT_DIR="$(cd "$(dirname "$0")" && pwd)/evidence"
mkdir -p "${OUT_DIR}"

echo "==> gateway pod"
GW=$(kubectl get pod -n media -l "gateway.networking.k8s.io/gateway-name=ingress" -o name | head -1)
[ -n "$GW" ] || { echo "no gateway pod"; exit 1; }
echo "    $GW"

echo "==> jellyfin pod + node + ztunnel on that node"
JF=$(kubectl get pod -n media -l app=jellyfin -o name | head -1)
NODE=$(kubectl get pod -n media -l app=jellyfin -o jsonpath='{.items[0].spec.nodeName}')
ZT=$(kubectl get pod -n istio-system -l app=ztunnel --field-selector "spec.nodeName=${NODE}" -o name | head -1)
echo "    jellyfin: $JF on $NODE"
echo "    ztunnel:  $ZT"

echo
echo "==> 1/6 ztunnel logs (full tail, includes any RST_STREAM / errors / access entries)"
kubectl logs -n istio-system "$ZT" --tail=10000 2>/dev/null \
  | grep -E "stream error|RST_STREAM|INTERNAL_ERROR|error|access" \
  > "${OUT_DIR}/ztunnel.log" || true
echo "    $(wc -l < "${OUT_DIR}/ztunnel.log") lines (look for: stream error received: unexpected internal error encountered)"
RST_COUNT=$(grep -c "stream error received" "${OUT_DIR}/ztunnel.log" || true)
echo "    RST_STREAM(INTERNAL_ERROR) count: ${RST_COUNT}"

echo "==> 2/6 gateway envoy access log (look for 0 DC = downstream disconnected on stuck request)"
kubectl logs -n media "$GW" -c istio-proxy --tail=5000 2>/dev/null \
  | grep -E "^\[" \
  | sed -E 's/(ApiKey=)[^&" ]+/\1REDACTED/g; s/(api_key=)[^&" ]+/\1REDACTED/g; s/(deviceId=)[^&" ]+/\1REDACTED/g; s/(UserId=)[^&" ]+/\1REDACTED/g; s/(mediaSourceId=)[^&" ]+/\1REDACTED/g; s/(Tag=)[^&" ]+/\1REDACTED/g' \
  > "${OUT_DIR}/gateway-access-log.log" || true
echo "    $(wc -l < "${OUT_DIR}/gateway-access-log.log") access log lines"
DC_COUNT=$(grep -c " 0 DC " "${OUT_DIR}/gateway-access-log.log" || true)
echo "    \"0 DC\" (downstream disconnect) count: ${DC_COUNT}"

echo "==> 3/6 gateway envoy /clusters dump for jellyfin upstream (counter signature)"
kubectl exec -n media "$GW" -c istio-proxy -- pilot-agent request GET /clusters 2>/dev/null \
  | grep "outbound|8096||jellyfin" \
  > "${OUT_DIR}/gateway-clusters-jellyfin.txt" || true
echo "    $(wc -l < "${OUT_DIR}/gateway-clusters-jellyfin.txt") lines"
echo "    rq counters:"
grep -E "rq_active|rq_total|rq_success|rq_error|rq_timeout" "${OUT_DIR}/gateway-clusters-jellyfin.txt" | sed 's/^/      /'

echo "==> 4/6 gateway envoy istio_requests_total breakdown (response_code × response_flags)"
kubectl exec -n media "$GW" -c istio-proxy -- pilot-agent request GET stats 2>/dev/null \
  | grep "istio_requests_total.*destination_service.jellyfin" \
  | sed -En 's/.*response_code\.([0-9-]+)\.grpc_response_status\.response_flags\.([^.]+).*: ([0-9]+)/code=\1 flags=\2 count=\3/p' \
  | awk '{ key=$1 " " $2; split($3, v, "="); sum[key]+=v[2] } END { for (key in sum) print key " count=" sum[key] }' \
  | sort \
  > "${OUT_DIR}/gateway-requests-by-flag.txt" || true
echo "    breakdown:"
sed 's/^/      /' "${OUT_DIR}/gateway-requests-by-flag.txt"

echo "==> 5/6 envoy cluster config (HTTP/2 settings on connect_originate + inner + jellyfin)"
kubectl exec -n media "$GW" -c istio-proxy -- pilot-agent request GET /config_dump 2>/dev/null \
  | python3 -c '
import sys, json
d = json.load(sys.stdin)
out = []
for cfg in d.get("configs", []):
    for c in cfg.get("dynamic_active_clusters", []):
        n = c.get("cluster", {}).get("name", "")
        if n in ("connect_originate", "inner_connect_originate") or "jellyfin" in n:
            out.append(c["cluster"])
print(json.dumps(out, indent=2))
' > "${OUT_DIR}/gateway-cluster-configs.json" || true
echo "    $(wc -l < "${OUT_DIR}/gateway-cluster-configs.json") lines of envoy cluster config"

echo "==> 6/6 versions"
{
  echo "kind:    $(kind --version)"
  kubectl version --client 2>/dev/null | head -3
  echo
  echo "istio components:"
  kubectl get pod -n istio-system -o jsonpath='{range .items[*]}  {.metadata.name}: {.spec.containers[*].image}{"\n"}{end}'
  echo
  echo "gateway pod image:"
  kubectl get -n media "$GW" -o jsonpath='  {.spec.containers[*].image}{"\n"}'
  echo "jellyfin image (resolved digest):"
  kubectl get -n media "$JF" -o jsonpath='  {.status.containerStatuses[?(@.name=="jellyfin")].imageID}{"\n"}'
} > "${OUT_DIR}/versions.txt"
echo "    written"

echo
echo "================================================================"
echo "evidence written to ${OUT_DIR}"
ls -la "${OUT_DIR}"
echo
echo "Summary of bug indicators captured:"
echo "  RST_STREAM(INTERNAL_ERROR) count: ${RST_COUNT}"
echo "  Access-log \"0 DC\" count:          ${DC_COUNT}"
RQ_TOTAL=$(grep "rq_total" "${OUT_DIR}/gateway-clusters-jellyfin.txt" | awk -F:: '{print $NF}' | head -1)
RQ_SUCC=$(grep "rq_success" "${OUT_DIR}/gateway-clusters-jellyfin.txt" | awk -F:: '{print $NF}' | head -1)
RQ_ACT=$(grep "rq_active" "${OUT_DIR}/gateway-clusters-jellyfin.txt" | awk -F:: '{print $NF}' | head -1)
RQ_ERR=$(grep "rq_error" "${OUT_DIR}/gateway-clusters-jellyfin.txt" | awk -F:: '{print $NF}' | head -1)
RQ_TO=$(grep "rq_timeout" "${OUT_DIR}/gateway-clusters-jellyfin.txt" | awk -F:: '{print $NF}' | head -1)
echo "  jellyfin upstream: rq_total=${RQ_TOTAL} rq_success=${RQ_SUCC} rq_active=${RQ_ACT} rq_error=${RQ_ERR} rq_timeout=${RQ_TO}"
echo "  if rq_active is high while rq_success is frozen and rq_error/rq_timeout are 0 → wedge confirmed"
echo "================================================================"
