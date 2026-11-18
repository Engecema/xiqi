#!/bin/sh
set -eu

# ==============================================================================
# XIQI OS v1.0 — Instalador Corporativo Independente (x86_64 / Data Center)
# Corporação Engecema — Sem dependências de distribuições externas
#
# Modos de uso:
#   sh setup-xiqi.sh --local
#     Instala e configura o XIQI OS no servidor atual (/opt/xiqi).
#
#   sh setup-xiqi.sh --install-disk /dev/sdX [--yes]
#     Particiona, formata e instala o XIQI OS diretamente no disco rígido/NVMe
#     do servidor de data center (UEFI/GPT + Bootloader GRUB + Núcleo XIQI).
# ==============================================================================

if [ "$(id -u)" -ne 0 ]; then
  echo "Erro: setup-xiqi.sh deve ser executado como root." >&2
  exit 1
fi

umask 027

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODE="local"
TARGET_DISK=""
AUTO_YES="false"
NODE_VERSION="v22.14.0"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --install-disk)
      MODE="disk"
      TARGET_DISK="${2:-}"
      shift 2
      ;;
    --local)
      MODE="local"
      shift
      ;;
    --yes|-y)
      AUTO_YES="true"
      shift
      ;;
    --help|-h)
      echo "Uso: $0 [--local | --install-disk /dev/sdX [--yes]]"
      exit 0
      ;;
    *)
      echo "Parâmetro desconhecido: $1" >&2
      exit 1
      ;;
  esac
done

echo "=================================================================="
echo "   XIQI OS v1.0 — INSTALADOR OFICIAL INDEPENDENTE (DATA CENTER)"
echo "   Arquitetura: x86_64 | Organização: Corporação Engecema"
echo "=================================================================="

