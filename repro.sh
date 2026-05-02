#!/usr/bin/env bash
# Minimal reproducer for an Istio ambient gateway wedge during sustained video playback.
#
# Brings up a single-node kind cluster (default kindnet CNI), installs Istio
# 1.29.2 in ambient mode (default profile, no env-var overrides), installs
# Gateway API v1.5.1 standard channel, enables access logging, deploys a
# single jellyfin pod pinned to the digest observed wedging, and stages a
# 62 MB MP4 in the kind node so jellyfin can serve it as a real media library.
#
# After this script, follow the manual browser steps in README.md to set up
# jellyfin's wizard, add the /media library, and play the video. Then run
# ./watch-stats.sh to observe the upstream cluster stats wedge.
#
# Idempotent: rerunning rebuilds the cluster from scratch.

set -euo pipefail

CLUSTER="${CLUSTER:-ambient-repro}"
ISTIO_VERSION="${ISTIO_VERSION:-1.29.2}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.5.1}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.31.0@sha256:25a3504b2b340954595fa7a6ed1575ef2edadf5abd83c0776a4308b64bf47c93}"
JELLYFIN_DIGEST="${JELLYFIN_DIGEST:-sha256:1694ff069f0c9dafb283c36765175606866769f5d72f2ed56b6a0f1be922fc37}"
VIDEO_URL="${VIDEO_URL:-https://download.blender.org/peach/bigbuckbunny_movies/BigBuckBunny_320x180.mp4}"

WORK_DIR="${WORK_DIR:-$HOME/.cache/istio-hbone-wedge-repro}"
KUBECONFIG_PATH="${WORK_DIR}/kubeconfig"
ISTIOCTL="${WORK_DIR}/istio-${ISTIO_VERSION}/bin/istioctl"
VIDEO_LOCAL="${WORK_DIR}/bbb.mp4"

mkdir -p "${WORK_DIR}"

step() { echo; echo "==> $*"; }

step "1) prerequisites"
for t in kind kubectl docker curl; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing: $t"; exit 1; }
done

step "2) download istioctl ${ISTIO_VERSION} (cached)"
case "$(uname -s)/$(uname -m)" in
  Linux/x86_64)  ISTIOCTL_ARCH="linux-amd64"  ;;
  Linux/aarch64) ISTIOCTL_ARCH="linux-arm64"  ;;
  Darwin/arm64)  ISTIOCTL_ARCH="osx-arm64"    ;;
  Darwin/x86_64) ISTIOCTL_ARCH="osx-amd64"    ;;
  *) echo "unsupported host: $(uname -s)/$(uname -m)"; exit 1 ;;
esac
if [ ! -x "${ISTIOCTL}" ]; then
  mkdir -p "${WORK_DIR}/istio-${ISTIO_VERSION}/bin"
  curl -sSL "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istioctl-${ISTIO_VERSION}-${ISTIOCTL_ARCH}.tar.gz" \
    | tar -xz -C "${WORK_DIR}/istio-${ISTIO_VERSION}/bin"
fi
"${ISTIOCTL}" version --remote=false

step "3) download test video (cached, ~62 MB)"
if [ ! -f "${VIDEO_LOCAL}" ]; then
  curl -sSLo "${VIDEO_LOCAL}" "${VIDEO_URL}"
fi
ls -lh "${VIDEO_LOCAL}"

step "4) fresh kind cluster (single-node, default kindnet CNI)"
kind delete cluster --name "${CLUSTER}" 2>/dev/null || true
cat <<EOF | kind create cluster --name "${CLUSTER}" --image "${KIND_NODE_IMAGE}" --kubeconfig "${KUBECONFIG_PATH}" --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - { containerPort: 30080, hostPort: 30080, protocol: TCP }
EOF
export KUBECONFIG="${KUBECONFIG_PATH}"

step "5) Gateway API ${GATEWAY_API_VERSION} (standard channel only)"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

step "6) Istio ${ISTIO_VERSION} ambient (default profile, no env-var overrides)"
"${ISTIOCTL}" install --set profile=ambient -y

step "7) enable mesh access logging (default Istio install does NOT enable it)"
kubectl apply -f - <<'EOF'
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: mesh-default
  namespace: istio-system
spec:
  accessLogging:
  - providers:
    - name: envoy
EOF

step "8) media namespace, ambient-enrolled"
kubectl create namespace media
kubectl label namespace media istio.io/dataplane-mode=ambient

