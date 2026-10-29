# Prerequisites and parameter reference — `auth-service`

Everything that must be true **before** `kubectl apply -k k8s/auth-service` can produce a
running pod, plus every parameter the deployment depends on and the one command that checks it.

Each row carries a value that was verified against the live project, not copied from a plan.
Where a value is still open, it says so.

**Verified:** 2026-10-29 against `vincent-mini-apps-project` / `vincent-cluster`.
**Step-by-step deploy:** [deploy.md](./deploy.md). **Field-by-field rationale:**
[manifest-reference.md](./manifest-reference.md). **Upstream citations:**
[parameters.md](./parameters.md).

---

## Status at a glance

| # | Requisite | State |
| --- | --- | --- |
| 1 | Local tooling (`gcloud`, `kubectl`, auth plugin) | ✅ verified |
| 2 | Project APIs enabled | ✅ verified |
| 3 | Cluster reachable, one `Ready` node | ✅ verified |
| 4 | Node CPU budget fits the pod | ⚠️ **tight** — 89m spare, see §3.2 |
| 5 | Workload Identity chain, all four links | ✅ verified |
| 6 | Cloud SQL instance reachable by the proxy | ✅ verified |
| 7 | Namespace `auth` | ✅ exists |
| 8 | Secret `auth-service-secrets`, all four keys | ✅ exists |
| 9 | **Auth schema migrated into the database `DB_NAME` points at** | ❌ **open — see §6.2** |

Items 1–8 need no action. Item 9 is the only prerequisite still outstanding, and it will not
show up as a startup failure — the pod will go Ready and then fail at runtime on missing tables.

---

## 1. Local tooling

| Parameter | Required value | Check |
| --- | --- | --- |
| gcloud account | `vinhnguyentan99@gmail.com` | `gcloud config get account` |
| gcloud project | `vincent-mini-apps-project` | `gcloud config get project` |
| gcloud configuration | `personal` | `gcloud config configurations list` |
| kubectl context | `gke_vincent-mini-apps-project_asia-southeast1-a_vincent-cluster` | `kubectl config current-context` |
| GKE auth plugin | present at `/opt/homebrew/share/google-cloud-sdk/bin/gke-gcloud-auth-plugin` | `/opt/homebrew/share/google-cloud-sdk/bin/gke-gcloud-auth-plugin --version` |

### Why the account matters more than the context

The kubeconfig stores **no credential**. It stores an `exec` hook that calls
`gke-gcloud-auth-plugin`, which mints a fresh token for whichever gcloud configuration is
*active at that moment*. A context pointing at `vincent-cluster` is therefore not sufficient on
its own: switch gcloud configurations and `kubectl` silently changes identity with it, then
returns `Forbidden`. This is why the preflight in §8 checks both, every time.

The plugin is not on `PATH` — a plain `which gke-gcloud-auth-plugin` reports nothing. Harmless;
the kubeconfig references it by absolute path. Only if that path ever disappears:

```bash
brew install google-cloud-sdk-gke-gcloud-auth-plugin
```

`gcloud components install` is rejected on a Homebrew-managed SDK.

---

## 2. Project APIs

| API | Why it is needed | State |
| --- | --- | --- |
| `sqladmin.googleapis.com` | the proxy calls it to discover the instance and mint certificates | ✅ enabled |
| `iamcredentials.googleapis.com` | Workload Identity token exchange | ✅ enabled |
| `container.googleapis.com` | GKE itself | ✅ enabled |
| `artifactregistry.googleapis.com` | image pulls | ✅ enabled |

```bash
gcloud services list --enabled | grep -E 'sqladmin|iamcredentials|container\.|artifactregistry'
```

`secretmanager.googleapis.com` is deliberately **not** enabled — secrets live in Kubernetes.

---

## 3. Cluster and node pool

### 3.1 Identity and shape

