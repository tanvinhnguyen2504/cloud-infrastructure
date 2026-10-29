# Manifest field reference — `k8s/auth-service/`

Every field in every manifest: what it is, what value is set, and why that value. Written
against `auth-be` specifically, so "why" means "because of this line of Go", not "because the
Kubernetes docs say so".

Companion doc: [parameters.md](./parameters.md) carries the official doc link for every field
below. This file holds the *reasoning*; that one holds the *citations*.

Read [Cross-file invariants](#cross-file-invariants) first. Most manifest bugs here are not a
wrong field — they are two fields in different files that stopped agreeing.

- [Cross-file invariants](#cross-file-invariants) ← **start here**
- [kustomization.yaml](#kustomizationyaml)
- [namespace.yaml](#namespaceyaml)
- [service-account.yml](#service-accountyml)
- [configmap.yaml](#configmapyaml)
- [deployment.yaml](#deploymentyaml)
- [service.yaml](#serviceyaml)

---

## Cross-file invariants

These are the couplings YAML cannot check for you. Each row is a pair of fields that must agree;
the right column is what happens when they don't.

| # | Must agree | If they disagree |
| --- | --- | --- |
| 1 | `configmap: PORT` ⟷ `deployment: containerPort` | Probes hit a dead port. Pod never becomes ready, then restarts forever. |
| 2 | `configmap: DB_PORT` ⟷ proxy `--port` ⟷ proxy `startupProbe.tcpSocket.port` | App dials a closed loopback port → `db.Connect` fails → `log.Fatalf` → CrashLoopBackOff. |
| 3 | `configmap: DB_NAME` ⟷ the database you actually migrated | App starts, then fails at runtime on missing tables — or silently writes into the wrong schema. |
| 4 | `service: targetPort` ⟷ `deployment: ports[].name` | Service has no endpoints; `curl` to the LB hangs or 502s. |
| 5 | `service: selector` ⟷ `deployment: template.metadata.labels` | Same: no endpoints, with both objects looking healthy in isolation. |
| 6 | `deployment: serviceAccountName` ⟷ KSA name ⟷ the `workloadIdentityUser` member string | Proxy falls back to the node identity; Cloud SQL rejects it. |

### ✅ Invariant 1 is satisfied: the app port is `9999`

`9999` was chosen over `8080` because it is already this app's own convention — it is the
`BASE_URL` default in `config.go`, the `EXPOSE` in the Dockerfile, and the port in the embedded
`google_oauth_redirect_url`. The three fields that have to agree:

| Field | File | Value |
| --- | --- | --- |
| `PORT` | `configmap.yaml:11` | `9999` |
| `containerPort` | `deployment.yaml:85` | `9999` |
| `BASE_URL` | `configmap.yaml:25` | `:9999` |

`service.yaml` needs nothing: `targetPort: http` resolves by *name*, as do all three probes, so
`containerPort` is the only numeric edit a port change requires.

Invariant 2, separately:

| Field | File | Now | Fix |
| --- | --- | --- | --- |
| `DB_PORT` | `configmap.yaml:17` | `5433` | → `5432`, **or** change the two proxy fields below to `5433` |
| proxy `--port` | `deployment.yaml:43` | `5432` | must match `DB_PORT` |
| proxy `startupProbe` | `deployment.yaml:62` | `5432` | must match `DB_PORT` |

This port is pod-internal loopback only — nothing outside the pod sees it, so `5432` is fine and
there is no collision to avoid. Simplest fix is reverting `DB_PORT` to `5432`.

Invariant 3 — **check this one is what you meant:**

`DB_NAME` is now `recommendations-backend`, which is the *other* service's database. The auth
migration (`db/migrations/00001_init.sql`) targets `auth_service` per
[prerequisites.md §6.2](./prerequisites.md#62-open-the-auth-schema-has-nowhere-to-live-yet). Pointing auth-service at `recommendations-backend` puts the
sessions and users tables inside the recommendations database. If you want one shared database,
that works but migrate there deliberately; if not, revert to `auth_service`.

---

## `kustomization.yaml`

The entry point: `kubectl apply -k k8s/auth-service` reads only this file and follows it.

| Field | Value | Why |
| --- | --- | --- |
| `apiVersion` | `kustomize.config.k8s.io/v1beta1` | Current stable Kustomize schema. Not a Kubernetes API group — this file is never sent to the cluster. |
| `kind` | `Kustomization` | — |
| `namespace` | `auth` | Stamps `auth` onto every resource, which is why the `namespace:` lines in the other files are belt-and-braces rather than required. Keeps a namespace rename to one edit. |
| `resources` | 5 files | Apply order is **not** the list order — Kustomize renders one stream and the API server sorts by kind, so the Namespace is created before things inside it regardless. |
| `labels[].includeSelectors` | `false` | **Load-bearing.** `true` would inject the label pairs into `spec.selector` too. A Deployment's selector is immutable after creation, so a later label change would make every `apply` fail with a field-immutable error. `false` keeps selectors under your control. |
| `labels[].pairs` | `app.kubernetes.io/{name,part-of}` | Standard recommended labels, for `kubectl get -l app.kubernetes.io/part-of=mini-apps` across services. Purely descriptive. |

### Why there is no Secret here

`auth-service-secrets` is created imperatively (`kubectl create secret`,
[deploy.md step 3](./deploy.md)) and deliberately left out of `resources`. A `secretGenerator`
would need the plaintext in the repo. The tradeoff: the Secret is not captured in version
control, so it must be recreated by hand in a new cluster — documented in [deploy.md](./deploy.md) instead.

---

## `namespace.yaml`

| Field | Value | Why |
| --- | --- | --- |
| `apiVersion` | `v1` | Core API group. |
| `kind` | `Namespace` | — |
| `metadata.name` | `auth` | Also the `auth` in the Workload Identity member string `...svc.id.goog[auth/auth-service]`. **Renaming this namespace breaks the IAM binding** — invariant 6. |

---

## `service-account.yml`

Four lines, and one of them is the entire reason the database connection works.

| Field | Value | Why |
| --- | --- | --- |
| `kind` | `ServiceAccount` | The pod's in-cluster identity. |
| `metadata.name` | `auth-service` | Referenced by `deployment.serviceAccountName` and by the GSA's IAM binding. Three places, one string. |
| `annotations."iam.gke.io/gcp-service-account"` | `auth-sql@vincent-mini-apps-project.iam.gserviceaccount.com` | The Workload Identity link. The GKE metadata server reads this annotation and mints tokens for that Google SA instead of the node's. **Note:** Google now documents this as the *alternative* method — the current recommendation is a direct IAM principal reference with no annotation. We keep it because Google's own Cloud SQL-on-GKE example still uses it. See [parameters.md](./parameters.md#workload-identity-federation-for-gke). |

### The binding is bidirectional

The annotation alone does nothing. Two halves:

1. **This annotation** — KSA → "I want to act as `auth-sql`".
2. **`roles/iam.workloadIdentityUser`** on the GSA, member
   `...svc.id.goog[auth/auth-service]` — GSA → "this KSA may act as me".

With only half, the proxy silently gets a **node** identity token and Cloud SQL rejects it — and
the error names the node SA, pointing you at the wrong account entirely. See
[prerequisites.md §4](./prerequisites.md#4-the-workload-identity-chain) and the proxy table in
[troubleshooting](./troubleshooting.md).

> `automountServiceAccountToken` is left at its default (`true`). The app never calls the
> Kubernetes API, so `false` would be marginally tighter — but the GKE metadata path the proxy
> uses is unrelated to that token, so it buys little here.

---

## `configmap.yaml`

Non-secret environment, injected wholesale via `envFrom`. Every key maps to something
`config.Load()` reads.

| Key | Value | Read by | Why |
| --- | --- | --- | --- |
| `APP_ENV` | `production` | `config.go` | Selects which embedded YAML is loaded — `production.yaml`, not `development.yaml`. Also flips `IsProduction()`, which enables the HSTS middleware in `router.go`. Visible in the health response as `"env":"production"`. |
| `PORT` | `9999` | `config.go` | Overrides `server.port` from the embedded YAML (which says `5001`). `config.go` applies `PORT` *last*, so the manifest wins over the baked-in value. ⚠️ invariant 1. |
| `DB_HOST` | `127.0.0.1` | `config.go` | **The sidecar, not Cloud SQL.** Containers in a pod share a network namespace, so loopback reaches the proxy. |
| `DB_PORT` | `5433` | `config.go` | Must equal the proxy's `--port`. ⚠️ invariant 2. |
| `DB_USER` | `postgres` | `config.go` | The instance's built-in superuser. A dedicated least-privilege user is better — see the note in [deploy.md step 2b](./deploy.md). |
| `DB_NAME` | `recommendations-backend` | `config.go` | ⚠️ invariant 3 — likely should be `auth_service`. |
| `DB_SSLMODE` | `disable` | `config.go` | **Correct, and not a weakening.** This hop is loopback inside the pod; the proxy holds the TLS connection to Cloud SQL. Encrypting loopback would add cost and no security. Contrast with [deploy.md step 2c](./deploy.md), where the laptop connects over the public internet and `require` is mandatory. |
| `BASE_URL` | `http://localhost:9999` | `config.go` | The service's own public origin. Placeholder until Phase 2. `config.go` strips a trailing slash, so both forms are safe. |
| `FRONTEND_URL` | `http://localhost:5173` | `config.go`, `main.go` | **Does two jobs:** post-login redirect target *and* the single allowed CORS origin (`main.go` passes it to `cors.Options{AllowedOrigins}` with `AllowCredentials: true`). One wrong value breaks login and every XHR at once. Must be a bare origin — scheme + host + port, no path. |
| `SESSION_TTL` | `12h` | `config.go` | Absolute session lifetime from creation. Go duration string. |
| `SESSION_IDLE_TTL` | `30m` | `config.go` | Idle window, reset on each authenticated request. A session dies at whichever limit comes first. `config.go` **rejects startup** if this exceeds `SESSION_TTL` — a real validation, not a warning. |

### What is deliberately *not* here

`DB_PASSWORD`, `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET`, `ENCRYPTION_KEY` — all in
the Secret. A ConfigMap is plaintext to anyone with namespace read access.

`GOOGLE_OAUTH_REDIRECT_URL` is absent because the current image cannot read it: that value is
compiled in via `//go:embed` and `config.go` has no env override for it. Added in
[Phase 2.1](./phase-2-domain-tls-oauth.md) along with the code change.

### One consequence of `envFrom`

ConfigMap edits do **not** reach a running pod. `envFrom` is resolved once at container start.
After editing, restart explicitly:

```bash
kubectl -n auth rollout restart deploy/auth-service
```

(A `configMapGenerator` with a name suffix hash would make this automatic, at the cost of a
changing resource name on every edit.)

---

## `deployment.yaml`

### Top level

| Field | Value | Why |
| --- | --- | --- |
| `apiVersion` | `apps/v1` | — |
| `metadata.labels.app` | `auth-service` | On the Deployment object itself. Distinct from the pod template labels below — only the template ones drive the Service. |
| `spec.replicas` | `1` | One `e2-medium` node, ~940m allocatable CPU. The old skeleton's `replicaCount: 4` could never have scheduled. |
| `spec.selector.matchLabels` | `app: auth-service` | Which pods this Deployment owns. **Immutable after creation** — the reason `includeSelectors: false` matters in `kustomization.yaml`. |
| `strategy.type` | `RollingUpdate` | Default; stated explicitly since the two knobs below only apply to it. |
| `maxUnavailable` | `0` | Never drop below the desired count — no downtime window during a rollout. |
| `maxSurge` | `1` | One extra pod allowed. With `replicas: 1` this means new-up-then-old-down. **On a single node this needs headroom for two pods at once**; if a rollout sticks at `Pending`, this is why. |
| `template.metadata.labels` | `app: auth-service` | Must match both `spec.selector` and the Service's selector — invariant 5. |

### Pod-level `spec`

| Field | Value | Why |
| --- | --- | --- |
| `serviceAccountName` | `auth-service` | Binds the pod to the KSA carrying the Workload Identity annotation. Omit and you get `default`, which has no annotation — the proxy then fails with a node-identity error. |
| `securityContext.runAsNonRoot` | `true` | Pod-level, so it covers **both** containers. The kubelet refuses to start a container whose image resolves to UID 0. |
| `securityContext.seccompProfile.type` | `RuntimeDefault` | Applies the container runtime's default syscall filter. Cheap hardening; required by the restricted Pod Security Standard. |

### `initContainers[0]` — `cloud-sql-proxy`

> **Why an initContainer and not a normal container.** `main.go` calls `db.Connect`, which
> `Ping`s, and `log.Fatalf`s on failure. Ordinary containers in a pod start **in parallel** — so
> the app can win the race, ping a port nothing is listening on, and die. You get a
> CrashLoopBackOff that self-heals after enough restarts: intermittent, and misleading.
>
> An initContainer with `restartPolicy: Always` is a **native sidecar** (stable since Kubernetes
> v1.33; this cluster is 1.36). It runs to *started* before the app container begins, and keeps running
> for the pod's life. Startup order becomes a guarantee instead of luck.

| Field | Value | Why |
| --- | --- | --- |
| `name` | `cloud-sql-proxy` | Needed for `kubectl logs -c cloud-sql-proxy` — the proxy's logs are where DB failures are actually diagnosable. |
| `image` | `...cloud-sql-proxy:2.14.1` | v2 line. Pinned minor, not `:latest`, so a node restart can't silently change behaviour. |
| `restartPolicy` | `Always` | **The field that makes this a sidecar.** Without it the container must exit for startup to proceed — and a proxy never exits, so the pod would hang in `Init` forever. |
| `args[0]` | `--structured-logs` | JSON logs, so Cloud Logging parses severity instead of showing one opaque text blob. |
| `args[1]` | `--port=5432` | Loopback port the proxy listens on. Must equal `DB_PORT` — invariant 2. |
| `args[2]` | `vincent-mini-apps-project:asia-southeast1:recommendations-app-instance` | Instance connection name (`project:region:instance`) — **not** a hostname. The proxy resolves it through the Cloud SQL Admin API, which is why `sqladmin.googleapis.com` must be enabled. |
| *(no `--credentials-file`)* | — | Workload Identity supplies the token. A key file here would defeat the point of enabling WI. |
| `securityContext` | non-root, no priv-esc, read-only FS, all caps dropped | The proxy needs no filesystem writes and no capabilities. |
| `resources.requests` | `50m` / `64Mi` | What the scheduler reserves. The proxy is a thin TCP relay. |
| `resources.limits` | `200m` / `128Mi` | Memory limit is a hard kill (OOMKill); CPU limit only throttles. |
| `startupProbe.tcpSocket.port` | `5432` | Belt-and-braces on top of the native-sidecar guarantee: "started" means the process began, not that it is accepting connections. This makes it mean *listening*. Must match `--port`. |
| `startupProbe.periodSeconds/failureThreshold` | `2` / `30` | Up to 60s for the proxy to reach Cloud SQL. Generous because the first connection does API discovery and certificate minting. |

### `containers[0]` — `auth-service`

| Field | Value | Why |
| --- | --- | --- |
| `name` | `auth-service` | — |
| `image` | `...auth-service:0.0.1@sha256:2e3283ac…` | **Tag *and* digest.** The digest is what actually resolves; the tag is documentation for humans reading the diff. A tag can be moved, and a moved tag makes `kubectl rollout undo` meaningless. |
| `imagePullPolicy` | `IfNotPresent` | Correct *because* of the digest pin — a digest cannot change meaning, so re-pulling buys nothing. Use `Always` only with mutable tags. |
| `ports[].name` | `http` | Named so the Service and all three probes can reference `http` instead of repeating a number. Changing the port becomes a one-line edit. |
| `ports[].containerPort` | `9999` | Must equal `PORT` (invariant 1) — and does. Note this field is **informational**; it does not restrict what the process binds, which is why a mismatch here shows up as a failing probe rather than a bind error. |
| `envFrom[0].configMapRef` | `auth-service-config` | Imports all ConfigMap keys as env vars. |
| `envFrom[1].secretRef` | `auth-service-secrets` | Same for the Secret. **Must exist before the pod starts** — a missing Secret here leaves the pod in `CreateContainerConfigError`, not a crash loop. |
| `securityContext` — no `runAsUser` | *(unset)* | **Deliberate.** The distroless `:nonroot` tag already sets numeric UID 65532, and the *numeric* form is what lets Kubernetes verify `runAsNonRoot`. Restating it as a name breaks the check — the Dockerfile says so too. |
| `securityContext.readOnlyRootFilesystem` | `true` | Safe here: `main.go` logs to stderr via stdlib `log`, and the `logger.file_name` in `production.yaml` is vestigial — no logrus writer is wired up. If this ever bites, add an `emptyDir` rather than dropping the setting ([troubleshooting](./troubleshooting.md)). |
| `resources.requests` | `100m` / `128Mi` | Scheduling floor. Keep requests + the proxy's well under node allocatable, or the pod sits `Pending`. |
| `resources.limits` | `500m` / `256Mi` | Go's GC targets available memory; 256Mi is comfortable for this service but worth watching under load. |

### The three probes

All hit `GET /api/v1/health`. That endpoint is a deliberate choice twice over: `csrf.go` exempts
safe methods, so no token is needed, and `health.go` **deliberately does not touch the
database** — a liveness probe that failed on one slow query would evict a healthy pod.

| Probe | Settings | Role |
| --- | --- | --- |
| `startupProbe` | `period 3`, `failureThreshold 20` | Up to 60s to boot. **While it runs, liveness is suspended** — which is the point: without it, a slow start looks like a liveness failure and the pod is killed mid-boot, forever. |
| `readinessProbe` | `period 10`, `timeout 3`, `failures 3` | Gates **traffic**. Failing removes the pod from Service endpoints but does not restart it. GKE Ingress also derives its backend health check from this probe in Phase 2. |
| `livenessProbe` | `period 20`, `timeout 3`, `failures 3` | Gates **life**. Failing restarts the container. Interval is deliberately looser than readiness: restarting is the more destructive response, so it should be slower to trigger. |

> Startup failure here is mostly moot in practice — `config.Load()` and `db.Connect()` both
> `log.Fatalf`, so a misconfigured app exits rather than lingering unhealthy. The probes catch
> the *later* cases: a wedged process, or a port mismatch like invariant 1.

---

## `service.yaml`

| Field | Value | Why |
| --- | --- | --- |
| `kind` | `Service` | Stable virtual IP + DNS name in front of the pods. |
| `metadata.name` | `auth-service` | Gives in-cluster DNS `auth-service.auth.svc.cluster.local`. |
| `spec.type` | `LoadBalancer` | **Phase 1 only.** Provisions a GCP network load balancer with a public IP — enough to `curl` health. Phase 2 switches to `NodePort` behind a GKE Ingress, because Google OAuth needs a real hostname and TLS. Leaving it as `LoadBalancer` then would provision a second, billed, redundant load balancer. |
| `spec.selector` | `app: auth-service` | Matches the **pod template** labels, not the Deployment's own. Mismatch = a Service with zero endpoints and no error anywhere — invariant 5. |
| `ports[].name` | `http` | Named so the Phase 2 Ingress can reference `port.name: http`. |
| `ports[].port` | `80` | The port on the load balancer. |
| `ports[].targetPort` | `http` | The **container's port name**, not a number — so it follows `containerPort` automatically. This is why invariant 1 surfaces as a failing probe rather than a broken Service. |
| `protocol` | `TCP` | Default; explicit for symmetry. |

> No `sessionAffinity`. Sessions live in Postgres and are looked up per request, so any pod can
> serve any user — the app is already stateless in the way that matters. Nothing to configure.

---

## Verifying the invariants

A rendered-manifest check catches invariants 1, 2 and 4 before you apply anything:

```bash
cd cloud-infrastructure
kubectl kustomize k8s/auth-service | grep -E 'PORT|containerPort|DB_PORT|--port|targetPort|DB_NAME'
```

Read the output as pairs: `PORT` must equal `containerPort`, and `DB_PORT` must equal the
proxy's `--port`. Then:

```bash
# invariant 5 — the real test is whether endpoints exist after applying
kubectl -n auth get endpoints auth-service
# want an IP:port. "<none>" means the selector matches no ready pod.

# invariant 6 — which identity the pod actually gets
kubectl -n auth run wi-test --rm -it --restart=Never \
  --image=google/cloud-sdk:slim \
  --overrides='{"spec":{"serviceAccountName":"auth-service"}}' \
  -- gcloud auth list
# want auth-sql@vincent-mini-apps-project.iam.gserviceaccount.com
```
