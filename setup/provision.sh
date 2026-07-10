#!/usr/bin/env bash
# Provisionamento dos GPU Servers hp-gpu01/hp-gpu02 (HPE DL380 Gen12, 2× NVIDIA L40S)
# Instala: driver NVIDIA 595-server-open + Docker CE (repositório oficial) + NVIDIA Container Toolkit
# Uso: sudo bash provision.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

step() { echo; echo "=== [$(date +%H:%M:%S)] $* ==="; }

step "Base: atualização do sistema e utilitários"
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq ca-certificates curl gnupg htop nvme-cli pciutils dmidecode

step "Timezone: America/Sao_Paulo"
timedatectl set-timezone America/Sao_Paulo

step "Driver NVIDIA 595-server-open (ramo datacenter, módulos assinados do archive Ubuntu)"
apt-get install -y -qq nvidia-driver-595-server-open linux-modules-nvidia-595-server-open-generic

step "Docker CE (repositório oficial)"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
if ! curl -fsI "https://download.docker.com/linux/ubuntu/dists/${CODENAME}/Release" >/dev/null 2>&1; then
    echo "Aviso: dist '${CODENAME}' ainda não existe no repositório do Docker — usando fallback 'questing'"
    CODENAME="questing"
fi
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
usermod -aG docker embrapa

step "NVIDIA Container Toolkit (repositório oficial NVIDIA)"
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt-get update -qq
apt-get install -y -qq nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker
systemctl enable docker
systemctl restart docker

step "Concluído — reboot necessário para carregar o driver NVIDIA"
echo PROVISION-OK
