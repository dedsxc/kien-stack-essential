# Build your own container images

Put your images in `containers/<name>/`. The `Containers` workflow builds them on GitHub-hosted runners and publishes them to the GitHub Container Registry of your account.

```
containers/
  my-app/
    Dockerfile   # required
    VERSION      # image tag, managed by release-please
    PLATFORM     # optional, default linux/amd64 (e.g. linux/amd64,linux/arm64)
```

| When | What happens |
|---|---|
| Pull request touching `containers/` | Image is built and scanned with Trivy. The result is posted as a PR comment. Nothing is pushed. |
| Release PR merged | release-please bumped `VERSION`: the image is built and pushed as `ghcr.io/<owner>/<name>:<VERSION>` and `:latest`. |
| Every day (02:00 UTC) | Every image is rebuilt and pushed, so base image security fixes land without a code change. |

## Versions with release-please

Each image is a release-please package. A `feat:` or `fix:` commit touching `containers/<name>/` opens (or updates) a release PR that bumps `VERSION` and writes `containers/<name>/CHANGELOG.md`. Merging it tags `<name>-vX.Y.Z` and publishes the image. Never edit `VERSION` by hand.

Renovate keeps the `FROM` lines (tag and digest) up to date with `fix(deps):` commits, so a base image update also ships a new patch version.

## Add an image

1. Copy `containers/example` to `containers/<name>` and set `VERSION` to `0.1.0`.
2. Register it in `.github/release-please-config.json`:
   `"containers/<name>": { "component": "<name>", "package-name": "<name>", "release-type": "simple", "version-file": "VERSION", "include-component-in-tag": true }`
3. Add `"containers/<name>": "0.1.0"` to `.github/.release-please-manifest.json`.

No secret is needed: the workflow uses the built-in `GITHUB_TOKEN`. Packages are private by default; to pull them from the cluster, make the package public or add an image pull secret.

Use the image in a brick: `image: ghcr.io/<owner>/my-app:1.2.0`.

`containers/example` is a minimal example you can copy or delete.

## GitHub recommended

The CI of kien/stack (chart tests, Renovate workflow, container builds) runs on GitHub Actions. You can host the GitOps repo on any Git server ArgoCD can reach (GitLab, Gitea, Forgejo...), but these workflows will not run there.
