# Phase 2 — Domain, TLS, and working Google login

**Goal:** `auth-service` on HTTPS at a real hostname, with Google sign-in completing end to end.

**Blocked on you:** a hostname. Google **rejects raw IP addresses as OAuth redirect URIs**, so
there is no version of this phase that works off the Phase 1 LoadBalancer IP. Everything below
uses `auth.example.com` as a placeholder — substitute yours.

**Requires a code change and a `0.0.2` image.** Phase 1 did not.

---

## 2.1 Make the OAuth redirect URL configurable

### The problem

`internal/platform/config/production.yaml`:

```yaml
auth:
  google_oauth_redirect_url: http://localhost:9999/api/v1/auth/google/callback
```

That file is compiled into the binary by `//go:embed` in `config.go`. And `Load()` overrides
`BASE_URL` and `FRONTEND_URL` from the environment — but never `google_oauth_redirect_url`,
even though all three are deployment-specific host values. That inconsistency is the actual
bug; no amount of YAML can fix it from outside the image.

### The fix

In `internal/platform/config/config.go`, next to the existing `BASE_URL` / `FRONTEND_URL` lines,
reusing the `envOr` helper already defined at the bottom of that file:

```go
config.Auth.GoogleOAuthRedirectURL = envOr("GOOGLE_OAUTH_REDIRECT_URL",
    config.Auth.GoogleOAuthRedirectURL)
```

The second argument is the embedded YAML value, so local development keeps working unchanged
with no `.env` edit. The required-vars loop further down already fails fast on an empty value,
so no new validation is needed.

Add `GOOGLE_OAUTH_REDIRECT_URL` to `.env.example` while you're there, so the next person sees it.

**Verify locally before building:**

```bash
cd ../auth-be
GOOGLE_OAUTH_REDIRECT_URL=https://auth.example.com/api/v1/auth/google/callback make api
# startup should succeed; hit /api/v1/auth/google/login and check the
# redirect_uri= parameter in the Location header reflects the new value
```

---

## 2.2 Build and push `0.0.2`

The `Makefile`'s `AR_IMAGE` has been corrected to
`.../auth-repository/auth-service` (it previously pointed at a `mini-apps/auth-be` path that
holds no images).

```bash
cd ../auth-be
make ar-login          # one-time: gcloud auth configure-docker
make image-push TAG=0.0.2
```

`--platform linux/amd64` is already in the target and is **not optional** — your Mac is arm64,
the nodes are `e2-medium` amd64, and a native build dies on the node with `exec format error`.

**Verify, and capture the digest for the manifest:**

```bash
gcloud artifacts docker images list \
  asia-southeast1-docker.pkg.dev/vincent-mini-apps-project/auth-repository/auth-service \
  --include-tags --filter="tags:0.0.2"
```

---

## 2.3 Reserve a static IP

GKE Ingress needs a **global** address (it provisions a global HTTP(S) load balancer). A
regional address will be rejected.

```bash
gcloud compute addresses create auth-service-ip --global
gcloud compute addresses describe auth-service-ip --global --format='value(address)'
```

Note the IP. Reserving it first means DNS and the certificate can be set up in parallel, and the
address survives Ingress deletion.

---

## 2.4 Point DNS at it

Create an **A record**: `auth.example.com` → the reserved IP.

**Verify before continuing** — the managed certificate will not issue until DNS resolves, and a
failed issuance is slow to retry:

```bash
dig +short auth.example.com      # must return your reserved IP
```

---

## 2.5 Switch to Ingress + managed TLS

Three manifest changes:

1. In `k8s/auth-service/service.yaml`, change `type: LoadBalancer` to `type: NodePort`. The
   Ingress fronts the service now; leaving it a LoadBalancer would provision a second,
   redundant, billed load balancer.

2. Add `k8s/auth-service/managedcertificate.yaml`:

