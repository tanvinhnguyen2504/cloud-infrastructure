# Troubleshooting checklist — `auth-service`

Every failure mode this deploy can hit, in the order the deploy can hit them. Walk the phase that
matches where you are; each box names the symptom, the cause, and the command that confirms it.

Context: [prerequisites.md](./prerequisites.md) · [deploy.md](./deploy.md) ·
[parameters.md](./parameters.md) · [manifest-reference.md](./manifest-reference.md) ·
[phase-2-domain-tls-oauth.md](./phase-2-domain-tls-oauth.md).

Namespace `auth`, deployment `auth-service`, app container `auth-service`, sidecar
`cloud-sql-proxy`. `make <target> SVC=auth` targets this service from the repo root.

---

## Phase 0 — Read the failure before theorising

- [ ] Get the pod's real status, not the Deployment's: `make ps SVC=auth`
- [ ] Read the `Events` block — it names the layer that failed: `make events SVC=auth`
- [ ] Confirm which ReplicaSet generation you are reading. `describe pod` on a pod from an **old**
      ReplicaSet shows a spec that no longer exists in the repo:
      `kubectl -n auth get rs -o custom-columns='NAME:.metadata.name,REV:.metadata.annotations.deployment\.kubernetes\.io/revision,DESIRED:.spec.replicas,READY:.status.readyReplicas'`
- [ ] Do not trust the Deployment's `Available` condition. With `replicas: 1` and
      `maxUnavailable: 1`, zero running pods still satisfies the minimum, so `Available: True`
      can coexist with nothing running. Only `Progressing` reports the failure.
- [ ] Follow both containers at once:
      `kubectl -n auth logs -f deploy/auth-service --all-containers --prefix`
- [ ] Reach the service without waiting on a load balancer:
      `kubectl -n auth port-forward deploy/auth-service 8080:9999` then
      `curl -s localhost:8080/api/v1/health`

---

## Phase 1 — Access and identity

- [ ] `kubectl` returns `Forbidden` naming an unexpected account → the **identity** is wrong, not
      the context. The kubeconfig holds no credential, only an `exec` hook that mints a token for
      whichever gcloud configuration is active right now, so switching configurations silently
      changes who `kubectl` is.
      `gcloud config get account` · `gcloud config configurations list` · `kubectl config current-context`
- [ ] The error reads like a missing IAM role → it usually is not. Fix the active gcloud
      configuration before editing bindings for an account that should not have had access.
- [ ] `gcloud` succeeds against the wrong project: `gcloud config get project`

---

## Phase 2 — Rendering and applying the manifests

- [ ] `kubectl apply --dry-run=server` fails with `namespaces "auth" not found` → not a bug.
      Server-side dry-run never persists the Namespace, so every namespaced object in the bundle
      validates against a namespace that does not exist. Render client-side instead:
      `kubectl kustomize k8s/auth-service`
- [ ] Kustomize labels leak into the selector → `includeSelectors` must stay `false`;
      `selector.matchLabels` is immutable after creation.
- [ ] A selector change is rejected → the Deployment must be deleted and recreated, not patched.

---

## Phase 3 — Pod `Pending`, never schedules

- [ ] `Insufficient cpu` → the sum of **requests** on the node exceeds allocatable. Requests, not
      usage, decide scheduling: the node can be almost idle and still refuse the pod.
      `kubectl describe node | sed -n '/Allocated resources/,/^Events/p'`
- [ ] `Insufficient memory` → same ledger, different column. Check both rows.
- [ ] No `TriggerScaleUp` event appears → autoscaling is off on the node pool. Nothing will
      rescue a `Pending` pod; add capacity or lower requests.
- [ ] A high `replicas` count can never schedule on a single small node → this is why
      `replicas: 1`.
- [ ] Rollout deadlocks with `maxUnavailable: 0` → two copies of the pod must fit on one node for
      a surge strategy to work. If they do not, the old pod cannot leave until the new one is
      Ready and the new one cannot schedule until the old one leaves.

---

## Phase 4 — Pod scheduled, container will not start

- [ ] `CreateContainerConfigError` → the Secret is missing, or a key it names is absent.
      `envFrom.secretRef` is not optional, so the container config cannot be built and nothing
      runs — there will be no app logs at all.
      `kubectl -n auth get secret auth-service-secrets -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'`
      Want: `DB_PASSWORD`, `ENCRYPTION_KEY`, `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET`.
- [ ] The Secret "does not exist" but you remember creating it → check whether it landed in
      **another namespace**. A `create secret` without `-n auth` silently targets the current
      context's namespace: `kubectl get secret -A | grep auth-service-secrets`
- [ ] Creating the Secret does not immediately fix the pod → the container is in a backoff timer.
      Force it: `make restart SVC=auth`
- [ ] `ImagePullBackOff` with `manifest unknown` → the tag or digest in `deployment.yaml` does not
      exist. `gcloud artifacts docker images list …/auth-repository --include-tags`
- [ ] `ImagePullBackOff` with `denied: Permission ... downloadArtifacts` → the **node** service
      account needs Artifact Registry read. Confirm the repo region and image path have no typo
      first, then grant `roles/artifactregistry.reader` on the repository if needed.