| Parameter | Value | Check |
| --- | --- | --- |
| Cluster | `vincent-cluster`, **zonal** `asia-southeast1-a` | `gcloud container clusters list` |
| Control plane / kubelet | `v1.36.4-gke.2046003` | `kubectl get nodes` |
| Node pool | `minimal-pool` | `gcloud container node-pools list --cluster vincent-cluster --zone asia-southeast1-a` |
| Machine type | `e2-medium` | `--format='value(config.machineType)'` |
| Nodes | 1, **spot**, autoscaling off | `--format='value(initialNodeCount,config.spot,autoscaling.enabled)'` |

The version matters for one reason: **native sidecars** (`initContainers` with
`restartPolicy: Always`) require Kubernetes **1.29+**. At 1.36 this is well satisfied; on an
older cluster the API server would reject the field outright.

Spot + one node means preemption is a full outage. Acceptable for bring-up; not acceptable once
anything depends on it.

### 3.2 CPU budget — the binding constraint

⚠️ **This is a prerequisite, not a detail.** The node is small and GKE's own system pods
take most of it:

| | CPU requests |
| --- | --- |
| `e2-medium` allocatable | **940m** |
| GKE system pods (kube-dns, fluentbit, gke-metadata-server, kube-proxy, metrics-server, gmp, …) | **~701m** |
| **Free for workloads** | **~239m** |
| `auth-service` pod needs (100m app + 50m proxy) | **150m** |
| Remaining headroom | **~89m** |

```bash
kubectl describe node -l cloud.google.com/gke-nodepool=minimal-pool \
  | sed -n '/Allocated resources/,/^Events/p'
```

Two consequences that have already bitten this deployment:

1. **No third workload will schedule.** 89m is not enough for anything meaningful.
2. **A rollout cannot run two copies of the pod at once.** This is why
   `deployment.yaml` sets `maxUnavailable: 1` / `maxSurge: 0`. With the more usual
   `maxUnavailable: 0` / `maxSurge: 1`, the old pod cannot be removed until the new one is
   Ready, and the new one cannot be *scheduled* until the old one is removed — the rollout
   deadlocks with the new pod `Pending` on `Insufficient cpu` and the autoscaler reporting
   `NotTriggerScaleUp`. See the [incident record](./phase-1-fix-blockers.md).

Moving to `e2-standard-2` (1930m allocatable) ends this whole class of problem.

---

## 4. The Workload Identity chain

Four links. **All four must hold** — any single break ends with the proxy using the node's
identity, which Cloud SQL rejects with an error naming the wrong service account.

| # | Link | Required value | State |
| --- | --- | --- | --- |
| 1 | Cluster identity pool | `vincent-mini-apps-project.svc.id.goog` | ✅ |
| 2 | Node pool metadata mode | `GKE_METADATA` | ✅ |
| 3 | GSA exists, holds `roles/cloudsql.client` | `auth-sql@vincent-mini-apps-project.iam.gserviceaccount.com` | ✅ |
| 4 | GSA grants `roles/iam.workloadIdentityUser` to the KSA | `serviceAccount:vincent-mini-apps-project.svc.id.goog[auth/auth-service]` | ✅ |
| — | KSA annotation points back at the GSA | `iam.gke.io/gcp-service-account: auth-sql@…` | ✅ |

```bash
P=vincent-mini-apps-project
GSA="auth-sql@${P}.iam.gserviceaccount.com"

# 1
gcloud container clusters describe vincent-cluster --zone asia-southeast1-a \
  --format='value(workloadIdentityConfig.workloadPool)'
# 2
gcloud container node-pools describe minimal-pool --cluster vincent-cluster \
  --zone asia-southeast1-a --format='value(config.workloadMetadataConfig.mode)'
# 3
gcloud projects get-iam-policy "$P" --flatten='bindings[].members' \
  --filter="bindings.members:${GSA}" --format='table(bindings.role)'
# 4
gcloud iam service-accounts get-iam-policy "$GSA" --format=json | grep workloadIdentityUser
# KSA side
kubectl -n auth get sa auth-service -o jsonpath='{.metadata.annotations.iam\.gke\.io/gcp-service-account}'
```

