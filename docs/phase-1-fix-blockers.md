# Incident record — the stalled `auth-service` rollout

> **CLOSED.** All seven problems below are resolved and verified. Nothing here is an action
> item. It is kept because it is the only record of *why* several parameters are the way they
> are — the sidecar probe, the port, and the rollout strategy each encode a failure that was
> observed here.
>
> For what to actually run, see [deploy.md](./deploy.md). For current values and checks, see
> [prerequisites.md](./prerequisites.md).

**Diagnosed:** 2026-10-28, after `kubectl apply -k k8s/auth-service` returned
`exceeded its progress deadline`.
**Closed:** 2026-10-29, after the resource deadlock in problem 7 was found and fixed.

> ### Read this first: `ProgressDeadlineExceeded` is not the fault
> `error: deployment "auth-service" exceeded its progress deadline` is the Deployment
> controller giving up after `spec.progressDeadlineSeconds` (default 600s) because no pod ever
> became Ready. It names a timer, not a cause. Separately, `--timeout=3m` on
> `rollout status` is a *client-side* watch timeout — raising either number fixes nothing.
> Always go to the pod:
>
> ```bash
> kubectl -n auth get pod -l app=auth-service
> kubectl -n auth describe pod -l app=auth-service | sed -n '/Events:/,$p'
> ```

---

## What was actually wrong

Seven independent problems, found in this order. Each was a complete blocker on its own, which
is why fixing any one of them did not visibly help.

| # | Problem | Where | Status |
| --- | --- | --- | --- |
| 1 | Sidecar startup probe could never pass | `deployment.yaml` | ✅ fixed in repo |
| 2 | `DB_PORT` was 5433, proxy listens on 5432 | `configmap.yaml` | ✅ fixed in repo |
| 3 | Workload Identity never enabled | cluster + node pool | ✅ step 1, done 2026-10-29 |
| 4 | `auth-sql` GSA did not exist, neither binding | GCP IAM | ✅ step 2, done 2026-10-29 |
| 5 | Secret `auth-service-secrets` absent | namespace `auth` | ✅ step 3, done 2026-10-29 |
| 6 | `PORT` 9999 vs `containerPort` 8080 | `configmap.yaml` / `deployment.yaml` | ✅ step 4, resolved to `9999` |
| 7 | `maxUnavailable: 0` deadlocked the rollout on a full node | `deployment.yaml` | ✅ step 7 |

Problem 7 is the one that outlived all the others, and the most instructive: every piece of
configuration was correct by then, and the rollout still could not complete.

### Already fixed: the startup probe (problem 1)

This was the cause of the crashloop. The evidence:

```
proxy log:  "[...] Listening on 127.0.0.1:5432"
pod event:  Startup probe failed: dial tcp 10.110.0.12:5432: connect: connection refused
            (x458 over 54m) -> Killing -> BackOff -> repeat
```

`startupProbe: tcpSocket: port 5432` cannot work here. **Kubelet probes a pod from outside its
network namespace**, so it dials the pod IP (`10.110.0.12`), while the proxy deliberately binds
`127.0.0.1` only. The probe failed forever, kubelet killed the sidecar every ~2 min, and because
the proxy is an `initContainer` (native sidecar) the app container never started — which is why
there were no app logs to look at.

The fix is **not** `--address=0.0.0.0` on the database port; that would expose an
IAM-authenticated database tunnel on the pod IP. Use the proxy's own health server, which is
designed to be reachable:

```yaml
args:
  - "--structured-logs"
  - "--port=5432"
  - "--health-check"
  - "--http-address=0.0.0.0"     # only the health server listens on the pod IP
  - "--http-port=9090"
  - "vincent-mini-apps-project:asia-southeast1:recommendations-app-instance"
startupProbe:
  httpGet:
    path: /startup
    port: 9090
  periodSeconds: 2
  failureThreshold: 30
```

### Already fixed: `DB_PORT` (problem 2)

`DB_PORT` was `5433` while the proxy listens on `5432`. Three places must agree, and nothing
enforces it: the proxy's `--port`, the sidecar probe, and `DB_PORT`. All three are now `5432`.

### Not a bug: `DB_NAME` stays `recommendations-backend`

