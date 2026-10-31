# Making room for the pod — the three CPU options compared

`recommendations-service` cannot be scheduled on the cluster as it stands. This document is the
decision record for *how* to fix that: what each option actually buys, what it costs, and why the
recommendation is a two-step sequence rather than a single choice.

**Verified:** 2026-10-31 against `vincent-mini-apps-project` / `vincent-cluster`, live cluster.

Narrower views of the same facts: [prerequisites.md §3.2](./prerequisites.md#32-blocker-the-node-has-no-room-for-this-pod)
(the blocker as a prerequisite) · [deploy.md step 1](./deploy.md#step-1--make-room-on-the-cluster-blocker)
(the command to run) · [troubleshooting.md](./troubleshooting.md) (the symptom).

> ### Naming, because the letters collide
> [prerequisites.md §3.2](./prerequisites.md#32-blocker-the-node-has-no-room-for-this-pod) already
> lettered these options **A/B/C**, and its letters are **not** the ones used in the chat thread
> this document came from. To avoid a costly mix-up, the options here are **named**:
>
> | This document | §3.2 letter | Chat thread letter |
> | --- | --- | --- |
> | **Scale out** — add a second `e2-medium` | A | A |
> | **Scale up** — recreate the pool as `e2-standard-2` | B | C |
> | **Shrink requests** — lower the pod's CPU requests | C | B |
>
> Quote the **name** in commits and reviews, never the bare letter.

---

## The symptom

```
$ kubectl -n recommendations rollout status deploy/recommendations-service --timeout=5m
error: deployment "recommendations-service" exceeded its progress deadline
```

`rollout status` is only reporting a stalled wait; the real message is on the pod:

```
$ kubectl -n recommendations describe pod -l app=recommendations-service | sed -n '/^Events/,$p'
Warning  FailedScheduling    0/1 nodes are available: 1 Insufficient cpu.
                             preemption: 0/1 nodes are available: No preemption victims found.
Normal   NotTriggerScaleUp   (x92) Pod didn't trigger scale-up:
```

The pod is `Pending` and was never assigned to a node, so no container ever started and there are
no application logs to read. `NotTriggerScaleUp` repeating with an empty reason is autoscaling
being **off** on `minimal-pool` — nothing is coming to rescue it.

One misleading detail in `describe deploy`: the `Available` condition reads
`True / MinimumReplicasAvailable` even with zero pods running. With `replicas: 1` and
`maxUnavailable: 1`, zero available replicas *does* satisfy the minimum. Only the `Progressing`
condition (`False / ProgressDeadlineExceeded`) reports the failure. Do not read `Available: True`
as "the service is up".

---

## The ledger

Measured on the live node, not estimated:

| | CPU requests |
| --- | --- |
| `e2-medium` allocatable | **940m** |
| Per-node DaemonSets + `kube-proxy` (fluentbit 105m, gke-metadata-server 100m, kube-proxy 100m, node-local-dns 30m, gke-metrics-agent 21m, pdcsi 15m, netd 8m, gmp collector 7m) | 386m |
| Once-per-cluster system pods (kube-dns 110m, kube-state-metrics 105m, metrics-server 43m, kube-dns-autoscaler 20m, konnectivity 25m, l7-default-backend 10m, event-exporter 3m, gmp-operator 1m) | 317m |
| `auth-service` pod (100m app + 50m proxy) | 150m |
| **Total requested** | **853m (90%)** |
| **Free** | **87m** |
| `recommendations-service` needs (100m app + 50m proxy) | **150m** |
| **Shortfall** | **−63m** |

```bash
# reproduce the total
kubectl describe node -l cloud.google.com/gke-nodepool=minimal-pool \
  | sed -n '/Allocated resources/,/^Events/p'
# cpu  853m (90%)
```

**Requests decide this, not usage.** The node is nowhere near 90% busy — the scheduler refuses on
a reservation ledger. "But the CPU is idle" is true and irrelevant.

### The per-node tax is what makes this interesting

Splitting the system total by *whether it is replicated onto every node* is the number that
decides between the options:

| | Cost per **node** | Cost per **cluster** |
| --- | --- | --- |
| DaemonSets + `kube-proxy` | **386m** | — |
| kube-dns, kube-state-metrics, metrics-server, konnectivity, … | — | **317m** |

Every GKE node pays a flat ~386m DaemonSet tax before running any of your code. On a 940m
`e2-medium` that is **41% of the node gone on arrival**; on a 1930m `e2-standard-2` the identical
tax is **20%**. For a cluster this small, fewer-and-larger nodes is not a style preference — it is
strictly more usable capacity for the same spend.

---

## The three options

| Option | Usable for your workloads | ~150m services it fits | Relative node cost |
| --- | --- | --- | --- |
| *today* — 1× `e2-medium` | 237m | 1 (+87m stranded) | 1× |
| **Scale out** — 2× `e2-medium` | 87m + 554m = **641m** | 4 | **2×** |
| **Scale up** — 1× `e2-standard-2` | **1227m** | 8 | **2×** |
| **Shrink requests** — 1× `e2-medium`, smaller requests | 237m | 2, with 12m spare | 1× |

### Scale out — add a second `e2-medium`

```bash
gcloud container clusters resize vincent-cluster \
  --node-pool minimal-pool --num-nodes 2 \
  --zone asia-southeast1-a
```

Additive and non-destructive: the existing node and its pods are untouched, and the pool keeps its
`GKE_METADATA` setting. Takes ~2 min. A fresh `e2-medium` carries only the 386m of per-node
DaemonSets, leaving ~554m free.

**Why this is the weakest of the three.** It costs the same as *Scale up* and delivers roughly half
the usable CPU, because the 386m tax is paid twice instead of once. It also strands the 87m sliver
on node 1 permanently — too small for anything that would realistically be deployed.

The one argument for it is surviving a node loss, which matters more than usual here because
`minimal-pool` is a **spot** pool and preemption is routine, not hypothetical. But that argument
does not currently hold: with `replicas: 1` there is no second copy to survive on the other node,
and nothing spreads the two services across nodes. It would be paying for resilience the manifests
are not configured to use. See the spot caveat in
[prerequisites.md §3.2](./prerequisites.md#32-blocker-the-node-has-no-room-for-this-pod).

### Scale up — recreate the pool as `e2-standard-2`

1930m allocatable. After the 386m per-node tax and the 317m cluster-wide pods, **~1227m** is free —
room for about eight services at this size, roughly double *Scale out* for the same money
(`e2-standard-2` lists at almost exactly 2× `e2-medium`; the 2:1 ratio is structural to E2 pricing,
but confirm for `asia-southeast1` in the pricing calculator before committing).

A second, quieter benefit: `e2-medium` is a **shared-core** machine type, so the pod's 500m CPU
*limit* is burst capacity that can be lost to a noisy neighbour. `e2-standard-2` has dedicated
vCPU — more predictable latency for a service fronting Cloud SQL.

**The cost is operational, not financial.** A machine-type change **recreates the node pool**, so:

- `auth-service` goes down for the duration unless a new pool is created first and the old one
  cordoned and drained.
- The replacement pool **must** be given `--workload-metadata=GKE_METADATA` again. Omit it and
  every Workload Identity pod in the cluster breaks at once — both services, with a failure mode
  (token minting) that looks nothing like a node-pool problem.

This is the right destination and the wrong thing to do mid-deploy.

### Shrink requests — lower the pod's CPU requests

In `k8s/recommendations-service/deployment.yaml`: app `100m → 50m` (line 104), proxy `50m → 25m` (line 62). Total 75m,
which fits in the 87m free with 12m to spare. Free, instant, one `kubectl apply`.

**What it genuinely is:** a paper change. It lowers the *reservation*, not what the app can consume
— the 500m limit is untouched, so on a near-idle dev cluster the practical risk is close to zero.
It is the fastest way to a green rollout.

**What it costs:** the node sits at ~99% reserved, and the wall returns the moment a third service
appears. It is also a measurement-free squeeze: nobody has established that 50m is the right floor
for this workload under load.

---

## Recommendation: shrink now, scale up later

Not a single pick — a sequence, because the two steps answer different questions.

**Step 1 — Shrink requests, and get a green rollout today.** Zero cost, no infrastructure change,
and it does something *Scale up* cannot: it proves the image, Workload Identity, the Cloud SQL
proxy path, the Secret and the probes all actually work **while the node pool is still a known
quantity**. Rebuild the pool first and any failure afterwards has two candidate causes instead of
one.

**Step 2 — Scale up to `e2-standard-2`, then restore the original requests.** Done deliberately,
with the `GKE_METADATA` flag checked and `auth-service`'s downtime planned rather than discovered.

With ~1227m free afterwards, also revisit two things the current manifests only settled for because
the node was full:

- `maxUnavailable: 1` / `maxSurge: 0` at `deployment.yaml:22-23`. Two copies of the pod finally fit,
  so this can return to `maxUnavailable: 0` / `maxSurge: 1` and give zero-downtime rollouts. The
  comment in the manifest already says to do this "once the node pool has room".
- `replicas: 1` at `deployment.yaml:11`, plus a `topologySpreadConstraint` — the point at which
  surviving a spot preemption stops being theoretical.
