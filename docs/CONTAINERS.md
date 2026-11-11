# Build your own container images

Put your images in `containers/<name>/`. The `Containers` workflow builds them on GitHub-hosted runners and publishes them to the GitHub Container Registry of your account.

```
containers/
  my-app/
    Dockerfile   # required
    VERSION      # required, e.g. 1.2.0 (image tag)
    PLATFORM     # optional, default linux/amd64 (e.g. linux/amd64,linux/arm64)
```

| When | What happens |
|---|---|
| Pull request touching `containers/` | Image is built and scanned with Trivy. The result is posted as a PR comment. Nothing is pushed. |
| Merge to `main` | Image is built and pushed as `ghcr.io/<owner>/<name>:<VERSION>` and `:latest`. |
| Every day (02:00 UTC) | Every image is rebuilt and pushed, so base image security fixes land without a code change. |

Renovate keeps the `FROM` lines (tag and digest) up to date, like the rest of the stack.

No secret is needed: the workflow uses the built-in `GITHUB_TOKEN`. Packages are private by default; to pull them from the cluster, make the package public or add an image pull secret.

Use the image in a brick: `image: ghcr.io/<owner>/my-app:1.2.0`.

`containers/example` is a minimal example you can copy or delete.

## GitHub recommended

The CI of kien/stack (chart tests, Renovate workflow, container builds) runs on GitHub Actions. You can host the GitOps repo on any Git server ArgoCD can reach (GitLab, Gitea, Forgejo...), but these workflows will not run there.
