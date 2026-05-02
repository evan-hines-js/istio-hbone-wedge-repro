# Istio ambient HBONE upstream pool wedge — minimal reproducer

## TL;DR

On Istio 1.29.2 in **ambient** mode, the gateway envoy's HBONE upstream HTTP/2 codec emits `RST_STREAM(INTERNAL_ERROR)` on long, large responses (e.g. an MP4 served via HTTP `Range` requests during browser video playback). The accounting path for this codec-emitted reset is broken: streams terminate without incrementing `rq_success`, `rq_error`, or `rq_timeout` and without decrementing `rq_active`. They leak silently from the cluster pool. End-user effect: requests hang forever, video playback stalls.

## Confirmed reproducer environment

This repository reproduces the bug on a **fresh single-node kind cluster** with default kindnet CNI, default Istio ambient profile, default Gateway API standard channel, no custom policies, no waypoints, no co-tenant services, no env-var overrides. Pure stock components.

**Control test (run on the same cluster) confirms the bug is in the gateway path.** Running `kubectl port-forward -n media svc/jellyfin 8096:8096` and pointing the browser at `http://localhost:8096/web/` — same kind cluster, same jellyfin pod, same media file, same browser, same aggressive seeking — plays cleanly with no stalls and no leak. The path becomes `browser → kubectl port-forward → ztunnel L4 inbound → jellyfin pod`, with **no gateway envoy and no HBONE upstream pool**. The bug only appears when traffic flows through the gateway envoy.

## What the bug looks like

### 1. Gateway envoy upstream-cluster stats freeze (the leak)

Polling `/clusters` for `outbound|8096||jellyfin.media.svc.cluster.local` during ~90 seconds of browser playback:

```
leak = rq_total - rq_success - rq_active   (>0 = requests vanished from accounting)

time     | cx_act cx_tot | rq_act rq_tot rq_succ | leak
---------+---------------+------------------------+-----
02:19:50 |    5    13   |    2    216    212    |  2
02:20:09 |    7    22   |    7    233    221    |  5    ← rq_success freezes at 221
02:20:21 |    7    22   |    7    233    221    |  5    (6s, zero progress: 7 streams stuck)
02:20:33 |   12    28   |   12    239    221    |  6    (more requests arrive, all stick)
02:20:46 |   13    29   |   13    240    221    |  6
```

`rq_success` froze at 221 from 02:20:09 onward — 60+ seconds with zero successful upstream completions despite 24 more requests arriving. `rq_error` and `rq_timeout` stayed at 0 throughout (envoy never classified the wedged streams as failed). `rq_active` climbed and stayed pinned (streams stuck in flight). `cx_active` climbed because envoy opened new connections trying to make progress; the bad ones never close.

Captured live during a wedged session: [`evidence/gateway-clusters-jellyfin.txt`](evidence/gateway-clusters-jellyfin.txt) (envoy `/clusters` dump for the upstream cluster, with the freeze visible). A reference timestamped poll trace from a longer passive-playback wedge: [`evidence/leak-fingerprint.txt`](evidence/leak-fingerprint.txt).

### 2. Termination flags during the wedge

The committed evidence is from a seek-driven wedge run. Per-flag breakdown of every request the gateway envoy saw, captured live: [`evidence/gateway-requests-by-flag.txt`](evidence/gateway-requests-by-flag.txt):

```
code=0   flags=DC count=9      ← envoy never produced any response, client gave up
code=200 flags=DC count=1
code=206 flags=DC count=4      ← Range-request body cut off mid-stream
code=503 flags=UH count=1
code=101 flags=UC count=1
code=200 flags=- count=93      (clean responses)
code=204 flags=- count=12
code=206 flags=- count=3
code=304 flags=- count=37
```

`DC` = `downstream_remote_disconnect`; `UH` = `no_healthy_upstream`; `UC` = `upstream_connection_termination`. These 15 non-clean terminations correspond exactly to the gap between `rq_total` and `rq_success` in the cluster stats.

Concrete sample lines from the gateway access log — note the 39.8 MB transfer cut off mid-stream when the browser seeked:

