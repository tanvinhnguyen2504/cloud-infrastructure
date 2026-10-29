# Deploying `auth-service` — step by step

One linear path from an empty cluster to a pod serving `GET /api/v1/health` over a public IP.

Steps 1 and 3 are **one-time setup and already done** — they are kept here so the path is
complete and reproducible, each reduced to its verify command. Steps 2, 4 and 5 are what you
actually run.

**Prerequisites and every parameter:** [prerequisites.md](./prerequisites.md).
**When something breaks:** [troubleshooting.md](./troubleshooting.md).

| | |
| --- | --- |
| **Goal** | `2/2 Running`, `database connected`, health 200 on `34.87.12.86` |
| **Time** | ~10 min from here (step 2 is most of it) |
| **Image** | the published `0.0.1` — no rebuild in this phase |
| **Destructive** | no, as long as you skip step 1 (it recreates the node pool) |

> ### Why login does not work yet, and why that is fine
> The `0.0.1` image has the OAuth callback URL compiled in as `http://localhost:9999/...` —
> `production.yaml` is loaded via `//go:embed`, and `config.go` overrides `BASE_URL` and
> `FRONTEND_URL` from the environment but **not** the redirect URL. So login needs a code change
> and a rebuild.
>
> Health and database connectivity do not. `config.Load()` only checks that the redirect value
> is non-empty, and it is never consulted until a callback actually arrives. Splitting here
> means this deploy validates Workload Identity, the Cloud SQL proxy, secrets, probes and
> networking against an image you already have — so when login is the only thing left, login is
> the only thing that can be wrong. That is
> [Phase 2](./phase-2-domain-tls-oauth.md).

---

## Step 0 — Preflight

Never skip this. `kubectl`'s token comes from the **active gcloud configuration**, so a context
pointing at `vincent-cluster` is not sufficient on its own.

```bash
kubectl config current-context    # gke_vincent-mini-apps-project_asia-southeast1-a_vincent-cluster
gcloud config get account         # vinhnguyentan99@gmail.com
kubectl get nodes                 # one Ready node
```

If `kubectl` returns `Forbidden`, the account is wrong — not the context. See
[troubleshooting.md](./troubleshooting.md).

---

## Step 1 — One-time GCP setup ✅ done, do not re-run

<details>
<summary>Verify (fast) — expand for the original commands</summary>

**Verify all four Workload Identity links plus the APIs:**

```bash
P=vincent-mini-apps-project
GSA="auth-sql@${P}.iam.gserviceaccount.com"

gcloud services list --enabled | grep -E 'sqladmin|iamcredentials'
gcloud container clusters describe vincent-cluster --zone asia-southeast1-a \
  --format='value(workloadIdentityConfig.workloadPool)'          # => ...svc.id.goog
gcloud container node-pools describe minimal-pool --cluster vincent-cluster \
  --zone asia-southeast1-a --format='value(config.workloadMetadataConfig.mode)'  # => GKE_METADATA
gcloud iam service-accounts get-iam-policy "$GSA" --format=json | grep workloadIdentityUser
```

All four must pass. If any is empty, the pod will come up with the **node's** identity and Cloud
SQL will reject it, naming the wrong service account in the error.

**The original commands**, for rebuilding this project from scratch only:

```bash
gcloud services enable sqladmin.googleapis.com iamcredentials.googleapis.com

# identity pool on the cluster (non-destructive, ~2 min)
gcloud container clusters update vincent-cluster --zone asia-southeast1-a \
  --workload-pool=vincent-mini-apps-project.svc.id.goog

# ⚠️ RECREATES THE NODES (~5 min)
gcloud container node-pools update minimal-pool --cluster vincent-cluster \
  --zone asia-southeast1-a --workload-metadata=GKE_METADATA

P=vincent-mini-apps-project
GSA="auth-sql@${P}.iam.gserviceaccount.com"

gcloud iam service-accounts create auth-sql \
  --display-name="auth-service Cloud SQL client"

# GSA -> Cloud SQL: the identity may connect
gcloud projects add-iam-policy-binding "$P" \
  --member="serviceAccount:${GSA}" --role="roles/cloudsql.client"

# KSA -> GSA: the pod may act as that identity.
# "auth" is the namespace, "auth-service" the KSA — both from k8s/auth-service/.
gcloud iam service-accounts add-iam-policy-binding "$GSA" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${P}.svc.id.goog[auth/auth-service]"
```

