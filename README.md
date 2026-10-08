# k8s-kind-platform

A production-style Kubernetes setup that runs on a laptop with one command: a hardened app with health probes, autoscaling, zero-downtime rollouts, network policy and ingress, deployed with Kustomize onto a multi-node kind cluster, and tested end to end in CI.

## Why this project

Most Kubernetes tutorials stop at "deploy nginx." This one focuses on what makes a deployment safe to run: it refuses to start insecure pods, it survives a pod being killed and a rolling update without dropping requests, it scales with load, and every claim is backed by a script you can run and a CI job that runs it automatically.

## Architecture

```
 curl localhost:8080
        |
        v
 [ kind node port mapping 8080 -> 80 ]
        |
        v
 ingress-nginx  (namespace: ingress-nginx)
        |   NetworkPolicy: only this namespace may reach the app, only on 8080
        v
 Service shop-api  (ClusterIP)
        |
        v
 Pods shop-api x2..6   <-- HorizontalPodAutoscaler (CPU 50%) <-- metrics-server
   spread across 2 worker nodes
   ConfigMap (greeting, version)  +  Secret (API key, never in git)

 kind cluster "shop":  1 control-plane + 2 workers
```

## What it demonstrates

| Concern | How it is handled |
|---|---|
| **Health** | Startup, readiness and liveness probes are separate. A pod that fails readiness leaves the Service but is not killed. |
| **Zero-downtime updates** | `maxUnavailable: 0`, a `preStop` delay and readiness gating. |
| **Autoscaling** | HPA scales 2 to 6 pods on CPU (target 50%). |
| **Availability** | PodDisruptionBudget plus topology spread across nodes. |
| **Security** | Namespace enforces the `restricted` Pod Security Standard: non-root, read-only filesystem, no privilege escalation, all capabilities dropped, seccomp on, no service account token. |
| **Network isolation** | Default-deny ingress, with one explicit allow from the ingress controller. |
| **Config and secrets** | ConfigMap generated with a content hash (config changes trigger a rollout). The Secret is created in the cluster by the script and never committed. |
| **Environments** | Kustomize `dev` and `prod` overlays differ only by patches (replica bounds, resources, budget, greeting). |
| **Observability** | `/metrics` in Prometheus format with scrape annotations, ready to plug into a Prometheus stack. |

## Repo structure

```
app/            the service and its Dockerfile
kind/           cluster definition (1 control-plane, 2 workers)
k8s/base/       Deployment, Service, HPA, PDB, NetworkPolicy, Ingress, Namespace
k8s/overlays/   dev and prod
scripts/        cluster-up, smoke-test, loadtest, chaos, validate, cluster-down
tests/          unit tests for the app
.github/        CI: validate, then a real cluster end-to-end test
```

## Run it