The since-retired `docs/phase-1-deploy.md` §1.1, and `README.md`, both described a dedicated
`auth_service` database. That is **not** what exists. Verified live:

```bash
gcloud sql databases list --instance=recommendations-app-instance
# postgres
# recommendations-backend        <- no auth_service
```

So `DB_NAME` naming `recommendations-backend` is at least *consistent* with what exists, and
creating `auth_service` was never done.

**What this section originally asserted — that the auth migrations had been run into
`recommendations-backend` — was an inference, not a verified fact.** The command above only
proves `auth_service` is absent; it says nothing about which tables exist in
`recommendations-backend`. Confirming that is the one prerequisite still open; see
[prerequisites.md §6.2](./prerequisites.md#62-open-the-auth-schema-has-nowhere-to-live-yet).

### Not a bug: the network path is the proxy over public IP

There is no private-IP Cloud SQL instance in any accessible project. Verified live:

```bash
gcloud sql instances describe recommendations-app-instance \
  --format="yaml(ipAddresses,settings.ipConfiguration)"
# ipAddresses: 34.142.199.254 (PRIMARY), 34.142.253.164 (OUTGOING)   <- no PRIVATE
# privateNetwork: absent, enablePrivatePathForGoogleCloudServices: false
```

The Cloud SQL Auth Proxy is private in the sense that matters — IAM-authenticated, mTLS, no
authorized-network entry needed for the pod — but it reaches the instance over its **public** IP.
That is the chosen design; no infrastructure change is required. The pod never needs to know the
IP: the proxy takes only the instance connection name.

---

## Step 1 — Enable Workload Identity ✅ DONE 2026-10-29  ⚠️ was destructive

**Resolved.** `workloadPool` is `vincent-mini-apps-project.svc.id.goog` and the node pool is on
`GKE_METADATA`. The node pool was recreated as part of this. **Do not re-run the commands
below** — they are kept for rebuilding the project from scratch.

This was never completed when the deployment was first attempted. Both halves are
required: the cluster-level identity pool, and the node pool's metadata server. The cluster
setting alone is not enough — without `GKE_METADATA` the pod's token request returns the **node**
service account, and Cloud SQL then denies a request that looks like it came from the right place.

```bash
# 1a. Create the identity pool on the cluster (non-destructive, ~2 min)
gcloud container clusters update vincent-cluster --zone asia-southeast1-a \
  --workload-pool=vincent-mini-apps-project.svc.id.goog

# 1b. Switch the node pool to the GKE metadata server (RECREATES NODES, ~5 min)
gcloud container node-pools update minimal-pool --cluster vincent-cluster \
  --zone asia-southeast1-a --workload-metadata=GKE_METADATA
```

**Verify both** — the second command is the one usually forgotten:

```bash
gcloud container clusters describe vincent-cluster --zone asia-southeast1-a \
  --format="value(workloadIdentityConfig.workloadPool)"
# => vincent-mini-apps-project.svc.id.goog        (empty means 1a did not take)

gcloud container node-pools describe minimal-pool --cluster vincent-cluster \
  --zone asia-southeast1-a \
  --format="value(config.workloadMetadataConfig.mode)"
# => GKE_METADATA

kubectl get nodes      # back to Ready, probably under a new node name
```

---

## Step 2 — Create the GSA and both IAM bindings ✅ DONE 2026-10-29

**Resolved.** `auth-sql@vincent-mini-apps-project.iam.gserviceaccount.com` exists, holds
`roles/cloudsql.client`, and grants `roles/iam.workloadIdentityUser` to
`vincent-mini-apps-project.svc.id.goog[auth/auth-service]`. Proven at runtime: the proxy logged
`Authorizing with Application Default Credentials` followed by a successful connection.

This was also never run — the service account referenced by
`k8s/auth-service/service-account.yml:10` did not exist. Two bindings, in opposite directions:

- **GSA → Cloud SQL** (`roles/cloudsql.client`) — the identity may connect.
- **KSA → GSA** (`roles/iam.workloadIdentityUser`) — the pod may *act as* that identity.

```bash
PROJECT=vincent-mini-apps-project
GSA="auth-sql@${PROJECT}.iam.gserviceaccount.com"

gcloud iam service-accounts create auth-sql \
  --display-name="auth-service Cloud SQL client"

gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:${GSA}" \
  --role="roles/cloudsql.client"

# "auth" is the namespace, "auth-service" the KSA -- both from k8s/auth-service/.
gcloud iam service-accounts add-iam-policy-binding "$GSA" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT}.svc.id.goog[auth/auth-service]"
```

**Verify:**

```bash
gcloud iam service-accounts list --filter="email:auth-sql" --format="value(email)"
# => auth-sql@vincent-mini-apps-project.iam.gserviceaccount.com

gcloud projects get-iam-policy "$PROJECT" --flatten=bindings \
  --filter="bindings.role=roles/cloudsql.client" \
  --format="value(bindings.members)" | grep auth-sql

gcloud iam service-accounts get-iam-policy "$GSA" --format=json \
  | grep -A3 workloadIdentityUser
# must contain: vincent-mini-apps-project.svc.id.goog[auth/auth-service]
```

> The proxy logging `"The proxy has started successfully"` does **not** mean IAM is in order. The
> proxy binds its listener before authenticating and only dials Cloud SQL lazily, on the first
> client connection. With the app container blocked, that connection never happened, so the
> missing GSA had not surfaced yet.

---

## Step 3 — Create the Secret ✅ DONE 2026-10-29

**Resolved.** All four keys present in `auth-service-secrets`.

Four values the app hard-requires; `config.Load()` errors on any empty one and `main.go` turns
that into `log.Fatalf`. A missing value is a CrashLoopBackOff, not a degraded start.

```bash
kubectl -n auth create secret generic auth-service-secrets \
  --from-literal=DB_PASSWORD='<the postgres password>' \
  --from-literal=GOOGLE_OAUTH_CLIENT_ID='<from GCP console>' \
  --from-literal=GOOGLE_OAUTH_CLIENT_SECRET='<from GCP console>' \
  --from-literal=ENCRYPTION_KEY="$(openssl rand -base64 32)"
```

- **`ENCRYPTION_KEY` must decode to exactly 32 bytes** (AES-256). `secret.go` rejects any other
  length. It seals live session cookies, so changing it logs every user out, and there is no
  recovery path and no second-key reader in the code today — **store it in your password manager
  before running this command.**
- `DB_PASSWORD` is the instance-wide `postgres` password, because `DB_USER` is `postgres`.
- The Secret is created imperatively and is deliberately absent from `kustomization.yaml`, so no
  credential ever enters this repository.

**Verify:**

```bash
kubectl -n auth get secret auth-service-secrets \
  -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'
# DB_PASSWORD / ENCRYPTION_KEY / GOOGLE_OAUTH_CLIENT_ID / GOOGLE_OAUTH_CLIENT_SECRET
```

---

## Step 4 — `PORT` 9999 or 8080 — **RESOLVED: 9999**

**Done.** The app port is `9999` everywhere.

`configmap.yaml` sets `PORT: "9999"`, so the app listens on 9999. `deployment.yaml` previously
declared `containerPort: 8080` under the name `http`, and all three app probes target `http` —
so kubelet probed 8080 while nothing listened there. The fix, applied:

```yaml
# k8s/auth-service/deployment.yaml:85
ports:
  - name: http
    containerPort: 9999       # was 8080
```

The three app probes reference the port by *name* (`port: http`), so they follow automatically.
`service.yaml` uses `targetPort: http`, so it follows too — `containerPort` was the only edit
needed in either file.

9999 was chosen over 8080 because it is already the app's own convention: the `BASE_URL` default
in `config.go`, the `EXPOSE` in the Dockerfile, and the port in the embedded
`google_oauth_redirect_url` — including the OAuth callback URL compiled into image `0.0.1`.
`README.md`, `phase-1-deploy.md`, `manifest-reference.md`, `parameters.md` and
`troubleshooting.md` have been updated to match.

---

## Step 5 — Service type — **RESOLVED: stay `LoadBalancer`**

**Resolved.** Left as `type: LoadBalancer`; the load balancer is live at `34.87.12.86`. Phase 2
switches it to `NodePort` behind a GKE Ingress, because Google OAuth needs a real hostname.

`service.yaml:9` is `type: LoadBalancer`. A Service is required either way — deleting it would remove the ClusterIP and DNS
name that a future Ingress must target — so only `type` is in question:

| Want | Set | Note |
| --- | --- | --- |
| No external IP for now | `type: ClusterIP` | reach it with `kubectl -n auth port-forward svc/auth-service 8080:80` |
| Keep the public IP for now | leave `type: LoadBalancer` | ✅ **chosen** — current state |
| Phase 2 (Ingress + managed TLS) | `type: NodePort` | per `docs/phase-2-domain-tls-oauth.md` §2.5 |

If the cluster's `httpLoadBalancing` addon has been disabled, Phase 2's GKE Ingress will not
provision at all and `phase-2-domain-tls-oauth.md:161` is wrong. Check with:

```bash
gcloud container clusters describe vincent-cluster --zone asia-southeast1-a \
  --format="value(addonsConfig.httpLoadBalancing.disabled)"
# True = addon disabled -> Phase 2 needs the addon re-enabled, or Gateway API instead
```

---

## Step 6 — Apply and watch

```bash
kubectl kustomize k8s/auth-service        # dry read: inspect before applying
kubectl apply -k k8s/auth-service

# REQUIRED. The ConfigMap has no name hash (no configMapGenerator), so editing it
# does not roll the Deployment -- the running pod keeps the old env until restarted.
kubectl -n auth rollout restart deploy/auth-service

kubectl -n auth rollout status deploy/auth-service --timeout=5m
```

**Verify, in this order** — each command isolates a different layer:

```bash
# 1. the sidecar got past its probe
kubectl -n auth get pod -l app=auth-service     # expect 2/2 Running, not Init:*

# 2. the proxy authenticated and connected
kubectl -n auth logs deploy/auth-service -c cloud-sql-proxy --tail=20

# 3. the app connected and is serving
kubectl -n auth logs deploy/auth-service -c auth-service
# want "database connected" + "listening on :9999"

# 4. end to end
kubectl -n auth port-forward svc/auth-service 8080:80
curl -fsS localhost:8080/api/v1/health
```

---

## Step 7 — The resource deadlock ✅ FIXED 2026-10-29

**The last blocker, and the only one that survived every other fix.** By this point Workload
Identity, the GSA, both bindings, the Secret, the probe and the port were all correct — and the
rollout still could not complete.

### What it looked like

```
auth-service-7c4db98947-dmmp4   0/2   Pending                 0 restarts    (revision 2)
auth-service-cdf8b979b-fxh79    0/2   Init:CrashLoopBackOff   38 restarts   (revision 1)
```

```
FailedScheduling    0/1 nodes are available: 1 Insufficient cpu.
NotTriggerScaleUp   Pod didn't trigger scale-up
```

### Two traps in reading that output

**Trap 1 — `describe pod` showed a spec that no longer existed in the repo.** The crashlooping
pod belonged to revision 1 and still carried the old `tcpSocket :5432` probe and the old proxy
args. Pods are immutable: editing a Deployment creates a *new* ReplicaSet and the old pod keeps
its original spec forever. So the fix from problem 1 was correctly applied and correctly live in
revision 2, while `describe` on the surviving old pod kept showing the bug. `kubectl get rs` with
the revision annotation is what disambiguates:

```bash
kubectl -n auth get rs -o custom-columns='NAME:.metadata.name,REV:.metadata.annotations.deployment\.kubernetes\.io/revision,DESIRED:.spec.replicas,READY:.status.readyReplicas'
```

**Trap 2 — exit code 143 is not a crash.** 143 = 128 + 15 = SIGTERM. The old pod's own proxy
logs told the whole story:

```
14:04:44  "The proxy has started successfully and is ready for new connections!"
14:05:42  "Sending SIGTERM signal for proxy to shutdown."
```

Exactly 60 seconds apart — which is `failureThreshold: 30 × periodSeconds: 2`. The container was
healthy and kubelet killed it because the startup probe could never pass. A container that
reports `CrashLoopBackOff` while logging success is almost always a probe, not the process.

### The actual cause

| | CPU requests |
| --- | --- |
| `e2-medium` allocatable | 940m |
| GKE system pods | ~701m |
| revision-1 pod (crashlooping, still holding its reservation) | 150m |
| **Free** | **89m** |
| revision-2 pod needs | 150m |

A crashlooping pod still holds its CPU *request* — scheduling is accounted on requests, not
usage, and a pod that never becomes Ready is still a scheduled pod.

Then the strategy closed the loop:

```yaml
maxUnavailable: 0   # don't remove the old pod until the new one is Ready
maxSurge: 1         # => both must coexist => 2x resources
```

The old pod could not be removed until the new one was Ready; the new one could not even be
*scheduled* until the old one was removed. With `replicas: 1` on a node that cannot fit two
copies, `maxUnavailable: 0` is unsatisfiable. And `NotTriggerScaleUp` meant the autoscaler had
already declined, so waiting would never have helped.

### The fix

```yaml
# k8s/auth-service/deployment.yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 1     # was 0
    maxSurge: 0           # was 1
```

This inverts the order: scale **down** to 0, then **up** to 1. Peak demand stays 1×. The cost is
a brief full outage during a rollout — honest rather than regressive, since one replica never
had a zero-downtime path, it just failed less legibly.

**Takeaway:** `maxUnavailable: 0` is the safe-looking default and it is actively harmful at
`replicas: 1` on a saturated node. Zero-downtime rollouts need somewhere for the second pod to
land.

---

## Preflight before any future apply

The minimum manual version — three commands, and the only thing standing
between you and applying manifests to whatever cluster your kubeconfig last pointed at:

```bash
kubectl config current-context    # gke_vincent-mini-apps-project_asia-southeast1-a_vincent-cluster
gcloud config get account         # vinhnguyentan99@gmail.com
kubectl get nodes                 # one Ready node
```

The kubeconfig stores no credential — only an `exec` hook to `gke-gcloud-auth-plugin`, which
mints a token for whichever gcloud configuration is active *at that moment*. A correct context is
therefore not sufficient on its own.

---

## Exit checklist — verified 2026-10-29

- [x] `workloadIdentityConfig.workloadPool` is `vincent-mini-apps-project.svc.id.goog`
- [x] node pool `workloadMetadataConfig.mode` is `GKE_METADATA`
- [x] `auth-sql` GSA exists, holds `roles/cloudsql.client`, **and** has the
      `workloadIdentityUser` binding for `[auth/auth-service]`
- [x] `auth-service-secrets` holds all four keys
- [x] step 4 decided — `PORT` and `containerPort` both `9999`
- [x] step 5 decided — stays `LoadBalancer`
- [x] step 7 fixed — `maxUnavailable: 1` / `maxSurge: 0`
- [ ] pod is `2/2 Running`; app logs show `database connected` — **pending the apply**
- [ ] `GET /api/v1/health` returns 200 — **pending the apply**

The last two require `kubectl apply -k k8s/auth-service`; see
[deploy.md step 4](./deploy.md).

---

## What this incident changed in the docs

The drift this investigation uncovered has been resolved rather than catalogued. For the record:

| Was wrong | Now |
| --- | --- |
| `phase-0-prerequisites.md` and `phase-1-deploy.md` described steps that were never run, and a `auth_service` database that does not exist | both files replaced by [prerequisites.md](./prerequisites.md) and [deploy.md](./deploy.md), written against verified live state |
| `README.md` listed database `auth_service` "created in Phase 1" | corrected to the real database, with the open question called out |
| Port documented inconsistently as `8080` across five files | all now `9999` |
| `phase-0-prerequisites.md` exit checklist implied §0.5/§0.6 were complete | they are now genuinely complete (steps 1 and 2 above) |

One item remains genuinely open and is **not** a doc bug:
**whether the auth schema exists in the database `DB_NAME` points at.** See
[prerequisites.md §6.2](./prerequisites.md#62-open-the-auth-schema-has-nowhere-to-live-yet).

`phase-2-domain-tls-oauth.md:161` also still assumes the `httpLoadBalancing` addon is enabled;
unverified, and checked in step 5 above.