### Why not a key file

| Approach | Verdict |
| --- | --- |
| Node service account | **Cannot work here.** The node SA holds `roles/editor`, but its OAuth *scopes* are only `devstorage.read_only`, `logging.write`, `monitoring`. Scopes cap a token regardless of IAM, and `sqladmin` is not among them. |
| Downloaded JSON key in a Secret | Works, no cluster change — but a long-lived credential with no rotation story. |
| **Workload Identity** ← chosen | KSA mapped to GSA; tokens short-lived and minted per pod. No key exists to leak. |

The cost was a one-time node pool recreation when the metadata mode changed. That is already
done — do **not** re-run it.

Image pulls need no extra IAM: the node SA's `devstorage.read_only` scope is what Artifact
Registry honours for reads.

### Link 2 is observable from inside the cluster

`gke-metadata-server` running on the node is the proof that `GKE_METADATA` took effect:

```bash
kubectl -n kube-system get pods -l k8s-app=gke-metadata-server -o wide
```

---

## 5. Cloud SQL

| Parameter | Value | Where it is consumed |
| --- | --- | --- |
| Instance | `recommendations-app-instance` | — |
| Version / tier | `POSTGRES_18` / `db-perf-optimized-N-8` | — |
| Connection name | `vincent-mini-apps-project:asia-southeast1:recommendations-app-instance` | `deployment.yaml` proxy arg (last positional) |
| Public IP | `34.142.199.254` | laptop-side migrations only |
| Private IP | **none** | — |
| Databases present | `postgres`, `recommendations-backend` | see §6.2 |

```bash
gcloud sql instances describe recommendations-app-instance \
  --format='value(databaseVersion,settings.tier,connectionName,ipAddresses[0].ipAddress)'
gcloud sql databases list --instance=recommendations-app-instance
```

The instance has **no private IP**, so the proxy reaches it over the public endpoint. That is
fine and is not a weakening: the proxy makes a mutually-authenticated TLS connection regardless
of which address it dials. The instance is shared with `recommendations-backend` — worth knowing
when reading its metrics.

---

## 6. Kubernetes objects that must pre-exist

### 6.1 Namespace and Secret

| Object | Requirement | State |
| --- | --- | --- |
| Namespace `auth` | created by `kustomization.yaml`, but the Secret needs it first | ✅ |
| Secret `auth-service-secrets` | **all four keys**, created imperatively | ✅ |

```bash
kubectl -n auth get secret auth-service-secrets \
  -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'
# DB_PASSWORD / ENCRYPTION_KEY / GOOGLE_OAUTH_CLIENT_ID / GOOGLE_OAUTH_CLIENT_SECRET
```

`config.Load()` errors on any empty one and `main.go` turns that into `log.Fatalf`, so a missing
value is a CrashLoopBackOff — and a *missing Secret* is `CreateContainerConfigError`, which looks
different and is easy to misread.

The Secret is deliberately absent from `kustomization.yaml` so no credential enters this repo.

**`ENCRYPTION_KEY` constraints:**

- Must decode to **exactly 32 bytes** — `secret.go` rejects anything else. That is the AES-256
  key length, not a preference. `openssl rand -base64 32` is exactly right.
- It seals live session cookies. **Changing it logs every user out**, and nothing in the code
  reads a fallback key. Store it in a password manager the moment it is generated.

### 6.2 Open: the auth schema has nowhere to live yet

❌ **The one real gap, and it is quiet:**

- `configmap.yaml` sets `DB_NAME: "recommendations-backend"`.
- The instance has **no `auth_service` database** — only `postgres` and
  `recommendations-backend`.
- The auth migration `db/migrations/00001_init.sql` in `../auth-be` targets `auth_service`.

So unless that migration has been run **into `recommendations-backend`**, the pod will connect
successfully, log `database connected`, pass its health probe — and then fail on the first
request that touches `users` or `sessions`. The health handler deliberately does not touch the
database, so it cannot catch this.