Both bindings point in **opposite directions** and this is the part that is easy to
half-finish. Missing the second one is silent: the proxy falls back to the node identity rather
than erroring at startup.

</details>

---

## Step 2 — Database and migration ❌ the one open step

Decide first, then run one column. The full reasoning is in
[prerequisites.md §6.2](./prerequisites.md#62-open-the-auth-schema-has-nowhere-to-live-yet);
the short version is that `DB_NAME` currently says `recommendations-backend`, no `auth_service`
database exists, and the auth migration targets `auth_service`. The health probe cannot detect
the mismatch — the pod goes green and then fails on the first request that touches `users` or
`sessions`.

### 2a. Confirm what exists

```bash
gcloud sql databases list --instance=recommendations-app-instance
# today: postgres, recommendations-backend   <- no auth_service
```

### Option B — separate database (recommended)

Matches what the Go repo expects, and keeps the two services' schemas apart.

```bash
gcloud sql databases create auth_service --instance=recommendations-app-instance
```

Then set `DB_NAME` in `k8s/auth-service/configmap.yaml`:

```yaml
DB_NAME: "auth_service"
```

### Option A — share `recommendations-backend`

Change nothing in the ConfigMap; migrate into the existing database. Auth tables land alongside
the recommendations tables.

### 2b. Make sure you know the password

The manifests authenticate as `postgres`. You need that password for both the migration and the
Secret.

```bash
gcloud sql users set-password postgres \
  --instance=recommendations-app-instance --prompt-for-password
```

> This rotates the password for **every** app on the instance, `recommendations-backend`
> included. If that service is live, create a dedicated user instead — cleaner regardless, and
> least privilege per service:
> ```bash
> gcloud sql users create auth_app \
>   --instance=recommendations-app-instance --prompt-for-password
> ```
> then set `DB_USER: "auth_app"` in `configmap.yaml`, grant it rights on the auth database, and
> update `DB_PASSWORD` in the Secret (step 3).

### 2c. Run the migration

`make migrate` already exists in `auth-be` and runs `db/migrations/00001_init.sql` through goose.
Your home IP is in the instance's authorized networks, so point it at the public IP directly —
no proxy needed from the laptop.

```bash
cd ../auth-be
cp .env .env.local.bak            # keep your local settings

# Note sslmode=require: unlike the in-pod hop, this one crosses the public internet.
# DB_NAME must match whichever option you chose above.
cat >> .env <<'ENVEOF'
DB_HOST=34.142.199.254
DB_PORT=5432
DB_NAME=auth_service
DB_USER=postgres
DB_SSLMODE=require
ENVEOF

make migrate
make migrate-status               # 00001_init.sql must read as applied

mv .env.local.bak .env            # restore local env
cd ../cloud-infrastructure
```

**Verify the tables are really there**, because this is the whole point of the step:

```bash
# from the laptop, over the public IP
psql "host=34.142.199.254 dbname=auth_service user=postgres sslmode=require" -c '\dt'
# want: users, sessions, goose_db_version
```

---

## Step 3 — Secret ✅ done

```bash
kubectl -n auth get secret auth-service-secrets \
  -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'
# DB_PASSWORD / ENCRYPTION_KEY / GOOGLE_OAUTH_CLIENT_ID / GOOGLE_OAUTH_CLIENT_SECRET
```

All four must be listed. `config.Load()` errors on any empty one and `main.go` turns that into
`log.Fatalf`, so a missing value is a CrashLoopBackOff. A missing *Secret* is
`CreateContainerConfigError` instead — a different symptom for a nearby cause.

<details>
<summary>Expand: creating it from scratch, and the ENCRYPTION_KEY rules</summary>

```bash
kubectl apply -f k8s/auth-service/namespace.yaml

kubectl -n auth create secret generic auth-service-secrets \
  --from-literal=DB_PASSWORD='<the postgres password from step 2b>' \
  --from-literal=GOOGLE_OAUTH_CLIENT_ID='<from GCP console>' \
  --from-literal=GOOGLE_OAUTH_CLIENT_SECRET='<from GCP console>' \
  --from-literal=ENCRYPTION_KEY="$(openssl rand -base64 32)"
```

- `ENCRYPTION_KEY` must decode to **exactly 32 bytes** — `secret.go` rejects anything else.
  That is the AES-256 key length, not a preference. `openssl rand -base64 32` is exact.
- It seals live session cookies. **Changing it logs every user out**, and there is no fallback
  key reader in the code. Store it in a password manager the moment you generate it.

To rotate `DB_PASSWORD` later, replace and restart — editing a Secret does not roll the pod:

```bash
kubectl -n auth create secret generic auth-service-secrets \
  --from-literal=... --dry-run=client -o yaml | kubectl apply -f -
kubectl -n auth rollout restart deploy/auth-service
```

The Secret is deliberately absent from `kustomization.yaml` so no credential enters this repo.

</details>

---

## Step 4 — Apply

```bash
# dry read: see exactly what will be sent
kubectl kustomize k8s/auth-service

# sanity-check the invariants in that output before sending it
kubectl kustomize k8s/auth-service | grep -E 'containerPort|targetPort|PORT:|maxUnavailable'
# want: PORT: "9999" / containerPort: 9999 / targetPort: http / maxUnavailable: 1

kubectl apply -k k8s/auth-service
kubectl -n auth rollout status deploy/auth-service --timeout=5m
```

### If you changed only `configmap.yaml`

There is no `configMapGenerator`, so the ConfigMap has no name hash and editing it does **not**
roll the Deployment — the running pod keeps the old environment. This is required:

```bash
kubectl -n auth rollout restart deploy/auth-service
```

### What gets applied

| File | Role |
| --- | --- |
| `namespace.yaml` | namespace `auth` |
| `service-account.yml` | KSA `auth-service`, annotated with the `auth-sql` GSA — the Workload Identity link |
| `configmap.yaml` | non-secret env: `APP_ENV`, `PORT=9999`, `DB_*`, URLs, session TTLs |
| `deployment.yaml` | app container + `cloud-sql-proxy` **native sidecar** |
| `service.yaml` | `LoadBalancer` :80 → :9999 (by port name `http`) |

Four parameters in `deployment.yaml` each prevent a specific, already-observed failure:

1. **The proxy is a native sidecar** (`initContainers` + `restartPolicy: Always`). The app pings
   the DB at boot and `log.Fatalf`s on failure; an ordinary sidecar starts *in parallel*, so the
   app can lose the race and crashloop against a port nothing is listening on yet.
2. **The proxy's startup probe is `httpGet /startup` on 9090**, not `tcpSocket` on 5432.
   Kubelet probes from outside the pod's network namespace and dials the pod IP, while the DB
   tunnel binds `127.0.0.1` only — a tcpSocket probe there can *never* pass. It killed this
   container every 60 seconds.
3. **`maxUnavailable: 1` / `maxSurge: 0`.** Two copies of this pod do not fit on one
   `e2-medium`; the usual `0`/`1` pair deadlocks the rollout with the new pod `Pending` on
   `Insufficient cpu`.
4. **`runAsUser` is deliberately unset.** The distroless `:nonroot` base already sets numeric
   UID 65532, and that numeric form is what lets Kubernetes verify `runAsNonRoot`.

<details>
<summary>Coming from the stalled rollout? Expand.</summary>

If `kubectl -n auth get pods` shows **two** pods — one `Init:CrashLoopBackOff` and one
`Pending` — you are looking at the deadlock that `maxUnavailable: 1` fixes. The crashlooping pod
belongs to an **old ReplicaSet** and still carries the old `tcpSocket` probe, so
`kubectl describe pod` on it shows a spec that no longer exists in the repo. Confirm which
generation is which before believing any describe output:

```bash
kubectl -n auth get rs \
  -o custom-columns='NAME:.metadata.name,REV:.metadata.annotations.deployment\.kubernetes\.io/revision,DESIRED:.spec.replicas,READY:.status.readyReplicas'
```

`kubectl apply -k k8s/auth-service` with the current manifest resolves it on its own: the
strategy change lets the Deployment controller scale the old ReplicaSet to 0, which frees the
150m of CPU the new pod is waiting for. No `rollout restart` needed — the pod template itself
changed, so a new rollout triggers automatically.

</details>

---

## Step 5 — Verify, in layers

Each command isolates a different layer. Run them in order; the first failure tells you where
to look.

```bash
# 1. the sidecar got past its probe
kubectl -n auth get pods -l app=auth-service
# want: 2/2 Running, 0 restarts.  Init:* means the proxy has not passed startup yet.
```

```bash
# 2. the proxy authenticated and connected
kubectl -n auth logs deploy/auth-service -c cloud-sql-proxy --tail=20
# want: "Authorizing with Application Default Credentials"
#       "Listening on 127.0.0.1:5432"
#       "The proxy has started successfully and is ready for new connections!"
```

If you see those three lines **followed by** `SIGTERM signal received`, the proxy is healthy and
its *probe* is what is failing — check `--health-check`, `--http-address=0.0.0.0` and
`--http-port=9090` against the probe's port. Exit code 143 is 128 + 15, i.e. SIGTERM, not a
crash.

```bash
# 3. the app connected and is serving
kubectl -n auth logs deploy/auth-service -c auth-service
# want: "database connected (127.0.0.1:5432/<DB_NAME>)"
#       "listening on :9999"
```

Both lines sit immediately after code that `log.Fatalf`s on failure, which is what makes them a
real success signal rather than a hopeful one. `127.0.0.1` is correct — the app talks to the
sidecar, which holds the TLS connection to Cloud SQL.

```bash
# 4. the Service actually selected the pod
kubectl -n auth get endpointslice -l kubernetes.io/service-name=auth-service \
  -o jsonpath='{.items[*].endpoints[*].addresses}{"\n"}'
# want an IP. Empty means the selector matches no *ready* pod (invariants 4 and 5).
```

```bash
# 5. end to end
IP=$(kubectl -n auth get svc auth-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s "http://$IP/api/v1/health"
# => {"ok":true,"env":"production"}
```

`env:"production"` confirms `APP_ENV` selected the embedded `production.yaml` rather than the
development default.

```bash
# 6. the identity the pod actually got — not the one you configured
kubectl -n auth exec deploy/auth-service -c cloud-sql-proxy -- \
  curl -s -H 'Metadata-Flavor: Google' \
  'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email'
# want auth-sql@vincent-mini-apps-project.iam.gserviceaccount.com,
# NOT  225614846438-compute@developer.gserviceaccount.com
```

> **Step 5 does not prove the schema exists.** The health handler deliberately does not touch
> the database, so a green `/api/v1/health` is compatible with a completely empty schema. If you
> skipped step 2, this is where that decision stays hidden. Exercise one real endpoint, or check
> `\dt` directly.

---

## Routine redeploy

Once the above is green, day-to-day changes are:

```bash
# manifest change
kubectl apply -k k8s/auth-service
kubectl -n auth rollout status deploy/auth-service

# ConfigMap-only change — the restart is REQUIRED, see step 4
kubectl apply -k k8s/auth-service
kubectl -n auth rollout restart deploy/auth-service
kubectl -n auth rollout status deploy/auth-service

# no change, just bounce it
kubectl -n auth rollout restart deploy/auth-service
```

### Shipping a new image

```bash
cd ../auth-be && make image-push TAG=0.0.2
```

Then get the digest and pin **both** tag and digest in `deployment.yaml`, because
`imagePullPolicy: IfNotPresent` is only safe while the reference is immutable:

```bash
gcloud artifacts docker images describe \
  asia-southeast1-docker.pkg.dev/vincent-mini-apps-project/auth-repository/auth-service:0.0.2 \
  --format='value(image_summary.digest)'
```

```yaml
image: asia-southeast1-docker.pkg.dev/.../auth-service:0.0.2@sha256:<digest>
```

### Rolling back

```bash
kubectl -n auth rollout history deploy/auth-service
kubectl -n auth rollout undo deploy/auth-service
```

This works *because* images are digest-pinned. With a floating tag, an undo would re-pull
whatever that tag points at today and mean nothing.

---

## Exit checklist

- [ ] `DB_NAME` names a database the auth migration has actually been applied to
- [ ] Secret has all four keys; `ENCRYPTION_KEY` stored outside the cluster
- [ ] Exactly **one** pod, `2/2 Running`, `0` restarts
- [ ] Proxy logs show `ready for new connections`, with no `SIGTERM` after it
- [ ] App logs show `database connected` and `listening on :9999`
- [ ] EndpointSlice for `auth-service` is non-empty
- [ ] `curl http://$IP/api/v1/health` → `{"ok":true,"env":"production"}`
- [ ] Pod identity is `auth-sql@…`, not the compute default
- [ ] One real database-touching endpoint exercised

Something failed → [troubleshooting.md](./troubleshooting.md), organised by the error in front
of you.

→ Next: [Phase 2 — domain, TLS, working Google login](./phase-2-domain-tls-oauth.md). Needs a
domain name from you, a code change, and a `0.0.2` image.
