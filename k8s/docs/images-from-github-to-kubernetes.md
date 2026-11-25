# How the images get from GitHub to the cluster

## The path

```
git push / merge into main
  → the "Image" workflow of the service repo (GitHub Actions)
      → job "package": tests + builds the app once (jar, quarkus-app/ or www/)
      → reusable workflow jbh-deploy/.github/workflows/multi-arch-image.yml:
          Build image (amd64)  ┐  each pushes its image to GHCR by digest only
          Build image (arm64)  ┘
          Publish multi-arch tag → ghcr.io/kkpa-jbh/<service>:<git-sha> and :latest
          Delete old images (keep 10 tagged)
  → GHCR (GitHub Container Registry) holds the image
  → you set the tag in the overlay (make k8s-pin) and apply it (make k8s-up)
  → the kubelet on the node pulls the image and starts the pod
```

Kubernetes never builds an image. It only pulls one by name and tag.

## Tags and digests

- A **tag** is a name for an image version: `ghcr.io/kkpa-jbh/jbh-iam:7c906b3…` (the git SHA) or `:latest`.
  A tag can move to another image.
- A **digest** (`@sha256:…`) is the image's fingerprint. It never changes.
- We use the **git SHA tag**: it is exact, and you can see which commit runs. `latest` moves, and Kubernetes cannot
  see that it moved: nothing changes in the Deployment, so no rollout starts.

## Multi-arch: one tag, two images

Your Mac (and k3d on it) is **arm64**. The VPS is **amd64**. AWS can be both. One tag holds both images
(a "manifest list"). Each node pulls the one for its own CPU type, by itself.

```
$ docker buildx imagetools inspect ghcr.io/kkpa-jbh/jbh-web:<sha>
Name:      ghcr.io/kkpa-jbh/jbh-web:<sha>
MediaType: application/vnd.oci.image.index.v1+json
Manifests:
  Platform:  linux/amd64      ← the VPS pulls this one
  Platform:  linux/arm64      ← your Mac and k3d pull this one
```

## imagePullPolicy

- `IfNotPresent` (the default for a SHA tag): pull only if the node does not have it. Fast and exact.
- `Always` (the default for `latest`): ask the registry on every pod start.

## Public or private packages

- **Private** (our choice, as in production): every cluster needs an `imagePullSecret`, a Secret of type
  `docker-registry` with a token that has only `read:packages`, named in each pod spec. The local overlay adds it to
  every Deployment (`patches/image-pull-secret.yaml`), and `make k8s-ghcr-secret` creates the Secret.
  The VPS does the same with `docker login ghcr.io`. GHCR storage and downloads are free today, also for private images.
- **Public:** anyone can pull, and no secret is needed. But anyone can also open the layers and read every file.
  One secret built into an image by mistake would leak. On EKS, nodes pull from ECR with their IAM role instead.

## Old images and rollbacks

- `kubectl rollout undo` goes back to the previous version, so it pulls the old image again.
- The old cleanup kept only **2 package versions**. One multi-arch image is about 3 versions (the tag + one per CPU),
  so it would even delete parts of the newest image. Rollbacks would fail with `ImagePullBackOff`.
- Now `dataaxiom/ghcr-cleanup-action` keeps the **10 newest tagged images**, each with all its parts.

## Test an image that is not pushed yet

`docker build`, then `k3d image import <image:tag> -c jbh` copies it into the cluster's node. No registry needed.
Steps: `LOCAL-K8S.md`, section 4.