```yaml
apiVersion: networking.gke.io/v1
kind: ManagedCertificate
metadata:
  name: auth-service-cert
  namespace: auth
spec:
  domains:
    - auth.example.com
```

3. Add `k8s/auth-service/ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: auth-service
  namespace: auth
  annotations:
    kubernetes.io/ingress.class: "gce"
    kubernetes.io/ingress.global-static-ip-name: "auth-service-ip"
    networking.gke.io/managed-certificates: "auth-service-cert"
    # Redirect plain HTTP to HTTPS. Without this, http:// stays reachable and
    # the HSTS header the app sets under APP_ENV=production is doing nothing.
    kubernetes.io/ingress.allow-http: "false"
spec:
  rules:
    - host: auth.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: auth-service
                port:
                  name: http
```

Then add both files to `resources:` in `kustomization.yaml`.

The cluster's `httpLoadBalancing` addon is already enabled, so no cluster change is needed.

### A note on the health check

GKE Ingress derives its backend health check from the pod's **readiness probe**, which already
points at `/api/v1/health`. That works out, but it is worth knowing: if the readiness probe path
ever changes, the load balancer's health check follows it, and a mismatch there shows up as a
confusing `502` with healthy-looking pods.

---

## 2.6 Update config and roll out

```bash
# in k8s/auth-service/configmap.yaml
BASE_URL: "https://auth.example.com"
GOOGLE_OAUTH_REDIRECT_URL: "https://auth.example.com/api/v1/auth/google/callback"
FRONTEND_URL: "https://<your-spa-origin>"
```

`FRONTEND_URL` does **two** jobs — it is the post-login redirect target *and* the single allowed
CORS origin (`main.go` passes it straight into `cors.Options{AllowedOrigins: ...}` with
`AllowCredentials: true`). One wrong value breaks login and every XHR at once, with the CORS
failure visible only in the browser console.

Bump the image in `deployment.yaml` to `0.0.2` with its new digest, then:

```bash
kubectl apply -k k8s/auth-service
kubectl -n auth rollout status deploy/auth-service
```

---

## 2.7 Register the callback with Google

In the GCP console → **APIs & Services → Credentials** → your OAuth 2.0 client ID, add to
**Authorized redirect URIs**:

```
https://auth.example.com/api/v1/auth/google/callback
```

It must match **byte for byte** — scheme, host, path, no trailing slash. Google compares the
string exactly, and a mismatch returns `redirect_uri_mismatch` rather than anything that hints
at which character differs.

Add your SPA origin to **Authorized JavaScript origins** too, if the frontend initiates login.

---

## 2.8 Verify

Certificate first — this is the slow part, typically 10–20 minutes, occasionally up to an hour:

```bash
kubectl -n auth describe managedcertificate auth-service-cert
# Status: Active   (Provisioning is normal for a while; FailedNotVisible means DNS is wrong)
```

Then:

```bash
curl -sS https://auth.example.com/api/v1/health
# => {"ok":true,"env":"production"}

curl -sI https://auth.example.com/api/v1/health | grep -i strict-transport
# HSTS present — the app enables it automatically under APP_ENV=production,
# which is only correct now that TLS is genuinely in front.
```

Finally, the real test — in a browser:

1. Visit `https://auth.example.com/api/v1/auth/google/login`
2. Complete the Google consent screen
3. You land back on `FRONTEND_URL` with session + CSRF cookies set
4. `GET https://auth.example.com/api/v1/me` returns your user

Step 4 is the one that proves the whole chain: session cookie → DB lookup through the proxy →
authenticated response.

---

## Phase 2 exit checklist

- [ ] `GOOGLE_OAUTH_REDIRECT_URL` override merged; `0.0.2` pushed as amd64
- [ ] Static IP reserved, A record resolves to it
- [ ] `ManagedCertificate` is `Active`
- [ ] `https://.../api/v1/health` returns 200 with an HSTS header
- [ ] Browser login round-trips and `/api/v1/me` returns the user
