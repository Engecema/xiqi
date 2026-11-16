#!/bin/sh
set -e

if [ "$(id -u)" -ne 0 ]; then
  echo "Erro: branding-xiqi.sh deve ser executado como root." >&2
  exit 1
fi

echo "=========================================="
echo "   APLICANDO IDENTIDADE OFICIAL XIQI OS"
echo "   Infraestrutura Corporativa - Engecema"
echo "=========================================="

echo "[1/3] Atualizando /etc/os-release..."
rm -f /etc/os-release
cat << 'EOF' > /etc/os-release
NAME="XIQI OS"
ID=xiqi
VERSION_ID=1.0.0
PRETTY_NAME="XIQI OS v1.0 (Engecema)"
HOME_URL="https://github.com"
EOF

echo "[2/3] Substituindo banners de login (/etc/issue e /etc/motd)..."
cat << 'EOF' > /etc/issue

================================================================
  XIQI OS - Infraestrutura Corporativa Engecema
  Arquitetura: x86_64 | Sistema Operacional Corporativo
================================================================

EOF

cat << 'EOF' > /etc/motd
================================================================
  XIQI OS - Infraestrutura Corporativa Engecema
  Kernel Engine: XIQI Core x86_64 | Sistema Operacional Corporativo Ultraleve
  Diretorios: /opt/xiqi/config | /opt/xiqi/apps | /opt/xiqi/storage
================================================================
EOF

echo "[3/3] Atualizando /opt/xiqi/config/system.conf..."
mkdir -p /opt/xiqi/config
cat << 'EOF' > /opt/xiqi/config/system.conf
OS_NAME="XIQI OS"
KERNEL_ENGINE="XIQI Core x86_64"
ROLE="Operating System"
SYSTEM_TYPE="Corporate OS"
EOF

chmod 644 /etc/os-release /etc/issue /etc/motd /opt/xiqi/config/system.conf

echo "=========================================="
echo "   IDENTIDADE XIQI OS APLICADA!"
echo "=========================================="
