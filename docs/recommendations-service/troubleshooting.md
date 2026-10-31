# Troubleshooting — `recommendations-service`

Organised by the error you are actually looking at.

Context: [prerequisites.md](./prerequisites.md) · [deploy.md](./deploy.md).

First, always:

```bash
kubectl -n recommendations get pods -l app=recommendations-service
kubectl -n recommendations describe pod -l app=recommendations-service | tail -30
```

The `Events` block at the bottom of `describe` names the layer that failed. Note that
`describe pod` on a pod from an **old** ReplicaSet shows a spec that no longer exists in the
repo — check which generation you are reading before believing it:

```bash
kubectl -n recommendations get rs -o custom-columns='NAME:.metadata.name,REV:.metadata.annotations.deployment\.kubernetes\.io/revision,DESIRED:.spec.replicas,READY:.status.readyReplicas'
```

---

## Pod is `Pending` — `0/2 nodes are available: Insufficient cpu`

The expected first failure. The pod requests 150m and the nodes have reserved most of their CPU.

```bash
kubectl describe nodes | sed -n '/Allocated resources/,/^Events/p'
kubectl get nodes
```

Autoscaling is **off** on `minimal-pool`, so nothing will rescue it — there is no
`TriggerScaleUp` event to wait for. Run [deploy.md step 1](./deploy.md#step-1--make-room-on-the-cluster-blocker).

Requests, not usage, decide this: the node can be almost idle and still refuse the pod. See
[prerequisites.md §3.2](./prerequisites.md#32-blocker-the-node-has-no-room-for-this-pod).

---

## Pod is `CreateContainerConfigError`

The Secret is missing or a key it names is absent. Nothing ran, so there are no app logs.

```bash
kubectl -n recommendations get secret recommendations-service-secrets \
  -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'
# want: DB_PASSWORD / ENCRYPTION_KEY / GOOGLE_OAUTH_CLIENT_ID / GOOGLE_OAUTH_CLIENT_SECRET
```

`envFrom.secretRef` is not optional, so the whole container config fails to build. Create it —
[deploy.md step 5](./deploy.md#step-5--secret).

---

## App container `CrashLoopBackOff`, logs say `config: <NAME> is required`

One of the four required values is present but **empty**. `config.Load()` validates
`GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET`, `google_oauth_redirect_url` and
`ENCRYPTION_KEY` unconditionally, before anything checks whether this service has auth routes —
it does not, and they are still mandatory.

```bash
kubectl -n recommendations logs deploy/recommendations-service -c recommendations-service
```

If the name is `google_oauth_redirect_url`, the cause is different and unusual: that value comes
from the embedded `production.yaml`, not the environment, so an empty one means the image was
built from a modified config. No manifest change can fix it.

---

## App container `CrashLoopBackOff`, logs say `database: db: ping …`

The app reached `db.Connect`, the Ping failed, and `main.go` called `log.Fatalf`. Read the rest
of the message:

| Message fragment | Cause |
| --- | --- |
| `connection refused` on `127.0.0.1:5432` | the proxy is not listening. Check its logs and that `DB_PORT` matches `--port=5432` (invariant 2) |
| `password authentication failed` | `DB_PASSWORD` in the Secret is wrong, or the `postgres` password was rotated |
| `database "…" does not exist` | `DB_NAME` names a database that is not on the instance — `gcloud sql databases list --instance=recommendations-app-instance` |
| a host that is **not** `127.0.0.1` | `DATABASE_URL` is set somewhere. It *overrides* the whole `DB_*` block (invariant 7) — remove it from the ConfigMap |

The logged target is `RedactedDatabaseTarget()`, which prints host, port and name only. It is
also derived from `DATABASE_URL` when that is set, which makes it the fastest way to spot
invariant 7 breaking.

---

## Proxy container restarts every ~60s, exit code 143, logs look fine

Its own logs end with `The proxy has started successfully and is ready for new connections!`
followed by `SIGTERM signal received`. 143 is 128 + 15 — the kubelet killed it. The proxy is
healthy; its **startup probe** is failing.

```bash
kubectl -n recommendations get deploy recommendations-service -o yaml \
  | grep -A6 'startupProbe' | head -20
```

The probe needs all four of these to agree:

- `--health-check` (turns the health server on at all)
- `--http-address=0.0.0.0` (kubelet dials the **pod IP**, from outside the pod's network
  namespace — a server bound to loopback is unreachable to it)
- `--http-port=9090`
- `httpGet: { path: /startup, port: 9090 }`

A `tcpSocket` probe on 5432 can **never** pass: the DB tunnel binds `127.0.0.1` only, by design.
This exact misconfiguration killed auth-service's proxy on a 2-minute cycle.

---

## Proxy logs: Cloud SQL rejects a service account you did not configure

If the named account is `225614846438-compute@developer.gserviceaccount.com`, the pod is using
the **node's** identity. The Workload Identity chain is half-finished — almost always link 4.

```bash
# what the pod actually got
kubectl -n recommendations exec deploy/recommendations-service -c cloud-sql-proxy -- \
  curl -s -H 'Metadata-Flavor: Google' \
  'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email'

P=vincent-mini-apps-project
GSA="recommendations-sql@${P}.iam.gserviceaccount.com"
gcloud iam service-accounts get-iam-policy "$GSA" --format=json | grep workloadIdentityUser
# want member serviceAccount:vincent-mini-apps-project.svc.id.goog[recommendations/recommendations-service]
kubectl -n recommendations get sa recommendations-service \
  -o jsonpath='{.metadata.annotations.iam\.gke\.io/gcp-service-account}'
```

The member string embeds **namespace and KSA name**. A typo in either is silent — no error, just
the node identity. The node SA cannot work here even though it holds `roles/editor`: its OAuth
*scopes* exclude `sqladmin`, and scopes cap a token regardless of IAM.

---

## App container: `exec format error`

The image was built for arm64 (this laptop) and the nodes are amd64. The push and pull both
succeeded, which is why this does not look like an architecture problem.

```bash
docker buildx imagetools inspect \
  asia-southeast1-docker.pkg.dev/vincent-mini-apps-project/recommendations-repository/recommendations-service:0.0.1 \
  | grep -i platform
```

Rebuild with `--platform linux/amd64` — [deploy.md step 4](./deploy.md#step-4--build-and-push-the-image).

---

## `ImagePullBackOff`

```bash
kubectl -n recommendations describe pod -l app=recommendations-service | grep -A3 Failed
```

| Event text | Cause |
| --- | --- |
| `name unknown` / `not found` | the repo or tag does not exist. `gcloud artifacts docker images list …/recommendations-repository` |
| `denied` / `unauthorized` | rare here — image pulls use the node SA's `devstorage.read_only` scope, which is present. Check the repo is in `asia-southeast1` and the path has no typo |

---

## `curl` to the external IP hangs or 502s

```bash
kubectl -n recommendations get svc recommendations-service
kubectl -n recommendations get endpointslice \
  -l kubernetes.io/service-name=recommendations-service \
  -o jsonpath='{.items[*].endpoints[*].addresses}{"\n"}'
```

- **No `EXTERNAL-IP` yet** — GCP is still provisioning the forwarding rule. A minute or two.
- **Empty EndpointSlice** — the Service matches no *ready* pod. Either the pod is not Ready
  (go back up this page) or invariants 4/5 are broken: `service.selector` must equal the pod
  labels, and `service.targetPort: http` must match `ports[].name: http`.
- **Endpoint present, still 502** — the port the app bound does not match `containerPort`.
  `containerPort` is informational; the process binds whatever `PORT` says. Confirm with the
  `listening on :9998` log line.

---

## `/api/v1/health` is 200 but `/api/v1/places` is 500

The deploy is fine and the **schema is not**. `healthCheck` marshals two config strings and never
touches the pool, so it cannot detect this.

```bash
kubectl -n recommendations logs deploy/recommendations-service -c recommendations-service --tail=50
# look for: relation "gm_places" does not exist
```

```bash
psql "host=34.142.199.254 dbname=recommendations-backend user=postgres sslmode=require" \
  -c '\d gm_places'
```

`recommendations-be` ships no migrations — the `Makefile`'s `migrate` and `seed` targets point at
`./db/migrations` and `./internal/platform/db/seeds`, neither of which exists in the repo — so
there is nothing in that repo to run. Whatever creates `gm_places` lives elsewhere (the scraper,
or hand-applied SQL).

---

## A browser gets a CORS error but `curl` works

Expected. `middleware/cors.go` passes `FRONTEND_URL` straight into `AllowedOrigins` as the
**single** permitted origin, currently the `http://localhost:5173` placeholder. `curl` and the
kubelet probes send no `Origin` header, and `rs/cors` passes those through untouched.

Set `FRONTEND_URL` in `configmap.yaml` to the real frontend origin, then — because there is no
`configMapGenerator` and therefore no name hash — **restart**:

```bash
kubectl -n recommendations rollout restart deploy/recommendations-service
```

---

## A ConfigMap edit had no effect

Same root cause. `envFrom.configMapRef` has no name hash, so the Deployment's pod template does
not change when the ConfigMap does, so no rollout triggers and the running pod keeps its old
environment. `rollout restart` is required, every time.

```bash
# what the running pod actually has
kubectl -n recommendations exec deploy/recommendations-service -c recommendations-service -- env
```

That `exec` will fail — the image is distroless, with no shell and no `env` binary. Read the
ConfigMap and the pod's start time instead:

```bash
kubectl -n recommendations get cm recommendations-service-config -o yaml
kubectl -n recommendations get pod -l app=recommendations-service \
  -o jsonpath='{.items[0].status.startTime}{"\n"}'
```

If the pod started before your edit, it does not have it.

---

## `kubectl apply --dry-run=server` fails with `namespaces "recommendations" not found`

Not a bug. Server-side dry-run never persists the Namespace, so every namespaced object in the
same bundle is validated against a namespace that does not exist. Use the client-side render
instead:

```bash
kubectl kustomize k8s/recommendations-service
```

---

## `kubectl` returns `Forbidden`

The **account** is wrong, not the context. The kubeconfig holds no credential — it holds an
`exec` hook that mints a token for whichever gcloud configuration is active right now.

```bash
gcloud config get account            # want vinhnguyentan99@gmail.com
gcloud config configurations list    # want "personal" ACTIVE
kubectl config current-context
```