Decide one of these before calling the deployment done:

| Option | What to do |
| --- | --- |
| **A — share one database** (matches the current ConfigMap) | run the migration into `recommendations-backend`; auth tables live alongside the recommendations tables |
| **B — separate database** (matches the migration) | `gcloud sql databases create auth_service --instance=recommendations-app-instance`, migrate into it, then set `DB_NAME: "auth_service"` in `configmap.yaml` |

Option B is cleaner — separate schemas, separate blast radius, and it matches what the Go repo
already expects. Both are covered in [deploy.md §2](./deploy.md).

While you are there: the manifests authenticate as `postgres`, the instance superuser shared
with `recommendations-backend`. A dedicated `auth_app` user with rights on only the auth
database is the least-privilege version, and it avoids a password rotation taking down the other
service.

---

## 7. Every deployment parameter

### 7.1 Cross-file invariants — what YAML cannot check for you

| # | Must agree | Current | Symptom if broken |
| --- | --- | --- | --- |
| 1 | `configmap: PORT` ⟷ `deployment: containerPort` | `9999` ⟷ `9999` ✅ | probes hit a dead port; pod never Ready, restarts forever |
| 2 | `configmap: DB_PORT` ⟷ proxy `--port` | `5432` ⟷ `5432` ✅ | app dials a closed loopback port → `log.Fatalf` → CrashLoopBackOff |
| 3 | `configmap: DB_NAME` ⟷ the database actually migrated | `recommendations-backend` ⟷ **unverified** ⚠️ | starts fine, fails at runtime on missing tables |
| 4 | `service: targetPort` ⟷ `deployment: ports[].name` | `http` ⟷ `http` ✅ | Service has no endpoints; curl hangs or 502s |
| 5 | `service: selector` ⟷ pod labels | `app: auth-service` ✅ | same, with both objects looking healthy alone |
| 6 | `deployment: serviceAccountName` ⟷ KSA ⟷ `workloadIdentityUser` member | `auth-service` ✅ | proxy falls back to node identity; Cloud SQL rejects it |

Invariant 1 is worth understanding rather than memorising: `containerPort` is **informational**
in Kubernetes — it neither binds nor restricts anything. The process binds whatever `PORT` says.
So a mismatch does not fail as a bind error; it fails as a probe that can never pass.

### 7.2 `configmap.yaml` — non-secret environment

| Key | Value | Note |
| --- | --- | --- |
| `APP_ENV` | `production` | selects the embedded `production.yaml`; also switches on HSTS |
| `PORT` | `9999` | **invariant 1.** Wins over `server.port` in the embedded config — `config.go` reads `PORT` last. Set here so the manifest, not the baked-in config, owns the port. 9999 is the app's own convention: the `BASE_URL` default in `config.go`, the Dockerfile `EXPOSE`, and the port in the embedded OAuth redirect URL. |
| `DB_HOST` | `127.0.0.1` | the sidecar, **not** Cloud SQL |
| `DB_PORT` | `5432` | **invariant 2** |
| `DB_USER` | `postgres` | instance superuser — see §6.2 |
| `DB_NAME` | `recommendations-backend` | **invariant 3 — the open question** |
| `DB_SSLMODE` | `disable` | correct, not a weakening: this hop is loopback inside the pod, and the proxy makes the TLS connection to Cloud SQL itself |
| `BASE_URL` | `http://localhost:9999` | Phase 2 placeholder |
| `FRONTEND_URL` | `http://localhost:5173` | Phase 2 placeholder. Does double duty: post-login redirect **and** the single allowed CORS origin |
| `SESSION_TTL` | `12h` | absolute session lifetime |
| `SESSION_IDLE_TTL` | `30m` | idle timeout |

**`envFrom` has no name hash.** There is no `configMapGenerator`, so editing this file does
**not** roll the Deployment — a running pod keeps the old environment until something restarts
it. After a ConfigMap-only change you must `kubectl -n auth rollout restart deploy/auth-service`.

