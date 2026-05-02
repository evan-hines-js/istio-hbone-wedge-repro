# Istio ambient gateway wedge during sustained video playback — minimal reproducer

## TL;DR

On Istio 1.29.2 and 1.30.0-beta.0 in **ambient** mode, browser video playback through an Istio gateway wedges after a burst of mid-stream `Range` aborts (a few dozen player seeks over a short period): the browser stalls indefinitely, and the gateway envoy's upstream-cluster counters for the backend service show `rq_total` continuing to climb while `rq_success` freezes, with `rq_error` and `rq_timeout` staying at 0. ztunnel on the destination node also logs `stream error received: unexpected internal error encountered` on long-lived inbound transfers during the same session. Restarting the gateway pod clears the wedge until the next aggressive-seek session.

## Confirmed reproducer environment

This repository reproduces the wedge on a **fresh single-node kind cluster** with default kindnet CNI, default Istio ambient profile, default Gateway API standard channel, no custom policies, no waypoints, no co-tenant services, no env-var overrides. Pure stock components.

**Control test 1 — `kubectl port-forward` (gateway bypassed).** Running `kubectl port-forward -n media svc/jellyfin 8096:8096` and pointing the browser at `http://localhost:8096/web/` — same kind cluster, same jellyfin pod, same media file, same browser, same aggressive seeking — plays cleanly without stalls and the gateway envoy's upstream-cluster counters do not move. The two paths differ only in whether traffic transits the gateway envoy.

**Control test 2 — LoadBalancer Service (gateway not used).** On a separate cluster, exposing jellyfin via a `Service.type=LoadBalancer` (e.g. Cilium LB-IPAM) and reaching the pod through that VIP plays cleanly under the same playback pattern. The wedge does not appear.

## What you observe

### 1. Gateway envoy upstream-cluster counters

Polling `/clusters` for `outbound|8096||jellyfin.media.svc.cluster.local` during ~90 seconds of browser playback:

```
gap = rq_total - rq_success - rq_active   (>0 = requests not in success or active)

time     | cx_act cx_tot | rq_act rq_tot rq_succ | gap
---------+---------------+------------------------+-----
02:19:50 |    5    13   |    2    216    212    |  2
02:20:09 |    7    22   |    7    233    221    |  5    ← rq_success freezes at 221
02:20:21 |    7    22   |    7    233    221    |  5    (6s with no movement)
02:20:33 |   12    28   |   12    239    221    |  6
02:20:46 |   13    29   |   13    240    221    |  6
```

`rq_success` stays at 221 from 02:20:09 onward — 60+ seconds while 24 more requests arrive. `rq_error` and `rq_timeout` stay at 0. `rq_active` climbs and stays pinned. `cx_active` climbs alongside `cx_total`.

Captured live during a wedged session: [`evidence/gateway-clusters-jellyfin.txt`](evidence/gateway-clusters-jellyfin.txt) (envoy `/clusters` dump for the upstream cluster). A reference timestamped poll trace: [`evidence/leak-fingerprint.txt`](evidence/leak-fingerprint.txt).

### 2. Termination flags during the wedge

Per-flag breakdown of every request the gateway envoy saw during a seek-driven wedge run: [`evidence/gateway-requests-by-flag.txt`](evidence/gateway-requests-by-flag.txt):

```
code=0   flags=DC count=13
code=101 flags=DC count=1
code=101 flags=UC count=1
code=503 flags=UH count=1
code=200 flags=-  count=340
code=204 flags=-  count=83
code=206 flags=-  count=142
code=206 flags=DC count=6
code=304 flags=-  count=6
```

`DC` = `downstream_remote_disconnect`; `UH` = `no_healthy_upstream`; `UC` = `upstream_connection_termination`.

Sample lines from the gateway access log:

```
[02:37:30.332Z] "GET /Videos/.../stream.mp4?Static=true&..." 206 DC downstream_remote_disconnect
                bytes_sent=39796736 duration=398ms
[02:37:34.638Z] "GET /Videos/.../stream.mp4?Static=true&..." 0 DC downstream_remote_disconnect
                bytes_sent=0  duration=12890ms
```