step "9) stage Big Buck Bunny in the kind node at /opt/media"
docker exec "${CLUSTER}-control-plane" mkdir -p /opt/media
docker cp "${VIDEO_LOCAL}" "${CLUSTER}-control-plane:/opt/media/bbb.mp4"
docker exec "${CLUSTER}-control-plane" ls -l /opt/media

step "10) jellyfin Deployment + Service (pinned digest, /media hostPath, /config emptyDir)"
kubectl apply -n media -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: { name: jellyfin }
spec:
  replicas: 1
  selector: { matchLabels: { app: jellyfin } }
  template:
    metadata: { labels: { app: jellyfin } }
    spec:
      containers:
      - name: jellyfin
        image: docker.io/jellyfin/jellyfin@${JELLYFIN_DIGEST}
        ports: [{ containerPort: 8096 }]
        readinessProbe:
          tcpSocket: { port: 8096 }
          initialDelaySeconds: 15
          periodSeconds: 5
        volumeMounts:
        - { name: media, mountPath: /media }
        - { name: config, mountPath: /config }
      volumes:
      - { name: media, hostPath: { path: /opt/media, type: Directory } }
      - { name: config, emptyDir: {} }
---
apiVersion: v1
kind: Service
metadata: { name: jellyfin }
spec:
  selector: { app: jellyfin }
  ports: [{ port: 8096, targetPort: 8096 }]
EOF

step "11) Gateway + HTTPRoute (gatewayClassName: istio, plain HTTP listener)"
kubectl apply -n media -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: { name: ingress }
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes: { namespaces: { from: Same } }
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: jellyfin }
spec:
  parentRefs: [{ name: ingress }]
  rules:
  - backendRefs: [{ name: jellyfin, port: 8096 }]
EOF

step "12) separate NodePort Service selecting the gateway pod (avoids istio-controller reconciling its managed Service)"
kubectl apply -n media -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: ingress-nodeport
  namespace: media
spec:
  type: NodePort
  selector:
    gateway.networking.k8s.io/gateway-name: ingress
  ports:
  - { name: http, port: 80, targetPort: 80, nodePort: 30080 }
EOF

step "13) wait for gateway pod"
kubectl wait --for=condition=Ready pod -n media -l "gateway.networking.k8s.io/gateway-name=ingress" --timeout=180s

step "14) wait for jellyfin"
kubectl wait --for=condition=Ready pod -n media -l app=jellyfin --timeout=240s

step "15) sanity check (hard-fail if gateway not serving jellyfin)"
code=
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:30080/System/Info/Public" || true)
  [ "$code" = "200" ] && break
  sleep 1
done
echo "jellyfin response code via gateway: $code"
[ "$code" = "200" ] || { echo "FAIL: gateway is not serving jellyfin (got code=$code) — abort"; exit 1; }

cat <<'EOF'

==============================================================================
KIND CLUSTER UP. Now drive the wedge manually:

  1. Open http://localhost:30080/web/ in a browser.
     - Walk through the setup wizard. Pick any admin user/password.
     - Skip remote access / port mapping.
     - On the Library step: click "Add Media Library", name "Movies",
       folder "/media" (the path inside the pod, where Big Buck Bunny is).
     - Finish the wizard. Sign in with your admin user.
     - Wait ~10 s for the library scan; "Big Buck Bunny" appears on the home.
     - Click it, click Play.
     - FAST TRIGGER: seek aggressively (jump 2 min ahead, 2 min back, repeat).
       Aggressive seeking is the reliable trigger; passive linear playback
       may wedge more slowly in some runs but is not reliable.

  2. In another terminal, start the stats watcher:

       ./watch-stats.sh

  3. Within ~10 s of seek-driven playback you will see:
     - rq_success on the jellyfin upstream cluster freezes
     - rq_active climbs and stays pinned
     - rq_error and rq_timeout stay at zero

  4. Browser playback stalls (spinner indefinitely).

  5. Capture all evidence into ./evidence/ BEFORE restarting the gateway:

       ./gather-evidence.sh

  6. (Optional control test — same playback with the gateway bypassed)
     Bypass the gateway entirely from your laptop:

       ssh -L 8096:localhost:8096 <homelab-host> \
         "KUBECONFIG=$HOME/.cache/istio-hbone-wedge-repro/kubeconfig \
          kubectl port-forward -n media svc/jellyfin 8096:8096"

     Then in browser: http://localhost:8096/web/ — wizard again, /media library
     again, play and seek the same video. Plays cleanly. No stalls. Gateway
     upstream-cluster counters do not move.
==============================================================================
EOF
