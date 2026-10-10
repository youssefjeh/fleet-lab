#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# Prerequis Kubernetes + k3d + Helm + Fleet
# Compatible Ubuntu
# À exécuter en root : bash prerequis.sh
# ==========================================================

CLUSTER_NAME="fleet-mgmt"
FLEET_NAMESPACE="cattle-fleet-system"
FLEET_REPO="https://rancher.github.io/fleet-helm-charts/"

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERREUR : lance ce script en root :"
  echo "sudo bash prerequis.sh"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "=========================================="
echo " 1/8 - Installation des paquets système"
echo "=========================================="
apt-get update
apt-get install -y \
  ca-certificates curl bash-completion tar gzip

echo "=========================================="
echo " 2/8 - Installation de Docker"
echo "=========================================="

# Utiliser le dépôt officiel Docker
apt-get update
apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

systemctl enable --now docker

docker --version
docker info >/dev/null
echo "Docker est opérationnel."
echo "=========================================="
echo " 3/8 - Installation de k3d"
echo "=========================================="
if ! command -v k3d >/dev/null 2>&1; then
  curl -fsSL \
    https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh \
    -o /tmp/install-k3d.sh
  bash /tmp/install-k3d.sh
  rm -f /tmp/install-k3d.sh
fi
k3d version

echo "=========================================="
echo " 4/8 - Installation de kubectl"
echo "=========================================="
if ! command -v kubectl >/dev/null 2>&1; then
  ARCH="$(dpkg --print-architecture)"
  case "$ARCH" in
    amd64) KUBECTL_ARCH="amd64" ;;
    arm64) KUBECTL_ARCH="arm64" ;;
    *)
      echo "Architecture non prise en charge : $ARCH"
      exit 1
      ;;
  esac

  KUBECTL_VERSION="$(
    curl -fsSL https://dl.k8s.io/release/stable.txt
  )"

  curl -fsSLo /tmp/kubectl \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${KUBECTL_ARCH}/kubectl"

  curl -fsSLo /tmp/kubectl.sha256 \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${KUBECTL_ARCH}/kubectl.sha256"

  echo "$(cat /tmp/kubectl.sha256)  /tmp/kubectl" | sha256sum --check
  install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
  rm -f /tmp/kubectl /tmp/kubectl.sha256
fi
kubectl version --client

echo "=========================================="
echo " 5/8 - Installation de Helm 3"
echo "=========================================="
if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL \
    https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
    -o /tmp/get-helm-3
  bash /tmp/get-helm-3
  rm -f /tmp/get-helm-3
fi
helm version

echo "=========================================="
echo " 6/8 - Création du cluster k3d"
echo "=========================================="
if k3d cluster list | awk 'NR > 1 {print $1}' | grep -Fxq "$CLUSTER_NAME"; then
  echo "Le cluster ${CLUSTER_NAME} existe déjà : on le conserve."
else
  k3d cluster create "$CLUSTER_NAME" --wait
fi

kubectl config use-context "k3d-${CLUSTER_NAME}"
kubectl wait --for=condition=Ready node --all --timeout=180s
kubectl get nodes

echo "=========================================="
echo " 7/8 - Installation de Fleet avec Helm"
echo "=========================================="

# Ajouter le dépôt Helm de Fleet et actualiser les index
helm repo add fleet "$FLEET_REPO" --force-update
helm repo update

# Installer d'abord les CRD de Fleet
helm upgrade --install fleet-crd fleet/fleet-crd \
  --namespace "$FLEET_NAMESPACE" \
  --create-namespace \
  --wait \
  --timeout 5m

# Installer ensuite Fleet
helm upgrade --install fleet fleet/fleet \
  --namespace "$FLEET_NAMESPACE" \
  --create-namespace \
  --wait \
  --timeout 5m

echo "=========================================="
echo " 8/8 - Activation de l'autocomplétion Bash"
echo "=========================================="

BASHRC="/root/.bashrc"
MARKER="# >>> Kubernetes CLI completion >>>"

if ! grep -Fq "$MARKER" "$BASHRC" 2>/dev/null; then
  cat >> "$BASHRC" <<'BASHRC_EOF'

# >>> Kubernetes CLI completion >>>
if [[ $- == *i* ]]; then
  if command -v kubectl >/dev/null 2>&1; then
    source <(kubectl completion bash)
    alias k=kubectl
    complete -o default -F __start_kubectl k
  fi

  if command -v helm >/dev/null 2>&1; then
    source <(helm completion bash)
  fi
fi
# <<< Kubernetes CLI completion <<<
BASHRC_EOF
fi

echo
echo "=========================================="
echo " INSTALLATION TERMINÉE"
echo "=========================================="
echo
echo "Version des outils :"
docker --version
k3d version
kubectl version --client
helm version

echo
echo "Nœuds Kubernetes :"
kubectl get nodes

echo
echo "Pods Fleet :"
kubectl get pods -n "$FLEET_NAMESPACE"

echo
echo "Releases Helm :"
helm list -A

echo
echo "Pour activer l'autocomplétion dans le terminal actuel :"
echo "source /root/.bashrc"
echo
echo "Pour vérifier Fleet :"
echo "kubectl get pods -n cattle-fleet-system"
echo "kubectl get bundles -n fleet-local"
