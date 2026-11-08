#!/usr/bin/env bash
# kien/stack Essential bootstrap (free, Apache-2.0). Run it once, from YOUR fork, after editing it:
#   ./install.sh doctor      check the cluster and the repo
#   ./install.sh install     install ArgoCD + apply argocd/app-of-apps.yaml (default)
# Everything it uses is in Git, nothing is generated:
#   cluster.yaml             your settings (domain, TLS...), passed to every chart
#   argocd/app-of-apps.yaml  the repo/branch ArgoCD follows (same URL in argocd/applications/*/appset.yaml)
#   argocd/applications/platform/appset.yaml   optional bricks: remove an "exclude" entry to enable it
# After that, ArgoCD applies whatever you push. https://shop.kien.cc/install.sh does the edits for you.
# Optional environment variables (secrets, never stored in Git):
#   GIT_USERNAME / GIT_TOKEN          private GitOps repo (HTTPS)
#   INFISICAL_CLIENT_ID / INFISICAL_CLIENT_SECRET   if global.secrets.provider=infisical
#   DNS01_API_TOKEN                   if global.tls.issuer=letsencrypt-dns01
#   EXTERNAL_DNS_API_TOKEN            if the external-dns brick is enabled
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG="$ROOT/cluster.yaml"
APP="$ROOT/argocd/app-of-apps.yaml"
APPSET="$ROOT/argocd/applications/platform/appset.yaml"
PACK=essential
CMD=install
ARGOCD_TIMEOUT=${ARGOCD_TIMEOUT:-600s}

log()  { printf '\033[1;34m[kien/stack]\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
ko()   { printf '  \033[31mKO\033[0m   %s\n' "$*"; }
die()  { printf '\033[31m[kien/stack] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    doctor|install) CMD=$1 ;;
    --pack) [ "${2:-}" = "$PACK" ] || die "this repo installs the $PACK pack"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
  shift
done

cfg()  { yq -r "$1 // \"\"" "$CONFIG"; }
repo() { yq -r '.spec.source.repoURL' "$APP"; }
rev()  { yq -r '.spec.source.targetRevision' "$APP"; }

# macOS has no `timeout` nor `base64 -w0` (GNU): portable equivalents
run_timeout() { local t=$1; shift; if command -v timeout >/dev/null; then timeout "$t" "$@"; elif command -v gtimeout >/dev/null; then gtimeout "$t" "$@"; else "$@"; fi; }
b64() { base64 | tr -d '\n'; }
randpw() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-24}" || true; }

# Bricks ArgoCD will deploy: every helm/platform/* folder not excluded in the platform ApplicationSet, + helm/apps/*.
enabled_components() {
  local d n ex; ex=$(yq -r '.spec.generators[0].git.directories[] | select(.exclude == true) | .path' "$APPSET")
  for d in "$ROOT"/helm/platform/*/; do
    n=$(basename "$d"); grep -qx "helm/platform/$n" <<<"$ex" || echo "$n"
  done
  for d in "$ROOT"/helm/apps/*/; do [ -d "$d" ] && basename "$d"; done
  return 0
}
# k3s (and some distros) already run a metrics-server in kube-system with an immutable selector.
foreign_metrics_server() {
  [ -n "$(kubectl -n kube-system get deploy metrics-server -o jsonpath='{.spec.selector.matchLabels.k8s-app}' 2>/dev/null)" ]
}

git_ls_remote() {
  local url=$1
  if [ -n "${GIT_TOKEN:-}" ]; then
    GIT_TERMINAL_PROMPT=0 run_timeout 30 git -c credential.helper= \
      -c "http.extraheader=Authorization: Basic $(printf '%s:%s' "${GIT_USERNAME:-git}" "$GIT_TOKEN" | b64)" \
      ls-remote "$url" HEAD
  else
    GIT_TERMINAL_PROMPT=0 run_timeout 30 git -c credential.helper= ls-remote "$url" HEAD
  fi
}