### 7.3 `deployment.yaml` — top level and strategy

| Field | Value | Why |
| --- | --- | --- |
| `replicas` | `1` | one node, and §3.2's CPU budget. Raise only after the node pool grows |
| `strategy.type` | `RollingUpdate` | — |
| `rollingUpdate.maxUnavailable` | **`1`** | **Must not be 0.** See §3.2 — two copies do not fit, and `0` deadlocks the rollout |
| `rollingUpdate.maxSurge` | **`0`** | scale down first, then up: peak demand stays 1×, not 2× |
| `selector.matchLabels` | `app: auth-service` | invariant 5. Immutable after creation |
| `serviceAccountName` | `auth-service` | invariant 6 — the Workload Identity link |
| `securityContext.runAsNonRoot` | `true` | pod-level |
| `securityContext.seccompProfile` | `RuntimeDefault` | — |

With `replicas: 1`, `maxUnavailable: 1` means a rollout has a brief full outage. That is honest
rather than regressive: a single replica never had a zero-downtime path, it just failed in a
less legible way.

### 7.4 `initContainers[0]` — `cloud-sql-proxy` (native sidecar)

| Field | Value | Why |
| --- | --- | --- |
| placement | under `initContainers`, **not** `containers` | — |
| `restartPolicy` | `Always` | this plus the placement is what makes it a **native sidecar**. Load-bearing: `main.go` pings the DB at startup and `log.Fatalf`s if it cannot connect. An ordinary sidecar starts *in parallel*, so the app can lose the race and crashloop against a port nothing is listening on yet. A native sidecar is guaranteed fully started first |
| `image` | `gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.14.1` | — |
| `--structured-logs` | — | JSON logs |
| `--port` | `5432` | invariant 2. Binds **127.0.0.1 only** by default |
| `--health-check` | — | **required** — turns on the health server the probe needs |
| `--http-address` | `0.0.0.0` | **required.** Kubelet probes from *outside* the pod's network namespace, so it dials the pod IP. Only the health server listens there; the DB tunnel stays on loopback |
| `--http-port` | `9090` | the probe target |
| instance (positional) | `vincent-mini-apps-project:asia-southeast1:recommendations-app-instance` | — |
| **no** `--credentials-file` | — | deliberate. Workload Identity supplies the token via the bound KSA; a key file here would defeat the point |
| `startupProbe` | `httpGet /startup` on `9090`, `periodSeconds: 2`, `failureThreshold: 30` | **not** `tcpSocket` on 5432 — that probe can never pass, because the proxy binds loopback while kubelet dials the pod IP. It previously killed this container every 60s |
| `resources.requests` | `50m` / `64Mi` | counts toward §3.2 |
| `resources.limits` | `200m` / `128Mi` | — |
| `securityContext` | `runAsNonRoot`, no privilege escalation, read-only root, all caps dropped | — |

The `--health-check` / `--http-address` / `--http-port` trio and the `httpGet` probe are a
single unit. Drop any one and the probe fails; `startupProbe` failure means SIGTERM, which
surfaces as **exit code 143** (128 + 15) and `CrashLoopBackOff` on a container whose own logs
say `The proxy has started successfully`.

### 7.5 `containers[0]` — `auth-service`