Full access log: [`evidence/gateway-access-log.log`](evidence/gateway-access-log.log).

### 2b. ztunnel `stream error received` on long-lived inbound transfers

During the same seek-driven session, ztunnel on the destination node also logs lines of the form on inbound flows that ran for tens of seconds before the abort:

```
... error access connection complete  ... direction="inbound" ... bytes_sent=64223639
    duration="30217ms" error="send: io error: stream error received: unexpected internal error encountered"
```

Reference trace: [`evidence/leak-fingerprint.txt`](evidence/leak-fingerprint.txt).

### 3. Browser-visible symptom

Once enough seeks have accumulated, video playback in the browser stalls (spinner indefinitely). Restarting the gateway pod (`kubectl rollout restart deploy/ingress-istio -n media`) clears the wedge — until the next aggressive-seek session, at which point it returns.

### 4. URL pattern that triggers it

Browser playing the bundled MP4 (Big Buck Bunny, h264 baseline + AAC, browser-compatible) direct-plays via HTTP `Range` requests on `/Videos/{itemId}/stream.mp4`:

```
GET /Videos/7d7ee.../stream.mp4?Static=true&ApiKey=... HTTP/1.1
Range: bytes=0-1048575
→ 206 Partial Content
```

This is **not HLS** — for an h264 source, jellyfin direct-plays. The traffic pattern is large `Range`-served byte ranges over HTTP/2 streams from the browser. Sample lines: see [`evidence/gateway-access-log.log`](evidence/gateway-access-log.log) (grep for `/Videos/.*stream.mp4`).

The wedge requires **aggressive seeking** in the browser player (jump ~2 minutes forward, then back, repeat). Each seek aborts the in-flight `Range` request mid-response and starts a new one. A few dozen such aborts over a short period reliably wedges the gateway. Passive linear playback may wedge more slowly in some runs but is not reliable; multi-minute passive runs in this reproducer have left counters healthy.

A burst of `curl` requests against `/` (returns a 5 KB redirect) does **not** reproduce the wedge either — the reproducer needs the large-response traffic pattern *plus* mid-stream aborts.

## Also reproduces on Istio `1.30.0-beta.0`

Re-running the same reproducer with `ISTIO_VERSION=1.30.0-beta.0` (released 2026-04-27, all components from `registry.istio.io/release/`) produces the same counter signature within seconds of seek-driven playback:

```
rq_total = 379, rq_success = 353, rq_active = 6        → gap of 20
rq_error = 0,   rq_timeout = 0
ztunnel "stream error received…":  7 entries
gateway access-log "0 DC" / "206 DC":  32 entries
```

A single 1.30.0-beta.0 run captured both patterns concurrently — `stream error received` lines on long-lived inbound transfers (one with `bytes_sent=64223639` over `30217ms`) and `0 DC` / `206 DC` lines from seek-aborted Range requests.

Captured evidence: [`evidence-130-beta/`](evidence-130-beta/).

To reproduce against 1.30.0-beta.0 yourself:

```bash
ISTIO_VERSION=1.30.0-beta.0 ./repro.sh
```

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

- Linux or macOS host with Docker (kind on Docker Desktop works on macOS arm64/amd64)
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
- Creates a separate NodePort Service (`ingress-nodeport`) selecting the gateway pod on host port 30080 — kept distinct from the gateway-controller-managed Service so the controller doesn't reconcile it away

Takes 4–8 minutes depending on image-pull speed.

### 2. Set up jellyfin via browser (manual, ~60 s)

Open `http://localhost:30080/web/`. Walk through the wizard:

- Pick any admin username and password.
- Skip the Remote Access / port-mapping page.
- On the Library step: click **Add Media Library**, name it `Movies`, click the folder **+** under Folders, type `/media`, click OK. Click OK on the library form, Next through the rest, Finish.
- Sign in with the admin user you just created.
- Wait ~10 s for the library scan; **Big Buck Bunny** will appear on the home screen.
- Click it, click **Play**.
- **Seek aggressively.** Click ahead ~2 minutes on the seekbar, then back ~2 minutes, repeat. Each seek aborts the in-flight `Range` request and starts a new one. A few dozen seeks over a short period reliably wedges the gateway. Passive playback may wedge more slowly in some runs but is not reliable.