# ---------------------------------------------------------------- doctor
doctor() {
  local fail=0 b comps; comps=$(enabled_components)
  log "Checking prerequisites"
  for b in kubectl helm git yq; do
    if command -v "$b" >/dev/null 2>&1; then ok "$b found"; else ko "$b not found in PATH"; fail=1; fi
  done
  [ "$fail" -eq 0 ] || { ko "missing tools"; return 1; }

  local ctx; ctx=$(kubectl config current-context 2>/dev/null || true)
  if kubectl version --request-timeout=10s >/dev/null 2>&1; then
    ok "cluster reachable (context: ${ctx:-?}, $(kubectl version -o json 2>/dev/null | yq -r '.serverVersion.gitVersion'))"
  else ko "cluster unreachable (context: ${ctx:-none})"; fail=1; fi
  if [ "$fail" -eq 0 ]; then
    if kubectl auth can-i '*' '*' --all-namespaces >/dev/null 2>&1; then ok "cluster-admin rights"; else ko "cluster-admin rights required"; fail=1; fi
    local mem
    mem=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' | awk '{ v=$1; if (v ~ /Ki$/) s+=v/1048576; else if (v ~ /Mi$/) s+=v/1024; else if (v ~ /Gi$/) s+=v; else s+=v/1073741824 } END {print int(s)}')
    if [ "$mem" -ge 3 ]; then ok "allocatable memory: ${mem} Gi"; else warn "allocatable memory ${mem} Gi: >= 6 GB recommended"; fi
    if grep -qx metrics-server <<<"$comps" && foreign_metrics_server; then
      ko "this cluster already runs a metrics-server: exclude helm/platform/metrics-server in $APPSET"; fail=1
    fi
    if grep -qx cilium <<<"$comps" && ! kubectl -n kube-system get ds cilium >/dev/null 2>&1; then
      local cni; cni=$(kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -Eo '^(kindnet|flannel|kube-flannel|calico|canal|weave|kube-router|aws-node|antrea)' | head -1 || true)
      if [ -n "$cni" ]; then ko "cilium is enabled but this cluster already has a CNI ($cni): exclude helm/platform/cilium again"; fail=1
      else ok "no CNI found: Cilium will be installed"; fi
    fi
  fi

  local r; r=$(repo)
  case "$r" in *dedsxc/kien-stack-essential*) warn "argocd/app-of-apps.yaml still points to our public repo: put your fork's URL there (and in argocd/applications/*/appset.yaml)" ;; esac
  if grep -rq "repoURL: $r" "$ROOT"/argocd/applications/*/appset.yaml && [ "$(grep -rh 'repoURL:' "$ROOT"/argocd/applications/*/appset.yaml | sort -u | wc -l)" -eq 1 ]; then
    ok "ApplicationSets follow the same repo as app-of-apps"
  else ko "argocd/applications/*/appset.yaml must use the same repoURL as argocd/app-of-apps.yaml ($r)"; fail=1; fi
  if git_ls_remote "$r" >/dev/null 2>&1; then ok "Git repo reachable: $r ($(rev))"
  else ko "Git repo unreachable: $r (private repo? set GIT_USERNAME/GIT_TOKEN)"; fail=1; fi

  local domain; domain=$(cfg .global.domain)
  if [ -z "$domain" ] || [ "$domain" = example.com ]; then ko "set global.domain in cluster.yaml (no domain? <node-ip>.sslip.io)"; fail=1
  elif getent hosts "argocd.$domain" >/dev/null 2>&1; then ok "DNS: argocd.$domain -> $(getent hosts "argocd.$domain" | awk '{print $1; exit}')"
  else warn "argocd.$domain does not resolve (fine if external-dns will create it; otherwise create *.$domain)"; fi

  case "$(cfg .global.tls.issuer)" in
    letsencrypt-dns01)
      if [ -n "${DNS01_API_TOKEN:-}" ] || kubectl -n cert-manager get secret "$(cfg .global.tls.dns01.secretName)" >/dev/null 2>&1; then ok "DNS01 token"
      else ko "DNS01_API_TOKEN required"; fail=1; fi ;;
    letsencrypt-http01) warn "HTTP01: *.$domain must point to the Traefik load balancer, port 80 open from the Internet" ;;
    selfsigned) ok "self-signed certificates" ;;
    *) ko "invalid global.tls.issuer"; fail=1 ;;
  esac
  if [ "$(cfg .global.secrets.provider)" = infisical ]; then
    if [ -n "${INFISICAL_CLIENT_ID:-}" ] && [ -n "${INFISICAL_CLIENT_SECRET:-}" ]; then ok "Infisical credentials"; else ko "INFISICAL_CLIENT_ID/INFISICAL_CLIENT_SECRET required"; fail=1; fi
  fi
  if [ "$fail" -eq 0 ]; then log "doctor: OK"; else log "doctor: some prerequisites are missing"; fi
  return "$fail"
}

