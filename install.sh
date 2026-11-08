#!/usr/bin/env bash
# kien/stack Essential installer (free, Apache-2.0).
#   ./install.sh doctor  [--config stack.yaml]
#   ./install.sh install --pack essential [--config stack.yaml] [--dry-run]
#   ./install.sh --pack essential --config stack.yaml       (implicit install)
# Target: the cluster of the current kubectl context.
# Optional environment variables:
#   GIT_USERNAME / GIT_TOKEN          private GitOps repo (HTTPS)
#   INFISICAL_CLIENT_ID / INFISICAL_CLIENT_SECRET   if secrets.provider=infisical
#   DNS01_API_TOKEN                   if tls.issuer=letsencrypt-dns01
#   EXTERNAL_DNS_API_TOKEN            if dns.provider != none
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG="$ROOT/stack.yaml"
PACK=""
CMD=install
DRY_RUN=0
ARGOCD_TIMEOUT=${ARGOCD_TIMEOUT:-600s}

log()  { if [ "$DRY_RUN" -eq 1 ]; then printf "[kien/stack] %s\n" "$*" >&2; else printf '\033[1;34m[kien/stack]\033[0m %s\n' "$*"; fi; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
ko()   { printf '  \033[31mKO\033[0m   %s\n' "$*"; }
die()  { printf '\033[31m[kien/stack] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    doctor|install) CMD=$1 ;;
    --pack) PACK=${2:?--pack needs a value}; shift ;;
    --config|-c) CONFIG=${2:?--config needs a file}; shift ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
  shift
done

cfg() { yq -r "$1 // \"\"" "$CONFIG"; }

# No domain: <ip>.sslip.io (free public DNS that resolves to the IP), self-signed certificates.
# IP = ingress.ciliumLB.start, else ingress.nodeIP.
auto_domain() {
  local d ip; d=$(cfg .domain)
  if [ -n "$d" ] && [ "$d" != example.com ]; then echo "$d"; return; fi
  ip=$(cfg .ingress.ciliumLB.start); [ -n "$ip" ] || ip=$(cfg .ingress.nodeIP)
  [ -n "$ip" ] && echo "${ip}.sslip.io"
}

# macOS has no `timeout` nor `base64 -w0` (GNU): portable equivalents
run_timeout() { local t=$1; shift; if command -v timeout >/dev/null; then timeout "$t" "$@"; elif command -v gtimeout >/dev/null; then gtimeout "$t" "$@"; else "$@"; fi; }
b64() { base64 | tr -d '\n'; }

randpw() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-24}" || true; }

