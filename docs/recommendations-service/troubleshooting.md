# Troubleshooting checklist — `recommendations-service`

Every failure mode this deploy can hit, in the order the deploy can hit them. Walk the phase that
matches where you are; each box names the symptom, the cause, and the command that confirms it.

Context: [prerequisites.md](./prerequisites.md) · [deploy.md](./deploy.md) ·
[cpu-capacity-options.md](./cpu-capacity-options.md).

Namespace `recommendations`, deployment `recommendations-service`, app container
`recommendations-service`, sidecar `cloud-sql-proxy`. `make` targets below assume the repo root.

---

## Phase 0 — Read the failure before theorising

- [ ] Get the pod's real status, not the Deployment's: `make ps`
- [ ] Read the `Events` block — it names the layer that failed: `make events`
- [ ] Confirm which ReplicaSet generation you are reading. `describe pod` on a pod from an **old**
      ReplicaSet shows a spec that no longer exists in the repo:
      `kubectl -n recommendations get rs -o custom-columns='NAME:.metadata.name,REV:.metadata.annotations.deployment\.kubernetes\.io/revision,DESIRED:.spec.replicas,READY:.status.readyReplicas'`
- [ ] Do not trust the Deployment's `Available` condition. With `replicas: 1` and
      `maxUnavailable: 1`, zero running pods still satisfies the minimum, so `Available: True`
      can coexist with nothing running. Only `Progressing` reports the failure.
- [ ] Treat `rollout status ... exceeded its progress deadline` as "something below me failed",
      never as a cause in itself.

---

## Phase 1 — Access and identity

- [ ] `kubectl` returns `Forbidden` → the **account** is wrong, not the context. The kubeconfig
      holds no credential, only an `exec` hook that mints a token for whichever gcloud
      configuration is active right now. Check both:
      `gcloud config get account` · `gcloud config configurations list` · `kubectl config current-context`
- [ ] The `Forbidden` message reads like a missing IAM role, which sends you editing bindings for
      an account that should not have had access at all. Fix the active configuration first.
- [ ] `gcloud` commands succeed but target the wrong project: `gcloud config get project`

---

## Phase 2 — Rendering and applying the manifests

- [ ] `kubectl apply --dry-run=server` fails with `namespaces "recommendations" not found` → not a
      bug. Server-side dry-run never persists the Namespace, so every namespaced object in the
      bundle validates against a namespace that does not exist. Use the client-side render:
      `kubectl kustomize k8s/recommendations-service`
- [ ] Kustomize labels leak into the selector → `includeSelectors` must stay `false`;
      `selector.matchLabels` is immutable after creation.
- [ ] A selector change is rejected outright → the Deployment must be deleted and recreated, not
      patched.

---

## Phase 3 — Pod `Pending`, never schedules

- [ ] `Insufficient cpu` → the sum of **requests** on the node exceeds allocatable. Requests, not
      usage, decide scheduling: the node can be almost idle and still refuse the pod.
      `make capacity` equivalent: `kubectl describe node | sed -n '/Allocated resources/,/^Events/p'`
- [ ] No `TriggerScaleUp` event appears → autoscaling is off on the node pool. Nothing will
      rescue a `Pending` pod; you must add capacity or lower requests. See
      [cpu-capacity-options.md](./cpu-capacity-options.md).
- [ ] `NotTriggerScaleUp` repeating with an empty reason → same thing. Not a transient.
- [ ] `Insufficient memory` → same ledger, different column. Check both rows of
      `Allocated resources`.
- [ ] Rollout deadlocks with `maxUnavailable: 0` → two copies of the pod must fit on one node for
      a surge strategy to work. If they do not, the old pod cannot leave until the new one is
      Ready and the new one cannot schedule until the old one leaves. `maxUnavailable: 1` /
      `maxSurge: 0` is required while the node is tight.
- [ ] The node is near-fully reserved after a successful deploy → nothing further will schedule,
      including a second copy of this pod. Every rollout then has a brief outage by design.

---

## Phase 4 — Pod scheduled, container will not start

- [ ] `CreateContainerConfigError` → the Secret is missing, or a key it names is absent.
      `envFrom.secretRef` is not optional, so the container config cannot be built and nothing
      runs — there will be no app logs at all.
      `kubectl -n recommendations get secret recommendations-service-secrets -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'`
      Want: `DB_PASSWORD`, `ENCRYPTION_KEY`, `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET`.
- [ ] The Secret "does not exist" but you remember creating it → check whether it landed in
      **another namespace**. A `create secret` without `-n recommendations` silently targets the
      current context's namespace, and the Secret then sits unreferenced somewhere else:
      `kubectl get secret -A | grep recommendations-service-secrets`
- [ ] Creating the Secret does not immediately fix the pod → the container is in a backoff timer.
      Force it: `make restart`
