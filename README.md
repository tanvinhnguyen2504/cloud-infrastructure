# cloud-infrastructure

Kubernetes manifests and deployment runbooks for the `my-mini-apps` services on GKE.

Currently covers **`auth-service`** (source: `../auth-be`).

---

## Docs

| Document | What it is for |
| --- | --- |
| **[prerequisites.md](docs/prerequisites.md)** | Everything that must be true before an apply, **and every parameter** — each with its verified live value and the one command that checks it. Start here. |
| **[deploy.md](docs/deploy.md)** | The linear step-by-step deploy, plus the routine redeploy / new-image / rollback paths. |
| [phase-2-domain-tls-oauth.md](docs/phase-2-domain-tls-oauth.md) | HTTPS on a real hostname and working Google login. Needs **a domain name**, a code change, and a `0.0.2` image. |
| [troubleshooting.md](docs/troubleshooting.md) | Organised by the error you are actually looking at. |
| [manifest-reference.md](docs/manifest-reference.md) | Field-by-field rationale for `k8s/auth-service/`. |
| [parameters.md](docs/parameters.md) | Every parameter linked to the upstream Kubernetes or Google Cloud doc that defines it. |
| [phase-1-fix-blockers.md](docs/phase-1-fix-blockers.md) | **Closed** incident record for the stalled first rollout. Not an action list — it is why the probe, port and rollout-strategy parameters are what they are. |

### Current state — 2026-10-29

One-time GCP setup (Workload Identity, the `auth-sql` GSA and both IAM bindings) and the
Kubernetes Secret are **done and verified**. One prerequisite is still open: confirming the auth
schema exists in the database `DB_NAME` points at — see
[prerequisites.md §6.2](docs/prerequisites.md#62-open-the-auth-schema-has-nowhere-to-live-yet).
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
| Database | `recommendations-backend` (per `configmap.yaml`) — shared with the recommendations app. No `auth_service` database exists; see [prerequisites.md §6.2](docs/prerequisites.md#62-open-the-auth-schema-has-nowhere-to-live-yet) |
| Registry | `asia-southeast1-docker.pkg.dev/vincent-mini-apps-project/auth-repository/auth-service` |

---

## Layout

```
k8s/auth-service/
  kustomization.yaml     entry point: kubectl apply -k k8s/auth-service
  namespace.yaml         namespace "auth"
  service-account.yml    KSA + Workload Identity annotation
  configmap.yaml         non-secret env (APP_ENV, PORT, DB_*, URLs, TTLs)
  deployment.yaml        app container + cloud-sql-proxy native sidecar
  service.yaml           LoadBalancer :80 -> :9999  (Phase 2: NodePort + Ingress)
docs/                    prerequisites.md + deploy.md + references + troubleshooting
```

Plain YAML + Kustomize, not Helm. One service doesn't justify templating, and the indirection
would obscure exactly the details that matter while this is still being brought up. Revisit when
the second and third services land — at which point the `infra-root/` + `app-root/` Helm and
Argo CD shape sketched out earlier becomes the right answer.

### Secrets are not in this repo

`auth-service-secrets` (`DB_PASSWORD`, `GOOGLE_OAUTH_CLIENT_ID`,
`GOOGLE_OAUTH_CLIENT_SECRET`, `ENCRYPTION_KEY`) is created imperatively with
`kubectl create secret` in [deploy.md step 3](docs/deploy.md) and is deliberately absent from
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
  [prerequisites.md §3.2](docs/prerequisites.md#32-cpu-budget--the-binding-constraint).
- **Cloud SQL instance is shared** with `recommendations-backend`. Fine at this scale, worth
  knowing when you read the instance's metrics.
- **No CI.** Deploys are manual `kubectl apply`. Natural next step once Phase 2 is green.
- **`infra-root/`, `app-root/` and `auth-service/` are leftover empty scaffolding** and should
  be deleted — every template file in them is 0 bytes, and the one file with content
  (`infra-root/values.yaml`) describes the wrong project, wrong region, and a private Cloud SQL
  IP that doesn't exist. Superseded by `k8s/`.
