# Kubernetes concepts used in JBH

Each concept in plain words, and where JBH uses it. Read this before the YAML files in `k8s/`.

## The cluster

| Concept | In plain words | In JBH |
|---|---|---|
| **Cluster** | A group of machines (nodes) that Kubernetes manages as one. | One local cluster `jbh`, made by k3d (`k8s.mk`). |
| **Node** | One machine of the cluster. It runs the pods. | k3d makes one node: a Docker container `k3d-jbh-server-0`. |
| **kubelet** | The Kubernetes agent on each node. It starts containers, pulls images, runs probes. | Pulls the images from GHCR; calls the health endpoints. |
| **k3s / k3d** | k3s is a small Kubernetes. k3d runs k3s inside Docker. | Laptop: k3d. The VPS later (JBH-88): k3s directly. |
| **Namespace** | A named area of the cluster, like a folder. | `jbh` (`base/namespace.yaml`). |
| **kubectl** | The command line tool that talks to the cluster. | `kubectl get pods -n jbh`, `kubectl logs`, `kubectl apply`. |

## Running the apps

| Concept | In plain words | In JBH |
|---|---|---|
| **Pod** | The smallest unit: one or more containers that run together, with one IP. Pods are replaceable. | One pod per service. |
| **Deployment** | "Keep N pods of this template running." Replaces dead pods. A new image tag starts a **rollout**. | 5 Deployments: `base/<service>/deployment.yaml`. |
| **ReplicaSet** | The object a Deployment makes for each version. You rarely touch it. | One per image version; `kubectl rollout undo` goes back to the old one. |
| **StatefulSet** | Like a Deployment, for apps with data: fixed pod names and one disk per pod. | Postgres: `components/postgres/statefulset.yaml`. |
| **Probes** | HTTP calls (or commands) the kubelet makes to check a container. **startup**: has it started? **liveness**: is it stuck (then restart)? **readiness**: may it take traffic? | Spring: `/actuator/health/liveness`, `/readiness`. Quarkus: `/q/health/started`, `/live`, `/ready`. Postgres: `pg_isready`. |
| **Resources** | `requests`: what the scheduler reserves. `limits`: the most a container may use. Above the memory limit the container is killed (`OOMKilled`). | The same memory limits as Compose. No CPU limits (they slow the JVM start). |

## Networking

| Concept | In plain words | In JBH |
|---|---|---|
| **Service** | A stable name and address for a set of pods. Sends each connection to a ready pod. | `jbh-iam:9999`, `jbh-gateway:8080`, ... This replaces Consul ([why](consul-vs-kubernetes.md)). |
| **DNS name** | Every Service gets one: `<service>.<namespace>.svc.cluster.local`, short `<service>` in the same namespace. | The gateway calls `http://jbh-iam:9999`. |
| **ClusterIP** | The default Service type: reachable only inside the cluster. | Every JBH Service. |
| **Ingress** | Rules for HTTP traffic that comes from outside (path → Service). | `base/ingress.yaml`: `/jbh-api` → gateway, `/` → web. Same as Caddy. |
| **Ingress controller** | The proxy that applies the Ingress rules. Not part of Kubernetes itself. | Traefik (built into k3s). On AWS it would be the AWS Load Balancer Controller. |

## Configuration and data

| Concept | In plain words | In JBH |
|---|---|---|
| **ConfigMap** | Plain settings, given to a container as env vars or files. | One per service (`configmap.yaml`), plus the gateway's discovery file. |
| **Secret** | Like a ConfigMap, for passwords and keys. | `jbh-secrets`, made from `k8s/overlays/local/.env.k8s` (git-ignored). |
| **PersistentVolume (PV)** | A piece of disk. | `overlays/local/postgres-pv.yaml`: fixed, so the data survives `make k8s-down`. |
| **PersistentVolumeClaim (PVC)** | A request for a disk ("2 GB, one writer"). Kubernetes binds it to a PV. | `data-jbh-postgres-0`, from the StatefulSet's `volumeClaimTemplates`. |
| **StorageClass** | A kind of disk a cluster can make on demand. | k3s: `local-path`. Not named in the base: each target has its own. |
| **emptyDir** | An empty folder made with the pod and deleted with it. | `/tmp` of every app; `/logs` of IAM; Caddy's folders. |

## Security

| Concept | In plain words | In JBH |
|---|---|---|
| **securityContext** | How a container may run: which user, which Linux capabilities, a read-only file system. | Every pod: user 10001 (Postgres: 70), no root, all capabilities dropped, read-only root. |
| **Pod Security Standards** | Three levels Kubernetes can enforce per namespace: privileged, baseline, **restricted** (the strictest). | `jbh` enforces `restricted` (`base/namespace.yaml`). CI checks it too (Kyverno, `ci.yml`). |

## Kustomize (how the YAML is put together)

| Concept | In plain words | In JBH |
|---|---|---|
| **Base** | The objects that are the same on every target. | `k8s/base/` |
| **Component** | An optional block an overlay can switch on. | `k8s/components/postgres/` (a target with RDS leaves it out). |
| **Overlay** | One target: the base + components + target-only values (patches). | `k8s/overlays/local/` now; `vps` in JBH-88. |
| **`images:`** | Sets the tag of each image in one place. | `make k8s-pin` writes the newest git SHA there. |
| **secretGenerator / configMapGenerator** | Makes a Secret / ConfigMap from files, with a hash in the name, so a change restarts the pods that use it. | `jbh-secrets`, `jbh-postgres-initdb`. |
| **Render** | Build the final YAML from base + overlay, without a cluster. | `make k8s-render`. |
