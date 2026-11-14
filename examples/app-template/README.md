# app-template examples

One folder per kind of workload, ready to copy. Each one is a tiny Helm chart that depends on
[app-template](https://github.com/dedsxc/labs/tree/main/helm/fork/app-template), the generic chart
used across kien/stack.

| Folder | What it runs | Kubernetes object |
|---|---|---|
| [frontend](frontend) | Website or SPA over HTTPS | Deployment + Service + HTTPRoute |
| [backend](backend) | API with a secret from Infisical | Deployment + Service + HTTPRoute + ExternalSecret |
| [worker](worker) | Background worker, no URL | Deployment |
| [cronjob](cronjob) | Scheduled task | CronJob |
| [job](job) | One-off task (migration, import) | Job |
| [statefulset](statefulset) | Service with its own disk | StatefulSet + Service |
| [daemonset](daemonset) | Agent on every node | DaemonSet |

## Use one

```sh
cp -r examples/app-template/frontend helm/apps/my-site
# edit helm/apps/my-site/Chart.yaml (name: my-site) and values.yaml (image, port...)
git add helm/apps/my-site && git commit -m "feat: my-site" && git push
```

ArgoCD deploys every folder under `helm/apps/` in its own namespace. These examples live outside
`helm/apps/` on purpose: nothing here is deployed until you copy it.

Exposed over HTTPS? Add the name to `global.gatewayHosts` in `cluster.yaml` and set
`sectionName: https-<name>` in the route.

## Not the chart you want?

This app-template is a fork of [bjw-s app-template](https://github.com/bjw-s-labs/helm-charts),
customised for the platform. Any Helm chart works in `helm/apps/`, including the upstream one.

## Checked

Each example renders with `helm template -f cluster.yaml` and passes `kubeconform -strict`
(Kubernetes 1.33).
