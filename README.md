# cloud-infrastructure

Kubernetes manifests and deployment runbooks for the `my-mini-apps` services on GKE.

Covers two services:

| Service | Source | Namespace | Manifests | Docs | State |
| --- | --- | --- | --- | --- | --- |
| **`auth-service`** | `../auth-be` | `auth` | `k8s/auth-service/` | [docs/](docs/auth-service/prerequisites.md) | deployed, `2/2 Running` on `34.87.12.86` |
| **`recommendations-service`** | `../recommendations-be` | `recommendations` | `k8s/recommendations-service/` | [docs/recommendations-service/](docs/recommendations-service/prerequisites.md) | **not deployed** — blocked on node CPU, see below |

---

## `recommendations-service` — start here

| Document | What it is for |
| --- | --- |
| **[prerequisites.md](docs/recommendations-service/prerequisites.md)** | Everything that must be true before an apply, **and every parameter** with its verified live value and the command that checks it. §7 is the field-by-field manifest rationale. Start here. |
| **[deploy.md](docs/recommendations-service/deploy.md)** | The linear step-by-step deploy — node resize, Artifact Registry, Workload Identity, image build, Secret, apply, layered verification — plus redeploy / new-image / rollback. |
| [troubleshooting.md](docs/recommendations-service/troubleshooting.md) | Organised by the error you are actually looking at. |