install_xiqi_stack() {
  ROOT_PREFIX="${1:-}"
  XIQI_BASE="${ROOT_PREFIX}/opt/xiqi"

  echo "[1/6] Criando hierarquia oficial de diretórios XIQI OS..."
  mkdir -p \
    "${XIQI_BASE}/app" \
    "${XIQI_BASE}/bin" \
    "${XIQI_BASE}/config" \
    "${XIQI_BASE}/config/profiles" \
    "${XIQI_BASE}/storage" \
    "${XIQI_BASE}/storage/profiles" \
    "${XIQI_BASE}/logs"

  chmod 750 "${XIQI_BASE}" "${XIQI_BASE}/config" "${XIQI_BASE}/config/profiles" \
            "${XIQI_BASE}/storage/profiles" "${XIQI_BASE}/logs"

  echo "[2/6] Verificando runtime Node.js x86_64 independente..."
  if [ -z "${ROOT_PREFIX}" ] && ! command -v node >/dev/null 2>&1; then
    ARCH="$(uname -m)"
    if [ "${ARCH}" = "x86_64" ]; then
      NODE_ARCH="x64"
    elif [ "${ARCH}" = "aarch64" ]; then
      NODE_ARCH="arm64"
    else
      echo "Arquitetura não suportada para runtime automático: ${ARCH}" >&2
      exit 1
    fi
    TMP_DIR="$(mktemp -d)"
    TMP_TAR="${TMP_DIR}/node.tar.xz"
    echo "Baixando runtime binário oficial Node.js ${NODE_VERSION} (${NODE_ARCH})..."
    curl --proto '=https' --tlsv1.2 -fsSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" -o "${TMP_TAR}"
    mkdir -p "${XIQI_BASE}/runtime"
    tar -xJf "${TMP_TAR}" -C "${XIQI_BASE}/runtime" --strip-components=1
    rm -rf "${TMP_DIR}"
    ln -sf "${XIQI_BASE}/runtime/bin/node" /usr/local/bin/node
    ln -sf "${XIQI_BASE}/runtime/bin/npm" /usr/local/bin/npm
  fi

  echo "[3/6] Copiando aplicação e núcleo XIQI OS para ${XIQI_BASE}/app..."
  for f in package.json package-lock.json server.js index.html admin.html xiqi-browser.py .env.example; do
    if [ -f "${SCRIPT_DIR}/${f}" ]; then
      cp -f "${SCRIPT_DIR}/${f}" "${XIQI_BASE}/app/${f}"
    fi
  done
  if [ -d "${SCRIPT_DIR}/node_modules" ]; then
    rm -rf "${XIQI_BASE}/app/node_modules"
    cp -a "${SCRIPT_DIR}/node_modules" "${XIQI_BASE}/app/node_modules"
  elif [ -z "${ROOT_PREFIX}" ] && command -v npm >/dev/null 2>&1; then
    (cd "${XIQI_BASE}/app" && npm install --omit=dev)
  fi

  echo "[4/6] Inicializando base de perfis e configuração de rede..."
  if [ ! -f "${XIQI_BASE}/config/profiles.json" ]; then
    cat << 'EOF' > "${XIQI_BASE}/config/profiles.json"
{
  "version": "1.0.0",
  "organization": "Corporação Engecema",
  "activeUserId": null,
  "users": [],
  "guestSession": null
}
EOF
    chmod 600 "${XIQI_BASE}/config/profiles.json"
  fi

  if [ ! -f "${XIQI_BASE}/config/network.conf" ]; then
    cat << 'EOF' > "${XIQI_BASE}/config/network.conf"
XIQI_HOST="0.0.0.0"
XIQI_PORT="3000"
XIQI_HOSTNAME="xiqios"
EOF
    chmod 644 "${XIQI_BASE}/config/network.conf"
  fi

  echo "[5/6] Instalando controlador nativo de serviços (xiqictl) e unit systemd..."
  cat << 'EOF' > "${XIQI_BASE}/bin/xiqictl"
#!/bin/sh
set -eu
XIQI_APP="/opt/xiqi/app"
XIQI_CONF="/opt/xiqi/config"
PID_FILE="/opt/xiqi/logs/xiqios.pid"
LOG_FILE="/opt/xiqi/logs/xiqios.log"

case "${1:-status}" in
  start)
    if [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
      echo "XIQI OS já está em execução (PID $(cat "${PID_FILE}"))."
      exit 0
    fi
    export PORT="${PORT:-3000}"
    export XIQI_CONFIG_DIR="${XIQI_CONF}"
    export XIQI_AI_KEY="${XIQI_AI_KEY:-}"
    nohup node "${XIQI_APP}/server.js" >> "${LOG_FILE}" 2>&1 &
    echo $! > "${PID_FILE}"
    echo "XIQI OS iniciado na porta ${PORT} (PID $!)."
    ;;
  stop)
    if [ -f "${PID_FILE}" ]; then
      PID="$(cat "${PID_FILE}")"
      kill "${PID}" 2>/dev/null || true
      rm -f "${PID_FILE}"
      echo "XIQI OS encerrado."
    else
      echo "XIQI OS não está em execução."
    fi
    ;;
  restart)
    "$0" stop
    sleep 1
    "$0" start
    ;;
  status)
    if [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
      echo "XIQI OS ATIVO (PID $(cat "${PID_FILE}"))"
    else
      echo "XIQI OS INATIVO"
      exit 1
    fi
    ;;
  *)
    echo "Uso: xiqictl {start|stop|restart|status}"
    exit 1
    ;;
esac
EOF
  chmod 750 "${XIQI_BASE}/bin/xiqictl"
  mkdir -p "${ROOT_PREFIX}/usr/local/bin"
  ln -sf "/opt/xiqi/bin/xiqictl" "${ROOT_PREFIX}/usr/local/bin/xiqictl"

  mkdir -p "${ROOT_PREFIX}/etc/systemd/system"
  cat << 'EOF' > "${ROOT_PREFIX}/etc/systemd/system/xiqios.service"
[Unit]
Description=XIQI OS Corporate Server (Corporação Engecema)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/xiqi/app
Environment=PORT=3000
Environment=XIQI_CONFIG_DIR=/opt/xiqi/config
Environment=XIQI_AI_KEY=
ExecStart=/usr/local/bin/node /opt/xiqi/app/server.js
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  if [ -z "${ROOT_PREFIX}" ] && command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
    systemctl enable xiqios.service || true
    systemctl restart xiqios.service || true
  fi

  echo "[6/6] Aplicando identidade oficial XIQI OS..."
  if [ -f "${SCRIPT_DIR}/branding-xiqi.sh" ]; then
    chmod 750 "${SCRIPT_DIR}/branding-xiqi.sh"
    sh "${SCRIPT_DIR}/branding-xiqi.sh" "${ROOT_PREFIX}"
  else
    echo "Erro: branding-xiqi.sh não encontrado em ${SCRIPT_DIR}." >&2
    exit 1
  fi
}

