# GitHub Actions changes for Kubernetes

## Now (JBH-86)

### 1. Multi-arch images, in one reusable workflow

The 5 service repos (`jbh-iam`, `jbh-gateway`, `jbh-personal-finance`, `jbh-notification`, `jbh-app`)
build the same way, so the shared part lives once, in `jbh-deploy/.github/workflows/multi-arch-image.yml`
(`on: workflow_call`). Each service's `image.yml` has 2 jobs:

```
Image (on push to main, or Run workflow)
  package                          "Test and build the app package"   (per repo: Gradle, Maven or npm)
    ↓ artifact: app-package
  image  → uses: kkpa-jbh/jbh-deploy/.github/workflows/multi-arch-image.yml@<jbh-deploy commit SHA>
             Build image (amd64)                     ubuntu-latest
             Build image (arm64)                     ubuntu-24.04-arm (free for public repos)
             Publish multi-arch tag (amd64 + arm64)
             Delete old images (keep 10 tagged)
  deploy   (jbh-app only, with AUTO_DEPLOY): needs: image
```

Why each piece:

- **Build once, image twice.** The jar / `www/` does not depend on the CPU type. Tests run once.
- **Native runners, no emulation.** Each CPU type builds on its own machine type: fast and exact.
- **Push by digest first.** Each build pushes its image with no tag. `publish-tag` creates the tag only when both
  exist. So a failed arm64 build never leaves a tag with only amd64.
- **Cleanup by tagged images.** `dataaxiom/ghcr-cleanup-action` keeps the 10 newest tagged images with all
  their parts, and always the image of `latest`. The old action counted package versions and would break multi-arch images.
- **Pinned to a commit SHA.** The callers pin the reusable workflow like an action. A change in `jbh-deploy`
  reaches a service only when its SHA is bumped.
- `jbh-app`'s auto-deploy waits for the job `image`, which ends only after the tag exists.

### 2. A PR check for this repo: `jbh-deploy/.github/workflows/ci.yml`

| Job | What it catches |
|---|---|
| Lint GitHub workflows (`actionlint`) | Mistakes in any workflow file, including the shell in `run:` |
| Render and validate the Kubernetes files (`kubectl kustomize`, `kubeconform -strict`, `scripts/check-k8s-base.sh`) | YAML that does not render, wrong or misspelled fields, a target-only value in `k8s/base/` |
| Check the restricted Pod Security policy (Kyverno CLI) | A pod that could run as root or keep capabilities, before anyone starts k3d |

No cluster is needed: fast, cheap feedback on every PR.

## Later

- **JBH-87 (image hardening):** Trivy scan, SBOM and provenance, cosign signature, base images pinned by digest.
  They go into `multi-arch-image.yml`, so all 5 services get them at once.
- **JBH-88 (VPS on Kubernetes):** the `Deploy` workflow stops using `ci-deploy.sh` over SSH. CI renders
  `k8s/overlays/<target>` and applies it with one kubeconfig per GitHub environment, or a GitOps tool (Argo CD,
  Flux) pulls from git. A new target (for example AWS) is then a new overlay plus a new environment.