- [ ] `ImagePullBackOff` with `name unknown` / `not found` → the repo, tag or digest does not
      exist. `gcloud artifacts docker images list …/recommendations-repository --include-tags`
- [ ] `ImagePullBackOff` with `denied` / `unauthorized` → check the repo is in the cluster's
      region and the image path has no typo, before touching IAM.
- [ ] `exec format error`, or `CrashLoopBackOff` with no app logs → the image is the wrong
      architecture. An arm64 build pushes and pulls without complaint, then fails on amd64 nodes,
      which is why this does not look like an architecture problem.
      `docker buildx imagetools inspect <image> | grep -i platform` — want `linux/amd64`.
- [ ] Pod runs old bytes after a redeploy → a moved tag plus `imagePullPolicy: IfNotPresent`.
      Pin the digest, and never move a tag that is already deployed.

---

## Phase 5 — App starts, then exits on config

- [ ] `config: <NAME> is required` → that variable is present but **empty**. `config.Load()`
      validates `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET`, `google_oauth_redirect_url`
      and `ENCRYPTION_KEY` unconditionally, before anything checks whether this service has auth
      routes — it does not, and they remain mandatory. `make logs`
- [ ] The name is `google_oauth_redirect_url` → different cause. That value comes from the
      embedded `production.yaml`, not the environment, so an empty one means the image was built
      from a modified config. No manifest change can fix it.
- [ ] A missing Secret and an empty value fail **differently**: missing → `CreateContainerConfigError`
      (Phase 4), empty → `CrashLoopBackOff` with a named variable here.
- [ ] `/api/v1/health` returns an `env` that is not `production` → `APP_ENV` did not select the
      embedded `production.yaml`. This is the only externally observable proof of which config
      was loaded.

---

## Phase 6 — Workload Identity and the Cloud SQL proxy

- [ ] Proxy logs `Unable to generate access token; IAM returned 403 Forbidden: Permission
      'iam.serviceAccounts.getAccessToken' denied` → the **KSA→GSA** binding is missing. This is
      the half of the chain that is easy to skip, because the two bindings point in opposite
      directions.
      `gcloud iam service-accounts get-iam-policy "$GSA" --format=json | grep workloadIdentityUser`
- [ ] Proxy logs `failed to get instance: ... PermissionDenied` → the **GSA** lacks
      `roles/cloudsql.client`. Different binding, different direction.
      `gcloud projects get-iam-policy "$P" --flatten='bindings[].members' --filter="bindings.members:$GSA" --format='value(bindings.role)'`
- [ ] Cloud SQL rejects an account you never configured, named `…-compute@developer.gserviceaccount.com`
      → the pod fell back to the **node's** identity. The node SA cannot work here even holding
      `roles/editor`: its OAuth *scopes* exclude `sqladmin`, and scopes cap a token regardless of
      IAM.
- [ ] The KSA annotation is absent or misspelled →
      `kubectl -n recommendations get sa recommendations-service -o jsonpath='{.metadata.annotations.iam\.gke\.io/gcp-service-account}'`
- [ ] The `workloadIdentityUser` member string embeds **namespace and KSA name**
      (`PROJECT.svc.id.goog[recommendations/recommendations-service]`). A typo in either is
      silent — no error, just the node identity.
- [ ] `metadata: GCE metadata "instance/service-accounts/default/token" not defined` → Workload
      Identity is not active on the node pool. Note that changing node-pool metadata mode
      **recreates nodes**.
- [ ] `Cloud SQL Admin API has not been used` → the API is disabled on the project.
- [ ] The proxy logs `started successfully` and you conclude Workload Identity works → it does
      not prove that. The proxy resolves credentials lazily; no token is minted until the first
      real connection, so startup succeeds and the 403 appears only once the app dials it.
- [ ] Confirm the identity the pod **actually** got, which is the only check that settles the
      above: `kubectl -n recommendations exec deploy/recommendations-service -c cloud-sql-proxy -- curl -s -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email'`
- [ ] A new IAM binding does not take effect immediately → propagation takes a minute or two. One
      further crash cycle after `make restart` is not necessarily failure.

---

## Phase 7 — The proxy sidecar itself

- [ ] Proxy restarts on a fixed cycle, exit code **143**, logs otherwise clean → 143 is 128 + 15;
      the kubelet killed it. The proxy is healthy and its **startup probe** is failing.
- [ ] The startup probe needs all four of these to agree: `--health-check` (turns the health
      server on at all), `--http-address=0.0.0.0`, `--http-port=9090`, and
      `httpGet: { path: /startup, port: 9090 }`.
- [ ] A `tcpSocket` probe on 5432 can **never** pass → the kubelet dials the pod IP from outside
      the pod's network namespace, while the DB tunnel binds `127.0.0.1` only, by design.