# ---------------------------------------------------------------- install
# Install helm/platform/<name> once with Helm, exactly like ArgoCD will (values.yaml + cluster.yaml);
# same release name, so ArgoCD takes it over.
helm_bootstrap() {
  local name=$1 ns=$2; shift 2
  helm dependency update "$ROOT/helm/platform/$name" >/dev/null
  helm upgrade --install "$name" "$ROOT/helm/platform/$name" -n "$ns" --create-namespace \
    -f "$CONFIG" "$@" --wait --timeout 10m >/dev/null
}


ensure_ns() { kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; }

# ensure_secret ns name [type] key=value...  (never overwrites an existing secret)
ensure_secret() {
  local ns=$1 name=$2; shift 2
  local type=generic
  case "${1:-}" in --type=*) type=${1#--type=}; shift ;; esac
  ensure_ns "$ns"
  if kubectl -n "$ns" get secret "$name" >/dev/null 2>&1; then ok "secret $ns/$name already exists"; return; fi
  local args=() kv
  for kv in "$@"; do args+=("--from-literal=$kv"); done
  kubectl -n "$ns" create secret generic "$name" --type="$type" "${args[@]}" >/dev/null
  ok "secret $ns/$name created"
}

bootstrap_secrets() {
  local comps=$1 provider issuer
  has() { grep -qx "$1" <<<"$comps"; }
  provider=$(cfg .global.secrets.provider); issuer=$(cfg .global.tls.issuer)
  log "Bootstrap secrets"
  if [ "$issuer" = letsencrypt-dns01 ] && [ -n "${DNS01_API_TOKEN:-}" ]; then
    ensure_secret cert-manager "$(cfg .global.tls.dns01.secretName)" "$(cfg .global.tls.dns01.secretKey)=$DNS01_API_TOKEN"
  fi
  if has external-dns && [ -n "${EXTERNAL_DNS_API_TOKEN:-}" ]; then
    ensure_secret external-dns external-dns-api-token "api-token=$EXTERNAL_DNS_API_TOKEN"
  fi
  if has infisical; then
    local vp; vp="$(randpw 32)"
    ensure_secret infisical infisical-secrets "ENCRYPTION_KEY=$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 32)" \
      "AUTH_SECRET=$(head -c 32 /dev/urandom | base64 | tr -d '\n')" "VALKEY_PASSWORD=$vp" \
      "REDIS_URL=redis://:$vp@infisical-valkey.infisical.svc:6379"
  fi
  if [ "$provider" = infisical ]; then
    ensure_secret external-secrets "$(cfg .global.secrets.infisical.credentialsSecret)" \
      "clientId=${INFISICAL_CLIENT_ID:?}" "clientSecret=${INFISICAL_CLIENT_SECRET:?}"
    ok "ClusterSecretStore 'infisical' will be created: use ExternalSecrets in your apps"
    return
  fi
  # provider none: generation locale (valeurs aleatoires), jamais commitees
  has monitoring && ensure_secret monitoring grafana-admin admin-user=admin "admin-password=$(randpw)"
  if has onyx; then
    local s3u s3p
    s3u=$(randpw 16); s3p=$(randpw 32)
    ensure_secret onyx onyx-postgresql --type=kubernetes.io/basic-auth username=postgres "password=$(randpw)"
    ensure_secret onyx onyx-redis "redis_password=$(randpw)"
    ensure_secret onyx onyx-objectstorage "s3_aws_access_key_id=$s3u" "s3_aws_secret_access_key=$s3p" "rootUser=$s3u" "rootPassword=$s3p"
    ensure_secret onyx onyx-opensearch opensearch_admin_username=admin "opensearch_admin_password=Aa1!$(randpw 20)"
    ensure_secret onyx onyx-userauth "user_auth_secret=$(randpw 64)"
  fi
  if has litellm; then
    local mk; mk="sk-$(randpw 32)"
    ensure_secret litellm litellm-masterkey "masterkey=$mk"
    ensure_secret litellm litellm-providers "PROXY_MASTER_KEY=$mk" "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}" \
      "GEMINI_API_KEY=${GEMINI_API_KEY:-}" "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-}" "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-}"
  fi
  if has seaweedfs; then
    local ak sk; ak="$(randpw 20)"; sk="$(randpw 40)"
    ensure_secret seaweedfs seaweedfs-s3 "seaweedfs_s3_config={\"identities\":[{\"name\":\"admin\",\"credentials\":[{\"accessKey\":\"$ak\",\"secretKey\":\"$sk\"}],\"actions\":[\"Admin\",\"Read\",\"List\",\"Tagging\",\"Write\"]}]}" "accessKey=$ak" "secretKey=$sk"
  fi
  has renovate && ensure_secret renovate renovate-env "RENOVATE_TOKEN=${RENOVATE_TOKEN:-}"
  has authentik && ensure_secret authentik authentik-env "AUTHENTIK_SECRET_KEY=$(randpw 50)"
  return 0
}

