#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "Erro: branding-xiqi.sh deve ser executado como root." >&2
  exit 1
fi

TARGET_ROOT="${1:-}"

echo "=================================================="
echo "   APLICANDO IDENTIDADE INDEPENDENTE XIQI OS"
echo "   Corporação Engecema | Núcleo XIQI Core x86_64"
echo "=================================================="

mkdir -p "${TARGET_ROOT}/etc" "${TARGET_ROOT}/opt/xiqi/config"

echo "[1/4] Configurando /etc/os-release e /etc/xiqi-release..."
rm -f "${TARGET_ROOT}/etc/os-release"
cat << 'EOF' > "${TARGET_ROOT}/etc/os-release"
NAME="XIQI OS"
ID=xiqi
VERSION="1.0.0"
VERSION_ID=1.0.0
PRETTY_NAME="XIQI OS v1.0 Independente (Corporação Engecema)"
HOME_URL="https://xiqios.local"
SUPPORT_URL="https://xiqios.local/admin"
XIQI_KERNEL="XIQI Core x86_64"
XIQI_EDITION="Data Center Bare-Metal"
EOF

cat << 'EOF' > "${TARGET_ROOT}/etc/xiqi-release"
XIQI OS v1.0 (XIQI Core x86_64) — Sistema Operacional Corporativo Independente — Corporação Engecema
EOF

echo "[2/4] Configurando hostname xiqios..."
echo "xiqios" > "${TARGET_ROOT}/etc/hostname"
if [ ! -f "${TARGET_ROOT}/etc/hosts" ]; then
  cat << 'EOF' > "${TARGET_ROOT}/etc/hosts"
127.0.0.1   localhost xiqios xiqios.local
::1         localhost xiqios xiqios.local
EOF
fi

echo "[3/4] Substituindo banners de sistema (/etc/issue e /etc/motd)..."
cat << 'EOF' > "${TARGET_ROOT}/etc/issue"

================================================================
  XIQI OS v1.0 — Sistema Operacional Corporativo Independente
  Corporação Engecema | Arquitetura: x86_64 | Data Center
================================================================

EOF

cat << 'EOF' > "${TARGET_ROOT}/etc/motd"
================================================================
  XIQI OS v1.0 — Infraestrutura Corporativa Engecema
  Núcleo: XIQI Core x86_64 | Edição Data Center Independente
  Diretórios: /opt/xiqi/app | /opt/xiqi/config | /opt/xiqi/storage
  Gerenciamento de serviço: xiqictl status
================================================================
EOF

echo "[4/4] Atualizando /opt/xiqi/config/system.conf..."
cat << 'EOF' > "${TARGET_ROOT}/opt/xiqi/config/system.conf"
OS_NAME="XIQI OS"
OS_VERSION="1.0.0"
KERNEL_ENGINE="XIQI Core x86_64"
ROLE="Corporate Operating System"
SYSTEM_TYPE="Data Center Bare-Metal"
ORGANIZATION="Corporação Engecema"
INDEPENDENT_BUILD="true"
DISPLAY_MODE="direct-browser"
DISPLAY_USER="xiqi"
DISPLAY_ENTRY="http://127.0.0.1:3000"
DEFAULT_PERSONAL_USER="none"
EOF

chmod 644 "${TARGET_ROOT}/etc/os-release" \
          "${TARGET_ROOT}/etc/xiqi-release" \
          "${TARGET_ROOT}/etc/issue" \
          "${TARGET_ROOT}/etc/motd" \
          "${TARGET_ROOT}/etc/hostname" \
          "${TARGET_ROOT}/opt/xiqi/config/system.conf"

echo "=================================================="
echo "   IDENTIDADE INDEPENDENTE XIQI OS APLICADA!"
echo "=================================================="
