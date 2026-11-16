#!/bin/sh
set -e

if [ "$(id -u)" -ne 0 ]; then
  echo "Erro: setup-xiqi.sh deve ser executado como root." >&2
  exit 1
fi

umask 027

echo "=========================================="
echo "   INICIANDO INSTALACAO DO XIQI OS"
echo "   Arquitetura: x86_64 | Engecema"
echo "=========================================="

echo "[1/6] Habilitando repositorios oficiais do XIQI OS..."
sed -i 's/^#\(.*\/community\)/\1/' /etc/apk/repositories
apk update && apk upgrade

echo "[2/6] Instalando pacotes essenciais e rede..."
apk add --no-cache git curl wget nano htop bash shadow ca-certificates

echo "[3/6] Instalando Docker, Docker Compose e Tailscale..."
apk add --no-cache docker docker-cli-compose tailscale

echo "[4/6] Ativando servicos na inicializacao (OpenRC)..."
rc-update add docker default
rc-update add tailscale default
rc-service docker start
rc-service tailscale start

echo "[5/6] Criando estrutura de diretorios XIQI..."
mkdir -p /opt/xiqi/config
mkdir -p /opt/xiqi/config/profiles
mkdir -p /opt/xiqi/apps
mkdir -p /opt/xiqi/storage
mkdir -p /opt/xiqi/storage/profiles
mkdir -p /opt/xiqi/logs

chmod 750 /opt/xiqi /opt/xiqi/config /opt/xiqi/config/profiles /opt/xiqi/storage/profiles /opt/xiqi/logs

cat << 'EOF' > /opt/xiqi/config/system.conf
OS_NAME="XIQI OS"
KERNEL_ENGINE="XIQI Core x86_64"
ROLE="Operating System"
SYSTEM_TYPE="Corporate OS"
EOF
chmod 644 /opt/xiqi/config/system.conf

if [ ! -f /opt/xiqi/config/profiles.json ]; then
  cat << 'EOF' > /opt/xiqi/config/profiles.json
{
  "version": "1.0.0",
  "organization": "Corporação Engecema",
  "activeUserId": null,
  "users": []
}
EOF
  chmod 600 /opt/xiqi/config/profiles.json
fi

echo "[6/6] Aplicando identidade oficial XIQI OS..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "${SCRIPT_DIR}/branding-xiqi.sh" ]; then
  chmod 750 "${SCRIPT_DIR}/branding-xiqi.sh"
  sh "${SCRIPT_DIR}/branding-xiqi.sh"
else
  echo "Erro: branding-xiqi.sh nao encontrado em ${SCRIPT_DIR}." >&2
  exit 1
fi

echo "=========================================="
echo "   XIQI OS INSTALADO COM SUCESSO!"
echo "   Proximo passo: conectar Tailscale com"
echo "   o comando: tailscale up"
echo "=========================================="