| Field | Value | Why |
| --- | --- | --- |
| `image` | `…/auth-service:0.0.1@sha256:2e3283ac…` | **tag *and* digest.** The digest resolves; the tag documents. A moved tag makes `kubectl rollout undo` meaningless |
| `imagePullPolicy` | `IfNotPresent` | correct *because* of the digest pin — a digest cannot change meaning, so re-pulling buys nothing |
| `ports[].name` | `http` | invariant 4. Named so the Service and all three probes reference `http`, never a number — which is why changing the port is a one-line edit |
| `ports[].containerPort` | `9999` | invariant 1. Informational only |
| `envFrom` | `auth-service-config`, `auth-service-secrets` | §7.2, §6.1 |
| `securityContext` — **no** `runAsUser` | *(unset)* | **deliberate.** The distroless `:nonroot` tag already sets numeric UID 65532, and the *numeric* form is what lets Kubernetes verify `runAsNonRoot`. Restating it as a name breaks the check |
| `securityContext.readOnlyRootFilesystem` | `true` | safe: `main.go` logs to stderr via stdlib `log`; `logger.file_name` in `production.yaml` is vestigial |
| `resources.requests` | `100m` / `128Mi` | counts toward §3.2 |
| `resources.limits` | `500m` / `256Mi` | Go's GC targets available memory; watch 256Mi under load |

### 7.6 The three app probes

All three target `port: http` by **name**, and all three hit `/api/v1/health`.

| Probe | Timing | Budget |
| --- | --- | --- |
| `startupProbe` | `periodSeconds: 3`, `failureThreshold: 20` | 60s to boot |
| `readinessProbe` | `periodSeconds: 10`, `timeoutSeconds: 3`, `failureThreshold: 3` | removed from endpoints after ~30s unhealthy |
| `livenessProbe` | `periodSeconds: 20`, `timeoutSeconds: 3`, `failureThreshold: 3` | restarted after ~60s unhealthy |

`/api/v1/health` is safe to probe for two specific reasons: the CSRF middleware exempts GET, and
the handler deliberately does **not** touch the database — so one slow query cannot evict a
healthy pod. The flip side is §6.2: a green probe says nothing about whether the schema exists.

### 7.7 `service.yaml`

| Field | Value | Why |
| --- | --- | --- |
| `type` | `LoadBalancer` | Phase 1 only. Phase 2 switches to `NodePort` behind a GKE Ingress with a managed certificate, because Google OAuth needs a real hostname |
| `selector` | `app: auth-service` | invariant 5 |
| `port` | `80` | external |
| `targetPort` | `http` | invariant 4 — **by name**, which is why a container port change needs no edit here |
| Current external IP | `34.87.12.86` | `kubectl -n auth get svc auth-service` |

### 7.8 `kustomization.yaml`

| Field | Value | Note |
| --- | --- | --- |
| `namespace` | `auth` | applied to every resource |
| `resources` | namespace, SA, configmap, deployment, service | **no Secret** — created imperatively |
| `labels[].includeSelectors` | `false` | important: `true` would inject these labels into the immutable `selector.matchLabels`, making future label changes a Deployment-replacing operation |

---

## 8. Preflight — run before every apply

Cheap, and it is the only thing standing between you and applying manifests to whatever cluster
your kubeconfig last pointed at:

```bash
# identity: both halves, because they fail independently
kubectl config current-context    # ...vincent-cluster
gcloud config get account         # vinhnguyentan99@gmail.com
kubectl get nodes                 # one Ready node

# room to land
kubectl describe node -l cloud.google.com/gke-nodepool=minimal-pool \
  | sed -n '/Allocated resources/,/^Events/p'

# the Secret the pod cannot start without
kubectl -n auth get secret auth-service-secrets \
  -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'

# what will actually be sent, before sending it
kubectl kustomize k8s/auth-service | grep -E 'containerPort|targetPort|PORT:|maxUnavailable'
```

---

## Exit checklist

- [ ] `gcloud config get account` is `vinhnguyentan99@gmail.com`
- [ ] `kubectl config current-context` ends in `vincent-cluster`
- [ ] `kubectl get nodes` shows one `Ready` node
- [ ] Node has ≥150m CPU free for this pod
- [ ] All four Workload Identity links verified (§4)
- [ ] `auth-service-secrets` holds all four keys; `ENCRYPTION_KEY` saved outside the cluster
- [ ] `DB_NAME` names a database the auth migration has actually been applied to (§6.2)
- [ ] All six invariants in §7.1 hold

→ Deploy: [deploy.md](./deploy.md)