Needs Docker, [kind](https://kind.sigs.k8s.io/) and kubectl. About 4 GB of free RAM, and port 8080 free.

```bash
chmod +x scripts/*.sh
./scripts/cluster-up.sh          # dev overlay; use "prod" for the prod overlay
./scripts/smoke-test.sh
curl localhost:8080/info
```

Experiments:

```bash
./scripts/loadtest.sh            # CPU load; watch the HPA add pods (kubectl -n shop get hpa -w)
./scripts/chaos.sh kill-pod      # delete a pod while traffic flows
./scripts/chaos.sh rollout       # rolling restart while traffic flows
./scripts/chaos.sh unready       # one pod fails readiness and leaves the Service
kubectl -n shop run bad --image=busybox:1.36 --restart=Never -- sleep 60   # must be rejected
```

Validate without a cluster (needs kubectl, and kubeconform for schema checks):

```bash
./scripts/validate.sh
```

Clean up:

```bash
./scripts/cluster-down.sh
```

## Results

Measured on a laptop (HP EliteBook 830 G5, Ubuntu, Docker, kind v0.25.0) with the `dev` overlay. These are single runs, so treat them as evidence the design works, not as benchmarks.

| Test | Result |
|---|---|
| Smoke test (`/health`, `/ready`, `/info`, ConfigMap, Secret) | Passed. Requests were answered by 2 distinct pods, running on `shop-worker` and `shop-worker2`. |
| Rolling restart under traffic (`chaos.sh rollout`) | **298 requests sent, 0 failed.** |
| Pod killed under traffic (`chaos.sh kill-pod`) | **164 requests sent, 0 failed.** The replacement became ready and the rollout completed. |
| Readiness failure (`chaos.sh unready`) | Service endpoints went from **2 to 1** and the pod was not restarted. It rejoined after being marked ready. |
| Root pod in the `shop` namespace | **Rejected** by Pod Security `restricted:latest` with four violations listed: privilege escalation, capabilities not dropped, `runAsNonRoot`, and seccomp profile. |
| Autoscaling under CPU load | CPU reached **254% of the 50% target** and the HPA scaled to its maximum of **6 replicas**. After the load stopped, CPU fell to 2 to 3% and replicas began scaling back toward 2. |

**Not measured:** time for the autoscaler to reach 6 replicas, time to scale back down, cold start time of `cluster-up.sh` on a laptop, and whether kind's default network plugin actually enforces the NetworkPolicy.

**CI:** every push runs unit tests and manifest validation, then creates a real kind cluster, deploys, runs the smoke test and a zero-downtime rollout test. The first end-to-end run failed on a startup race (issue 7) and passed after the fix.

## Design decisions

**Multi-node kind.** A single node hides scheduling, spreading and disruption behavior. Two workers let topology spread, pod disruption budgets and rescheduling be shown for real.

**Separate startup, readiness and liveness probes.** Startup protects a slow container from being killed early. Readiness decides whether a pod receives traffic, and failing it removes the pod from the Service without restarting it. Liveness restarts a stuck process and checks only the process, not dependencies, so an outage elsewhere cannot cause a restart storm. The app exposes `/unready` so readiness and liveness can be shown to be independent.

**Zero-downtime rollouts.** `maxUnavailable: 0` (never lose capacity), readiness gating (new pods get traffic only when ready), and a 5 second `preStop` sleep (the Service and ingress stop sending to a pod before it receives SIGTERM).

**`replicas` is omitted from the Deployment.** With an HPA managing scale, a fixed `replicas` would reset the count on every `kubectl apply`. The HPA's `minReplicas` is the floor.

**Resource requests and limits.** The HPA's CPU percentage is measured against the request, so requests must be set or autoscaling does not work. Limits cap a runaway pod.

**Pod Security Standards on the namespace.** The cluster itself rejects a non-compliant pod, so security does not rely on every author remembering. The Deployment complies explicitly.

**Default-deny NetworkPolicy.** Pods start isolated, and the only allowed path is the ingress controller to port 8080. Caveat: a NetworkPolicy only has an effect if the cluster's network plugin enforces it. kind's default plugin may not on every version, so enforcement should be verified, or Calico used, before claiming the policy blocks traffic.

**Secrets are not in git.** The Secret is created in the cluster by `cluster-up.sh` with a random value. Committing a Secret manifest, even base64-encoded, would publish it. The app reports only whether the key is set, and a unit test checks it never returns the value.

**Generated ConfigMap.** `configMapGenerator` appends a content hash to the name, so a config change produces a new name, changes the pod template and triggers a rolling update. Editing a plain ConfigMap does not restart pods.

**Overlays, not copies.** `prod` is the base plus a few patches, so environments cannot drift in structure.

**Ingress with no host rule.** `curl localhost:8080` works with no DNS or hosts-file changes.

**Limitations accepted.** kind has no cloud load balancer, node autoscaling or real multi-zone. Load tests run from the host, so numbers reflect a laptop. The app is intentionally simple; the project is about the platform around it.

## Troubleshooting

| Symptom | What to do |
|---|---|
| Pods `Pending` | `kubectl -n shop describe pod <pod>` and read Events. "Insufficient cpu" means Docker has no spare capacity: raise its CPU allocation. |
| `ImagePullBackOff` / `ErrImageNeverPull` | There is no registry. Load the image: `docker build -t shop-api:1.0.0 app && kind load docker-image shop-api:1.0.0 --name shop`, then `kubectl -n shop rollout restart deployment/shop-api`. |
| "violates PodSecurity" | The namespace enforces `restricted`. The pod must set non-root, drop all capabilities, forbid privilege escalation and use seccomp `RuntimeDefault`. |
| `secret "shop-secrets" not found` | Create it: `kubectl -n shop create secret generic shop-secrets --from-literal=API_KEY=$(openssl rand -hex 16)` |
| `curl localhost:8080` fails | Check `kubectl -n ingress-nginx get pods`; confirm the cluster was created from `kind/cluster.yaml` (the 8080 mapping only exists then); check nothing else uses port 8080 (`ss -ltnp \| grep 8080`). |
| 503/404 from ingress | `kubectl -n shop get endpoints shop-api`. Empty means no pod is ready. |
| HPA shows `<unknown>` | metrics-server is not ready yet. Check `kubectl -n kube-system get pods \| grep metrics` and `kubectl top pods -n shop`. |
| Roll back a bad release | `kubectl -n shop rollout undo deployment/shop-api` |
| Change config | Edit the overlay's `kustomization.yaml` literals, then `kubectl apply -k k8s/overlays/dev`. Pods roll automatically. |
| Start over | `./scripts/cluster-down.sh && ./scripts/cluster-up.sh` |

## Issues encountered

Every one of these happened during real runs.

1. **`Missing required tool: kind`.** kind was not installed. Fixed by downloading the binary into `~/.local/bin` and adding it to `PATH`. (`sudo mv` failed because the sudo password was mistyped, so installing without sudo was simpler.)
2. **`open kind/cluster.yaml: no such file or directory`.** The file had not been created in the local copy of the project. Fixed by creating it and checking all other files against the expected layout.
3. **`Permission denied` on the scripts.** The executable bit was missing after files were re-created. Fixed with `chmod +x scripts/*.sh`.
4. **`Missing required tool: docker` in one terminal.** A different shell environment did not have Docker on its `PATH`. Fixed by using a fresh terminal.
5. **Load test printed wrong numbers (`cpu=cpu:`, `replicas=6`).** The script parsed the HPA table with `awk`, but the target column (`cpu: 45%/50%`) contains a space, which shifted every column. The value shown as "replicas" was actually the maximum. Fixed by reading the values with `kubectl ... -o jsonpath` instead of parsing table text. Lesson: never scrape human-formatted CLI tables when a structured output exists.
6. **`git push` rejected, then `403`.** GitHub no longer accepts account passwords, and the first token lacked write permission. Fixed by creating a classic token with the `repo` scope and clearing the cached credential.
7. **CI end-to-end failed on the first run: `/health did not return 200`.** The smoke test fired its first request the instant the rollout finished, before the ingress route was live and before the autoscaler had raised the Deployment from 1 to its minimum of 2 replicas. It passed locally only because I ran the scripts by hand, seconds apart. Fixed by making the smoke test wait (bounded to 120 seconds) for the route and for 2 ready replicas.

## Next steps

- [ ] Measure how long the autoscaler takes to scale up and back down
- [ ] Add a CNI that enforces NetworkPolicy (for example Calico) and test the policy
- [ ] Scrape the app from a Prometheus stack and alert on it
- [ ] Add a Helm chart alongside Kustomize
- [ ] Add Argo CD for GitOps deployment