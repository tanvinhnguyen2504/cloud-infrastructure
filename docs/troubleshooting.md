# Troubleshooting

Failure modes specific to *this* service and *this* cluster, in rough order of likelihood.
Each entry names the diagnosis command, not just the symptom.

---

## `kubectl` returns `Forbidden` with an unexpected account name

```
User "<some-other-account>" cannot get resource "namespaces" ...
requires one of ["container.namespaces.get"] permission(s) in Cloud IAM
```

The context is fine; the **identity** is wrong. Your kubeconfig stores an `exec` hook that calls
`gke-gcloud-auth-plugin`, which mints a token for whichever gcloud configuration is *active* —
not for whatever account the context was created under. So switching gcloud configurations
silently changes who `kubectl` is.

```bash
gcloud config configurations activate personal
gcloud config get account      # => vinhnguyentan99@gmail.com
kubectl get nodes
```

Note the error reads like a missing IAM role, which sends you editing bindings for an account
that should not have had access in the first place.

---

## `CrashLoopBackOff`, logs show `config: X is required`

`config.Load()` hard-requires `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET`,
`ENCRYPTION_KEY` and a non-empty redirect URL. Any missing one aborts startup — there is no
degraded mode.

```bash
kubectl -n auth get secret auth-service-secrets -o jsonpath='{.data}' | tr ',' '\n' | cut -d'"' -f2
```

All four keys must be present. Note the error names the *variable*, so it tells you exactly
which one.

---

## `CrashLoopBackOff`, logs show `secret: key must decode to 32 bytes, got N`

`ENCRYPTION_KEY` is not a 32-byte base64 value. This is an AES-256 key length requirement, not a
preference — `secret.go` refuses rather than weakening the cipher.

```bash
kubectl -n auth create secret generic auth-service-secrets \
  --from-literal=ENCRYPTION_KEY="$(openssl rand -base64 32)" \
  --dry-run=client -o yaml | kubectl apply -f -
```

Common cause: using `openssl rand -hex 32`, which yields 64 characters that decode to the wrong
length. **Changing this key invalidates every live session.**

---

## `CrashLoopBackOff`, logs show `db: ping ...: context deadline exceeded`

The app reached the sidecar's port but the sidecar can't reach Cloud SQL. Read the proxy's own
logs — the app's error is downstream of the real one:

```bash
kubectl -n auth logs deploy/auth-service -c cloud-sql-proxy
```

