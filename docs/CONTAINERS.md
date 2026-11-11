# Container images

Build your own images in this repo. GitHub Actions builds them and pushes them to `ghcr.io/<owner>/<name>`.

## Add an image

1. Create `containers/my-app/` with:
   - `Dockerfile`
   - `VERSION` containing `0.1.0`

2. In `.github/release-please-config.json`, add under `packages`:

   ```json
   "containers/my-app": { "component": "my-app", "release-type": "simple", "version-file": "VERSION", "include-component-in-tag": true }
   ```

3. In `.github/.release-please-manifest.json`, add:

   ```json
   "containers/my-app": "0.1.0"
   ```

4. Open a PR with a `feat:` or `fix:` commit and merge it. Other types (`chore:`, `docs:`...) don't trigger a release.

release-please then opens a release PR with the next version (e.g. `0.1.1`). Merge it: the image is pushed as `ghcr.io/<owner>/my-app:0.1.1`.

`0.1.0` is the starting point, not a published version: the first image gets the next one.

## What runs

- **Pull request**: build + security scan, result posted in the PR. Nothing is pushed.
- **Release PR merged**: build + push to GHCR.
- **Every night**: rebuild to pick up base image fixes.

Don't edit `VERSION` by hand: release-please bumps it from your `feat:` / `fix:` commits.

## Good to know

- No secret to set up.
- Images are private if your repo is private. Make the package public, or add an image pull secret in your cluster.
- Multi-arch: add a `PLATFORM` file, e.g. `linux/amd64,linux/arm64`.
- `containers/example` is a sample you can copy or delete.
- This needs GitHub. On another Git server, ArgoCD works but this CI does not run.
