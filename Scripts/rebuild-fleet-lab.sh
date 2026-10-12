#!/usr/bin/env bash
# =============================================================================
#  rebuild-fleet-lab.sh — Reconstruit tout le lab Fleet "zero to hero"
#
#  Refait, dans l'ordre :
#    0. Outils       : Docker, k3d, kubectl, Helm, CLI fleet, autocomplétion
#    1. Réseau       : docker network "fleet-net"
#    2. Clusters     : fleet-mgmt (chef), fleet-dev, fleet-prod
#    3. Fleet        : installé sur fleet-mgmt avec apiServerURL + apiServerCA
#    4. Apps         : GitRepo "nginx-lab" (LAB 1 / 2-a / 2-b) sur fleet-mgmt
#    5. Enregistrement (LAB 3-b) : fleet-dev et fleet-prod présentés au chef
#                       (mode manager-initiated : kubeconfig -> Secret -> Cluster)
#    6. Ciblage (LAB 3-c) : ClusterGroup "production" + GitRepo "fleet-lab"
#    7. Rancher (LAB 5a) : cluster neuf "rancher-mgmt" + cert-manager + Rancher
#                          + proxy nginx (accès UI via "View Port" KodeKloud 30080)
#                          + server-url joignable par les clusters importés
#
#  Usage :
#    ./rebuild-fleet-lab.sh               # tout
#    ./rebuild-fleet-lab.sh --no-tools    # sauter l'étape 0 (outils déjà là)
#    ./rebuild-fleet-lab.sh --no-rancher  # sauter l'étape 7 (Rancher est lourd)
#    ./rebuild-fleet-lab.sh --only-rancher # module 5 : Rancher + fleet-dev / fleet-prod VIDES
#                                          # (à importer dans Rancher, sans Fleet standalone)
#    (les options se combinent : --no-tools --only-rancher)
#
#  ⚠️ Module 5 : utiliser --only-rancher sur un playground neuf. Un cluster ne doit
#     avoir qu'UN seul chef Fleet : soit le Fleet standalone (fleet-mgmt), soit Rancher.
#
#  Le script est rejouable : ce qui existe déjà est conservé.
#  Prévu pour Ubuntu, lancé en root (playground KodeKloud).
# =============================================================================
set -Eeuo pipefail

# ---------- Paramètres -------------------------------------------------------
REPO_URL="https://github.com/youssefjeh/fleet-lab"
REPO_DIR="$HOME/fleet-lab"          # clone du repo Git
WORK_DIR="$HOME/fleet-work"         # fichiers sensibles (ca.pem, kubeconfigs) : hors du repo
NETWORK="fleet-net"
MGMT="fleet-mgmt"
TARGETS=("fleet-dev:dev" "fleet-prod:prod")   # "<cluster k3d>:<nom Fleet + label env>"

# Rancher (LAB 5a) — versions épinglées (vérifiées compatibles : Rancher 2.15.2 accepte k8s < 1.37)
RANCHER_CLUSTER="rancher-mgmt"
RANCHER_HOSTNAME="rancher.localhost"
RANCHER_BOOTSTRAP_PASSWORD='Admin123!Fleet'     # >= 12 caractères (exigence Rancher)
RANCHER_VERSION="2.15.2"
CERT_MANAGER_VERSION="v1.21.2"
RANCHER_PROXY_PORT="30080"                      # NodePort du proxy nginx = port "View Port"
# Adresse que les clusters importés utilisent pour appeler Rancher (réseau fleet-net).
# En http : le formulaire Rancher l'interdit, kubectl patch l'accepte (LAB uniquement).
RANCHER_SERVER_URL="http://k3d-${RANCHER_CLUSTER}-server-0:${RANCHER_PROXY_PORT}"

INSTALL_TOOLS=true
RUN_FLEET=true
RUN_RANCHER=true
for arg in "$@"; do
  case "$arg" in
    --no-tools)     INSTALL_TOOLS=false ;;
    --no-rancher)   RUN_RANCHER=false ;;
    --only-rancher) RUN_FLEET=false ;;
    *) echo "Option inconnue : $arg (options : --no-tools --no-rancher --only-rancher)"; exit 1 ;;
  esac
done