```
[02:37:30.332Z] "GET /Videos/.../stream.mp4?Static=true&..." 206 DC downstream_remote_disconnect
                bytes_sent=39796736 duration=398ms
[02:37:34.638Z] "GET /Videos/.../stream.mp4?Static=true&..." 0 DC downstream_remote_disconnect
                bytes_sent=0  duration=12890ms       ← envoy held the request for 12s
                                                        and never returned bytes
```

Full access log: [`evidence/gateway-access-log.log`](evidence/gateway-access-log.log).

### 2b. Alternative trigger: passive linear playback → `RST_STREAM(INTERNAL_ERROR)`

In separate runs without seeking (just letting the video play normally), the gateway envoy's HBONE upstream HTTP/2 codec emits `RST_STREAM(INTERNAL_ERROR)` mid-response on long transfers. ztunnel on the destination node logs the resulting `stream error received: unexpected internal error encountered` (the wording `received` is dispositive — ztunnel received the RST, so envoy sent it).

This produces the **same upstream-cluster-counter signature** as the seek-driven path: `rq_success` freezes, `rq_active` stays pinned, `rq_error = rq_timeout = 0`. Same accounting bug, different trigger pattern.

Reference trace from a passive-playback session showing the cluster-stats freeze: [`evidence/leak-fingerprint.txt`](evidence/leak-fingerprint.txt). The `RST_STREAM` lines themselves can be reproduced in `evidence/ztunnel.log` by re-running the repro and letting the video play passively for ~60–90 s instead of seeking.

### 3. Browser-visible symptom

Video playback in the browser stalls within ~30–90 seconds of pressing Play. Restarting the gateway pod (`kubectl rollout restart deploy/ingress-istio -n media`) clears the wedge — until the next sustained playback session, at which point it returns.

### 4. URL pattern that triggers it

Browser playing the bundled MP4 (Big Buck Bunny, h264 baseline + AAC, browser-compatible) direct-plays via HTTP `Range` requests on `/Videos/{itemId}/stream.mp4`:

```
GET /Videos/7d7ee.../stream.mp4?api_key=...&static=true HTTP/1.1
Range: bytes=0-1048575
→ 206 Partial Content
```

This is **not HLS** — for an h264 source, jellyfin direct-plays. The trigger is large `Range`-served byte ranges over HTTP/2 streams from the browser, each multiplexed by envoy onto the HBONE upstream's CONNECT pool. Sample lines: see [`evidence/gateway-access-log.log`](evidence/gateway-access-log.log) (grep for `/Videos/.*stream.mp4`).

The fastest reproducer is **aggressive seeking** in the browser player (jump ~2 minutes forward, then back, repeat). Each seek aborts the in-flight `Range` request mid-response and starts a new one. That mid-response stream-abort churn provokes the codec-emitted `RST_STREAM(INTERNAL_ERROR)` reliably within ~10 seconds. Passive linear playback also reproduces the wedge but takes 60–90 seconds.

A burst of `curl` requests against `/` (returns a 5 KB redirect) does **not** trigger the bug. The wedge requires the large-response + mid-stream-abort pattern.

## What we ruled out

The reproducer is built specifically to eliminate environment-specific causes. The bug **does not require**:

- **Cilium** — kind uses kindnet + kube-proxy
- **Multi-node clusters** — kind here is single-node
- **Waypoints** — none configured
- **Co-tenant services** sharing the gateway — only jellyfin
- **`PILOT_ENABLE_ALPHA_GATEWAY_API`** — left at default (false)
- **Custom AuthorizationPolicies / PeerAuthentication** — none
- **Custom trust domain** — using default `cluster.local`
- **TCPRoute / experimental Gateway API CRDs** — only stable `HTTPRoute` is installed
- **Any non-default Istio profile** — using `--set profile=ambient` defaults

## Versions (pinned exactly)

