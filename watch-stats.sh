#!/usr/bin/env bash
# Poll the Istio gateway envoy's upstream cluster stats and surface the
# counter signature while jellyfin video playback is running.
#
# Run this in a separate terminal AFTER repro.sh is up and you have started
# playback in the browser. Aggressive seeking in the player is the reliable
# trigger; passive linear playback may wedge more slowly in some runs but is
# not reliable.

set -euo pipefail

CLUSTER="${CLUSTER:-ambient-repro}"
WORK_DIR="${WORK_DIR:-$HOME/.cache/istio-hbone-wedge-repro}"
export KUBECONFIG="${WORK_DIR}/kubeconfig"
INTERVAL="${INTERVAL:-3}"
DURATION="${DURATION:-300}"

GW=$(kubectl get pod -n media -l "gateway.networking.k8s.io/gateway-name=ingress" -o name | head -1)
[ -n "$GW" ] || { echo "no gateway pod found — is repro.sh up?"; exit 1; }

# Sum each counter across all endpoints of the cluster (resilient to replica
# count or transient endpoint changes).
counter_sum() {
  local name="$1"
  awk -F:: -v n="$name" '$0 ~ "::"n"::" {sum+=$NF} END {print sum+0}'
}

echo "watching gateway envoy upstream stats every ${INTERVAL}s for ${DURATION}s..."
echo "gap = rq_total - rq_success - rq_active   (requests not yet in success or active)"
echo
printf "%-9s | %6s %6s | %6s %6s %7s | %s\n" "time" "cx_act" "cx_tot" "rq_act" "rq_tot" "rq_succ" "gap"
echo "----------+-----------------+----------------------+-----"

START=$(date +%s)
while :; do
  NOW=$(date +%s)
  if [ $((NOW - START)) -ge "$DURATION" ]; then break; fi

  TS=$(date +%H:%M:%S)
  STATS=$(kubectl exec -n media "$GW" -c istio-proxy -- pilot-agent request GET /clusters 2>/dev/null \
            | grep "outbound|8096||jellyfin" || true)

  if [ -z "$STATS" ]; then
    printf "%s | (no stats — gateway has not seen jellyfin traffic yet)\n" "$TS"
    sleep "$INTERVAL"
    continue
  fi

  CXA=$(echo "$STATS" | counter_sum cx_active)
  CXT=$(echo "$STATS" | counter_sum cx_total)
  RQA=$(echo "$STATS" | counter_sum rq_active)
  RQT=$(echo "$STATS" | counter_sum rq_total)
  RQS=$(echo "$STATS" | counter_sum rq_success)
  GAP=$(( RQT - RQS - RQA ))

  printf "%-9s | %6d %6d | %6d %6d %7d | %d\n" "$TS" "$CXA" "$CXT" "$RQA" "$RQT" "$RQS" "$GAP"
  sleep "$INTERVAL"
done