# ---------- Affichage --------------------------------------------------------
step() { echo; echo "==================== $* ===================="; }
info() { echo "  -> $*"; }
ok()   { echo "  [OK] $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

[[ "$EUID" -eq 0 ]] || { echo "Lance ce script en root (sudo -i)."; exit 1; }

# =============================================================================
# 0. Outils
# =============================================================================
install_tools() {
  step "0. Outils"

  apt-get update -qq
  apt-get install -y -qq ca-certificates curl git bash-completion >/dev/null

  if ! have docker; then
    info "Installation de Docker"
    . /etc/os-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin >/dev/null
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
  ok "Docker $(docker --version | awk '{print $3}' | tr -d ,)"

  if ! have k3d; then
    info "Installation de k3d"
    curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash >/dev/null
  fi
  ok "$(k3d version | head -1)"

  if ! have kubectl; then
    info "Installation de kubectl"
    local arch; arch="$(dpkg --print-architecture)"
    curl -fsSLo /tmp/kubectl \
      "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/${arch}/kubectl"
    install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
    rm -f /tmp/kubectl
  fi
  ok "kubectl $(kubectl version --client -o json | grep -m1 gitVersion | cut -d'"' -f4)"

  if ! have helm; then
    info "Installation de Helm"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null
  fi
  ok "Helm $(helm version --short)"

  if ! have fleet; then
    info "Installation de la CLI fleet"
    curl -fsSLo /usr/local/bin/fleet \
      https://github.com/rancher/fleet/releases/latest/download/fleet-linux-amd64
    chmod +x /usr/local/bin/fleet
  fi
  ok "$(fleet --version)"

  if ! grep -q "alias k=kubectl" /root/.bashrc; then
    info "Autocomplétion kubectl / helm + alias k"
    cat >> /root/.bashrc <<'EOF'

# --- Fleet lab ---
source <(kubectl completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k
source <(helm completion bash)
EOF
  fi
  ok "Autocomplétion (active dans un nouveau shell, ou : source ~/.bashrc)"
}

# =============================================================================
# 1. Réseau Docker commun
# =============================================================================
create_network() {
  step "1. Réseau Docker '$NETWORK'"
  if docker network inspect "$NETWORK" >/dev/null 2>&1; then
    ok "existe déjà"
  else
    docker network create "$NETWORK" >/dev/null
    ok "créé"
  fi
}

# =============================================================================
# 2. Les 3 clusters
#    --tls-san ajoute le nom du conteneur au certificat de l'API :
#    évite l'erreur TLS quand un autre cluster appelle k3d-<nom>-server-0:6443
# =============================================================================
create_cluster() {
  local name="$1"
  if k3d cluster get "$name" >/dev/null 2>&1; then
    ok "cluster $name existe déjà"
    return
  fi
  info "création du cluster $name"
  k3d cluster create "$name" \
    --network "$NETWORK" \
    --k3s-arg "--tls-san=k3d-${name}-server-0@server:0" >/dev/null
  ok "cluster $name créé"
}

create_clusters() {
  step "2. Clusters"
  create_cluster "$MGMT"
  local t
  for t in "${TARGETS[@]}"; do create_cluster "${t%%:*}"; done
  k3d cluster list
}

# =============================================================================
# 3. Fleet sur le chef
# =============================================================================
install_fleet() {
  step "3. Fleet sur $MGMT (le chef)"

  kubectl config use-context "k3d-$MGMT" >/dev/null
  ok "contexte : $(kubectl config current-context)"

  mkdir -p "$WORK_DIR"
  kubectl config view --raw \
    -o jsonpath="{.clusters[?(@.name==\"k3d-$MGMT\")].cluster.certificate-authority-data}" \
    | base64 -d > "$WORK_DIR/ca.pem"
  grep -q "BEGIN CERTIFICATE" "$WORK_DIR/ca.pem" || { echo "ca.pem vide"; exit 1; }
  ok "certificat CA : $WORK_DIR/ca.pem"

  helm repo add fleet https://rancher.github.io/fleet-helm-charts/ >/dev/null 2>&1 || true
  helm repo update fleet >/dev/null

  helm upgrade --install --wait -n cattle-fleet-system --create-namespace \
    fleet-crd fleet/fleet-crd >/dev/null
  ok "fleet-crd installé"

  helm upgrade --install --wait -n cattle-fleet-system --create-namespace \
    fleet fleet/fleet \
    --set apiServerURL="https://k3d-${MGMT}-server-0:6443" \
    --set-file apiServerCA="$WORK_DIR/ca.pem" >/dev/null
  ok "fleet installé (apiServerURL=https://k3d-${MGMT}-server-0:6443)"

  kubectl get pods -n cattle-fleet-system
}

# =============================================================================
# 4. Repo Git + GitRepo (apps des LAB 1, 2-a, 2-b sur le chef)
# =============================================================================
apply_gitrepo() {
  step "4. Repo Git et GitRepo"
  if [[ -d "$REPO_DIR/.git" ]]; then
    git -C "$REPO_DIR" pull -q || info "git pull impossible (modifs locales ?) : on garde la version locale"
    ok "repo à jour : $REPO_DIR"
  else
    git clone -q "$REPO_URL" "$REPO_DIR"
    ok "repo cloné : $REPO_DIR"
  fi

  kubectl --context "k3d-$MGMT" apply -f "$REPO_DIR/gitrepo-nginx.yaml"
}

# =============================================================================
# 5. LAB 3-b — Enregistrer fleet-dev et fleet-prod (manager-initiated)
#    clé (kubeconfig) -> coffre (Secret) -> fiche employé (Cluster + label env)
# =============================================================================
register_targets() {
  step "5. Enregistrement des clusters cibles"
  local ctx="k3d-$MGMT"

  kubectl --context "$ctx" create namespace clusters --dry-run=client -o yaml \
    | kubectl --context "$ctx" apply -f - >/dev/null
  ok "namespace 'clusters'"

  local t k3d_name fleet_name kcfg
  for t in "${TARGETS[@]}"; do
    k3d_name="${t%%:*}"
    fleet_name="${t##*:}"
    kcfg="$WORK_DIR/${fleet_name}.kubeconfig"

    # 1) la clé : kubeconfig, avec l'adresse vue depuis le réseau fleet-net
    k3d kubeconfig get "$k3d_name" \
      | sed "s#https://0.0.0.0:[0-9]*#https://k3d-${k3d_name}-server-0:6443#" > "$kcfg"
    grep -q "server: https://k3d-${k3d_name}-server-0:6443" "$kcfg" \
      || { echo "adresse non remplacée dans $kcfg"; exit 1; }

    # 2) le coffre : Secret (la clé doit s'appeler 'value')
    kubectl --context "$ctx" -n clusters create secret generic "${fleet_name}-kubeconfig" \
      --from-file=value="$kcfg" --dry-run=client -o yaml \
      | kubectl --context "$ctx" apply -f - >/dev/null

    # 3) la fiche employé : Cluster avec son badge env
    kubectl --context "$ctx" apply -f - >/dev/null <<EOF
apiVersion: fleet.cattle.io/v1alpha1
kind: Cluster
metadata:
  name: ${fleet_name}
  namespace: clusters
  labels:
    env: ${fleet_name}
spec:
  kubeConfigSecret: ${fleet_name}-kubeconfig
EOF
    ok "$k3d_name enregistré comme Cluster '$fleet_name' (label env=$fleet_name)"
  done

  info "attente des agents (jusqu'à 3 min)..."
  local seen_all name
  for _ in $(seq 1 36); do
    seen_all=true
    for t in "${TARGETS[@]}"; do
      name="${t##*:}"
      # Signal fiable : BUNDLES-READY = 1/1 (l'agent a installé son bundle et l'a signalé).
      # LAST-SEEN peut rester vide quelques minutes : ce n'est pas une erreur.
      if [[ "$(kubectl --context "$ctx" -n clusters get clusters.fleet.cattle.io "$name" \
                -o jsonpath='{.status.display.readyBundles}' 2>/dev/null)" != "1/1" ]]; then
        seen_all=false
      fi
    done
    $seen_all && break
    sleep 5
  done

  kubectl --context "$ctx" get clusters.fleet.cattle.io -A
  if $seen_all; then
    ok "tous les agents sont installés et ont répondu (BUNDLES-READY 1/1)"
  else
    echo "  [!] Un agent n'a pas encore répondu. Diagnostic :"
    echo "      kubectl describe clusters.fleet.cattle.io <dev|prod> -n clusters"
  fi
}

# =============================================================================
# 6. LAB 3-c — Cibler par labels : ClusterGroup "production" + GitRepo "fleet-lab"
#    Le GitRepo est dans le namespace "clusters" : il ne voit que dev et prod.
# =============================================================================
apply_targeting() {
  step "6. Ciblage (ClusterGroup + GitRepo fleet-lab)"
  local ctx="k3d-$MGMT"

  kubectl --context "$ctx" apply -f - >/dev/null <<'EOF'
apiVersion: fleet.cattle.io/v1alpha1
kind: ClusterGroup
metadata:
  name: production
  namespace: clusters
spec:
  selector:
    matchLabels:
      env: prod
EOF
  ok "ClusterGroup 'production' (env=prod)"

  kubectl --context "$ctx" apply -f - >/dev/null <<EOF
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: fleet-lab
  namespace: clusters
spec:
  repo: ${REPO_URL}
  branch: main
  paths:
    - apps
    - infra
  targets:
    - name: dev
      clusterSelector:
        matchLabels:
          env: dev
    - name: prod
      clusterGroup: production
EOF
  ok "GitRepo 'fleet-lab' (dev par badge, prod par équipe)"

  kubectl --context "$ctx" get clustergroups,gitrepo -n clusters
}

# =============================================================================
# 7. LAB 5a — Rancher sur un cluster NEUF (pas sur le Fleet standalone)
#    Rancher embarque son propre Fleet : on ne l'installe jamais sur fleet-mgmt.
#
#    Accès à l'interface sur KodeKloud ("View Port") :
#      navigateur --HTTPS--> KodeKloud --HTTP--> VM:30080 --> serverlb k3d
#        --> NodePort 30080 --> proxy nginx (pod) --HTTPS--> service rancher
#    Le proxy ajoute "X-Forwarded-Proto: https" : sans lui, Rancher redirige
#    sans fin vers https (ERR_TOO_MANY_REDIRECTS), car KodeKloud lui parle en HTTP.
# =============================================================================
rancher_proxy_manifest() {
  # Heredoc entre quotes : les $ de nginx ne sont pas interprétés par bash.
  cat <<'EOF' | sed "s/__NODEPORT__/${RANCHER_PROXY_PORT}/"
apiVersion: v1
kind: ConfigMap
metadata:
  name: rancher-proxy-config
  namespace: cattle-system
data:
  default.conf: |
    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }
    server {
        listen 80;
        location / {
            proxy_pass https://rancher.cattle-system.svc.cluster.local;
            proxy_ssl_verify off;
            proxy_http_version 1.1;
            proxy_set_header Host              $host;
            proxy_set_header X-Forwarded-Proto https;
            proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
            # websockets : interface en direct + tunnel des agents des clusters importés
            proxy_set_header Upgrade           $http_upgrade;
            proxy_set_header Connection        $connection_upgrade;
            proxy_read_timeout 900s;
            proxy_buffering    off;
        }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rancher-http-proxy
  namespace: cattle-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rancher-http-proxy
  template:
    metadata:
      labels:
        app: rancher-http-proxy
    spec:
      containers:
        - name: nginx
          image: nginx:alpine
          ports:
            - containerPort: 80
          volumeMounts:
            - name: config
              mountPath: /etc/nginx/conf.d/default.conf
              subPath: default.conf
      volumes:
        - name: config
          configMap:
            name: rancher-proxy-config
---
apiVersion: v1
kind: Service
metadata:
  name: rancher-http-proxy
  namespace: cattle-system
spec:
  type: NodePort
  selector:
    app: rancher-http-proxy
  ports:
    - port: 80
      targetPort: 80
      nodePort: __NODEPORT__
EOF
}

install_rancher() {
  step "7. Rancher sur $RANCHER_CLUSTER"
  local ctx="k3d-$RANCHER_CLUSTER"

  # 7.0 cluster : 443 (ingress) + 30080 (proxy pour "View Port") ouverts sur la VM
  if k3d cluster get "$RANCHER_CLUSTER" >/dev/null 2>&1; then
    ok "cluster $RANCHER_CLUSTER existe déjà"
    if ! docker port "k3d-${RANCHER_CLUSTER}-serverlb" 2>/dev/null | grep -q "^${RANCHER_PROXY_PORT}/tcp"; then
      info "ouverture du port ${RANCHER_PROXY_PORT} sur le load balancer k3d"
      k3d node edit "k3d-${RANCHER_CLUSTER}-serverlb" \
        --port-add "${RANCHER_PROXY_PORT}:${RANCHER_PROXY_PORT}" >/dev/null
    fi
  else
    info "création du cluster $RANCHER_CLUSTER (ports 443 et ${RANCHER_PROXY_PORT} exposés)"
    k3d cluster create "$RANCHER_CLUSTER" \
      --network "$NETWORK" \
      -p "443:443@loadbalancer" \
      -p "${RANCHER_PROXY_PORT}:${RANCHER_PROXY_PORT}@loadbalancer" \
      --k3s-arg "--tls-san=k3d-${RANCHER_CLUSTER}-server-0@server:0" >/dev/null
    ok "cluster $RANCHER_CLUSTER créé"
  fi

  # 7.1 cert-manager : fabrique les certificats HTTPS de Rancher
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo add rancher-latest https://releases.rancher.com/server-charts/latest >/dev/null 2>&1 || true
  helm repo update jetstack rancher-latest >/dev/null

  helm upgrade --install --wait --kube-context "$ctx" \
    cert-manager jetstack/cert-manager \
    -n cert-manager --create-namespace \
    --version "$CERT_MANAGER_VERSION" \
    --set crds.enabled=true >/dev/null
  ok "cert-manager $CERT_MANAGER_VERSION installé"

  # 7.2 Rancher
  #   CATTLE_DEV_MODE : au démarrage, Rancher prépare une "jail" (/usr/bin/jailer.sh)
  #   qui recopie des fichiers de périphériques (/dev) avec tar. Dans un playground
  #   déjà conteneurisé (KodeKloud + k3d = conteneurs dans des conteneurs), cette copie
  #   est refusée -> "[FATAL] error running the jail command: exit status 2" -> CrashLoopBackOff.
  #   Avec CATTLE_DEV_MODE, Rancher saute cette étape. LAB UNIQUEMENT, jamais en production.
  helm upgrade --install --kube-context "$ctx" \
    rancher rancher-latest/rancher \
    -n cattle-system --create-namespace \
    --version "$RANCHER_VERSION" \
    --set hostname="$RANCHER_HOSTNAME" \
    --set-string bootstrapPassword="$RANCHER_BOOTSTRAP_PASSWORD" \
    --set replicas=1 \
    --set 'extraEnv[0].name=CATTLE_DEV_MODE' \
    --set-string 'extraEnv[0].value=30' >/dev/null
  ok "chart Rancher $RANCHER_VERSION installé"

  info "attente du démarrage de Rancher (jusqu'à 10 min)..."
  if kubectl --context "$ctx" -n cattle-system rollout status deploy/rancher --timeout=600s; then
    ok "Rancher est démarré"
  else
    echo "  [!] Rancher n'est pas encore prêt. Diagnostic :"
    echo "      kubectl --context $ctx -n cattle-system get pods"
    echo "      kubectl --context $ctx -n cattle-system logs deploy/rancher --previous --tail=30"
    return 1
  fi

  # 7.3 proxy nginx dans le cluster (stable, contrairement à un kubectl port-forward)
  rancher_proxy_manifest | kubectl --context "$ctx" apply -f - >/dev/null
  kubectl --context "$ctx" -n cattle-system rollout status deploy/rancher-http-proxy --timeout=180s >/dev/null
  ok "proxy nginx exposé sur le NodePort ${RANCHER_PROXY_PORT}"

  # 7.4 réglages Rancher (comme le lab KodeKloud "Deploy Rancher") :
  #   - server-url : adresse que les clusters importés utiliseront (réseau fleet-net)
  #   - first-login=false : pas d'assistant de 1re connexion (il écraserait server-url
  #     et refuse le http)
  #   Les settings existent quelques secondes après le démarrage : on réessaie.
  local _
  for _ in $(seq 1 30); do
    if kubectl --context "$ctx" patch settings.management.cattle.io server-url --type=merge \
         -p "{\"value\":\"${RANCHER_SERVER_URL}\"}" >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done
  kubectl --context "$ctx" patch settings.management.cattle.io first-login --type=merge \
    -p '{"value":"false"}' >/dev/null 2>&1 || info "setting first-login introuvable (sans gravité)"
  ok "server-url = $(kubectl --context "$ctx" get settings.management.cattle.io server-url -o jsonpath='{.value}')"

  kubectl --context "$ctx" -n cattle-system rollout restart deploy/rancher >/dev/null
  kubectl --context "$ctx" -n cattle-system rollout status deploy/rancher --timeout=600s >/dev/null
  ok "Rancher redémarré avec ses réglages"

  # 7.5 test : par le même chemin que le navigateur (VM:30080 -> proxy -> Rancher)
  local pong="" code=""
  for _ in $(seq 1 24); do
    pong="$(curl -s --max-time 5 "http://127.0.0.1:${RANCHER_PROXY_PORT}/ping" || true)"
    [[ "$pong" == "pong" ]] && break
    sleep 5
  done
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
          "http://127.0.0.1:${RANCHER_PROXY_PORT}/dashboard/" || true)"
  if [[ "$pong" == "pong" && "$code" == "200" ]]; then
    ok "http://127.0.0.1:${RANCHER_PROXY_PORT}/ping -> pong ; /dashboard/ -> 200"
  else
    echo "  [!] Rancher ne répond pas encore via le proxy (ping='${pong:-vide}', dashboard=${code:-?})."
    echo "      kubectl --context $ctx -n cattle-system get pods"
    echo "      kubectl --context $ctx -n cattle-system logs deploy/rancher-http-proxy --tail=20"
  fi
}

# =============================================================================
# 8. Module 5 — clusters fleet-dev / fleet-prod VIDES, à importer dans Rancher
#    (uniquement avec --only-rancher : jamais branchés au Fleet standalone)
# =============================================================================
create_rancher_downstream() {
  step "8. Clusters à importer dans Rancher (vides)"
  local t
  for t in "${TARGETS[@]}"; do create_cluster "${t%%:*}"; done
  kubectl config use-context "k3d-$RANCHER_CLUSTER" >/dev/null
  ok "contexte remis sur k3d-$RANCHER_CLUSTER"
}

# =============================================================================
# Résumé
# =============================================================================
summary() {
  step "Terminé"
  if $RUN_FLEET; then
    kubectl config use-context "k3d-$MGMT" >/dev/null
    echo "Contexte actif : $(kubectl config current-context)  (le chef Fleet standalone)"
    echo
    echo "Vérifications Fleet :"
    echo "  kubectl get gitrepo,bundle -n fleet-local"
    echo "  kubectl get clusters.fleet.cattle.io -A --show-labels"
    echo "  kubectl get clustergroups,gitrepo,bundles -n clusters"
    echo "  kubectl --context k3d-fleet-dev  get pods -A"
    echo "  kubectl --context k3d-fleet-prod get pods -A"
  fi
  if $RUN_RANCHER; then
    kubectl config use-context "k3d-$RANCHER_CLUSTER" >/dev/null
    echo
    echo "Rancher :"
    echo "  Interface    : KodeKloud -> View Port -> ${RANCHER_PROXY_PORT}"
    echo "  Utilisateur  : admin"
    echo "  Mot de passe : ${RANCHER_BOOTSTRAP_PASSWORD}  (installation neuve ; sinon celui que tu as choisi)"
    echo "  server-url   : ${RANCHER_SERVER_URL}  (adresse utilisée par les clusters importés)"
    echo "  Contexte     : $(kubectl config current-context)"
    if ! $RUN_FLEET; then
      echo
      echo "Import (LAB 5b) : Cluster Management -> Import Existing -> Generic -> nom 'dev' -> Create."
      echo "  Rancher affiche : kubectl apply -f ${RANCHER_SERVER_URL}/v3/import/XXXX.yaml"
      echo "  La VM ne connaît pas ce nom : remplace-le par 127.0.0.1 et vise le bon cluster :"
      echo "    curl -s http://127.0.0.1:${RANCHER_PROXY_PORT}/v3/import/XXXX.yaml | kubectl --context k3d-fleet-dev apply -f -"
      echo "  Puis idem pour 'prod' avec --context k3d-fleet-prod."
    fi
  fi
  echo
  echo "Fichiers sensibles (ne pas commiter) : $WORK_DIR"
}

# =============================================================================
$INSTALL_TOOLS && install_tools
create_network
if $RUN_FLEET; then
  create_clusters
  install_fleet
  apply_gitrepo
  register_targets
  apply_targeting
fi
if $RUN_RANCHER; then
  install_rancher
  $RUN_FLEET || create_rancher_downstream
fi
summary