### 3. Watch the counters

In a second terminal:

```bash
./watch-stats.sh
```

After a few dozen seeks over a short period, you will see `rq_success` freeze on the `outbound|8096||jellyfin.media.svc.cluster.local` cluster while `rq_total` keeps climbing, with `rq_error = rq_timeout = 0`. The "gap" column will grow.

In the browser: video playback will stall (spinner indefinitely).

### 4. Capture evidence (do this BEFORE restarting the gateway)

```bash
./gather-evidence.sh
```

Writes the following to `./evidence/`:

- `ztunnel.log` — ztunnel log lines matching `stream error|RST_STREAM|INTERNAL_ERROR|error|access`. Look for `stream error received: unexpected internal error encountered` on long-lived inbound transfers (only appears if at least one Range fetch ran for tens of seconds before its abort).
- `gateway-access-log.log` — gateway envoy access log entries during the wedge. Look for response code `0` with flag `DC` (`0 DC downstream_remote_disconnect`) — entries with `bytes_sent=0` and a long `duration` showing the downstream side closed.
- `gateway-clusters-jellyfin.txt` — `/clusters` dump for the `outbound|8096||jellyfin.media.svc.cluster.local` cluster, captured live during a wedged session so the counters show the freeze.
- `gateway-requests-by-flag.txt` — `istio_requests_total` tally as `code=N flags=X count=Y` rows; the count of rows with non-`-` flags matches the gap in the cluster counters.
- `gateway-cluster-configs.json` — full envoy cluster config for `connect_originate`, `inner_connect_originate`, and the jellyfin upstream. Useful for inspecting HTTP/2 settings, idle timeouts, circuit-breaker thresholds.
- `versions.txt` — resolved versions of every component for traceability.

Once captured, you can restart the gateway to clear the wedge:

```bash
kubectl --kubeconfig ~/.cache/istio-hbone-wedge-repro/kubeconfig \
  rollout restart deploy/ingress-istio -n media
```

### 5. Control tests — same playback, gateway not used

**(a) `kubectl port-forward`.** Bypass the gateway and point the browser at the pod directly:

```bash
# replace <homelab-host> with wherever the kind cluster is running.
# if you ran kind locally, this is just the kubectl command without ssh.
ssh -L 8096:localhost:8096 <homelab-host> \
  "KUBECONFIG=/home/ubuntu/.cache/istio-hbone-wedge-repro/kubeconfig \
   kubectl port-forward -n media svc/jellyfin 8096:8096"
```

Then point the browser at `http://localhost:8096/web/`, run the wizard again (different origin, jellyfin treats it as a separate setup; same `/media` library), play the same video, seek aggressively the same way. Playback is smooth, the gateway envoy's upstream-cluster counters do not move, and no `0 DC` lines appear in the gateway access log.

Path comparison:

```
Wedges (via gateway):
  browser → kind 30080 → ingress-istio gateway pod (envoy)
                       → HTTP/2 CONNECT to ztunnel:15008
                       → ztunnel inbound on jellyfin's node
                       → jellyfin pod

Does not wedge (via port-forward):
  browser → kubectl port-forward
          → ztunnel L4 inbound on jellyfin's node
          → jellyfin pod
```

**(b) LoadBalancer Service.** On a separate cluster (not bundled into this `repro.sh` because kind has no LoadBalancer implementation by default), reaching jellyfin via a `Service.type=LoadBalancer` (e.g. Cilium LB-IPAM) plays cleanly under the same playback pattern. The wedge does not appear.

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
  ztunnel.log                      filtered ztunnel log (look for `stream error received`)
  gateway-access-log.log           gateway envoy access log (look for 0 DC)
  gateway-clusters-jellyfin.txt    /clusters dump from a wedged session
  gateway-requests-by-flag.txt     istio_requests_total tally by code × flags
  gateway-cluster-configs.json     envoy cluster configs (HTTP/2 settings)
  versions.txt                     resolved versions of every component
  leak-fingerprint.txt             reference timestamped poll trace from prior run
evidence-130-beta/                 same artifacts captured against Istio 1.30.0-beta.0
```