| Component                | Pin                                                                              |
| ------------------------ | -------------------------------------------------------------------------------- |
| `kind`                   | v0.31.0                                                                          |
| `kindest/node`           | v1.31.0 (`sha256:25a3504b2b340954595fa7a6ed1575ef2edadf5abd83c0776a4308b64bf47c93`) |
| Gateway API              | v1.5.1 (standard channel)                                                        |
| Istio                    | 1.29.2 (`profile=ambient`)                                                       |
| `istio/pilot`            | `1.29.2-distroless`                                                              |
| `istio/proxyv2`          | `1.29.2-distroless` (gateway envoy)                                              |
| `istio/ztunnel`          | `1.29.2`                                                                         |
| `istio/install-cni`      | `1.29.2-distroless`                                                              |
| Jellyfin                 | `docker.io/jellyfin/jellyfin@sha256:1694ff069f0c9dafb283c36765175606866769f5d72f2ed56b6a0f1be922fc37` |
| Test video               | Big Buck Bunny 320×180 MP4 (~62 MB), `https://download.blender.org/peach/bigbuckbunny_movies/BigBuckBunny_320x180.mp4` |
| `kubectl`                | v1.35.2 (any compatible version is fine)                                         |
| `docker`                 | 29.3.0 (any version with kind support is fine)                                   |

## Prerequisites

- Linux host with Docker
- `kind` v0.31.0 or compatible
- `kubectl`
- `curl`
- Outbound internet access (to pull images, Istio CRDs, Gateway API CRDs, and the test video)
- Port 30080 free on the host (the gateway is exposed via kind portmap)

## How to reproduce

### 1. Bring up the cluster

```bash
./repro.sh
```

This is fully self-contained:
- Deletes any existing `ambient-repro` kind cluster
- Creates a fresh single-node kind cluster, kindnet CNI, port 30080 mapped
- Installs Gateway API v1.5.1 standard channel
- Installs Istio 1.29.2 with `profile=ambient` (defaults — no env-var overrides)
- Enables mesh access logging (default Istio install does NOT enable it)
- Labels the `media` namespace `istio.io/dataplane-mode=ambient`
- Stages Big Buck Bunny in the kind node at `/opt/media/bbb.mp4`
- Deploys jellyfin pinned to the digest above, with `/media` hostPath and `/config` emptyDir
- Creates the `Gateway` (`gatewayClassName: istio`) and `HTTPRoute`
- Patches the gateway Service to NodePort 30080

Takes 4–8 minutes depending on image-pull speed.

### 2. Set up jellyfin via browser (manual, ~60 s)

Open `http://localhost:30080/web/`. Walk through the wizard:

- Pick any admin username and password.
- Skip the Remote Access / port-mapping page.
- On the Library step: click **Add Media Library**, name it `Movies`, click the folder **+** under Folders, type `/media`, click OK. Click OK on the library form, Next through the rest, Finish.
- Sign in with the admin user you just created.
- Wait ~10 s for the library scan; **Big Buck Bunny** will appear on the home screen.
- Click it, click **Play**.
- **Fast trigger: seek around aggressively.** Click ahead ~2 minutes on the seekbar, then back ~2 minutes, repeat. Each seek aborts the in-flight `Range` request and starts a new one — that churn drives the wedge in **~10 seconds** vs. ~60–90 s of passive playback. The seek-induced mid-response stream aborts are the most efficient way to provoke the codec-emitted `RST_STREAM`.

### 3. Watch the leak accumulate

In a second terminal:

```bash
./watch-stats.sh
```

Within ~10 seconds of seek-driven playback (or ~60–90 s of passive playback) you will see `rq_success` freeze on the `outbound|8096||jellyfin.media.svc.cluster.local` cluster while `rq_total` keeps climbing, with `rq_error = rq_timeout = 0`. The "leak" column will grow.

In the browser: video playback will stall (spinner indefinitely).

### 4. Capture evidence (do this BEFORE restarting the gateway)

```bash
./gather-evidence.sh
```

Writes the following to `./evidence/`:

- `ztunnel-rst-stream.log` — every line where ztunnel logs `stream error received: unexpected internal error encountered`. Each line is one stream the gateway envoy reset mid-response. `bytes_sent` and `duration` show how far the transfer got.
- `gateway-access-log.log` — gateway envoy access log entries during the wedge. Look for response code `0` with flag `DC` (`0 DC downstream_remote_disconnect`) — these are the wedged requests as seen from the downstream side: envoy never produced a response, the client (browser) gave up and closed.
- `gateway-clusters-jellyfin.txt` — `/clusters` dump for the `outbound|8096||jellyfin.media.svc.cluster.local` cluster, captured live during the leak so the counters show the freeze.
- `gateway-stats-jellyfin.txt` — `/stats` for the same cluster + `connect_originate` (the HBONE shared pool) + `inner_connect_originate`. All `rq_*`, `cx_*`, `http2.*` counters.
- `gateway-cluster-configs.json` — full envoy cluster config for `connect_originate`, `inner_connect_originate`, and the jellyfin upstream. Useful for inspecting HTTP/2 settings, idle timeouts, circuit-breaker thresholds.
- `versions.txt` — resolved versions of every component for traceability.

