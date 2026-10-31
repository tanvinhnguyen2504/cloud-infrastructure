# Prerequisites and parameter reference — `recommendations-service`

Everything that must be true **before** `kubectl apply -k k8s/recommendations-service` can
produce a running pod, plus every parameter the deployment depends on and the one command that
checks it.

Each row carries a value verified against the live project, not copied from a plan. Where a value
is still open, it says so.

**Verified:** 2026-10-30 against `vincent-mini-apps-project` / `vincent-cluster`.
**Step-by-step deploy:** [deploy.md](./deploy.md). **When it breaks:**
[troubleshooting.md](./troubleshooting.md). Field-by-field rationale for every manifest is §7
below.

Source repository: `../recommendations-be` (module
`github.com/nguyentanvinh/recommendations-be/backend`).

---

## Status at a glance

| # | Requisite | State |
| --- | --- | --- |
| 1 | Local tooling (`gcloud`, `kubectl`, `docker`, auth plugin) | ✅ verified |
| 2 | Project APIs enabled | ✅ verified |
| 3 | Cluster reachable, node `Ready` | ✅ verified |
| 4 | **Node CPU budget fits the pod** | ❌ **BLOCKER — 89m free, pod needs 150m. §3.2** |
| 5 | Cluster-level Workload Identity (pool + `GKE_METADATA`) | ✅ already done for auth-service |
| 6 | **GSA `recommendations-sql` + both IAM bindings** | ❌ **does not exist yet. §4** |
| 7 | Cloud SQL instance reachable by the proxy | ✅ verified |
| 8 | **Artifact Registry repo `recommendations-repository`** | ❌ **does not exist yet. §5** |
| 9 | **A pushed `recommendations-service` image** | ❌ **none exists. §5** |
| 10 | Namespace `recommendations` | ❌ created by `kustomization.yaml` |
| 11 | **Secret `recommendations-service-secrets`, all four keys** | ❌ **does not exist yet. §6.1** |
| 12 | **`gm_places` exists in the database `DB_NAME` points at** | ⚠️ **unverified. §6.2** |

Unlike auth-service, this is a **first** deployment: items 6, 8, 9 and 11 are genuinely new work,
and item 4 is a hard blocker that no manifest change can route around. Items 1, 2, 3, 5 and 7 are
inherited from the auth-service bring-up and need nothing.

---

## 1. Local tooling

| Parameter | Required value | Check |
| --- | --- | --- |
| gcloud account | `vinhnguyentan99@gmail.com` | `gcloud config get account` |
| gcloud project | `vincent-mini-apps-project` | `gcloud config get project` |
| kubectl context | `gke_vincent-mini-apps-project_asia-southeast1-a_vincent-cluster` | `kubectl config current-context` |
| GKE auth plugin | `/opt/homebrew/share/google-cloud-sdk/bin/gke-gcloud-auth-plugin` | the kubeconfig calls it by absolute path |
| docker + buildx | `/usr/local/bin/docker` | `docker buildx version` |
| psql (migrations / `\dt`) | `/opt/homebrew/opt/postgresql@18/bin/psql` | `psql --version` |
| cloud-sql-proxy (local) | `/opt/homebrew/bin/cloud-sql-proxy` | optional — only for laptop-side DB access |

### Why the account matters more than the context

The kubeconfig stores **no credential**. It stores an `exec` hook that calls
`gke-gcloud-auth-plugin`, which mints a fresh token for whichever gcloud configuration is *active
at that moment*. A context pointing at `vincent-cluster` is therefore not sufficient on its own:
switch gcloud configurations and `kubectl` silently changes identity with it, then returns
`Forbidden`. Check both, every time.

---

## 2. Project APIs

The set is identical to auth-service and all four are already enabled — this service adds no new
API surface.

```bash
gcloud services list --enabled | grep -E 'sqladmin|iamcredentials|container\.|artifactregistry'
```

| API | Why this service needs it |
| --- | --- |
| `sqladmin.googleapis.com` | the proxy calls it to discover the instance and mint certificates |
| `iamcredentials.googleapis.com` | Workload Identity token exchange |
| `container.googleapis.com` | GKE itself |
| `artifactregistry.googleapis.com` | image push **and** pull |

---

## 3. Cluster and node pool

### 3.1 Identity and shape

