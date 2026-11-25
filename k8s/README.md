# k8s/: JBH on Kubernetes

The Kubernetes files of JBH, as plain YAML put together with Kustomize (built into `kubectl`).
To run them on your laptop: [`../LOCAL-K8S.md`](../LOCAL-K8S.md). New to Kubernetes: [`docs/concepts.md`](docs/concepts.md).

## Folder map

```
k8s/
  base/                         the same on every target
    kustomization.yaml          lists every object; namespace jbh
    namespace.yaml              namespace jbh, "restricted" Pod Security
    ingress.yaml                /jbh-api → jbh-gateway, / → jbh-web (no controller, no host)
    jbh-iam/                    configmap, deployment, service   (the fully commented example)
    jbh-personal-finance/       configmap, deployment, service
    jbh-notification/           configmap, deployment, service
    jbh-gateway/                configmap, discovery-configmap (replaces Consul), deployment, service
    jbh-web/                    deployment, service
  components/
    postgres/                   StatefulSet + Service + initdb ConfigMap (optional: a target with RDS leaves it out)
  overlays/
    local/                      k3d on a laptop: image tags, Secret, Traefik, local values, fixed Postgres disk
  policies/
    pod-security-restricted.yaml   Kyverno policy, CI only (ci.yml)
  docs/                         the learning guides
```

## Portability: base vs overlay

JBH runs on the laptop now, on the VPS next (JBH-88), and maybe on AWS later. The same base must work everywhere.

| In `base/` (same everywhere) | In `overlays/<target>/` (per target) |
|---|---|
| Deployments, Services, probes, `securityContext`, resource requests | Image tags (`images:`), replicas, memory limits |
| Secret **names and keys** the services read | Where the secret values come from (a local file now; SOPS or External Secrets later) |
| Ingress path rules, with no controller-specific annotations | `ingressClassName`, annotations (Traefik on k3s, AWS Load Balancer Controller on EKS), TLS |
| DB host and name as config keys | Postgres itself: the component (laptop, VPS) or an external database (RDS). No `storageClassName` in the base. |
| — | `SPRING_PROFILES_ACTIVE`, `JBH_TRUSTED_PROXIES`, `CORS_ALLOWED_ORIGINS`, `JBH_FRONTEND_URL`, `JBH_ENV` |

`scripts/check-k8s-base.sh` fails if the base holds a storage class, an Ingress class, a host, an IP range or
`localhost`. CI runs it on every PR.

## Render

```bash
make k8s-render
# = kubectl kustomize --load-restrictor LoadRestrictionsNone k8s/overlays/local
```

`--load-restrictor LoadRestrictionsNone` is needed because the Postgres component reads `../../../initdb/`.
Rendering needs `k8s/overlays/local/.env.k8s` (copy it from `.env.k8s.example`).

## Docs

| Guide | Question it answers |
|---|---|
| [docs/concepts.md](docs/concepts.md) | What is a Pod, a Service, an Ingress, a PVC, ...? Where does JBH use each one? |
| [docs/consul-vs-kubernetes.md](docs/consul-vs-kubernetes.md) | Do we still need Consul? What replaces it, and how? |
| [docs/images-multistage-distroless.md](docs/images-multistage-distroless.md) | Do we need multi-stage and distroless images for Kubernetes? Tradeoffs? |
| [docs/images-from-github-to-kubernetes.md](docs/images-from-github-to-kubernetes.md) | How does an image get from a commit to a running pod? Tags, multi-arch, private packages and the pull Secret. |
| [docs/github-actions-for-kubernetes.md](docs/github-actions-for-kubernetes.md) | What changed in GitHub Actions, and what comes later? |