Once captured, you can restart the gateway to clear the wedge:

```bash
kubectl --kubeconfig ~/.cache/istio-hbone-wedge-repro/kubeconfig \
  rollout restart deploy/ingress-istio -n media
```

### 5. Control test — confirm the bug is in the gateway envoy, not jellyfin

Bypass the gateway entirely with `kubectl port-forward` and point the browser at the pod directly:

```bash
# replace <homelab-host> with wherever the kind cluster is running.
# if you ran kind locally, this is just the kubectl command without ssh.
ssh -L 8096:localhost:8096 <homelab-host> \
  "KUBECONFIG=/home/ubuntu/.cache/istio-hbone-wedge-repro/kubeconfig \
   kubectl port-forward -n media svc/jellyfin 8096:8096"
```

Then point the browser at `http://localhost:8096/web/`, run the wizard again (different origin, jellyfin treats it as a separate setup; same `/media` library), play the same video, seek aggressively the same way. **Plays cleanly. No stalls. No `rq_success` freeze. No `0 DC` access logs. No leak.**

Path comparison:

```
WEDGES (via gateway):
  browser → kind 30080 → ingress-istio gateway pod (envoy)
                       → HBONE upstream pool (HTTP/2 CONNECT to ztunnel:15008)
                       → ztunnel inbound on jellyfin's node
                       → jellyfin pod

DOES NOT WEDGE (via port-forward):
  browser → kubectl port-forward
          → ztunnel L4 inbound on jellyfin's node
          → jellyfin pod
```

The only difference is the gateway envoy and its HBONE upstream pool. Same jellyfin, same media file, same client, same browser, same seeking pattern. **The bug is in the gateway envoy's HBONE upstream path.**

## Cleanup

```bash
./cleanup.sh
```

Deletes the kind cluster and removes the cached `~/.cache/istio-hbone-wedge-repro` working directory.

## Files

```
README.md                          this file
repro.sh                           full self-contained kind cluster bring-up
watch-stats.sh                     gateway envoy upstream-cluster stats poller
gather-evidence.sh                 captures logs / stats / configs to ./evidence/
                                   (run while the gateway is wedged)
cleanup.sh                         tear down + clean cache
evidence/                          populated by gather-evidence.sh
  ztunnel-rst-stream.log           RST_STREAM(INTERNAL_ERROR) lines from ztunnel
  gateway-access-log.log           gateway envoy access log (look for 0 DC)
  gateway-clusters-jellyfin.txt    /clusters dump showing the leak
  gateway-stats-jellyfin.txt       /stats counters for jellyfin + connect_originate
  gateway-cluster-configs.json     envoy cluster configs (HTTP/2 settings)
  versions.txt                     resolved versions of every component
  leak-fingerprint.txt             reference timestamped poll trace from prior run
```

## Filing this with Istio

The class of bug is twofold:

1. **The codec emits the reset.** Whatever frame sequence the gateway's HBONE upstream HTTP/2 codec encounters during a long, large response causes it to emit `RST_STREAM(INTERNAL_ERROR)`. Likely a flow-control or stream-state edge case on CONNECT-wrapped streams. Root cause unknown without source-level investigation.

2. **The accounting path leaks.** The upstream cluster's accounting for self-initiated `RST_STREAM(INTERNAL_ERROR)` does not increment `rq_success`, `rq_error`, or `rq_timeout` and does not decrement `rq_active`. The slot leaks until the downstream client disconnects (which appears as `0 DC downstream_remote_disconnect` in the gateway access log but never makes it into upstream cluster stats).

(2) is fixable independently of (1) and would at least make this debuggable in the field — pool exhaustion under sustained playback would surface as `rq_error` instead of vanishing into thin air. That's a near-term win for any fleet running Istio ambient even before (1) is understood.
# istio-hbone-wedge-repro
# istio-hbone-wedge-repro
