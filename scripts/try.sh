#!/usr/bin/env bash
# kien/stack Essential TRY: a disposable demo on your current cluster, zero questions.
#   curl -fsSL https://raw.githubusercontent.com/kien-stack/essential/main/scripts/try.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/kien-stack/essential/main/scripts/try.sh | bash -s uninstall
# Uses the public repo on main (ArgoCD follows main; pin a release with KSTACK_REF=vX.Y.Z),
# <node-ip>.sslip.io and self-signed certs. For real use: https://raw.githubusercontent.com/kien-stack/essential/main/scripts/install.sh
# Overrides: KSTACK_IP, KSTACK_REF. Requires kubectl, helm, git (yq is fetched if missing).
set -euo pipefail
REPO=${KSTACK_SOURCE:-https://github.com/kien-stack/essential}
REF=${KSTACK_REF:-main}
DIR=${KSTACK_DIR:-$HOME/kien-stack-try}
log() { printf '\033[1;35m[kien/stack]\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
ask() { # ask VAR "question" default
  local v=${!1:-}; if [ -n "$v" ] || [ -n "${KSTACK_YES:-}" ] || [ ! -r /dev/tty ]; then printf -v "$1" %s "${v:-$3}"; return; fi
  read -r -p "  $2 [${3:-none}]: " v </dev/tty || true; printf -v "$1" %s "${v:-$3}"
}

for b in kubectl helm git; do command -v "$b" >/dev/null || die "$b is required (https://helm.sh/docs/intro/install, https://kubernetes.io/docs/tasks/tools)"; done
if ! command -v yq >/dev/null; then
  mkdir -p "$DIR/.bin"; export PATH="$DIR/.bin:$PATH"
  if ! [ -x "$DIR/.bin/yq" ]; then
    os=$(uname -s | tr A-Z a-z); arch=$(uname -m); case $arch in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; esac
    log "fetching yq ($os/$arch)"; curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_${os}_${arch}" -o "$DIR/.bin/yq"; chmod +x "$DIR/.bin/yq"
  fi
fi
kubectl version --request-timeout=10s >/dev/null 2>&1 || die "no reachable cluster in the current kubectl context.
  No Kubernetes? k3s in one minute: curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC=\"--disable traefik\" sh -"

if [ -d "$DIR/src/.git" ]; then git -C "$DIR/src" fetch -q origin "$REF" && git -C "$DIR/src" checkout -q FETCH_HEAD
else mkdir -p "$DIR"; git -c advice.detachedHead=false clone -q --depth 1 -b "$REF" "$REPO" "$DIR/src"; fi
cd "$DIR/src"

if [ "${1:-}" = uninstall ]; then
  # Order matters: ArgoCD manages itself, so stop the self-management first or it deletes its own
  # controller and the remaining Applications hang on their finalizers.
  log "removing the platform (ArgoCD apps, then ArgoCD)"
  unfin() { kubectl -n argocd patch application "$1" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true; }
  unfin app-of-apps; kubectl -n argocd delete application app-of-apps --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n argocd delete applicationsets --all --cascade=orphan >/dev/null 2>&1 || true
  unfin argocd; kubectl -n argocd delete application argocd --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n argocd delete applications --all --wait=true --timeout=5m || {
    log "some apps did not finish pruning: forcing"
    for a in $(kubectl -n argocd get applications -o name 2>/dev/null); do unfin "${a#*/}"; done; }
  kubectl -n argocd delete appprojects platform apps --ignore-not-found >/dev/null 2>&1 || true
  helm uninstall argocd -n argocd --wait 2>/dev/null || true
  log "done (namespaces, CRDs and PVCs are kept; delete them with kubectl if you want)"; exit 0
fi

ip=${KSTACK_IP:-$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')}
dom=$ip.sslip.io
log "demo on context $(kubectl config current-context), https://*.$dom, release $REF"
# A demo has no fork: ArgoCD reads OUR public repo at $REF (its cluster.yaml says example.com).
# So, and ONLY in this demo, the root Application pins $REF and overrides global.domain.
# A real install has none of this: https://raw.githubusercontent.com/kien-stack/essential/main/scripts/install.sh writes your settings into your fork.
D="$dom" yq -i '.global.domain = strenv(D)' cluster.yaml
ms=false
[ -z "$(kubectl -n kube-system get deploy metrics-server -o jsonpath='{.spec.selector.matchLabels.k8s-app}' 2>/dev/null)" ] || ms=true
if [ "$ms" = true ]; then
  yq -i '.spec.generators[0].git.directories += [{"path": "helm/platform/metrics-server", "exclude": true}]' argocd/applications/platform/appset.yaml
fi
D="$dom" V="$REF" MS="$ms" yq -i '.spec.source.targetRevision = strenv(V) |
  .spec.source.kustomize.patches = [{"target": {"kind": "ApplicationSet"}, "patch": ([
    {"op": "replace", "path": "/spec/generators/0/git/revision", "value": strenv(V)},
    {"op": "replace", "path": "/spec/template/spec/source/targetRevision", "value": strenv(V)},
    {"op": "add", "path": "/spec/template/spec/source/helm/valuesObject", "value": {"global": {"domain": strenv(D)}}}] | to_json)}] |
  (select(strenv(MS) == "true") | .spec.source.kustomize.patches += [{"target": {"kind": "ApplicationSet", "name": "platform"},
    "patch": ([{"op": "add", "path": "/spec/generators/0/git/directories/-", "value": {"path": "helm/platform/metrics-server", "exclude": true}}] | to_json)}]) // .' argocd/app-of-apps.yaml

bash install.sh install
cat <<TXT

  This is a demo: it tracks the public release $REF, self-signed certs, no customisation.
  minikube/kind: run 'minikube tunnel' if the URLs above do not answer.

  Real install (your domain, Let's Encrypt, your own GitOps repo):
    curl -fsSL https://raw.githubusercontent.com/kien-stack/essential/main/scripts/install.sh | bash
  Private AI, monitoring, SSO, rollouts: https://shop.kien.cc
  Remove: curl -fsSL https://raw.githubusercontent.com/kien-stack/essential/main/scripts/try.sh | bash -s uninstall
TXT