install() {
  local comps; comps=$(enabled_components)
  log "Pack $PACK -> ArgoCD will deploy: $(tr '\n' ' ' <<<"$comps")"
  doctor || die "doctor failed: fix the prerequisites above"

  bootstrap_secrets "$comps"

  if grep -qx cilium <<<"$comps"; then
    log "Installing Cilium (CNI, before everything else; then managed by ArgoCD)"
    # LB pool / L2 policy CRDs only exist once the Cilium operator runs: ArgoCD adds them right after.
    helm_bootstrap cilium kube-system --set ciliumLB.enabled=false
    kubectl wait --for=condition=Ready nodes --all --timeout=5m >/dev/null
    ok "Cilium ready, nodes Ready"
  fi

  log "Installing ArgoCD (Helm, then self-managed by ArgoCD)"
  helm_bootstrap argocd argocd
  ok "ArgoCD ready"
  local pw; pw=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
  log "ArgoCD login: admin / ${pw:-<see argocd-initial-admin-secret>}"
  log "  UI now (no ingress needed): kubectl -n argocd port-forward svc/argocd-server 8080:443  ->  https://localhost:8080"

  if [ -n "${GIT_TOKEN:-}" ]; then
    kubectl -n argocd apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: gitops-repo
  namespace: argocd
  labels: {argocd.argoproj.io/secret-type: repository}
stringData:
  type: git
  url: $(repo)
  username: ${GIT_USERNAME:-git}
  password: ${GIT_TOKEN}
YAML
    ok "GitOps repo credential registered in ArgoCD"
  fi

  log "kubectl apply -f argocd/app-of-apps.yaml (as committed in Git)"
  kubectl apply -f "$APP" >/dev/null
  ok "ArgoCD now syncs from $(repo) ($(rev)): push to change the platform"

  wait_apps "$comps"
  summary
}

wait_apps() {
  local comps=$1 deadline=$(( $(date +%s) + ${ARGOCD_TIMEOUT%s} )) pending
  log "Waiting for Synced/Healthy (timeout $ARGOCD_TIMEOUT)"
  while :; do
    pending=""
    for a in app-of-apps $comps; do
      local st
      st=$(kubectl -n argocd get application "$a" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)
      [ "$st" = Synced/Healthy ] || pending="$pending $a(${st:-absent})"
    done
    [ -z "$pending" ] && { ok "all applications are Synced/Healthy"; return 0; }
    if [ "$(date +%s)" -ge "$deadline" ]; then
      warn "not ready yet:$pending"
      if [ -z "$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress}' 2>/dev/null)" ] \
         && [ "$(kubectl -n traefik get svc traefik -o jsonpath='{.spec.type}' 2>/dev/null)" = LoadBalancer ]; then
        warn "Traefik is waiting for a load balancer IP: this cluster does not provide one."
        warn "  -> minikube: 'minikube tunnel'; homelab: Cilium L2 (ciliumLB in cluster.yaml) or traefik NodePort"
      fi
      return 1
    fi
    sleep 15
  done
}

summary() {
  local d; d=$(cfg .global.domain)
  log "Done. Access:"
  echo "  ArgoCD : https://argocd.$d  (admin / kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
  grep -qx infisical <<<"$(enabled_components)" && echo "  Infisical: https://infisical.$d (create the admin account on first visit)"
  echo "  Change anything: edit cluster.yaml or helm/*/<brick>/values.yaml in $(repo), push."
  [ "$(cfg .global.tls.issuer)" = selfsigned ] && echo "  (self-signed certificates: CA in cert-manager/selfsigned-ca)"
  return 0
}

command -v yq >/dev/null 2>&1 || die "yq (mikefarah, v4) is required"
case "$CMD" in
  doctor) doctor ;;
  install) install ;;
esac