# ---------------------------------------------------------------- doctor
doctor() {
  local fail=0 b
  log "Checking prerequisites (config: $CONFIG)"
  for b in kubectl helm git yq; do
    if command -v "$b" >/dev/null 2>&1; then ok "$b found"; else ko "$b not found in PATH"; fail=1; fi
  done
  [ "$fail" -eq 0 ] || { ko "missing tools"; return 1; }
  if [ -f "$CONFIG" ]; then ok "config $CONFIG"; else ko "config $CONFIG not found (cp stack.example.yaml stack.yaml)"; return 1; fi

  local ctx; ctx=$(kubectl config current-context 2>/dev/null || true)
  if kubectl version --request-timeout=10s >/dev/null 2>&1; then
    ok "cluster reachable (context: ${ctx:-?}, $(kubectl version -o json 2>/dev/null | yq -r '.serverVersion.gitVersion'))"
  else ko "cluster unreachable (context: ${ctx:-none})"; fail=1; fi
  if [ "$fail" -eq 0 ]; then
    if kubectl auth can-i '*' '*' --all-namespaces >/dev/null 2>&1; then ok "cluster-admin rights"; else ko "cluster-admin rights required"; fail=1; fi
    if kubectl get storageclass -o name 2>/dev/null | grep -q .; then ok "StorageClass: $(kubectl get sc -o name | tr '\n' ' ')"; else warn "no StorageClass (Postgres PVCs would stay Pending; set storage.provider: openebs-hostpath)"; fi
    local cpu mem
    cpu=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.cpu}{"\n"}{end}' | awk '{ if ($1 ~ /m$/) s+=$1/1000; else s+=$1 } END {print int(s)}')
    mem=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' | awk '{ v=$1; if (v ~ /Ki$/) s+=v/1048576; else if (v ~ /Mi$/) s+=v/1024; else if (v ~ /Gi$/) s+=v; else s+=v/1073741824 } END {print int(s)}')
    ok "allocatable capacity: ${cpu} CPU / ${mem} Gi"
    local p=${PACK:-$(cfg .pack)}
    case "$p" in
      essential) [ "$mem" -ge 3 ] || warn "essential: >= 2 CPU / 6 GB recommended" ;;
      ia|full) [ "$mem" -ge 14 ] || warn "pack $p: >= 8 CPU / 16 GB recommended" ;;
    esac
  fi

  local repo; repo=$(cfg .gitops.repoURL)
  if [ -z "$repo" ]; then ko "gitops.repoURL is empty"; fail=1
  elif git_ls_remote "$repo" >/dev/null 2>&1; then ok "Git repo reachable: $repo"
  else ko "Git repo unreachable: $repo (private repo? set GIT_USERNAME/GIT_TOKEN)"; fail=1; fi

  local domain; domain=$(auto_domain)
  if [ -z "$domain" ]; then ko "no domain: set domain, or ingress.ciliumLB.start / ingress.nodeIP (<ip>.sslip.io + self-signed)"; fail=1
  elif [ "$domain" != "$(cfg .domain)" ]; then ok "no domain: using $domain (self-signed certificates)"
  elif getent hosts "argocd.$domain" >/dev/null 2>&1; then ok "DNS: argocd.$domain -> $(getent hosts "argocd.$domain" | awk '{print $1; exit}')"
  else warn "argocd.$domain does not resolve (fine if external-dns will create it; otherwise create *.$domain)"; fi

  case "$(cfg .tls.issuer)" in
    letsencrypt-dns01)
      if [ -n "${DNS01_API_TOKEN:-}" ] || kubectl -n cert-manager get secret "$(cfg .tls.dns01.secretName)" >/dev/null 2>&1; then ok "DNS01 token"
      else ko "DNS01_API_TOKEN required"; fail=1; fi ;;
    letsencrypt-http01) warn "HTTP01: *.$domain must point to the Traefik load balancer, port 80 open from the Internet" ;;
    selfsigned) ok "self-signed issuer" ;;
    *) ko "invalid tls.issuer"; fail=1 ;;
  esac
  if [ "$(cfg .secrets.provider)" = infisical ]; then
    if [ -n "${INFISICAL_CLIENT_ID:-}" ] && [ -n "${INFISICAL_CLIENT_SECRET:-}" ]; then ok "Infisical credentials"; else ko "INFISICAL_CLIENT_ID/INFISICAL_CLIENT_SECRET required"; fail=1; fi
  fi
  if [ "$(cfg .optional.cilium)" = true ] && ! kubectl -n kube-system get ds cilium >/dev/null 2>&1; then
    local cni; cni=$(kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -Eo '^(kindnet|flannel|kube-flannel|calico|canal|weave|kube-router|aws-node|antrea)' | head -1 || true)
    if [ -n "$cni" ]; then ko "optional.cilium=true but this cluster already has a CNI ($cni): set optional.cilium: false (Cilium is only for clusters created without a CNI)"; fail=1
    else ok "no CNI found: Cilium will be installed"; fi
  fi
  if [ "$fail" -eq 0 ]; then log "doctor: OK"; else log "doctor: some prerequisites are missing"; fi
  return "$fail"
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