- [ ] `exec format error`, or `CrashLoopBackOff` with no app logs → the image is the wrong
      architecture. An arm64 build pushes and pulls without complaint, then fails on amd64 nodes,
      which is why this does not look like an architecture problem. Check `Last State`:
      `kubectl -n auth describe pod -l app=auth-service | grep -A3 'Last State'`
      Rebuild via the service repo's `image-push` target, which carries the platform flag.
- [ ] The pod runs old bytes after a redeploy → a moved tag plus `imagePullPolicy: IfNotPresent`.
      Pin the digest, and never move a tag that is already deployed.

---

## Phase 5 — App starts, then exits on config

- [ ] `config: <NAME> is required` → that variable is missing or empty. `config.Load()`
      hard-requires `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET`, `ENCRYPTION_KEY` and a
      non-empty redirect URL. Any one of them aborts startup — there is no degraded mode, and the
      error names the variable.
- [ ] `secret: key must decode to 32 bytes, got N` → `ENCRYPTION_KEY` is not a 32-byte base64
      value. This is an AES-256 length requirement, not a preference. Generate with
      `openssl rand -base64 32`.
- [ ] You used `openssl rand -hex 32` → that yields 64 characters which decode to the wrong
      length. This is the usual cause of the box above.
- [ ] **Changing `ENCRYPTION_KEY` invalidates every live session.** Treat it as a migration, not a
      config tweak, and store it outside the cluster.
- [ ] A missing Secret and an empty value fail **differently**: missing →
      `CreateContainerConfigError` (Phase 4), empty → `CrashLoopBackOff` with a named variable here.
- [ ] `CrashLoopBackOff` mentioning a read-only filesystem or a log file path → the config names a
      log file while the container runs with `readOnlyRootFilesystem: true`. Fix with a writable
      scratch mount (`emptyDir`), not by dropping the security setting.

---

## Phase 6 — Workload Identity and the Cloud SQL proxy

