# Parameter citation index — `k8s/auth-service/`

Every parameter in the manifest set, linked to its authoritative source.

This is the **citation layer**. It answers "where is this documented and what exactly does the
spec say?" The *reasoning* — why each value was chosen for this service, and the cross-file
invariants — lives in [manifest-reference.md](./manifest-reference.md). Use them together.

Verified 2026-10-28 against upstream Kubernetes and Google Cloud docs. Cluster target: **GKE
1.36**.

---

## ⚠️ Corrections this research forced

Two claims in the earlier docs were wrong. Both are now fixed here and in
`manifest-reference.md`:

| Claim previously made | Actually |
| --- | --- |
| Native sidecars "GA in 1.29" | **Stable since v1.33**, first available (alpha) in v1.28, on-by-default in v1.29. GKE 1.36 is comfortably past it, so the manifest is fine — but the version I cited was wrong. [Source](https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/) |
| The `iam.gke.io/gcp-service-account` annotation is *the* way to do Workload Identity | It is now documented as the **"Alternative"** method. Google's current recommendation is to reference the Kubernetes ServiceAccount **directly as an IAM principal**, no annotation and no intermediate Google service account. The annotation is not marked deprecated and still works. [Source](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/workload-identity) |

**Keep the annotation anyway.** Google's own Cloud SQL-on-GKE guide still uses it, and the
newer principal-identifier path carries per-API limitations that I could not confirm cover
Cloud SQL (see [gaps](#unverified--gaps)). Matching Google's working example beats being
first to the new syntax. Revisit if you add more Google APIs.

---

## A. Kubernetes core

### Objects and metadata

| Parameter | Source |
| --- | --- |
| `Namespace` v1, `metadata.name` | [Namespaces](https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/) |
| `ServiceAccount` v1 | [ServiceAccounts](https://kubernetes.io/docs/concepts/security/service-accounts/) |
| `metadata.annotations` | [Annotations](https://kubernetes.io/docs/concepts/overview/working-with-objects/annotations/) |
| `app.kubernetes.io/*` labels | [Recommended labels](https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/) |

### ConfigMap and environment

| Parameter | Source | Note |
| --- | --- | --- |
| `ConfigMap.data` | [ConfigMaps](https://kubernetes.io/docs/concepts/configuration/configmap/) | |
| `envFrom.configMapRef` / `secretRef` | [Define env vars from ConfigMaps](https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/) | |
| **env vars do not hot-reload** | [ConfigMaps § updates](https://kubernetes.io/docs/concepts/configuration/configmap/) | ✅ **Verified.** Env vars "are not updated when the source data changes"; a Pod replacement is required. Mounted volumes *do* update, with delay = kubelet sync period (1 min default) + ConfigMap cache TTL (1 min default). This is why a ConfigMap edit needs `rollout restart`. |

### Deployment

| Parameter | Source | Note |
| --- | --- | --- |
| `apps/v1 Deployment` | [Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/) | |
| `spec.replicas` | [Deployment § replicas](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#replicas) | |
| `spec.selector.matchLabels` | [Deployment § selector](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#selector) | Immutable in `apps/v1` once created. Drives the `includeSelectors` choice in [§B](#b-kustomize). |
| `strategy.type: RollingUpdate` | [Deployment § strategy](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#strategy) | |
| `rollingUpdate.maxUnavailable` | [§ Max Unavailable](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#max-unavailable) | |
| `rollingUpdate.maxSurge` | [§ Max Surge](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#max-surge) | With `replicas: 1` + `maxSurge: 1`, a rollout needs room for 2 pods — relevant on a 1-node cluster. |

### Security context

| Parameter | Source | Note |
| --- | --- | --- |
| `securityContext` (pod + container) | [Configure a Security Context](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/) | |
| `runAsNonRoot` | [§ set the security context for a Pod](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/#set-the-security-context-for-a-pod) | |
| `runAsUser` | same | Left unset deliberately — the distroless `:nonroot` tag supplies numeric UID 65532. |
| `allowPrivilegeEscalation` | [§ privilege escalation](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/#set-capabilities-for-a-container) | |
| `readOnlyRootFilesystem` | [Pod API reference](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/) | |
| `capabilities.drop` | [§ set capabilities](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/#set-capabilities-for-a-container) | |
| `seccompProfile.type: RuntimeDefault` | [Restrict syscalls with seccomp](https://kubernetes.io/docs/tutorials/security/seccomp/) | |
| Pod Security Standards | [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/) | ⚠️ See [gaps](#unverified--gaps) — I could not verify which fields `restricted` requires. |

### Container

| Parameter | Source | Note |
| --- | --- | --- |
| `image` | [Images](https://kubernetes.io/docs/concepts/containers/images/) | |
| `imagePullPolicy` | [Images § imagePullPolicy](https://kubernetes.io/docs/concepts/containers/images/#image-pull-policy) | |
| digest pinning | [Images § image names](https://kubernetes.io/docs/concepts/containers/images/#image-names) | |
| `ports[].name` | [Service § named ports](https://kubernetes.io/docs/concepts/services-networking/service/) | Lets `targetPort` and probes reference `http` instead of a number. |
| **`ports[].containerPort` is informational** | [Pod API reference](https://kubernetes.io/docs/reference/kubernetes-api/core/pod-v1/) | ✅ **Verified, verbatim:** *"Not specifying a port here does not prevent that port from being exposed. Any port which is listening on the default `0.0.0.0` address inside a container will be accessible from the network."* This is precisely why the earlier `PORT: 9999` vs `containerPort: 8080` mismatch surfaced as a dead probe rather than a bind error. Both are now `9999`. |

### Resources

| Parameter | Source | Note |
| --- | --- | --- |
| `resources.requests` / `.limits` | [Resource Management](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/) | |
| CPU is compressible | [§ CPU resource units](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/#meaning-of-cpu) | Over-limit CPU is **throttled**. |
| Memory is not | [§ memory](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/#meaning-of-memory) | Over-limit memory is an **OOMKill** — a hard kill, not throttling. |
| QoS classes | [Pod QoS](https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/) | Requests ≠ limits here, so these pods are **Burstable** — evicted before Guaranteed pods under node pressure. |

### Probes

| Parameter | Source | Note |
| --- | --- | --- |
| `livenessProbe`, `readinessProbe`, `startupProbe` | [Configure Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/) | |
| **liveness/readiness suspended during startup** | [Pod Lifecycle § startup probe](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#when-should-you-use-a-startup-probe) | ✅ **Verified.** Liveness and readiness do not run until the startup probe succeeds; on startup-probe failure the container is killed. Without a startupProbe, a slow boot looks like a liveness failure and the pod is killed mid-start, forever. |
| `httpGet`, `tcpSocket` | [§ probe handlers](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#probe-handlers) | |
| `periodSeconds`, `timeoutSeconds`, `failureThreshold` | [§ configure probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/#configure-probes) | |

### Native sidecars

| Parameter | Source | Note |
| --- | --- | --- |
| `initContainers` + `restartPolicy: Always` | [Sidecar Containers](https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/) | ✅ **Stable since v1.33**; first available v1.28; on-by-default v1.29. Not 1.29 GA as I previously wrote. |
| Ordering guarantee | [Init Containers](https://kubernetes.io/docs/concepts/workloads/pods/init-containers/) | ✅ **Verified:** *"Sidecar containers start before the main application container but continue to run."* This is the guarantee the design depends on — `main.go` pings the DB at boot and `log.Fatalf`s, so the proxy must already be listening. |
| `restartPolicy` is what makes it a sidecar | [Sidecar Containers](https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/) | Omit it and the container must *exit* for startup to proceed — a proxy never exits, so the pod would hang in `Init` forever. |
| Probes on sidecars | same | A sidecar's `startupProbe` is what makes its `started` status mean *listening* rather than merely *process running*. |
| Background | [v1.28 announcement](https://kubernetes.io/blog/2023/08/25/native-sidecar-containers/) · [Start Sidecar First](https://kubernetes.io/blog/2025/06/03/start-sidecar-first/) | The second post is specifically about the startup race this manifest avoids. |

### Service

| Parameter | Source | Note |
| --- | --- | --- |
| `Service` v1, `spec.selector` | [Service](https://kubernetes.io/docs/concepts/services-networking/service/) | Matches **pod template** labels, not the Deployment's own. |
| `spec.type: LoadBalancer` | [§ LoadBalancer](https://kubernetes.io/docs/concepts/services-networking/service/#loadbalancer) | |
| `ports[].port` / `targetPort` | [§ defining a Service](https://kubernetes.io/docs/concepts/services-networking/service/) | `targetPort` may name a container port: *"Port definitions in Pods have names, and you can reference these names in the `targetPort` attribute of a Service."* |
| `protocol` | [§ protocols](https://kubernetes.io/docs/reference/networking/service-protocols/) | |
| `sessionAffinity` | [Service API reference](https://kubernetes.io/docs/reference/kubernetes-api/service-resources/service-v1/) | Not set — sessions live in Postgres, so any pod can serve any user. |

---

## B. Kustomize

| Parameter | Source | Note |
| --- | --- | --- |
| `kustomize.config.k8s.io/v1beta1`, `kind: Kustomization` | [Kustomization reference](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/) | |
| `namespace` | [§ namespace](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/namespace/) | |
| `resources` | [§ resources](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/resource/) | |
| `labels` + `includeSelectors` | [§ labels](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/labels/) | ✅ **Verified:** `commonLabels` is deprecated in kustomize v5+; `labels` replaces it. `labels` is **metadata-only unless `includeSelectors: true`**, which makes it semantically identical to `commonLabels`. |
| `commonLabels` (deprecated) | [§ commonLabels](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/commonlabels/) · [kustomize#6200](https://github.com/kubernetes-sigs/kustomize/pull/6200) | |
| `secretGenerator` | [§ secretGenerator](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/secretgenerator/) | The alternative deliberately not used — it would need plaintext in the repo. |

### On `includeSelectors: false` — a correction of emphasis

My earlier note framed `false` as unconditionally the safe choice. More precisely, the
immutability hazard cuts **both ways**:

- For a **new** Deployment (our case), `false` is right: it keeps extra labels out of the
  immutable selector, so future label changes stay free.
- For an **existing** Deployment already created with `commonLabels`, switching *to* `false`
  attempts to **remove** labels from the selector and `kubectl apply` fails. Those must migrate
  to `labels` with `includeSelectors: **true**` to stay byte-identical.

Since `auth-service` has never been applied, `false` is correct and costs nothing.

---

## C. GKE and Google Cloud

### Workload Identity Federation for GKE

| Parameter | Source | Note |
| --- | --- | --- |
| Overview + both binding styles | [Authenticate to Google Cloud APIs from GKE workloads](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/workload-identity) | |
| **Current recommended**: direct IAM principal | same | `principal://iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/PROJECT_ID.svc.id.goog/subject/ns/NAMESPACE/sa/KSA_NAME` — no annotation, no intermediate GSA. |
| **In use here**: `iam.gke.io/gcp-service-account` annotation | same | Documented as the "Alternative". Member string: `serviceAccount:PROJECT_ID.svc.id.goog[NAMESPACE/KSA_NAME]` — ours is `vincent-mini-apps-project.svc.id.goog[auth/auth-service]`. Needs `roles/iam.workloadIdentityUser`. |
| `--workload-pool=PROJECT_ID.svc.id.goog` | same | Cluster-level enablement. |
| `--workload-metadata=GKE_METADATA` | same | Node-pool level; recreates nodes. |
| Terminology | [Make IAM for GKE easier](https://cloud.google.com/blog/products/identity-security/make-iam-for-gke-easier-to-use-with-workload-identity-federation) | Renamed "Workload Identity" → "Workload Identity Federation for GKE". The new path cuts setup from six steps to three. |
| Troubleshooting | [Troubleshoot GKE authentication](https://cloud.google.com/kubernetes-engine/docs/troubleshooting/authentication) | |

### Cloud SQL Auth Proxy v2

| Parameter | Source | Note |
| --- | --- | --- |
| Connect from GKE | [Connect to Cloud SQL for PostgreSQL from GKE](https://docs.cloud.google.com/sql/docs/postgres/connect-kubernetes-engine) | ✅ **Vindicates the native-sidecar choice, verbatim:** *"Add the Cloud SQL Auth Proxy to the pod configuration under `initContainers`, unless you're using Cloud Service Mesh or Istio. If you're using Cloud Service Mesh or Istio, then add the Cloud SQL Auth Proxy under the `containers` section instead."* Google's example even pins the same `2.14.1` tag we use. |
| `--port`, `--structured-logs` | same | Both appear in Google's own example. |
| `--credentials-file` | [Proxy flag reference](https://github.com/GoogleCloudPlatform/cloud-sql-proxy#readme) | Deliberately **not** used — Workload Identity supplies the token. |
| Instance connection name `project:region:instance` | [About the Auth Proxy](https://docs.cloud.google.com/sql/docs/postgres/sql-proxy) | Resolved via the Cloud SQL Admin API, not DNS — which is why `sqladmin.googleapis.com` must be enabled. |
| `roles/cloudsql.client` | [Connect from GKE](https://docs.cloud.google.com/sql/docs/postgres/connect-kubernetes-engine) | Google additionally lists `roles/cloudsql.instanceUser` **for IAM database authentication**. We use password auth, so `client` alone suffices. |
| Startup race | — | ⚠️ Google's page does **not** discuss it. The native-sidecar ordering guarantee from [§A](#native-sidecars) is what actually protects us. |

### Node access scopes vs IAM

| Parameter | Source | Note |
| --- | --- | --- |
| Access scopes in GKE | [Access scopes in GKE](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/access-scopes) | ✅ **Verified — the justification for using Workload Identity at all:** access scopes *"potentially further limit access to API methods when authenticating with Application Default Credentials."* So this cluster's node scopes (`devstorage.read_only`, `logging.write`, `monitoring`) cap what a node token can do **regardless** of the node SA holding `roles/editor`. Scopes are described as "the legacy method"; IAM/RBAC is recommended instead. |
| About GKE service accounts | [About service accounts in GKE](https://cloud.google.com/kubernetes-engine/docs/how-to/service-accounts) | |

### Artifact Registry

| Parameter | Source | Note |
| --- | --- | --- |
| Access control / `roles/artifactregistry.reader` | [Artifact Registry access control](https://docs.cloud.google.com/artifact-registry/docs/access-control) | ⚠️ I did not confirm that `devstorage.read_only` is officially documented as sufficient for Artifact Registry **reads**. It works in practice. If a pull fails, grant the reader role explicitly — see [troubleshooting](./troubleshooting.md). |

### GKE Ingress and managed TLS (Phase 2)

| Parameter | Source |
| --- | --- |
| GKE Ingress | [GKE Ingress for HTTP(S) Load Balancing](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/ingress) |
| `ManagedCertificate` / `networking.gke.io/managed-certificates` | [Google-managed SSL certificates](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/managed-certs) |
| `kubernetes.io/ingress.global-static-ip-name` | [Static IPs for Ingress](https://docs.cloud.google.com/kubernetes-engine/docs/tutorials/configuring-domain-name-static-ip) |
| Ingress health checks | [Ingress health checks](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/ingress#health_checks) |

---

## Unverified / gaps

Listed rather than papered over. Each is a claim in the docs that I could **not** confirm
against an authoritative source in this pass — none blocks Phase 1.

| Claim | Status |
| --- | --- |
| Which fields the PSS **`restricted`** profile requires — specifically whether `readOnlyRootFilesystem` is among them | **UNVERIFIED.** The page truncated on fetch and the summarizer then asserted it *is* required; I believe that is wrong (`restricted` covers `runAsNonRoot`, `allowPrivilegeEscalation`, `capabilities`, `seccompProfile`, but not the root filesystem). Not cited either way. Our manifest sets it regardless, so nothing depends on the answer. |
| Whether Cloud SQL supports the newer **direct principal** Workload Identity path, or needs the annotation | **INCONCLUSIVE.** Search results conflated *Workforce* Identity Federation (human users) with *Workload* Identity Federation (workloads). Moot in practice — we match Google's own annotation-based Cloud SQL example. |
| `devstorage.read_only` officially sufficient for Artifact Registry reads | **NOT CONFIRMED.** Empirically true. |
| GKE 1.36 → upstream Kubernetes minor version mapping | **NOT CHECKED.** Native sidecars went stable in 1.33, so 1.36 is clear by any reading. |
| GKE Ingress backend health check derived from `readinessProbe` | **NOT CONFIRMED** at the deep-link level. Widely documented behavior; Phase 2 concern only. |
| Autopilot vs Standard differences for hardened pod specs | **NOT CHECKED.** This cluster is Standard. |

---

## Sources

Kubernetes: [Sidecar Containers](https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/) ·
[Init Containers](https://kubernetes.io/docs/concepts/workloads/pods/init-containers/) ·
[Pod Lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/) ·
[Pod API reference](https://kubernetes.io/docs/reference/kubernetes-api/core/pod-v1/) ·
[ConfigMaps](https://kubernetes.io/docs/concepts/configuration/configmap/) ·
[Service](https://kubernetes.io/docs/concepts/services-networking/service/) ·
[Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/) ·
[Security Context](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/) ·
[Resource Management](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/) ·
[Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/) ·
[Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/) ·
[v1.28 sidecars](https://kubernetes.io/blog/2023/08/25/native-sidecar-containers/) ·
[Start Sidecar First](https://kubernetes.io/blog/2025/06/03/start-sidecar-first/)

Kustomize: [Kustomization reference](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/) ·
[kustomize#6200](https://github.com/kubernetes-sigs/kustomize/pull/6200)

Google Cloud: [Workload Identity for GKE](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/workload-identity) ·
[Connect to Cloud SQL from GKE](https://docs.cloud.google.com/sql/docs/postgres/connect-kubernetes-engine) ·
[Cloud SQL Auth Proxy](https://docs.cloud.google.com/sql/docs/postgres/sql-proxy) ·
[Access scopes in GKE](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/access-scopes) ·
[GKE service accounts](https://cloud.google.com/kubernetes-engine/docs/how-to/service-accounts) ·
[Artifact Registry access control](https://docs.cloud.google.com/artifact-registry/docs/access-control) ·
[GKE Ingress](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/ingress) ·
[Managed certificates](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/managed-certs) ·
[IAM for GKE blog](https://cloud.google.com/blog/products/identity-security/make-iam-for-gke-easier-to-use-with-workload-identity-federation)
