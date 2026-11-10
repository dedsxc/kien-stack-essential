#!/usr/bin/env bash
# kien/stack Essential INSTALL: the real, free install on your cluster.
#   curl -fsSL https://raw.githubusercontent.com/kien-stack/essential/main/scripts/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/kien-stack/essential/main/scripts/install.sh | bash -s uninstall
# Before: fork https://github.com/kien-stack/essential (you need push access to your fork).
# What it does, all visible in your Git history:
#   1. clones YOUR fork, asks a few questions
#   2. writes the answers into cluster.yaml and argocd/*.yaml, shows the diff, commits, pushes
#   3. runs ./install.sh from your fork: secrets, ArgoCD, kubectl apply argocd/app-of-apps.yaml
# Then ArgoCD applies whatever you push. Change a setting later: edit cluster.yaml, push.
# Non-interactive: KSTACK_REPO, KSTACK_BRANCH, KSTACK_DOMAIN, KSTACK_EMAIL, KSTACK_IP, KSTACK_CILIUM,
# KSTACK_YES=1; GIT_USERNAME/GIT_TOKEN for a private repo. Requires kubectl, helm, git.
set -euo pipefail
UPSTREAM=https://github.com/kien-stack/essential
DIR=${KSTACK_DIR:-$HOME/kien-stack}
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

log "context: $(kubectl config current-context). A few questions (Enter = default):"
ask KSTACK_REPO "Your fork of kien-stack-essential, HTTPS URL" ""
[ -n "$KSTACK_REPO" ] || die "a GitOps repo is required: fork $UPSTREAM first (or run https://raw.githubusercontent.com/kien-stack/essential/main/scripts/try.sh for a demo)"
case "$KSTACK_REPO" in *kien-stack/essential*|*dedsxc/kien-stack-essential*) die "that is our public repo: use your fork (or try.sh for a demo)" ;; esac
case "$KSTACK_REPO" in *.git) ;; *) KSTACK_REPO="$KSTACK_REPO.git" ;; esac
ask KSTACK_BRANCH "Branch ArgoCD tracks" main

# Your fork, on your machine (a normal clone: you can edit and push from it later)
auth=()
[ -z "${GIT_TOKEN:-}" ] || auth=(-c "http.extraheader=Authorization: Basic $(printf '%s:%s' "${GIT_USERNAME:-git}" "$GIT_TOKEN" | base64 | tr -d '\n')")
SRC="$DIR/repo"
if [ -d "$SRC/.git" ]; then git -C "$SRC" "${auth[@]}" pull -q --ff-only origin "$KSTACK_BRANCH" || die "cannot update $SRC (local changes?)"
else mkdir -p "$DIR"; git "${auth[@]}" clone -q -b "$KSTACK_BRANCH" "$KSTACK_REPO" "$SRC" || die "cannot clone $KSTACK_REPO ($KSTACK_BRANCH)"; fi
cd "$SRC"
[ -f cluster.yaml ] && [ -f argocd/app-of-apps.yaml ] || die "$KSTACK_REPO does not look like a kien-stack-essential fork (no cluster.yaml / argocd/app-of-apps.yaml)"

if [ "$(yq -r .spec.source.repoURL argocd/app-of-apps.yaml)" = "$KSTACK_REPO" ] && [ "$(yq -r .global.domain cluster.yaml)" != example.com ]; then
  log "your fork is already configured (cluster.yaml: $(yq -r .global.domain cluster.yaml)): installing as is"