if [ "${MODE}" = "disk" ]; then
  if [ -z "${TARGET_DISK}" ] || [ ! -b "${TARGET_DISK}" ]; then
    echo "Erro: especifique um dispositivo de bloco válido com --install-disk (ex: /dev/sda ou /dev/nvme0n1)." >&2
    exit 1
  fi

  for tool in parted mkfs.vfat mkfs.ext4 blkid mount umount; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      echo "Erro: utilitário de disco obrigatório ausente no ambiente de instalação: ${tool}" >&2
      exit 1
    fi
  done

  if [ "${AUTO_YES}" != "true" ]; then
    echo "ATENÇÃO: Todos os dados em ${TARGET_DISK} serão apagados para instalar o XIQI OS!"
    printf "Digite 'INSTALAR' para confirmar: "
    read -r CONFIRM
    if [ "${CONFIRM}" != "INSTALAR" ]; then
      echo "Instalação cancelada pelo operador."
      exit 1
    fi
  fi

  echo "Particionando ${TARGET_DISK} (GPT: EFI 512MB + Raiz XIQI ext4)..."
  parted -s "${TARGET_DISK}" mklabel gpt
  parted -s "${TARGET_DISK}" mkpart ESP fat32 1MiB 513MiB
  parted -s "${TARGET_DISK}" set 1 esp on
  parted -s "${TARGET_DISK}" mkpart XIQI_ROOT ext4 513MiB 100%

  case "${TARGET_DISK}" in
    *nvme*|*mmcblk*)
      PART_EFI="${TARGET_DISK}p1"
      PART_ROOT="${TARGET_DISK}p2"
      ;;
    *)
      PART_EFI="${TARGET_DISK}1"
      PART_ROOT="${TARGET_DISK}2"
      ;;
  esac

  sleep 2
  mkfs.vfat -F32 -n XIQIEFI "${PART_EFI}"
  mkfs.ext4 -F -L XIQIROOT "${PART_ROOT}"

  MNT_DIR="/mnt/xiqi-target"
  mkdir -p "${MNT_DIR}"
  mount "${PART_ROOT}" "${MNT_DIR}"
  mkdir -p "${MNT_DIR}/boot/efi" "${MNT_DIR}/etc" "${MNT_DIR}/dev" "${MNT_DIR}/proc" "${MNT_DIR}/sys" "${MNT_DIR}/tmp"
  mount "${PART_EFI}" "${MNT_DIR}/boot/efi"

  echo "Replicando sistema base para o disco do data center..."
  for d in bin lib lib64 sbin usr; do
    if [ -d "/${d}" ]; then
      cp -a "/${d}" "${MNT_DIR}/"
    fi
  done
  if [ -d "/boot" ]; then
    cp -a /boot/* "${MNT_DIR}/boot/" 2>/dev/null || true
  fi

  UUID_ROOT="$(blkid -s UUID -o value "${PART_ROOT}")"
  UUID_EFI="$(blkid -s UUID -o value "${PART_EFI}")"
  cat << EOF > "${MNT_DIR}/etc/fstab"
UUID=${UUID_ROOT}  /          ext4  defaults,noatime,errors=remount-ro  0  1
UUID=${UUID_EFI}   /boot/efi  vfat  umask=0077                          0  2
EOF

  install_xiqi_stack "${MNT_DIR}"

  if command -v grub-install >/dev/null 2>&1; then
    grub-install --target=x86_64-efi --efi-directory="${MNT_DIR}/boot/efi" --boot-directory="${MNT_DIR}/boot" --removable "${TARGET_DISK}" || \
    grub-install --target=i386-pc --boot-directory="${MNT_DIR}/boot" "${TARGET_DISK}" || true
  fi

  umount -R "${MNT_DIR}" || true
  echo "=================================================================="
  echo "   XIQI OS INSTALADO NO DISCO ${TARGET_DISK} COM SUCESSO!"
  echo "   Reinicie o servidor de data center para iniciar pelo XIQI OS."
  echo "=================================================================="
else
  install_xiqi_stack ""
  echo "=================================================================="
  echo "   XIQI OS CONFIGURADO COM SUCESSO NO SERVIDOR LOCAL!"
  echo "   Iniciar serviço: xiqictl start (ou systemctl start xiqios)"
  echo "=================================================================="
fi