| Parameter | Value | Check |
| --- | --- | --- |
| Cluster | `vincent-cluster`, **zonal** `asia-southeast1-a` | `gcloud container clusters list` |
| Control plane / kubelet | `v1.36.4-gke.2046003` | `kubectl get nodes` |
| Node pool | `minimal-pool`, 1 node, **spot**, autoscaling off | `gcloud container node-pools list --cluster vincent-cluster --zone asia-southeast1-a` |
| Machine type | `e2-medium` (940m allocatable CPU) | `--format='value(config.machineType)'` |

The version matters for one reason: **native sidecars** (`initContainers` with
`restartPolicy: Always`) require Kubernetes **1.29+**. At 1.36 this is well satisfied.

### 3.2 Blocker: the node has no room for this pod

This is the one prerequisite that will stop the deploy dead, and it is not a tuning question.
Measured requests on the single node right now:

| | CPU requests |
| --- | --- |
| `e2-medium` allocatable | **940m** |
| DaemonSets + `kube-proxy` (per-node, unavoidable) | 386m |
| kube-dns, kube-state-metrics, metrics-server, gmp, konnectivity, … | 315m |
| `auth-service` pod (100m app + 50m proxy) | 150m |
| **Total already requested** | **851m (90%)** |
| **Free** | **89m** |
| `recommendations-service` needs (100m app + 50m proxy) | **150m** |
| Shortfall | **−61m** |

```bash
kubectl describe node -l cloud.google.com/gke-nodepool=minimal-pool \
  | sed -n '/Allocated resources/,/^Events/p'
# cpu  851m (90%)
```

Applying the manifests as they stand produces a pod stuck `Pending` with
`0/1 nodes are available: Insufficient cpu`, and — because autoscaling is off — no
`TriggerScaleUp` to rescue it. The Deployment will report `0/1` forever and nothing in the logs
will explain why, because the container never starts.

Note that **requests**, not usage, decide this. The node is nowhere near 90% *busy*; the
scheduler is refusing on a reservation ledger, so "but the CPU is idle" is true and irrelevant.

Three ways out:

| Option | Command | Verdict |
| --- | --- | --- |
| **A — add a second node** (recommended) | `gcloud container clusters resize vincent-cluster --node-pool minimal-pool --num-nodes 2 --zone asia-southeast1-a` | Non-destructive, ~2 min, keeps the existing `GKE_METADATA` pool config. A new e2-medium carries only the 386m of per-node DaemonSets, leaving **~554m free** — room for this pod and the next one. Doubles node cost (spot e2-medium, so small). |
| **B — bigger machine type** | recreate the pool with `e2-standard-2` (1930m allocatable) | More headroom per rupiah than two e2-mediums, but a machine-type change **recreates the pool**, and the replacement must be given `--workload-metadata=GKE_METADATA` again or every Workload Identity pod breaks at once. Right answer eventually; wrong one to do mid-deploy. |
| **C — shrink the requests** | `cpu: 50m` app + `25m` proxy = 75m | Fits in 89m. Also leaves the node at 99% reserved with two services' rollouts competing for nothing, and a Go HTTP server paging a 1M-row table on 50m will throttle. A measurement-free squeeze, not a fix. |

