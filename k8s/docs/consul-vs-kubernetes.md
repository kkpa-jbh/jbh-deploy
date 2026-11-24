# Consul or Kubernetes Service DNS?

**Decision (JBH-86, 2026-11-23): inside a Kubernetes cluster, JBH uses Kubernetes Services. Consul is off.**
Consul stays for the Compose stack (`make local-up`) and for the VPS until it moves to Kubernetes (JBH-88).

## What Consul does for us today

On Compose and the VPS, each service registers in Consul when it starts (`jbh-iam` and `jbh-gateway` with
Spring Cloud Consul, the Quarkus services with their own `ConsulServiceRegistration`).
The gateway routes say `lb://jbh-iam-service`, and Spring Cloud LoadBalancer asks Consul where that name lives.

## What Kubernetes gives instead

| We use Consul for | Kubernetes gives |
|---|---|
| Find a service by name | A **Service** gets a DNS name: `jbh-iam.jbh.svc.cluster.local` (short: `jbh-iam`). |
| Health of each instance | **Readiness probes**: a pod that is not ready gets no traffic from its Service. |
| Load balancing | The Service spreads connections over the ready pods. |
| Register at start | Nothing to do: a pod with the right label is part of the Service at once. |

So in the cluster, Consul would only repeat what Kubernetes already does.

## The options we looked at

| Option | Change | Why not / why |
|---|---|---|
| **1. Service DNS + Spring "simple discovery" (chosen)** | Config only | The routes keep `lb://jbh-iam-service`. A ConfigMap maps each name to its Service URL. No code change. You learn the core Kubernetes idea. |
| 2. Spring Cloud Kubernetes discovery | New dependency in the gateway, plus RBAC (the gateway may read Services from the Kubernetes API) | Per-request load balancing, but more to learn and more to break. |
| 3. Run Consul inside the cluster | A Consul StatefulSet | No service change, but two systems do the same job. |

## How it works

- `k8s/base/jbh-gateway/discovery-configmap.yaml` holds the map (mounted as `/etc/jbh/application.yml`):

  ```yaml
  spring.cloud.discovery.client.simple.instances:
    jbh-iam-service:      [{ uri: http://jbh-iam:9999 }]
    jbh-personal-finance: [{ uri: http://jbh-personal-finance:7777 }]
    jbh-notification:     [{ uri: http://jbh-notification:7778 }]
  ```

- `SPRING_CONFIG_ADDITIONAL_LOCATION=optional:file:/etc/jbh/` makes the gateway read it.
- It is a file and not env vars because env var names cannot keep the dashes of the map keys.
- **Proved by a test:** `jbh-gateway` → `KubernetesRoutingIntegrationTest` routes a request with Consul off
  through this map to a fake IAM. Without the map it fails with `503`.

How each service turns Consul off (in its ConfigMap):

| Service | Setting |
|---|---|
| `jbh-iam`, `jbh-gateway` | `SPRING_CLOUD_CONSUL_ENABLED=false`, `SPRING_CLOUD_CONSUL_DISCOVERY_ENABLED=false` |
| `jbh-personal-finance`, `jbh-notification` | `CONSUL_ENABLED=false` |

Service-to-service calls (`jbh-gateway-client`) still go through the gateway: `JBH_GATEWAY_URL=http://jbh-gateway:8080`.

## Known limits

- **Balancing per connection, not per request.** A Service balances TCP connections. The gateway keeps
  connections open, so with 2 IAM pods one pod may get most requests. With 1 replica (today) it does not matter.
- **State inside each pod.** The gateway's rate limiter (`InMemoryRateLimiter`), the IAM user cache (Caffeine) and
  IAM's scheduled token cleanup live in each pod. That is fine with 1 replica, wrong with more. JBH-88 lists them.
