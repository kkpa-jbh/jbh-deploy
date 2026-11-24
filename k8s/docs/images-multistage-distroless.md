# Multi-stage Dockerfiles, distroless images, and Kubernetes

Short answer: **Kubernetes needs neither.** It needs an image that runs as a numeric non-root user, works with a
read-only file system, and answers HTTP health checks. JBH-86 did only that. Multi-stage and distroless are the
image hardening ticket, JBH-87.

## What the words mean

- **Multi-stage Dockerfile:** one Dockerfile with several `FROM` lines. Early stages prepare files (with tools);
  the last stage copies only the result into a small runtime image. The tools never reach the final image.
- **Layers:** each `COPY` makes a layer. A node downloads only the layers it does not have yet. If dependencies
  and our code are in separate layers, a code change downloads only a small layer.
- **Distroless:** a runtime image with only the language runtime (for example Java), and no shell, no package
  manager, no `wget`. Google publishes them (`gcr.io/distroless/java21-debian13:nonroot`).

## What Kubernetes really asks for

| Kubernetes needs | Our images before JBH-86 | Done in JBH-86 |
|---|---|---|
| A **numeric** non-root user (`runAsNonRoot` can only check a number) | `USER jbh` (a name) | `USER 10001:10001` in the 4 Java images |
| No root in `jbh-web` | Caddy ran as root | Caddy runs as 10001 |
| No Linux capabilities (`drop: [ALL]`) | The caddy binary carried a file capability, so it could not start without it | `setcap -r /usr/bin/caddy` (we listen on 8080, so it is not needed) |
| A read-only root file system | Already fine | `emptyDir` volumes for `/tmp` (and IAM's `/logs`, Caddy's folders) |
| Health checks | Compose used `wget` inside the container | Kubernetes probes call HTTP from outside, so no tool is needed in the image |

## The tradeoffs

| | Gain | Cost |
|---|---|---|
| Multi-stage with layers | A code change pushes and pulls only a small layer. Rollouts are faster, because each node pulls the image. | A more complex Dockerfile. |
| Distroless | Fewer CVEs (less software), a smaller attack surface, no shell an attacker could use. | No shell for debugging: use `kubectl debug`. The Compose health checks use `wget`, so the VPS needs work first. |

## What we decided

- JBH-86: the minimum for Kubernetes (the table above). The images still work the same on Compose and the VPS.
- JBH-87: multi-stage layers, distroless, digest pins, Trivy, SBOM, provenance and cosign.
  It must solve the Compose `wget` health checks first.
