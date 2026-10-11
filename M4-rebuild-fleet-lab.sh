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
#
#  Usage :
#    ./rebuild-fleet-lab.sh            # tout
#    ./rebuild-fleet-lab.sh --no-tools # sauter l'étape 0 (outils déjà là)
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

INSTALL_TOOLS=true
[[ "${1:-}" == "--no-tools" ]] && INSTALL_TOOLS=false

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
# Résumé
# =============================================================================
summary() {
  step "Terminé"
  kubectl config use-context "k3d-$MGMT" >/dev/null
  echo "Contexte actif : $(kubectl config current-context)  (le chef)"
  echo
  echo "Vérifications utiles :"
  echo "  kubectl get gitrepo,bundle -n fleet-local"
  echo "  kubectl get clusters.fleet.cattle.io -A"
  echo "  kubectl --context k3d-fleet-dev  get pods -n cattle-fleet-system"
  echo "  kubectl --context k3d-fleet-prod get pods -n cattle-fleet-system"
  echo
  echo "Fichiers sensibles (ne pas commiter) : $WORK_DIR"
}

# =============================================================================
$INSTALL_TOOLS && install_tools
create_network
create_clusters
install_fleet
apply_gitrepo
register_targets
summary