- [ ] Proxy logs `Unable to generate access token; IAM returned 403 Forbidden: Permission
      'iam.serviceAccounts.getAccessToken' denied` → the **KSA→GSA** binding is missing. This is
      the half of the chain that is easy to skip, because the two bindings point in opposite
      directions. [prerequisites.md §4](./prerequisites.md#4-the-workload-identity-chain), link 4.
- [ ] Proxy logs `failed to get instance: ... PermissionDenied` → the **GSA** lacks
      `roles/cloudsql.client`. Different binding, different direction. §4, link 3.
- [ ] Cloud SQL rejects an account you never configured, named `…-compute@developer.gserviceaccount.com`
      → the pod fell back to the **node's** identity because the KSA→GSA binding is absent. The
      node SA cannot work here even with broad project roles: its OAuth *scopes* exclude
      `sqladmin`, and scopes cap a token regardless of IAM. §4, link 4.
- [ ] `metadata: GCE metadata "instance/service-accounts/default/token" not defined` → Workload
      Identity is not active on the node pool. §4, link 2. Changing node-pool metadata mode
      **recreates nodes**.
- [ ] `Cloud SQL Admin API has not been used` → the API is disabled.
      [prerequisites.md §2](./prerequisites.md#2-project-apis)
- [ ] The KSA annotation is absent or misspelled →
      `kubectl -n auth get sa auth-service -o jsonpath='{.metadata.annotations.iam\.gke\.io/gcp-service-account}'`
- [ ] The `workloadIdentityUser` member string embeds **namespace and KSA name**
      (`PROJECT.svc.id.goog[auth/auth-service]`). A typo in either is silent — no error, just the
      node identity.
- [ ] The proxy logs `started successfully` and you conclude Workload Identity works → it does
      not prove that. The proxy resolves credentials lazily; no token is minted until the first
      real connection, so startup succeeds and the 403 appears only once the app dials it.
- [ ] Settle the two most confusable causes above with one command — the identity the pod
      **actually** got:
      ```bash
      kubectl -n auth run wi-test --rm -it --restart=Never \
        --image=google/cloud-sdk:slim \
        --overrides='{"spec":{"serviceAccountName":"auth-service"}}' \
        -- gcloud auth list
      ```
      It must print the service's own GSA, not the `…-compute@developer` node account.
- [ ] A new IAM binding does not take effect immediately → propagation takes a minute or two. One
      further crash cycle after a restart is not necessarily failure.

---

## Phase 7 — The proxy sidecar itself

- [ ] Proxy restarts on a fixed cycle, exit code **143**, logs otherwise clean → 143 is 128 + 15;
      the kubelet killed it. The proxy is healthy and its **startup probe** is failing.
- [ ] The startup probe needs all four of these to agree: `--health-check` (turns the health
      server on at all), `--http-address=0.0.0.0`, `--http-port=9090`, and
      `httpGet: { path: /startup, port: 9090 }`.
- [ ] A `tcpSocket` probe on 5432 can **never** pass → the kubelet dials the pod IP from outside
      the pod's network namespace, while the DB tunnel binds `127.0.0.1` only, by design.
- [ ] `Startup probe failed: connection refused` once or twice at container start → expected
      noise, not a fault. The probe fires before the proxy has bound its port.
- [ ] Proxy logs `SIGTERM signal received` straight after `ready for new connections` → the same
      startup-probe cause, not a shutdown bug.
- [ ] The app wins the startup race and dies before the proxy is ready → the proxy must be a
      **native sidecar** (`initContainers` + `restartPolicy: Always`), not an ordinary container.
      Requires Kubernetes 1.29+.

---

## Phase 8 — Database connection

- [ ] `db: ping ...: context deadline exceeded` → the app reached the sidecar's port but the
      sidecar cannot reach Cloud SQL. The app's error is downstream of the real one; read the
      proxy's own logs: `kubectl -n auth logs deploy/auth-service -c cloud-sql-proxy`
- [ ] `connection refused` on `127.0.0.1:5432` → the proxy is not listening at all. Phase 7, and
      check `DB_PORT` matches the proxy's `--port`.
- [ ] `connection reset by peer` → the proxy is listening but cannot reach Cloud SQL. Phase 6.
- [ ] `password authentication failed for user "postgres"` → `DB_PASSWORD` does not match the
      instance. The proxy authenticates the *connection* via IAM; the *database user* still uses a
      password, and both have to be right.
      `gcloud sql users set-password postgres --instance=<instance> --prompt-for-password`
      Then update the Secret and restart.
- [ ] `database "…" does not exist` → `DB_NAME` names a database not on the instance.
      `gcloud sql databases list --instance=<instance>`
- [ ] Rotating the instance's `postgres` password affects **every service sharing that instance**,
      since it is the same superuser. A per-service database user avoids this.

---

## Phase 9 — Reaching the service

- [ ] `LoadBalancer` EXTERNAL-IP stuck at `<pending>` → normal for about a minute. Beyond ~5 min:
      `kubectl -n auth describe svc auth-service | grep -A10 Events`
- [ ] `curl` hangs or 502s → check the EndpointSlice is non-empty:
      `kubectl -n auth get endpointslice -l kubernetes.io/service-name=auth-service -o jsonpath='{.items[*].endpoints[*].addresses}{"\n"}'`
- [ ] Empty EndpointSlice → the Service matches no **ready** pod. Either the pod is not Ready (go
      back up this page), or `service.selector` does not equal the pod labels, or
      `service.targetPort` does not match the container's port **name**.
- [ ] Endpoint present and still 502 → the port the process bound does not match
      `containerPort`. `containerPort` is informational; the process binds whatever `PORT` says.

---

## Phase 10 — HTTPS and OAuth

- [ ] `ManagedCertificate` stuck in `Provisioning` →
      `kubectl -n auth describe managedcertificate auth-service-cert`
- [ ] Status `FailedNotVisible` → DNS is not resolving to the Ingress IP yet. Check
      `dig +short <host>` and wait; the certificate retries on its own.
- [ ] Issuance is slow → 10–20 minutes is normal and it can reach an hour. **Do not delete and
      recreate** — that restarts the clock.
- [ ] OAuth `redirect_uri_mismatch` → the URI the app sends must match the GCP console entry byte
      for byte. Compare watching for `http` vs `https`, a trailing slash, `www.`, and the API
      path prefix.
- [ ] The redirect URL is empty in the running pod → the image predates the
      `GOOGLE_OAUTH_REDIRECT_URL` override. See
      [phase-2-domain-tls-oauth.md](./phase-2-domain-tls-oauth.md).
- [ ] A browser gets a CORS error after login while `curl` works → expected. `FRONTEND_URL` is
      both the single allowed CORS origin and the post-login redirect target, and `curl` and the
      kubelet probes send no `Origin` header. It must be the SPA's exact origin — scheme, host and
      port, no path, no trailing slash.
      `kubectl -n auth get cm auth-service-config -o jsonpath='{.data.FRONTEND_URL}'`

---

## Phase 11 — Changes that appear to do nothing

- [ ] A `configmap.yaml` edit has no effect → there is no `configMapGenerator`, so the ConfigMap
      has no name hash, so the pod template does not change, so no rollout triggers and the
      running pod keeps its old environment. A restart is required **every time**:
      `make apply-config SVC=auth`
- [ ] A Secret edit has no effect → same mechanism. Replace the Secret, then
      `make restart SVC=auth`.
- [ ] Check what actually reached the container:
      `kubectl -n auth exec deploy/auth-service -c auth-service -- env | sort`
      If the image is distroless this will fail (no shell, no `env` binary) — compare the
      ConfigMap against the pod's start time instead.
- [ ] `rollout undo` appears to change nothing → it is only meaningful because images are
      digest-pinned. With a floating tag, undo re-pulls whatever that tag points at today.
- [ ] The pod vanished and came back on its own → if the node pool is **spot**, preemption is
      normal and expected, and with `replicas: 1` it is a short full outage. Not a bug to fix — a
      tradeoff to accept, or to remove with a non-spot pool.
      `kubectl get events -A --field-selector reason=Preempted`