- [ ] `Startup probe failed: connection refused` appearing once or twice at container start →
      expected noise, not a fault. The probe fires before the proxy has bound its port; it is
      only a failure once the threshold is exhausted.
- [ ] The app wins the startup race and dies before the proxy is ready → the proxy must be a
      **native sidecar** (`initContainers` + `restartPolicy: Always`), not an ordinary container.
      `db.Connect` pings the pool and `main.go` calls `log.Fatalf` on failure, so the app exits
      rather than retrying. Requires Kubernetes 1.29+.
- [ ] Proxy logs `SIGTERM signal received` straight after `ready for new connections` → same
      startup-probe cause as above, not a shutdown bug.

---

## Phase 8 — Database connection and schema

- [ ] `database: db: ping …` then `log.Fatalf` → the app reached `db.Connect` and the Ping failed.
      The rest of the message names the cause — match it against the five boxes below.
- [ ] `connection refused` on `127.0.0.1:5432` → the proxy is not listening at all. Phase 7, and
      check `DB_PORT` matches the proxy's `--port`.
- [ ] `connection reset by peer` → the proxy is listening but cannot reach Cloud SQL. Phase 6.
- [ ] `password authentication failed` → `DB_PASSWORD` is wrong, or the user's password was
      rotated out from under the Secret.
- [ ] `database "…" does not exist` → `DB_NAME` names a database not on the instance.
      `gcloud sql databases list --instance=<instance>`
- [ ] The logged host is **not** `127.0.0.1` → `DATABASE_URL` is set somewhere and *overrides* the
      whole `DB_*` block. Remove it from the ConfigMap.

- [ ] The logged target comes from `RedactedDatabaseTarget()` (host, port, name only) and is
      derived from `DATABASE_URL` when set → the fastest way to spot that override breaking.
- [ ] Rotating the instance's `postgres` password affects **every service sharing that instance**,
      since it is the same superuser. A per-service database user avoids this.
- [ ] `/api/v1/health` is 200 but `/api/v1/places` is 500 → the deploy is fine and the **schema**
      is not. `healthCheck` marshals config strings and never touches the pool, so it cannot
      detect a missing table. `make logs` — look for `relation "gm_places" does not exist`.
- [ ] You expect the service repo to create the table → it ships no migrations. The `migrate` and
      `seed` targets point at directories that are not in the repo, so whatever creates
      `gm_places` lives elsewhere.
- [ ] A green `/health` is taken as a successful deploy → it is compatible with an empty
      database. `GET /api/v1/places` is the first request that proves the schema.

---

## Phase 9 — Reaching the service

- [ ] `EXTERNAL-IP` stuck at `<pending>` → normal for a minute or two while the forwarding rule
      provisions. Beyond that: `kubectl -n recommendations describe svc recommendations-service | grep -A10 Events`
- [ ] `curl` hangs or 502s → check the EndpointSlice is non-empty:
      `kubectl -n recommendations get endpointslice -l kubernetes.io/service-name=recommendations-service -o jsonpath='{.items[*].endpoints[*].addresses}{"\n"}'`
- [ ] Empty EndpointSlice → the Service matches no **ready** pod. Either the pod is not Ready
      (go back up this page), or `service.selector` does not equal the pod labels, or
      `service.targetPort` does not match the container's port **name**.
- [ ] Endpoint present and still 502 → the port the process bound does not match
      `containerPort`. `containerPort` is informational; the process binds whatever `PORT` says.
      Confirm against the `listening on :<port>` log line.
- [ ] A browser gets a CORS error while `curl` succeeds → expected. `FRONTEND_URL` is passed
      straight in as the **single** permitted origin; `curl` and the kubelet probes send no
      `Origin` header and pass through untouched. It must be the SPA's exact origin — scheme,
      host and port, no path, no trailing slash.

---

## Phase 10 — Changes that appear to do nothing

- [ ] A `configmap.yaml` edit has no effect → there is no `configMapGenerator`, so the ConfigMap
      has no name hash, so the pod template does not change, so no rollout triggers and the
      running pod keeps its old environment. A restart is required **every time**:
      `make apply-config`
- [ ] A Secret edit has no effect → same mechanism. Replace the Secret, then `make restart`.
- [ ] `kubectl exec ... -- env` fails → the image is distroless: no shell, no `env` binary. Read
      the ConfigMap and compare against the pod's start time instead:
      `kubectl -n recommendations get pod -l app=recommendations-service -o jsonpath='{.items[0].status.startTime}{"\n"}'`
      If the pod started before your edit, it does not have it.
- [ ] `rollout undo` appears to change nothing → it is only meaningful because images are
      digest-pinned. With a floating tag, undo re-pulls whatever that tag points at today.
- [ ] The pod vanished and came back on its own → if the node pool is **spot**, preemption is
      normal and expected, and with `replicas: 1` it is a short full outage.
      `kubectl get events -A --field-selector reason=Preempted`