# ---------------------------------------------------------------- install
VALUES=""
# Values every chart gets on top of its values.yaml and /cluster.yaml (from your stack.yaml).
gen_values() {
  local is=selfsigned-ca; case $(yq -r .tls.issuer "$VALUES") in letsencrypt*) is=letsencrypt ;; esac
  ISSUER=$is V="$VALUES" yq -n '
    .global.domain = load(strenv(V)).domain |
    .global.issuer = strenv(ISSUER) |
    .global.ingressClass = (load(strenv(V)).ingress.className // "traefik") |
    .global.storageClass = (load(strenv(V)).storageClass // "") |
    # cnpg-cluster chart (app Postgres): it has no global.storageClass, default openebs-hostpath
    (select((load(strenv(V)).storageClass // "") != "") | ."cnpg-cluster".cluster.storage.storageClass = load(strenv(V)).storageClass |
      ."cnpg-cluster".cluster.walStorage.storageClass = load(strenv(V)).storageClass) // . |
    .global.tls = load(strenv(V)).tls | .global.secrets = load(strenv(V)).secrets |
    .traefik.service.spec.type = (load(strenv(V)).ingress.serviceType // "LoadBalancer") |
    .ciliumLB = (load(strenv(V)).ingress.ciliumLB // {"enabled": false}) |
    .openebs."localpv-provisioner".hostpathClass.isDefaultClass = (load(strenv(V)).storage.makeDefault // false)' \
    | V="$VALUES" yq '
      (select(load(strenv(V)).ingress.serviceType == "NodePort") | .traefik.providers.kubernetesIngress =
        {"publishedService": {"enabled": false}, "ingressEndpoint": {"ip": (load(strenv(V)).ingress.nodeIP // "127.0.0.1")}}) // . |
      (select(load(strenv(V)).optional.cilium == true) | .cilium = {"k8sServiceHost": load(strenv(V)).cilium.k8sServiceHost,
        "k8sServicePort": load(strenv(V)).cilium.k8sServicePort, "ipam": {"mode": "cluster-pool",
        "operator": {"clusterPoolIPv4PodCIDRList": [load(strenv(V)).cilium.podCIDR]}}}) // . |
      (select(load(strenv(V)).dns.provider != "none") | ."external-dns" = {"provider": {"name": load(strenv(V)).dns.provider},
        "domainFilters": [load(strenv(V)).domain], "env": [{"name": "CF_API_TOKEN", "valueFrom": {"secretKeyRef":
        {"name": load(strenv(V)).dns.secretName, "key": "api-token", "optional": true}}}]}) // .'
}
# Install helm/platform/<name> once with Helm (same release name as ArgoCD, which then takes it over).
helm_bootstrap() {
  local name=$1 ns=$2 g; shift 2; g=$(mktemp); gen_values > "$g"
  helm dependency update "$ROOT/helm/platform/$name" >/dev/null
  helm upgrade --install "$name" "$ROOT/helm/platform/$name" -n "$ns" --create-namespace \
    -f "$ROOT/cluster.yaml" -f "$g" "$@" --wait --timeout 10m >/dev/null
  rm -f "$g"
}
# k3s (and some distros/addons) already run a metrics-server in kube-system with an immutable
# k8s-app selector: ours would fail to sync, so we keep theirs and skip the brick.
foreign_metrics_server() {
  [ -n "$(kubectl -n kube-system get deploy metrics-server -o jsonpath='{.spec.selector.matchLabels.k8s-app}' 2>/dev/null)" ]
}
enabled_components() {
  local d n
  for d in "$ROOT"/helm/platform/*/ "$ROOT"/helm/apps/*/; do
    n=$(basename "$d")
    case $n in
      cilium) [ "$(yq -r '.optional.cilium // false' "$VALUES")" = true ] || continue ;;
      external-dns) [ "$(yq -r '.dns.provider // "none"' "$VALUES")" != none ] || continue ;;
      metrics-server) ! foreign_metrics_server || continue ;;
    esac
    echo "$n"
  done
}
# app-of-apps with kustomize patches: your repo/branch in the ApplicationSets, your settings as Helm values,
# optional bricks (cilium, external-dns) un-excluded. argocd/applications/ itself stays plain YAML.
app_of_apps() {
  local g; g=$(mktemp); gen_values > "$g"
  R=$(cfg .gitops.repoURL) B=$(cfg .gitops.targetRevision) G="$g" \
  DNS=$(yq -r '.dns.provider // "none"' "$VALUES") CIL=$(yq -r '.optional.cilium // false' "$VALUES") \
  MS=$(foreign_metrics_server && echo true || echo false) yq -n '
    .apiVersion = "argoproj.io/v1alpha1" | .kind = "Application" |
    .metadata = {"name": "app-of-apps", "namespace": "argocd"} |
    .spec.project = "default" |
    .spec.destination = {"server": "https://kubernetes.default.svc", "namespace": "argocd"} |
    .spec.source = {"repoURL": strenv(R), "targetRevision": strenv(B), "path": "argocd/applications"} |
    .spec.syncPolicy.automated = {"prune": true, "selfHeal": true} |
    ([{"op": "replace", "path": "/spec/generators/0/git/repoURL", "value": strenv(R)},
      {"op": "replace", "path": "/spec/generators/0/git/revision", "value": strenv(B)},
      {"op": "replace", "path": "/spec/template/spec/source/repoURL", "value": strenv(R)},
      {"op": "replace", "path": "/spec/template/spec/source/targetRevision", "value": strenv(B)},
      {"op": "add", "path": "/spec/template/spec/source/helm/valuesObject", "value": load(strenv(G))}]) as $ops |
    # Each term parenthesised: "//" binds looser than "+". Removals highest index first.
    ([] + ((select(strenv(DNS) != "none") | [{"op": "remove", "path": "/spec/generators/0/git/directories/2"}]) // [])
        + ((select(strenv(CIL) == "true") | [{"op": "remove", "path": "/spec/generators/0/git/directories/1"}]) // [])
        + ((select(strenv(MS) == "true") | [{"op": "add", "path": "/spec/generators/0/git/directories/-", "value": {"path": "helm/platform/metrics-server", "exclude": true}}]) // [])) as $ex |
    .spec.source.kustomize.patches = [{"target": {"kind": "ApplicationSet"}, "patch": ($ops | to_json)}] |
    (select(($ex | length) > 0) | .spec.source.kustomize.patches += [{"target": {"kind": "ApplicationSet", "name": "platform"}, "patch": ($ex | to_json)}]) // .'
  rm -f "$g"
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
  provider=$(cfg .secrets.provider); issuer=$(cfg .tls.issuer)
  log "Bootstrap secrets"
  if [ "$issuer" = letsencrypt-dns01 ] && [ -n "${DNS01_API_TOKEN:-}" ]; then
    ensure_secret cert-manager "$(cfg .tls.dns01.secretName)" "$(cfg .tls.dns01.secretKey)=$DNS01_API_TOKEN"
  fi
  if [ "$(cfg .dns.provider)" != none ] && [ -n "${EXTERNAL_DNS_API_TOKEN:-}" ]; then
    ensure_secret external-dns "$(cfg .dns.secretName)" "api-token=$EXTERNAL_DNS_API_TOKEN"
  fi
  if has infisical; then
    local vp; vp="$(randpw 32)"
    ensure_secret infisical infisical-secrets "ENCRYPTION_KEY=$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 32)" \
      "AUTH_SECRET=$(head -c 32 /dev/urandom | base64 | tr -d '\n')" "VALKEY_PASSWORD=$vp" \
      "REDIS_URL=redis://:$vp@infisical-valkey.infisical.svc:6379"
  fi
  if [ "$provider" = infisical ]; then
    ensure_secret external-secrets "$(cfg .secrets.infisical.credentialsSecret)" \
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
  [ -f "$CONFIG" ] || die "config not found: $CONFIG"
  PACK=${PACK:-$(cfg .pack)}
  case "$PACK" in essential) ;; ia|full) die "pack $PACK is a paid edition (https://shop.kien.cc). This edition installs the essential." ;; *) die "--pack must be essential (got: '$PACK')" ;; esac
  VALUES=$(mktemp); trap 'rm -f "$VALUES"' EXIT
  yq ".pack = \"$PACK\"" "$CONFIG" > "$VALUES"
  local dom; dom=$(auto_domain)
  if [ -n "$dom" ] && [ "$dom" != "$(cfg .domain)" ]; then
    yq -i ".domain = \"$dom\" | .tls.issuer = \"selfsigned\" | .dns.provider = \"none\"" "$VALUES"
    log "No domain: $dom (self-signed, e.g. https://argocd.$dom)"
  fi

  local comps; comps=$(enabled_components)
  log "Pack $PACK -> components: $(tr '\n' ' ' <<<"$comps")"
  # Dry-run: stdout is valid YAML (kubectl apply -f - ready); values shown as comments (already in the patch)
  if [ "$DRY_RUN" -eq 1 ]; then echo "# Helm values injected in every chart:"; gen_values | sed 's/^/#   /'; app_of_apps; return; fi

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
  url: $(cfg .gitops.repoURL)
  username: ${GIT_USERNAME:-git}
  password: ${GIT_TOKEN}
YAML
    ok "GitOps repo credential registered in ArgoCD"
  fi

  log "Root Application 'app-of-apps' (argocd/applications: platform + apps ApplicationSets)"
  app_of_apps | kubectl apply -f - >/dev/null
  ok "applied: ArgoCD now syncs from $(cfg .gitops.repoURL)"

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
        warn "  -> homelab: ingress.ciliumLB.enabled=true (Cilium L2), or ingress.serviceType: NodePort; minikube: 'minikube tunnel'"
      fi
      return 1
    fi
    sleep 15
  done
}

summary() {
  local d; d=$(yq -r .domain "$VALUES")
  log "Done. Access:"
  echo "  ArgoCD : https://argocd.$d  (admin / kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
  grep -qx infisical <<<"$(enabled_components)" && echo "  Infisical: https://infisical.$d (create the admin account on first visit)"
  echo "  Your apps: add helm/apps/<name>/ (see helm/apps/hello) in $(cfg .gitops.repoURL), push."
  [ "$(yq -r .tls.issuer "$VALUES")" = selfsigned ] && echo "  (self-signed certificates: CA in cert-manager/selfsigned-ca)"
  return 0
}

command -v yq >/dev/null 2>&1 || die "yq (mikefarah, v4) is required"
case "$CMD" in
  doctor) doctor ;;
  install) install ;;
esac
