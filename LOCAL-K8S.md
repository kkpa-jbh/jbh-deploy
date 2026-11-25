# Run JBH on a local Kubernetes cluster (k3d)

This guide starts every JBH service on a small Kubernetes cluster on your laptop.
It is a learning setup (JBH-86). It does not change the VPS or the Compose stack (`LOCAL.md`).

What you get:

- A cluster named `jbh`, made by **k3d** (it runs k3s, a small Kubernetes, inside Docker).
- `jbh-iam`, `jbh-personal-finance`, `jbh-notification`, `jbh-gateway`, `jbh-web` and Postgres, in the namespace `jbh`.
- The app at **http://localhost:8081**.
- No Consul: Kubernetes Services find the services ([why](k8s/docs/consul-vs-kubernetes.md)).
- Traces, logs and metrics go to your local LGTM stack, through a Grafana Alloy in the cluster (section "Observability").

New to Kubernetes? Read [k8s/docs/concepts.md](k8s/docs/concepts.md) first. It explains every object used here.

## 1. Before the first run

| Need | How |
|------|-----|
| Docker Desktop with **at least 8 GB** of memory | Docker Desktop → Settings → Resources → Memory. The services and Alloy need about 3.5 GB, k3s about 0.5 GB, the LGTM container about 1 GB more. |
| `k3d` | `brew install k3d` |
| `kubectl` | `brew install kubectl` (probably already there) |
| `gh`, logged in | For `make k8s-pin`, and for the image token below: `gh auth status` |
| A token to pull the private GHCR images | Best: a classic token with only `read:packages` (GitHub → Settings → Developer settings → Personal access tokens). Run `export GHCR_TOKEN=<token>` before `make k8s-up`. Without it, your `gh` token is used: it works, but it has more rights. Never put it in `.env.k8s`. |

**Stop the Compose stack first** (`make local-down`). Both at once may not fit in Docker Desktop's memory.

## 2. First run

All commands run in the `jbh-deploy` folder.

```bash
# 1. Secrets for the local cluster (git-ignored). Fill at least POSTGRES_PASSWORD and JBH_JWT_SECRET.
cp k8s/overlays/local/.env.k8s.example k8s/overlays/local/.env.k8s
openssl rand -base64 32        # paste the output as JBH_JWT_SECRET

# 2. Pin the newest image of each service (writes the git SHAs into k8s/overlays/local/kustomization.yaml).
make k8s-pin

# 3. Create the cluster, apply everything, wait until all pods are Ready (about 3 minutes the first time).
make k8s-up
```

Open http://localhost:8081, sign up, sign in.

What `make k8s-up` does, step by step (`k8s.mk`):

1. Creates the Docker volume `jbh-k8s-pgdata` for the Postgres data, owned by user 70 (Postgres runs without root).
2. Creates the k3d cluster, if it does not exist: laptop port 8081 → Traefik (the Ingress controller), and the volume mounted into the node.
3. Creates the namespace `jbh` and the Secret `jbh-ghcr-pull` (`scripts/k8s-ghcr-secret.sh`). Every Deployment pulls its image with it.
4. Renders the files (`kubectl kustomize ... k8s/overlays/local`) and sends them to the cluster (`kubectl apply`).
5. Waits until every Deployment and the Postgres StatefulSet have finished their rollout (`kubectl rollout status`).

## 3. Every day

| Task | Command |
|------|---------|
| What runs, and its state | `make k8s-status` |
| Logs of one service | `kubectl logs -n jbh deploy/jbh-iam` (add `-f` to follow) |
| Why a pod does not start | `kubectl describe pod -n jbh <pod name>`, then read "Events" at the end |
| All recent events | `kubectl get events -n jbh --sort-by=.lastTimestamp` |
| See the YAML that is applied | `make k8s-render` |
| A new version of the services | `make k8s-pin`, then `make k8s-up` (a changed tag starts a rollout) |
| Watch a rollout | `kubectl rollout status -n jbh deploy/jbh-iam` |
| Go back one version | `kubectl rollout undo -n jbh deploy/jbh-iam` (the old image must still be in GHCR: the 10 newest are kept) |
| Renew the image token (it expired) | `export GHCR_TOKEN=<new token>`, then `make k8s-ghcr-secret`. Failed pulls retry by themselves. |
| Create the Postgres monitor role on an existing volume | `make k8s-pg-monitor` (section 7) |
| Delete the cluster, keep the data | `make k8s-down` |
| Delete the cluster and the data | `make k8s-reset-db` (asks first) |

## 4. Test a change before you push it

The cluster normally pulls images from GHCR. To test a local build:

```bash
# Example for jbh-iam: build the jar, then the image, then copy it into the cluster.
docker build -t ghcr.io/kkpa-jbh/jbh-iam:dev ../jbh-iam     # after ./gradlew :jbh-iam-api:bootJar there
k3d image import ghcr.io/kkpa-jbh/jbh-iam:dev -c jbh
```

Then set `newTag: dev` for `jbh-iam` in `k8s/overlays/local/kustomization.yaml` and run `make k8s-up`.
Run `make k8s-pin` afterwards to go back to the GHCR images.

## 5. Debugging without a shell

Some images may have no shell later (distroless, JBH-87). `kubectl debug` adds a temporary container with tools to a running pod:

```bash
kubectl debug -n jbh -it deploy/jbh-iam --image=busybox:1.36 --target=jbh-iam -- sh
```