else
  ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
  ask KSTACK_DOMAIN "Domain (empty = <ip>.sslip.io with self-signed certs)" ""
  KSTACK_EMAIL=${KSTACK_EMAIL:-}
  [ -z "$KSTACK_DOMAIN" ] || ask KSTACK_EMAIL "Email for Let's Encrypt (empty = self-signed)" ""
  ask KSTACK_IP "IP your browser uses to reach the cluster (Traefik node / LB)" "$ip"
  ask KSTACK_CILIUM "Install Cilium (only for a cluster created WITHOUT a CNI) true/false" false
  dom=${KSTACK_DOMAIN:-$KSTACK_IP.sslip.io}
  tls=selfsigned; is=selfsigned-ca; [ -z "$KSTACK_EMAIL" ] || { tls=letsencrypt-http01; is=letsencrypt; }

  # 1. cluster.yaml: your settings
  D="$dom" T="$tls" I="$is" E="${KSTACK_EMAIL:-admin@$dom}" yq -i '
    .global.domain = strenv(D) | .global.tls.issuer = strenv(T) | .global.issuer = strenv(I) |
    .global.tls.email = strenv(E)' cluster.yaml
  # 2. argocd/: ArgoCD follows your fork
  R="$KSTACK_REPO" B="$KSTACK_BRANCH" yq -i '.spec.source.repoURL = strenv(R) | .spec.source.targetRevision = strenv(B)' argocd/app-of-apps.yaml
  for f in argocd/applications/*/appset.yaml; do
    R="$KSTACK_REPO" B="$KSTACK_BRANCH" yq -i '.spec.generators[0].git.repoURL = strenv(R) | .spec.generators[0].git.revision = strenv(B) |
      .spec.template.spec.source.repoURL = strenv(R) | .spec.template.spec.source.targetRevision = strenv(B)' "$f"
  done
  # 3. optional bricks: an "exclude" entry in the platform ApplicationSet
  if [ "$KSTACK_CILIUM" = true ]; then
    yq -i 'del(.spec.generators[0].git.directories[] | select(.path == "helm/platform/cilium"))' argocd/applications/platform/appset.yaml
    IP="$KSTACK_IP" yq -i '.cilium.k8sServiceHost = strenv(IP) | .cilium.k8sServicePort = 6443 |
      .cilium.ipam = {"mode": "cluster-pool", "operator": {"clusterPoolIPv4PodCIDRList": ["10.42.0.0/16"]}}' cluster.yaml
  fi
  # k3s & co already run a metrics-server: do not deploy ours
  if [ -n "$(kubectl -n kube-system get deploy metrics-server -o jsonpath='{.spec.selector.matchLabels.k8s-app}' 2>/dev/null)" ]; then
    yq -i '.spec.generators[0].git.directories += [{"path": "helm/platform/metrics-server", "exclude": true}]' argocd/applications/platform/appset.yaml
  fi
  [ "$tls" = selfsigned ] || log "Let's Encrypt HTTP-01: *.$dom must point to $KSTACK_IP, port 80 open from the Internet"

  log "changes to your fork:"; git --no-pager diff --stat; git --no-pager diff -- cluster.yaml argocd/app-of-apps.yaml
  if [ -z "${KSTACK_YES:-}" ] && [ -r /dev/tty ]; then
    read -r -p "  Commit and push to $KSTACK_REPO ($KSTACK_BRANCH)? [Y/n]: " a </dev/tty || true
    case "${a:-y}" in y|Y|yes) ;; *) die "nothing pushed. Your edited fork is in $SRC: push it, then run ./install.sh there" ;; esac
  fi
  git -c user.name="${GIT_AUTHOR_NAME:-kien-stack}" -c user.email="${GIT_AUTHOR_EMAIL:-kien-stack@localhost}" \
    commit -qam "kien/stack: my settings (domain $dom)"
  git "${auth[@]}" push -q origin "HEAD:$KSTACK_BRANCH" || die "push failed (write access to $KSTACK_REPO? set GIT_USERNAME/GIT_TOKEN). Your edited fork is in $SRC"
  log "pushed: $(git log -1 --format='%h %s')"
fi

bash install.sh install
cat <<TXT

  Your fork: $SRC (cluster.yaml = your settings). Edit, commit, push: ArgoCD applies it.
  Our updates: merge new kien-stack-essential releases into your fork.

  Private AI, monitoring, SSO, rollouts: https://shop.kien.cc
  Remove: curl -fsSL https://raw.githubusercontent.com/kien-stack/essential/main/scripts/install.sh | bash -s uninstall
TXT
