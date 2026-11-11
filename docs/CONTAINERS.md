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

A new image must be registered by hand, once. Without it, release-please ignores the folder and the image is never published.

1. Create the folder, for example `containers/my-app/`, with:
   - `Dockerfile`
   - `VERSION` containing the starting version: `0.1.0`
   - `PLATFORM` (optional), e.g. `linux/amd64,linux/arm64`

2. Add the image to `.github/release-please-config.json`, under `packages`:

   ```json
   "containers/my-app": {
     "component": "my-app",
     "package-name": "my-app",
     "release-type": "simple",
     "version-file": "VERSION",
     "include-component-in-tag": true
   }
   ```

3. Add the same starting version to `.github/.release-please-manifest.json`:

   ```json
   "containers/my-app": "0.1.0"
   ```

   It must match `VERSION`.

4. Open a PR with a `feat:` commit, e.g. `feat(my-app): add my-app image`. CI builds and scans the image.

5. Merge it. release-please opens a release PR for `my-app`. Merging that release PR tags `my-app-vX.Y.Z` and publishes `ghcr.io/<owner>/my-app`.

After that, never edit `VERSION` by hand: release-please bumps it from your `feat:` / `fix:` commits.

To remove an image, delete its folder and its entries in both files.

## GitHub recommended

The CI of kien/stack (chart tests, Renovate workflow, container builds) runs on GitHub Actions. You can host the GitOps repo on any Git server ArgoCD can reach (GitLab, Gitea, Forgejo...), but these workflows will not run there.