## 6. Troubleshooting

| You see | Meaning | Fix |
|---------|---------|-----|
| `ImagePullBackOff` / `ErrImagePull` | The node cannot download the image | `401 Unauthorized` in `kubectl describe pod`: the token is missing, expired or lacks `read:packages` (`make k8s-ghcr-secret`). `not found`: the tag is gone (`make k8s-pin`); only the 10 newest images are kept. |
| `CrashLoopBackOff` | The app starts and stops again | `kubectl logs -n jbh deploy/<name> --previous` shows the last run's error (often a missing secret value). |
| `Pending` | No node can take the pod | Usually not enough memory: raise Docker Desktop's memory. `kubectl describe pod` says why. |
| `Running` but never `Ready` | The readiness probe fails | `kubectl describe pod`: look for "Readiness probe failed". Check the logs. |
| "image has non-numeric user" | The image runs as a user name, not a number | The image is older than JBH-86. Run `make k8s-pin` for a newer one. |
| `make k8s-up` fails: port 8081 is in use | Another program uses it | Stop it, or change `8081` in `k8s.mk` (and the URLs in the local overlay). |
| Alloy logs "connection refused" to `host.k3d.internal` | The LGTM is not running, or Docker Desktop does not forward the port to the k3d network | Start it (`make lgtm up` in `kkpa-docker-lab`). Still failing: `docker network connect k3d-jbh <lgtm container>`, then use that container's IP in `observability/alloy/k8s-local.alloy` (do not commit it). |
| Postgres metrics: auth error for `jbh_monitor` | The role does not exist yet (old volume), or the password differs | `make k8s-pg-monitor`. After a password change: `make k8s-up` first, then `make k8s-pg-monitor`. |
| Every `/collect` call gets 404, or no `/collect` call at all | Old `jbh-web` image without `runtime-config.js`, or the Ingress class of `jbh-faro` is missing | `make k8s-pin` after the `jbh-app` change is merged; `kubectl get ingress -n jbh` must list `jbh-faro` with class `traefik`. |
| Pod Security "violates PodSecurity restricted" | A pod could run as root or keep capabilities | The namespace refuses it on purpose. Fix the manifest; CI checks it too (`ci.yml`). |

## 7. Observability (traces, logs, metrics)

An Alloy in the cluster (`jbh-alloy`) collects everything and sends it to the LGTM stack on your laptop.
The files: `k8s/components/observability/` (the same on every target) and, for this cluster, `observability/alloy/k8s-local.alloy`.

- **Traces and logs:** the 4 Java services send OTLP to `http://jbh-alloy:4317`.
- **Metrics:** Alloy scrapes the 4 services and Postgres, with the same `job` names as Compose. The dashboards work unchanged.
- **Pod logs and pod CPU/memory:** Alloy reads stdout of every pod and the kubelet's cAdvisor (namespace `jbh` only).
- **Browser (Faro):** `jbh-web` sends to `http://localhost:8081/collect`, the same origin as the app. The Ingress `jbh-faro` forwards it to Alloy.
- Alloy reaches the LGTM through `host.k3d.internal`, a name k3d puts in the cluster DNS for your laptop.

Steps:

1. Start the LGTM first: `make lgtm up` in `kkpa-docker-lab`. Grafana: http://localhost:3000.
2. Set `JBH_PG_MONITOR_PASSWORD` in `k8s/overlays/local/.env.k8s` (URL-safe characters), then `make k8s-up`.
3. Your Postgres volume `jbh-k8s-pgdata` already has data, so the init scripts do not run again. Run `make k8s-pg-monitor` once.
   It creates the role `jbh_monitor`. A new, empty volume does it by itself.
4. In Grafana → Explore, filter on `deployment.environment.name = k8s-local` (Tempo) or `env`/`service` (Prometheus).
   Pod logs in Loki: `{k8s_namespace_name="jbh"} | log_source="kubernetes-stdout"`. Dashboard: `observability/grafana/jbh-k8s-pods.json`.
5. Faro needs a `jbh-web` image with `runtime-config.js` (from `jbh-app`). After that `jbh-app` change is merged, run `make k8s-pin`.

| Task | Command |
|------|---------|
| Alloy UI (every component and its health) | `kubectl port-forward -n jbh svc/jbh-alloy 12345:12345`, then http://localhost:12345 |
| Alloy logs | `kubectl logs -n jbh deploy/jbh-alloy` |
| Can a pod reach the LGTM? | `kubectl run -n jbh nettest --rm -it --restart=Never --image=busybox:1.36 -- nc -zv host.k3d.internal 4317` (also 9090) |
| Turn it all off | Remove the line `- ../../components/observability` in `k8s/overlays/local/kustomization.yaml`, then `make k8s-up` |

The Java services' logs appear twice in Loki: once over OTLP (with `traceId`), once from stdout (with `k8s_pod_name`).
That is on purpose: stdout also shows a crash before the OTel SDK starts.

## 8. Google sign-in

The Google button needs `http://localhost:8081` in the OAuth client's "Authorized JavaScript origins"
(Google Cloud Console → APIs & Services → Credentials). Email and password sign-in works without it.

## 9. Read more

- [k8s/README.md](k8s/README.md): the folder map, and the portability rule (base vs overlay).
- [k8s/docs/](k8s/docs/): concepts, Consul vs Kubernetes, images and distroless, GHCR → cluster, GitHub Actions.