Take A. [deploy.md step 1](./deploy.md#step-1--make-room-on-the-cluster-blocker) runs it.

> **Spot nodes:** preemption of a single node is a full outage for both services. Two nodes make
> that a partial outage *only if* the pods land on different nodes, which nothing currently
> guarantees. Worth revisiting with a `topologySpreadConstraint` once there is more than one
> replica to spread.

---

## 4. The Workload Identity chain

Four links. **All four must hold** — any single break ends with the proxy using the node's
identity, which Cloud SQL rejects with an error naming the wrong service account.

Links 1 and 2 are **cluster/pool-wide and already done**. Links 3 and 4 are per-service and do
not exist yet for this service.

| # | Link | Required value | State |
| --- | --- | --- | --- |
| 1 | Cluster identity pool | `vincent-mini-apps-project.svc.id.goog` | ✅ shared |
| 2 | Node pool metadata mode | `GKE_METADATA` | ✅ shared |
| 3 | GSA exists, holds `roles/cloudsql.client` | `recommendations-sql@vincent-mini-apps-project.iam.gserviceaccount.com` | ❌ **create it** |
| 4 | GSA grants `roles/iam.workloadIdentityUser` to the KSA | `serviceAccount:vincent-mini-apps-project.svc.id.goog[recommendations/recommendations-service]` | ❌ **bind it** |
| — | KSA annotation points back at the GSA | `iam.gke.io/gcp-service-account: recommendations-sql@…` | ✅ in `service-account.yml` |

```bash
P=vincent-mini-apps-project
GSA="recommendations-sql@${P}.iam.gserviceaccount.com"

# 1 and 2 (shared, should already pass)
gcloud container clusters describe vincent-cluster --zone asia-southeast1-a \
  --format='value(workloadIdentityConfig.workloadPool)'
gcloud container node-pools describe minimal-pool --cluster vincent-cluster \
  --zone asia-southeast1-a --format='value(config.workloadMetadataConfig.mode)'
# 3
gcloud projects get-iam-policy "$P" --flatten='bindings[].members' \
  --filter="bindings.members:${GSA}" --format='table(bindings.role)'
# 4
gcloud iam service-accounts get-iam-policy "$GSA" --format=json | grep workloadIdentityUser
```

Links 3 and 4 point in **opposite directions** and this is the part that is easy to half-finish:
3 says "this identity may connect to Cloud SQL", 4 says "this pod may *be* that identity".
Missing 4 is silent — nothing errors at startup, the proxy just falls back to the node's identity
and Cloud SQL refuses it later.

### Why a second GSA rather than reusing `auth-sql`

Both services need exactly `roles/cloudsql.client` today, so one shared GSA would work. It is
still the wrong default: a single identity means any future grant made for one service is
automatically held by the other, and an audit log entry can no longer tell you which workload
connected. One GSA per workload costs one `create` and one binding.

### Why not a key file

| Approach | Verdict |
| --- | --- |
| Node service account | **Cannot work here.** The node SA's OAuth *scopes* are only `devstorage.read_only`, `logging.write`, `monitoring`. Scopes cap a token regardless of IAM, and `sqladmin` is not among them. |
| Downloaded JSON key in a Secret | Works, no cluster change — but a long-lived credential with no rotation story. |
| **Workload Identity** ← chosen | KSA mapped to GSA; tokens short-lived and minted per pod. No key exists to leak. |

Image pulls need no extra IAM: the node SA's `devstorage.read_only` scope is what Artifact
Registry honours for reads.

---

## 5. Artifact Registry and the image

| Parameter | Value | State |
| --- | --- | --- |
| Registry host | `asia-southeast1-docker.pkg.dev` | — |
| Existing repos | `auth-repository` only | ✅ verified |
| Repo this service needs | `recommendations-repository` | ❌ **create it** |
| Image path | `asia-southeast1-docker.pkg.dev/vincent-mini-apps-project/recommendations-repository/recommendations-service` | — |
| Published tags | **none** | ❌ **build and push** |

```bash
gcloud artifacts repositories list --format='table(name,format,location)'
gcloud artifacts docker images list \
  asia-southeast1-docker.pkg.dev/vincent-mini-apps-project/recommendations-repository
```

A separate repo per service keeps retention and cleanup policies independent; pushing into
`auth-repository` would also work and is a worse habit. Either way the location must be
`asia-southeast1` — a cross-region pull is slower and billed as egress.

### ⚠️ `--platform linux/amd64` is required, not optional

This laptop is arm64; the GKE nodes are `e2-medium`, which is amd64. A natively built image
pushes and pulls fine and then fails on the node with **`exec format error`** — a runtime failure
that looks nothing like an architecture problem.

`recommendations-be` has **no `image` / `image-push` Makefile target** (unlike `auth-be`), so
there is nothing enforcing the flag. [deploy.md step 4](./deploy.md#step-4--build-and-push-the-image)
gives the explicit `docker buildx` command, and a Makefile snippet worth adding to that repo.

The Dockerfile's `runtime` stage is `gcr.io/distroless/static-debian12:nonroot` — no shell, no
package manager. Consequences that show up later: `kubectl exec … -- sh` cannot work, and
`readOnlyRootFilesystem: true` is safe because the binary logs to stderr.

---

## 6. Database and secrets

### 6.1 Secret `recommendations-service-secrets`: all four keys

The pod cannot start without it, and the key list is surprising:

```bash
kubectl -n recommendations get secret recommendations-service-secrets \
  -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'
# want: DB_PASSWORD / ENCRYPTION_KEY / GOOGLE_OAUTH_CLIENT_ID / GOOGLE_OAUTH_CLIENT_SECRET
```

| Key | Why this service needs it |
| --- | --- |
| `DB_PASSWORD` | the only one actually used at runtime — `postgres` on the shared instance |
| `GOOGLE_OAUTH_CLIENT_ID` | **not used by any route.** Required anyway — see below |
| `GOOGLE_OAUTH_CLIENT_SECRET` | same |
| `ENCRYPTION_KEY` | same |

**Why three unused auth values are mandatory.** `config.Load()` ends with a validation loop over
`GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET`, `google_oauth_redirect_url` and
`ENCRYPTION_KEY`, returning `config: <NAME> is required` if any is empty. That loop runs
unconditionally, before anything asks whether this build has auth routes — and `router.go`
registers only `/health` and `/places`. So the requirement is real even though the values are
inert. `main.go` turns the error into `log.Fatalf`, i.e. **CrashLoopBackOff with a one-line log**.
A missing *Secret* fails differently and earlier: `CreateContainerConfigError`, before any
process runs.

`google_oauth_redirect_url` is the fourth required value and is **not** an environment variable —
it comes from the embedded `production.yaml` (`http://localhost:9999/api/auth/google/callback`)
via `//go:embed`. It is non-empty, so it passes. Nothing can override it from the manifest, which
is fine while no callback ever arrives.

**`ENCRYPTION_KEY` constraints.** `secret.NewBox` requires base64 that decodes to **exactly 32
bytes** (the AES-256 key length) — but note that **nothing in this service calls `NewBox`**, so
that check never runs here and only the non-empty test applies. Generate a correct one anyway
with `openssl rand -base64 32`: it costs nothing and the day a route starts sealing values, a
placeholder would fail at request time instead of boot time.

The Secret is deliberately absent from `kustomization.yaml` so no credential enters this repo.

### 6.2 The `gm_places` table must already exist

| Parameter | Value |
| --- | --- |
| Instance | `recommendations-app-instance` (`POSTGRES_18`, `db-perf-optimized-N-8`) |
| Connection name | `vincent-mini-apps-project:asia-southeast1:recommendations-app-instance` |
| Public IP | `34.142.199.254` (laptop-side access only; no private IP) |
| Databases present | `postgres`, `recommendations-backend` ✅ verified |
| `DB_NAME` | `recommendations-backend` — **exists**, unlike auth's case |

So the database question is already settled; the **schema** question is not:

- Every `places` repository query targets one table: `gm_places`
  (`SELECT … FROM gm_places`, `INSERT INTO gm_places …`).
- `recommendations-be` ships **no migrations**. Its `Makefile` has `migrate` / `seed` targets
  pointing at `./db/migrations` and `./internal/platform/db/seeds`, and **neither directory
  exists** in the repo. Those targets cannot run.

Whatever created `gm_places` lives outside this repo (the scraper, or hand-applied SQL). Verify
before calling the deploy done:

```bash
psql "host=34.142.199.254 dbname=recommendations-backend user=postgres sslmode=require" \
  -c '\d gm_places'
```

`sslmode=require` because this hop crosses the public internet, unlike the in-pod loopback hop.
Your home IP must be in the instance's authorized networks.

**The health probe cannot detect a missing table.** `healthCheck` marshals two config strings
and never touches the pool, so the pod goes `Ready` and 200s happily while every `/api/v1/places`
request 500s. `GET /api/v1/places` is the only real test.

### Least privilege, deferred

The manifests authenticate as `postgres`, the instance superuser shared with auth-service. A
dedicated `recommendations_app` user with rights on this database only is the least-privilege
version, and it stops a password rotation from taking down the other service:

```bash
gcloud sql users create recommendations_app \
  --instance=recommendations-app-instance --prompt-for-password
```

Then set `DB_USER` in `configmap.yaml`, grant it rights on `gm_places`, and put the new password
in the Secret.

---

## 7. Every deployment parameter

### 7.1 Cross-file invariants — what YAML cannot check for you

| # | Must agree | Current | Symptom if broken |
| --- | --- | --- | --- |
| 1 | `configmap: PORT` ⟷ `deployment: containerPort` | `9998` ⟷ `9998` ✅ | probes hit a dead port; pod never Ready, restarts forever |
| 2 | `configmap: DB_PORT` ⟷ proxy `--port` | `5432` ⟷ `5432` ✅ | app dials a closed loopback port → `log.Fatalf` → CrashLoopBackOff |
| 3 | `configmap: DB_NAME` ⟷ a database containing `gm_places` | `recommendations-backend` ⟷ **unverified** ⚠️ | starts fine, every `/places` request 500s |
| 4 | `service: targetPort` ⟷ `deployment: ports[].name` | `http` ⟷ `http` ✅ | Service has no endpoints; curl hangs or 502s |
| 5 | `service: selector` ⟷ pod labels | `app: recommendations-service` ✅ | same, with both objects looking healthy alone |
| 6 | `deployment: serviceAccountName` ⟷ KSA ⟷ `workloadIdentityUser` member | `recommendations-service` ⟷ `[recommendations/recommendations-service]` ❌ not bound yet | proxy falls back to node identity; Cloud SQL rejects it |
| 7 | `DATABASE_URL` stays unset ⟷ the `DB_*` block | unset ✅ | `ConnectDatabaseString()` **prefers** `DATABASE_URL`, silently discarding all six `DB_*` values |

Invariant 1 is worth understanding rather than memorising: `containerPort` is **informational**
in Kubernetes — it neither binds nor restricts anything. The process binds whatever `PORT` says.
So a mismatch does not fail as a bind error; it fails as a probe that can never pass.

Invariant 7 is specific to this service. `config.go` does
`config.Database.URL = os.Getenv("DATABASE_URL")` unconditionally, and
`ConnectDatabaseString()` returns that URL verbatim whenever it is non-empty. Setting it "for
convenience" in the ConfigMap would bypass `DB_HOST=127.0.0.1` and send the app straight past its
own sidecar.

### 7.2 `configmap.yaml` — non-secret environment

| Key | Value | Note |
| --- | --- | --- |
| `APP_ENV` | `production` | selects the embedded `production.yaml`; echoed by `/api/v1/health` as `env`, which makes it the one externally observable proof the right config loaded |
| `PORT` | `9998` | **invariant 1.** Settles a three-way disagreement: `production.yaml` says `server.port: 5001`, the Dockerfile `EXPOSE`s `4000`, `.env` says `:9998`. `config.go` applies `PORT` last and strips a leading `:`, so the manifest wins. 9998 matches the app's own convention (`BASE_URL` default, swagger `@host`) |
| `DB_HOST` | `127.0.0.1` | the sidecar, **not** Cloud SQL |
| `DB_PORT` | `5432` | **invariant 2** |
| `DB_USER` | `postgres` | instance superuser — see §6.2 |
| `DB_NAME` | `recommendations-backend` | **invariant 3** |
| `DB_SSLMODE` | `disable` | correct, not a weakening: this hop is loopback inside the pod, and the proxy makes the TLS connection to Cloud SQL itself |
| `DATABASE_URL` | **absent** | **invariant 7** — must stay absent |
| `BASE_URL` | `http://localhost:9998` | placeholder; read by `config.go` but no handler currently uses it |
| `FRONTEND_URL` | `http://localhost:5173` | placeholder, and **functional**: `middleware/cors.go` passes it straight into `AllowedOrigins` as the single allowed browser origin |
| *(omitted)* `SESSION_TTL`, `SESSION_IDLE_TTL`, `ENCRYPTION_KEY_VERSION`, `GOOGLE_ALLOWED_HD` | — | defaulted by `config.go` (12h / 30m / 1 / any) and unused by any route here |

**`envFrom` has no name hash.** There is no `configMapGenerator`, so editing this file does
**not** roll the Deployment — a running pod keeps the old environment until something restarts
it. After a ConfigMap-only change you must
`kubectl -n recommendations rollout restart deploy/recommendations-service`.

**CORS is not a probe problem.** `rs/cors` only enforces `AllowedOrigins` on requests that carry
an `Origin` header. Kubelet sends none, so all three probes pass through untouched; `curl`
likewise. Only a browser on an origin other than `FRONTEND_URL` is blocked.

### 7.3 `deployment.yaml` — top level and strategy

| Field | Value | Why |
| --- | --- | --- |
| `replicas` | `1` | §3.2. Raise only after the node pool grows |
| `strategy.type` | `RollingUpdate` | — |
| `rollingUpdate.maxUnavailable` | **`1`** | **Must not be 0** on the current single node — two copies do not fit and `0`/`1` deadlocks the rollout. Safe to flip to `0` once §3.2 option A or B is done |
| `rollingUpdate.maxSurge` | **`0`** | scale down first, then up: peak demand stays 1×, not 2× |
| `selector.matchLabels` | `app: recommendations-service` | invariant 5. **Immutable after creation** — changing it later requires deleting the Deployment |
| `serviceAccountName` | `recommendations-service` | invariant 6 — the Workload Identity link |
| `securityContext.runAsNonRoot` | `true` | pod-level |
| `securityContext.seccompProfile` | `RuntimeDefault` | — |

With `replicas: 1`, `maxUnavailable: 1` means a rollout has a brief full outage. That is honest
rather than regressive: a single replica never had a zero-downtime path.

### 7.4 `initContainers[0]` — `cloud-sql-proxy` (native sidecar)

Identical in shape to auth-service's, and for the same reasons.

| Field | Value | Why |
| --- | --- | --- |
| placement | under `initContainers`, **not** `containers` | — |
| `restartPolicy` | `Always` | this plus the placement is what makes it a **native sidecar**. Load-bearing: `db.Connect` Pings the pool and `main.go` turns failure into `log.Fatalf`, so the app exits rather than retrying. An ordinary sidecar starts *in parallel*, so the app can lose the race and crashloop against a port nothing is listening on yet |
| `image` | `gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.14.1` | — |
| `--structured-logs` | — | JSON logs |
| `--port` | `5432` | invariant 2. Binds **127.0.0.1 only** by default |
| `--health-check` | — | **required** — turns on the health server the probe needs |
| `--http-address` | `0.0.0.0` | **required.** Kubelet probes from *outside* the pod's network namespace, so it dials the pod IP. Only the health server listens there; the DB tunnel stays on loopback |
| `--http-port` | `9090` | the probe target |
| instance (positional) | `vincent-mini-apps-project:asia-southeast1:recommendations-app-instance` | the same instance auth-service uses |
| **no** `--credentials-file` | — | deliberate. Workload Identity supplies the token via the bound KSA |
| `startupProbe` | `httpGet /startup` on `9090`, `periodSeconds: 2`, `failureThreshold: 30` | **not** `tcpSocket` on 5432 — that probe can never pass, because the proxy binds loopback while kubelet dials the pod IP |
| `resources.requests` | `50m` / `64Mi` | counts toward §3.2 |
| `resources.limits` | `200m` / `128Mi` | — |

The `--health-check` / `--http-address` / `--http-port` trio and the `httpGet` probe are a single
unit. Drop any one and the probe fails; `startupProbe` failure means SIGTERM, which surfaces as
**exit code 143** (128 + 15) and `CrashLoopBackOff` on a container whose own logs say
`The proxy has started successfully`.

### 7.5 `containers[0]` — `recommendations-service`

| Field | Value | Why |
| --- | --- | --- |
| `image` | `…/recommendations-repository/recommendations-service:0.0.1` | **tag only until the first push.** Pin the digest immediately after — see deploy.md step 6 |
| `imagePullPolicy` | `IfNotPresent` | only safe while the reference is immutable. With a tag-only reference this means "never re-push `0.0.1`" |
| `ports[].name` | `http` | invariant 4. Named so the Service and all three probes reference `http`, never a number |
| `ports[].containerPort` | `9998` | invariant 1. Informational only |
| `envFrom` | `recommendations-service-config`, `recommendations-service-secrets` | §7.2, §6.1 |
| `securityContext` — **no** `runAsUser` | *(unset)* | **deliberate.** The distroless `:nonroot` tag already sets numeric UID 65532, and the *numeric* form is what lets Kubernetes verify `runAsNonRoot`. Restating it as a name breaks the check |
| `securityContext.readOnlyRootFilesystem` | `true` | safe: `main.go` logs to stderr via stdlib `log`; `logger.file_name: logs/logrus.log` in `production.yaml` is vestigial — nothing opens it |
| `resources.requests` | `100m` / `128Mi` | counts toward §3.2 |
| `resources.limits` | `500m` / `256Mi` | watch this one: `ListPlaces` runs a `COUNT(*)` over a filtered CTE on `gm_places`, and the pgx pool is configured for `max_conns: 20`. Rows stream rather than buffer whole, but 256Mi is a first guess, not a measurement |

### 7.6 The three app probes

All three target `port: http` by **name**, and all three hit `/api/v1/health`.

| Probe | Timing | Budget |
| --- | --- | --- |
| `startupProbe` | `periodSeconds: 3`, `failureThreshold: 20` | 60s to boot |
| `readinessProbe` | `periodSeconds: 10`, `timeoutSeconds: 3`, `failureThreshold: 3` | removed from endpoints after ~30s unhealthy |
| `livenessProbe` | `periodSeconds: 20`, `timeoutSeconds: 3`, `failureThreshold: 3` | restarted after ~60s unhealthy |

`/api/v1/health` is cheap and side-effect-free: the handler marshals `{"env":…,"image":…}` from
config and never touches the pool, so one slow `gm_places` query cannot evict a healthy pod. The
flip side is §6.2 — a green probe says nothing about whether the table exists.

> `image` in that payload is always `""`. `Config.Image` is declared in `model.go` but never
> assigned in `config.Load()`, so there is no env var that fills it. Harmless, and a missed
> opportunity: it is exactly where the running tag belongs.
>
> `/api/v1/` is registered as a second alias for the same handler, if you ever want a probe path
> without the `/health` suffix.

### 7.7 `service.yaml`

| Field | Value | Why |
| --- | --- | --- |
| `type` | `LoadBalancer` | Phase 1 only. This is the **second** LoadBalancer in the project — each is its own GCP forwarding rule and billed external IP, which is the argument for moving both services behind one shared GKE Ingress |
| `selector` | `app: recommendations-service` | invariant 5 |
| `port` | `80` | external |
| `targetPort` | `http` | invariant 4 — **by name**, which is why a container port change needs no edit here |

For comparison, auth-service's LoadBalancer is on `34.87.12.86`. This service gets its own IP,
assigned at create time.

### 7.8 `kustomization.yaml`

| Field | Value | Note |
| --- | --- | --- |
| `namespace` | `recommendations` | applied to every resource |
| `resources` | namespace, SA, configmap, deployment, service | **no Secret** — created imperatively |
| `labels[].includeSelectors` | `false` | important: `true` would inject these labels into the immutable `selector.matchLabels`, making future label changes a Deployment-replacing operation |

---

## 8. Preflight — run before every apply

```bash
# identity: both halves, because they fail independently
kubectl config current-context    # ...vincent-cluster
gcloud config get account         # vinhnguyentan99@gmail.com
kubectl get nodes                 # want TWO Ready nodes after §3.2

# room to land -- the blocker
kubectl describe node -l cloud.google.com/gke-nodepool=minimal-pool \
  | sed -n '/Allocated resources/,/^Events/p'

# the Secret the pod cannot start without
kubectl -n recommendations get secret recommendations-service-secrets \
  -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'

# the image exists and is amd64
gcloud artifacts docker images describe \
  asia-southeast1-docker.pkg.dev/vincent-mini-apps-project/recommendations-repository/recommendations-service:0.0.1 \
  --format='value(image_summary.digest)'

# what will actually be sent, before sending it
kubectl kustomize k8s/recommendations-service \
  | grep -E 'containerPort|targetPort|PORT:|maxUnavailable|DATABASE_URL'
```

Use `kubectl kustomize` (client-side render), not `kubectl apply --dry-run=server`: server-side
dry-run never persists the Namespace, so every namespaced object in the bundle fails with
`namespaces "recommendations" not found`. That is an artifact of the dry run, not a manifest bug.

---

## Exit checklist

- [ ] `gcloud config get account` is `vinhnguyentan99@gmail.com`
- [ ] `kubectl config current-context` ends in `vincent-cluster`
- [ ] Node pool has **≥150m CPU free** for this pod (§3.2 — the blocker)
- [ ] GSA `recommendations-sql` exists with `roles/cloudsql.client` (§4 link 3)
- [ ] `workloadIdentityUser` binds `[recommendations/recommendations-service]` (§4 link 4)
- [ ] `recommendations-repository` exists in `asia-southeast1`
- [ ] A `linux/amd64` image is pushed, and its digest is pinned in `deployment.yaml`
- [ ] `recommendations-service-secrets` holds all four keys
- [ ] `gm_places` exists in `recommendations-backend` (§6.2)
- [ ] All seven invariants in §7.1 hold

→ Deploy: [deploy.md](./deploy.md)
