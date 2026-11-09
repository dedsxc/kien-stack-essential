# kien/stack Essential

Free, open source GitOps platform for Kubernetes, installed in one command.
ArgoCD deploys and manages everything from your Git repo.

| Component | Role |
|---|---|
| ArgoCD | GitOps: everything deployed from Git (app-of-apps, self-managed) |
| Traefik | Gateway API (HTTPRoute) |
| cert-manager | TLS: self-signed CA or Let's Encrypt (HTTP-01 / DNS-01) |
| external-dns | DNS records (only if `dns.provider` is set) |
| External Secrets + Infisical | Secrets out of Git (self-hosted Infisical on CloudNativePG + Valkey) |
| CloudNativePG | PostgreSQL operator; each app gets its own small cluster via the [cnpg-cluster](https://github.com/dedsxc/labs/tree/main/helm/cnpg-cluster) chart |
| metrics-server | `kubectl top`, HPA |
| Reloader | Restarts workloads annotated `reloader.stakater.com/auto: "true"` when their ConfigMap/Secret changes |
| OpenEBS hostpath (option) | Local volumes for k3s / bare metal |
| Cilium (option) | eBPF CNI, kube-proxy replacement, L2 load balancer for homelabs |

No Bitnami charts. All charts are upstream and pinned.

## Quick start

Demo (zero questions, public repo, self-signed certs):

```bash
curl -fsSL https://shop.kien.cc/try.sh | bash
curl -fsSL https://shop.kien.cc/try.sh | bash -s uninstall
```

Real install: [fork this repo](https://github.com/dedsxc/kien-stack-essential/fork), then

```bash
curl -fsSL https://shop.kien.cc/install.sh | bash    # asks for your fork, domain, email
```

Requirements: `kubectl`, `helm`, `git`, a Kubernetes cluster (2 vCPU, 6 GB RAM, 8 GB recommended).
No cluster? [k3s](https://docs.k3s.io/quick-start) in one minute:

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik" sh -
```

## CI and updates

Every PR is linted and the changed charts are rendered, validated (kubeconform) and installed in a
kind cluster (`.github/workflows/charts-test.yaml`). Renovate keeps the upstream charts and images
up to date with weekly PRs, in this repo and in your fork (Renovate GitHub App, or the self-hosted
workflow with a `RENOVATE_TOKEN` secret). Details: [docs/CI.md](docs/CI.md).
Releases and changelog: [GitHub releases](https://github.com/dedsxc/kien-stack-essential/releases).

## How the repo is organised

```
argocd/
  app-of-apps.yaml              the only thing install.sh applies: watches argocd/applications
  applications/
    kustomization.yaml          resources: [platform, apps]
    platform/                   AppProject + ApplicationSet: one Application per helm/platform/* folder
    apps/                       AppProject + ApplicationSet: one Application per helm/apps/* folder
helm/
  platform/<brick>/             Helm chart: Chart.yaml (upstream chart as dependency), values.yaml, templates/
  apps/<your-app>/              your apps (see helm/apps/hello, based on app-template)
cluster.yaml                    YOUR settings, passed to every chart (global.domain, TLS, traefik...)
install.sh                      one-time bootstrap: secrets, ArgoCD (Helm), kubectl apply argocd/app-of-apps.yaml
```

Plain ArgoCD YAML, no templating on the ArgoCD side. Exceptions (namespace, sync options) live in the
`templatePatch` of each ApplicationSet. Optional bricks (`cilium`, `external-dns`) are excluded in
`applications/platform/appset.yaml`: remove the `exclude` line to enable them.

No hidden configuration: what is in Git is what runs.

- `cluster.yaml` -> every Application gets `valueFiles: [values.yaml, ../../../cluster.yaml]`
  (in `argocd/applications/*/appset.yaml`), so `global.domain: acme.com` gives `argocd.acme.com`.
- `argocd/app-of-apps.yaml` and the two `appset.yaml` hold your repo URL and branch.
- `install.sh` runs once: it creates the root secrets, installs ArgoCD with Helm
  (`helm/platform/argocd` + `cluster.yaml`, the same release ArgoCD then manages), and applies
  `argocd/app-of-apps.yaml` as committed. After that, you push and ArgoCD applies.

[`shop.kien.cc/install.sh`](https://shop.kien.cc/install.sh) asks a few questions, writes the answers
into these files in your fork, commits, pushes, then runs `install.sh`. You can also edit them by hand:

```bash
git clone https://github.com/<you>/<your-fork> && cd <your-fork>
# 1. cluster.yaml: global.domain, global.tls...
# 2. argocd/app-of-apps.yaml + argocd/applications/*/appset.yaml: your repo URL
git commit -am "my settings" && git push
./install.sh doctor && ./install.sh
```

### Add your own ApplicationSet

Copy `argocd/applications/apps/` to `argocd/applications/<name>/`, change the folder pattern in
`appset.yaml`, add `<name>` to `argocd/applications/kustomization.yaml`, push.

### Deploy your app

```bash
cp -r helm/apps/hello helm/apps/my-site     # rename in Chart.yaml, edit values.yaml (image, port, host)
git add helm/apps/my-site && git commit -m "my-site" && git push
```

ArgoCD creates the `my-site` Application in the `my-site` namespace. Delete the folder to remove it.

### Change the platform

- Tune a brick: edit `helm/platform/<brick>/values.yaml` (upstream values go under the dependency name).
- Upgrade a brick: bump the version in `helm/platform/<brick>/Chart.yaml`.
- Add a brick: create `helm/platform/<brick>/` (namespace = folder name, or add an exception in `templatePatch`).

Private repo: set `GIT_USERNAME` / `GIT_TOKEN` when installing.
Validate offline: `bash hack/validate.sh` (helm template + kubeconform on every chart).

## Paid packs

**Private AI** (Onyx, Ollama, LiteLLM, Coder) and **All-In-One** (monitoring, SSO, S3, Argo Rollouts,
Renovate, Radar, Terraform for AWS EKS) build on this Essential: https://shop.kien.cc

## License

Apache-2.0. Open source components keep their own licenses.