Nothing is pre-done for this service: no GSA, no registry repo, no image, no Secret. And one hard
blocker comes first — the single `e2-medium` node has **89m CPU free** and the pod requests
**150m**, so it cannot be scheduled until the node pool grows
([prerequisites.md §3.2](docs/recommendations-service/prerequisites.md#32-blocker-the-node-has-no-room-for-this-pod)).

Two things about this service surprise people:

- It needs `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET` and `ENCRYPTION_KEY` in its
  Secret despite registering **no auth routes** — `config.Load()` validates them before anything
  checks whether they are used.
- A green `/api/v1/health` does **not** mean the database works. The handler never touches the
  pool, and `recommendations-be` ships no migrations, so `GET /api/v1/places` is the only real
  test.

---

## `auth-service` docs

| Document | What it is for |
| --- | --- |
| **[prerequisites.md](docs/auth-service/prerequisites.md)** | Everything that must be true before an apply, **and every parameter** — each with its verified live value and the one command that checks it. Start here. |
| **[deploy.md](docs/auth-service/deploy.md)** | The linear step-by-step deploy, plus the routine redeploy / new-image / rollback paths. |
| [phase-2-domain-tls-oauth.md](docs/auth-service/phase-2-domain-tls-oauth.md) | HTTPS on a real hostname and working Google login. Needs **a domain name**, a code change, and a `0.0.2` image. |
| [troubleshooting.md](docs/auth-service/troubleshooting.md) | Organised by the error you are actually looking at. |
| [manifest-reference.md](docs/auth-service/manifest-reference.md) | Field-by-field rationale for `k8s/auth-service/`. |
| [parameters.md](docs/auth-service/parameters.md) | Every parameter linked to the upstream Kubernetes or Google Cloud doc that defines it. |
| [phase-1-fix-blockers.md](docs/auth-service/phase-1-fix-blockers.md) | **Closed** incident record for the stalled first rollout. Not an action list — it is why the probe, port and rollout-strategy parameters are what they are. |

### Current state — 2026-10-29

One-time GCP setup (Workload Identity, the `auth-sql` GSA and both IAM bindings) and the
Kubernetes Secret are **done and verified**. One prerequisite is still open: confirming the auth
schema exists in the database `DB_NAME` points at — see
[prerequisites.md §6.2](docs/auth-service/prerequisites.md#62-open-the-auth-schema-has-nowhere-to-live-yet).
Then `kubectl apply -k k8s/auth-service`.

### Why login comes after a working pod, not with it

The published `0.0.1` image has the OAuth callback URL **compiled in** as
`http://localhost:9999/...` — `production.yaml` is loaded via `//go:embed`, and `config.go`
overrides `BASE_URL` and `FRONTEND_URL` from the environment but not the redirect URL. So login
needs a code change plus a rebuild.

Health and database connectivity don't. Splitting there means the first deploy validates Workload
Identity, the Cloud SQL proxy, secrets, probes and networking against an image you already
have — so when login is the only thing left, login is the only thing that can be wrong.

---

## Target environment

| | |
| --- | --- |
| Project | `vincent-mini-apps-project` (gcloud configuration **`personal`**) |
| Cluster | `vincent-cluster`, zonal `asia-southeast1-a` |
| Node pool | `minimal-pool` — 1× `e2-medium`, **spot**, no taints |
| Cloud SQL | `recommendations-app-instance`, POSTGRES_18, public IP `34.142.199.254` |
| Connection name | `vincent-mini-apps-project:asia-southeast1:recommendations-app-instance` |
| Database | `recommendations-backend` (per `configmap.yaml`) — shared with the recommendations app. No `auth_service` database exists; see [prerequisites.md §6.2](docs/auth-service/prerequisites.md#62-open-the-auth-schema-has-nowhere-to-live-yet) |
| Registry | `asia-southeast1-docker.pkg.dev/vincent-mini-apps-project/auth-repository/auth-service` |

---

## Layout

```
k8s/
  auth-service/
    kustomization.yaml   entry point: kubectl apply -k k8s/auth-service
    namespace.yaml       namespace "auth"
    service-account.yml  KSA + Workload Identity annotation (auth-sql GSA)
    configmap.yaml       non-secret env (APP_ENV, PORT=9999, DB_*, URLs, TTLs)
    deployment.yaml      app container + cloud-sql-proxy native sidecar
    service.yaml         LoadBalancer :80 -> :9999  (Phase 2: NodePort + Ingress)
  recommendations-service/
    ... same six files, namespace "recommendations", PORT=9998,
        recommendations-sql GSA
docs/
  auth-service/          prerequisites + deploy + troubleshooting + references
  recommendations-service/
                         prerequisites + deploy + troubleshooting
```

One folder per service under both `k8s/` and `docs/`, with the same file names in each — so a
path tells you the service and the role, and neither tree needs a prefix convention to stay
readable as services are added.

Plain YAML + Kustomize, not Helm. Two services that share a cluster but no templating still
don't justify it, and the indirection would obscure exactly the details that matter while this
is being brought up — the duplication between the two `deployment.yaml` files is the thing to
watch, and the signal to revisit. At that point the `infra-root/` + `app-root/` Helm and Argo CD
shape sketched out earlier becomes the right answer.

### Secrets are not in this repo

`auth-service-secrets` (`DB_PASSWORD`, `GOOGLE_OAUTH_CLIENT_ID`,
`GOOGLE_OAUTH_CLIENT_SECRET`, `ENCRYPTION_KEY`) is created imperatively with
`kubectl create secret` in [deploy.md step 3](docs/auth-service/deploy.md) and is deliberately absent from
`kustomization.yaml`.

**`ENCRYPTION_KEY` seals live session cookies — store it in a password manager the moment you
generate it.** Changing it logs every user out, and nothing in the code reads a fallback key.

---

## Quick reference

```bash
# PREFLIGHT -- always, before any apply. kubectl's token comes from the ACTIVE
# gcloud configuration, so a context pointing at vincent-cluster is not
# sufficient on its own.
kubectl config current-context    # ...vincent-cluster
gcloud config get account         # vinhnguyentan99@gmail.com
kubectl get nodes                 # one Ready node

# deploy / update
kubectl apply -k k8s/auth-service
kubectl -n auth rollout status deploy/auth-service

# is it healthy
kubectl -n auth get pods                                    # want 2/2 Running
kubectl -n auth logs deploy/auth-service -c auth-service    # want "database connected" + "listening on :9999"

# reach it
IP=$(kubectl -n auth get svc auth-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s "http://$IP/api/v1/health"                          # {"ok":true,"env":"production"}

# ship a new image
cd ../auth-be && make image-push TAG=0.0.2
```

---

## Known tradeoffs

- **Single spot node, `replicas: 1`.** Preemption is a full outage. Fine for staging; add a
  second node or a non-spot pool before anything depends on it.
- **The node is nearly full: ~701m of 940m allocatable CPU goes to GKE system pods**, leaving
  ~89m spare once this pod lands. Nothing else will schedule, and a rollout cannot run two
  copies — which is why `maxUnavailable: 1` / `maxSurge: 0` is mandatory here, not a preference.
  `e2-standard-2` ends this class of problem; see
  [prerequisites.md §3.2](docs/auth-service/prerequisites.md#32-cpu-budget--the-binding-constraint).
- **Cloud SQL instance is shared** with `recommendations-backend`. Fine at this scale, worth
  knowing when you read the instance's metrics.
- **No CI.** Deploys are manual `kubectl apply`. Natural next step once Phase 2 is green.
- **`infra-root/`, `app-root/` and `auth-service/` are leftover empty scaffolding** and should
  be deleted — every template file in them is 0 bytes, and the one file with content
  (`infra-root/values.yaml`) describes the wrong project, wrong region, and a private Cloud SQL
  IP that doesn't exist. Superseded by `k8s/`.