| Proxy log says | Cause | Fix |
| --- | --- | --- |
| `failed to get instance: ... PermissionDenied` | GSA lacks `roles/cloudsql.client` | [prerequisites.md §4](./prerequisites.md#4-the-workload-identity-chain), link 3 |
| `metadata: GCE metadata "instance/service-accounts/default/token" not defined` | Workload Identity not active on the node pool | [prerequisites.md §4](./prerequisites.md#4-the-workload-identity-chain), link 2 |
| `... does not have permission` naming the **node** SA (`...-compute@`) | The KSA→GSA binding is missing, so the proxy fell back to the node identity | [prerequisites.md §4](./prerequisites.md#4-the-workload-identity-chain), link 4 |
| `Cloud SQL Admin API has not been used` | API disabled | [prerequisites.md §2](./prerequisites.md#2-project-apis) |

Confirm Workload Identity actually works from inside the cluster:

```bash
kubectl -n auth run wi-test --rm -it --restart=Never \
  --image=google/cloud-sdk:slim \
  --overrides='{"spec":{"serviceAccountName":"auth-service"}}' \
  -- gcloud auth list
# must print auth-sql@vincent-mini-apps-project.iam.gserviceaccount.com,
# NOT 225614846438-compute@developer.gserviceaccount.com
```

That one command distinguishes the two most confusable causes above.

---

## `CrashLoopBackOff`, logs show `password authentication failed for user "postgres"`

`DB_PASSWORD` in the Secret doesn't match the instance. The proxy authenticates the *connection*
via IAM; the *database user* still uses a password. Both have to be right.

```bash
gcloud sql users set-password postgres \
  --instance=recommendations-app-instance --prompt-for-password
```

Then update the Secret and `kubectl -n auth rollout restart deploy/auth-service`.

---

## `CrashLoopBackOff` with no app logs at all, or `exec format error`

The image is the wrong architecture — built natively on your arm64 Mac for amd64 nodes.

```bash
kubectl -n auth describe pod -l app=auth-service | grep -A3 'Last State'
```

Rebuild with the platform flag (already in the Makefile target):

```bash
cd ../auth-be && make image-push TAG=0.0.3
```

---

## `CrashLoopBackOff` mentioning a read-only filesystem or `logs/logrus.log`

`production.yaml` configures `logger.file_name: logs/logrus.log`, but `main.go` only uses stdlib
`log` to stderr and no logrus writer is wired up — so `readOnlyRootFilesystem: true` should be
safe. If this ever does surface, the fix is a writable scratch mount rather than dropping the
security setting:

```yaml
# deployment.yaml, app container
volumeMounts:
  - name: logs
    mountPath: /logs
# pod spec
volumes:
  - name: logs
    emptyDir: {}
```

---

## `ImagePullBackOff`

```bash
kubectl -n auth describe pod -l app=auth-service | grep -A5 Events
```

- `denied: Permission ... downloadArtifacts` → the **node** SA needs AR read. It holds
  `roles/editor` and the `devstorage.read_only` scope, which normally suffices; if not:
  ```bash
  gcloud artifacts repositories add-iam-policy-binding auth-repository \
    --location=asia-southeast1 \
    --member="serviceAccount:225614846438-compute@developer.gserviceaccount.com" \
    --role="roles/artifactregistry.reader"
  ```
- `manifest unknown` → the tag or digest in `deployment.yaml` doesn't exist. Verify with
  `gcloud artifacts docker images list ... --include-tags`.

---

## Pod `Pending`, never schedules

One `e2-medium` node has roughly 940m allocatable CPU and ~2.8Gi memory, and system pods take a
share.

```bash
kubectl -n auth describe pod -l app=auth-service | grep -A5 Events
kubectl describe node | grep -A8 'Allocated resources'
```

`Insufficient cpu` means requests exceed what's left — lower them, or grow the node pool. This
is also why `replicas: 1`; the old skeleton's `replicaCount: 4` could never have scheduled.

---

## The pod vanished and came back

The node pool is **spot**. Preemption is normal and expected; with `replicas: 1` it means a
short full outage.

```bash
kubectl get events -A --field-selector reason=Preempted
```

Not a bug to fix — a tradeoff to accept for staging, or to remove with a non-spot pool.

---

## `LoadBalancer` EXTERNAL-IP stuck at `<pending>`

Normal for about a minute. Beyond ~5 min:

```bash
kubectl -n auth describe svc auth-service | grep -A10 Events
```

---

## HTTPS: `ManagedCertificate` stuck in `Provisioning`

```bash
kubectl -n auth describe managedcertificate auth-service-cert
```

- `FailedNotVisible` → DNS isn't resolving to the Ingress IP yet. Check `dig +short <host>` and
  wait for propagation; the certificate retries on its own.
- Normal issuance is 10–20 min and can reach an hour. Don't delete and recreate — that restarts
  the clock.

---

## OAuth: `redirect_uri_mismatch`

The URI the app sends must match the GCP console entry byte for byte.

```bash
kubectl -n auth exec deploy/auth-service -c auth-service -- env 2>/dev/null | grep -i redirect
```

If that is empty, you are still on an image without the `GOOGLE_OAUTH_REDIRECT_URL` override —
see [Phase 2.1](./phase-2-domain-tls-oauth.md). Then compare against the console value watching
for: `http` vs `https`, a trailing slash, `www.`, and the `/api/v1` prefix.

---

## Browser: CORS errors after login

`FRONTEND_URL` is the single allowed CORS origin *and* the post-login redirect target. It must
be the SPA's exact origin — scheme + host + port, no path, no trailing slash.

```bash
kubectl -n auth get cm auth-service-config -o jsonpath='{.data.FRONTEND_URL}'
```

---

## Useful one-liners

```bash
# follow both containers
kubectl -n auth logs -f deploy/auth-service --all-containers --prefix

# what actually reached the container
kubectl -n auth exec deploy/auth-service -c auth-service -- env | sort

# restart without changing anything
kubectl -n auth rollout restart deploy/auth-service

# roll back
kubectl -n auth rollout undo deploy/auth-service

# reach the service without a load balancer
kubectl -n auth port-forward deploy/auth-service 8080:9999
curl -s localhost:8080/api/v1/health
```
