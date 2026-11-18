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
#   sh setup-xiqi.sh --update-disk /dev/sdXN
#     Atualiza e aplica as configurações recentes diretamente na partição existente
#     do disco rígido (ex: Dell OptiPlex 380), SEM formatar e preservando AreiaPreta.
#
#   sh setup-xiqi.sh --target-root /mnt/ponto
#     Aplica as configurações recentes em um disco já montado, sem formatar.
#
#   sh setup-xiqi.sh --install-disk /dev/sdX [--bios | --uefi] [--yes]
#     Particiona, formata e instala do zero o XIQI OS em disco novo/limpo.
# ==============================================================================

if [ "$(id -u)" -ne 0 ]; then
  echo "Erro: setup-xiqi.sh deve ser executado como root." >&2
  exit 1
fi

umask 027

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODE="local"
TARGET_DISK=""
TARGET_ROOT_DIR=""
AUTO_YES="false"
BOOT_MODE="auto"
NODE_VERSION="v22.14.0"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --install-disk)
      MODE="disk"
      TARGET_DISK="${2:-}"
      shift 2
      ;;
    --update-disk)
      MODE="update-disk"
      TARGET_DISK="${2:-}"
      shift 2
      ;;
    --target-root)
      MODE="target-root"
      TARGET_ROOT_DIR="${2:-}"
      shift 2
      ;;
    --bios|--legacy)
      BOOT_MODE="bios"
      shift
      ;;
    --uefi)
      BOOT_MODE="uefi"
      shift
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
      echo "Uso: $0 [--local | --update-disk /dev/sdXN | --target-root /mnt/dir | --install-disk /dev/sdX [--bios | --uefi] [--yes]]"
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

create_neutral_xiqi_user() {
  ROOT_PREFIX="${1:-}"
  if [ -z "${ROOT_PREFIX}" ]; then
    if ! id -u xiqi >/dev/null 2>&1; then
      adduser -D -s /bin/sh xiqi 2>/dev/null || useradd -m -s /bin/sh xiqi
    fi
    for grp in video input tty audio render; do
      if grep -q "^${grp}:" /etc/group 2>/dev/null; then
        addgroup xiqi "${grp}" 2>/dev/null || usermod -aG "${grp}" xiqi 2>/dev/null || true
      fi
    done
  else
    if command -v chroot >/dev/null 2>&1 && [ -x "${ROOT_PREFIX}/bin/sh" ]; then
      if ! chroot "${ROOT_PREFIX}" id -u xiqi >/dev/null 2>&1; then
        chroot "${ROOT_PREFIX}" adduser -D -s /bin/sh xiqi 2>/dev/null || \
        chroot "${ROOT_PREFIX}" useradd -m -s /bin/sh xiqi 2>/dev/null || true
      fi
      for grp in video input tty audio render; do
        if grep -q "^${grp}:" "${ROOT_PREFIX}/etc/group" 2>/dev/null; then
          chroot "${ROOT_PREFIX}" addgroup xiqi "${grp}" 2>/dev/null || \
          chroot "${ROOT_PREFIX}" usermod -aG "${grp}" xiqi 2>/dev/null || true
        fi
      done
    fi
  fi
  mkdir -p "${ROOT_PREFIX}/home/xiqi"
}

install_xiqi_stack() {
  ROOT_PREFIX="${1:-}"
  XIQI_BASE="${ROOT_PREFIX}/opt/xiqi"

  echo "[1/7] Criando hierarquia oficial de diretórios XIQI OS..."
  mkdir -p \
    "${XIQI_BASE}/app" \
    "${XIQI_BASE}/bin" \
    "${XIQI_BASE}/config" \
    "${XIQI_BASE}/config/profiles" \
    "${XIQI_BASE}/storage" \
    "${XIQI_BASE}/storage/profiles" \
    "${XIQI_BASE}/logs"

  chmod 755 "${XIQI_BASE}" "${XIQI_BASE}/app" "${XIQI_BASE}/logs"
  chmod 750 "${XIQI_BASE}/config" "${XIQI_BASE}/config/profiles" \
            "${XIQI_BASE}/storage" "${XIQI_BASE}/storage/profiles"

  echo "[2/7] Configurando usuário de sistema neutro 'xiqi'..."
  create_neutral_xiqi_user "${ROOT_PREFIX}"
  if [ -z "${ROOT_PREFIX}" ]; then
    chown -R xiqi:xiqi "${XIQI_BASE}/logs" 2>/dev/null || true
  elif command -v chroot >/dev/null 2>&1 && [ -x "${ROOT_PREFIX}/bin/sh" ]; then
    chroot "${ROOT_PREFIX}" chown -R xiqi:xiqi /opt/xiqi/logs 2>/dev/null || true
  fi

  echo "[3/7] Verificando runtime Node.js x86_64 independente..."
  if [ -z "${ROOT_PREFIX}" ]; then
    if ! command -v node >/dev/null 2>&1; then
      ARCH="$(uname -m)"
      OS_PLAT="$(uname -s | tr '[:upper:]' '[:lower:]')"
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
      curl --proto '=https' --tlsv1.2 -fsSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-${OS_PLAT}-${NODE_ARCH}.tar.xz" -o "${TMP_TAR}"
      mkdir -p "${XIQI_BASE}/runtime"
      tar -xJf "${TMP_TAR}" -C "${XIQI_BASE}/runtime" --strip-components=1
      rm -rf "${TMP_DIR}"
      mkdir -p /usr/local/bin
      ln -sf "${XIQI_BASE}/runtime/bin/node" /usr/local/bin/node
      ln -sf "${XIQI_BASE}/runtime/bin/npm" /usr/local/bin/npm
    else
      NODE_FOUND="$(command -v node)"
      mkdir -p /usr/local/bin
      if [ ! -x /usr/local/bin/node ]; then
        ln -sf "${NODE_FOUND}" /usr/local/bin/node
      fi
      if command -v npm >/dev/null 2>&1 && [ ! -x /usr/local/bin/npm ]; then
        ln -sf "$(command -v npm)" /usr/local/bin/npm
      fi
    fi
  else
    mkdir -p "${ROOT_PREFIX}/usr/local/bin"
    if [ ! -e "${ROOT_PREFIX}/usr/local/bin/node" ]; then
      if [ -x "${ROOT_PREFIX}/usr/bin/node" ]; then
        ln -sf /usr/bin/node "${ROOT_PREFIX}/usr/local/bin/node"
      elif command -v node >/dev/null 2>&1; then
        cp -f "$(command -v node)" "${ROOT_PREFIX}/usr/local/bin/node" 2>/dev/null || true
        chmod 755 "${ROOT_PREFIX}/usr/local/bin/node" 2>/dev/null || true
      fi
    fi
  fi

  echo "[4/7] Copiando aplicação e núcleo XIQI OS para ${XIQI_BASE}/app..."
  for f in package.json package-lock.json server.js index.html admin.html xiqi-browser.py .env.example; do
    if [ -f "${SCRIPT_DIR}/${f}" ]; then
      cp -f "${SCRIPT_DIR}/${f}" "${XIQI_BASE}/app/${f}"
    fi
  done
  if [ -f "${XIQI_BASE}/app/xiqi-browser.py" ]; then
    chmod 755 "${XIQI_BASE}/app/xiqi-browser.py"
  fi
  if [ -d "${SCRIPT_DIR}/node_modules" ]; then
    rm -rf "${XIQI_BASE}/app/node_modules"
    cp -a "${SCRIPT_DIR}/node_modules" "${XIQI_BASE}/app/node_modules"
  elif [ -z "${ROOT_PREFIX}" ] && command -v npm >/dev/null 2>&1; then
    (cd "${XIQI_BASE}/app" && npm install --omit=dev)
  elif [ -n "${ROOT_PREFIX}" ] && [ ! -d "${XIQI_BASE}/app/node_modules" ] && command -v chroot >/dev/null 2>&1 && [ -x "${ROOT_PREFIX}/bin/sh" ]; then
    chroot "${ROOT_PREFIX}" sh -c "if command -v npm >/dev/null 2>&1; then cd /opt/xiqi/app && npm install --omit=dev; fi" || true
  fi

  echo "[5/7] Inicializando base neutra de perfis e configuração de rede..."
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

  echo "[6/7] Configurando controlador nativo e boot gráfico direto no navegador XIQI OS..."
  cat << 'EOF' > "${XIQI_BASE}/bin/xiqictl"
#!/bin/sh
set -eu
XIQI_APP="/opt/xiqi/app"
XIQI_CONF="/opt/xiqi/config"
PID_FILE="/opt/xiqi/logs/xiqios.pid"
LOG_FILE="/opt/xiqi/logs/xiqios.log"

find_node() {
  for n in /usr/local/bin/node /usr/bin/node /opt/xiqi/runtime/bin/node; do
    if [ -x "$n" ]; then
      echo "$n"
      return 0
    fi
  done
  command -v node 2>/dev/null || true
}

cleanup_port() {
  PORT_NUM="${1:-3000}"
  KILLED=0
  if pkill -f "node.*${XIQI_APP}/server\\.js" 2>/dev/null || pkill -f "node.*server\\.js" 2>/dev/null; then
    KILLED=1
  fi
  if command -v fuser >/dev/null 2>&1; then
    if fuser -k "${PORT_NUM}/tcp" 2>/dev/null; then
      KILLED=1
    fi
  fi
  if [ "$KILLED" -eq 1 ]; then
    sleep 1
  fi
}

load_env() {
  export PORT="${PORT:-3000}"
  export XIQI_CONFIG_DIR="${XIQI_CONF}"
  if [ -f "${XIQI_CONF}/xiqi.env" ]; then
    set -a
    . "${XIQI_CONF}/xiqi.env"
    set +a
  fi
  export XIQI_AI_KEY="${XIQI_AI_KEY:-}"
}

case "${1:-status}" in
  start)
    load_env
    mkdir -p /opt/xiqi/logs "${XIQI_CONF}"
    chown -R xiqi:xiqi /opt/xiqi/logs 2>/dev/null || true
    if [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
      echo "XIQI OS já está em execução (PID $(cat "${PID_FILE}"))."
      exit 0
    fi
    cleanup_port "${PORT}"
    NODE_BIN="$(find_node)"
    if [ -z "${NODE_BIN}" ]; then
      echo "Erro: runtime Node.js não encontrado." >&2
      exit 1
    fi
    if [ ! -x /usr/local/bin/node ] && [ -x "${NODE_BIN}" ]; then
      mkdir -p /usr/local/bin
      ln -sf "${NODE_BIN}" /usr/local/bin/node 2>/dev/null || true
    fi
    nohup "${NODE_BIN}" "${XIQI_APP}/server.js" >> "${LOG_FILE}" 2>&1 &
    echo $! > "${PID_FILE}"
    echo "XIQI OS iniciado na porta ${PORT} (PID $!)."
    ;;
  stop)
    PORT_NUM="${PORT:-3000}"
    if [ -f "${PID_FILE}" ]; then
      PID="$(cat "${PID_FILE}")"
      kill "${PID}" 2>/dev/null || true
      rm -f "${PID_FILE}"
    fi
    cleanup_port "${PORT_NUM}"
    echo "XIQI OS encerrado."
    ;;
  restart)
    if command -v rc-service >/dev/null 2>&1 && [ -x /etc/init.d/xiqios ]; then
      rc-service xiqios restart
    elif command -v systemctl >/dev/null 2>&1; then
      systemctl restart xiqios
    else
      "$0" stop
      sleep 1
      "$0" start
    fi
    ;;
  status)
    if [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
      echo "XIQI OS ATIVO (PID $(cat "${PID_FILE}"))"
    elif pgrep -f "node.*server\\.js" >/dev/null 2>&1; then
      echo "XIQI OS ATIVO (PID $(pgrep -f 'node.*server\\.js' | head -n 1))"
    else
      echo "XIQI OS INATIVO"
      exit 1
    fi
    ;;
  update)
    cd "${XIQI_APP}"
    git -c safe.directory="${XIQI_APP}" fetch origin main
    git -c safe.directory="${XIQI_APP}" reset --hard origin/main
    "$0" restart
    echo "XIQI OS atualizado e reiniciado."
    ;;
  reboot)
    exec /sbin/reboot 2>/dev/null || exec reboot
    ;;
  shutdown)
    exec /sbin/poweroff 2>/dev/null || exec poweroff
    ;;
  *)
    echo "Uso: xiqictl {start|stop|restart|status|update|reboot|shutdown}"
    exit 1
    ;;
esac
EOF
  chmod 755 "${XIQI_BASE}/bin/xiqictl"
  mkdir -p "${ROOT_PREFIX}/usr/local/bin"
  ln -sf "/opt/xiqi/bin/xiqictl" "${ROOT_PREFIX}/usr/local/bin/xiqictl"
  chown -R root:root "${XIQI_BASE}/app" "${XIQI_BASE}/bin" "${XIQI_BASE}/config" "${XIQI_BASE}/storage" 2>/dev/null || true

  # Permissão sudo estrita e mínima para usuário neutro xiqi (sem comandos curinga)
  mkdir -p "${ROOT_PREFIX}/etc/sudoers.d"
  cat << 'EOF' > "${ROOT_PREFIX}/etc/sudoers.d/xiqi"
xiqi ALL=(ALL) NOPASSWD: /sbin/reboot, /usr/sbin/reboot, /bin/reboot, /sbin/poweroff, /usr/sbin/poweroff, /bin/poweroff, /sbin/rc-service xiqios restart, /usr/bin/systemctl restart xiqios, /opt/xiqi/bin/xiqictl start, /opt/xiqi/bin/xiqictl stop, /opt/xiqi/bin/xiqictl restart, /opt/xiqi/bin/xiqictl status, /opt/xiqi/bin/xiqictl update, /opt/xiqi/bin/xiqictl reboot, /opt/xiqi/bin/xiqictl shutdown, /usr/local/bin/xiqictl start, /usr/local/bin/xiqictl stop, /usr/local/bin/xiqictl restart, /usr/local/bin/xiqictl status, /usr/local/bin/xiqictl update, /usr/local/bin/xiqictl reboot, /usr/local/bin/xiqictl shutdown, /usr/bin/git -c safe.directory=/opt/xiqi/app fetch origin main, /usr/bin/git -c safe.directory=/opt/xiqi/app reset --hard origin/main
EOF
  chmod 0440 "${ROOT_PREFIX}/etc/sudoers.d/xiqi"
  if command -v git >/dev/null 2>&1 && [ -z "${ROOT_PREFIX}" ]; then
    git config --system --add safe.directory /opt/xiqi/app 2>/dev/null || true
  fi

  # Configuração de sessão gráfica direta via startx + xfwm4 + xiqi-browser.py (sem tela de login do SO)
  mkdir -p "${ROOT_PREFIX}/etc/X11" "${ROOT_PREFIX}/home/xiqi"
  cat << 'EOF' > "${ROOT_PREFIX}/etc/X11/Xwrapper.config"
allowed_users=anybody
needs_root_rights=yes
EOF
  chmod 644 "${ROOT_PREFIX}/etc/X11/Xwrapper.config"

  cat << 'EOF' > "${ROOT_PREFIX}/home/xiqi/.xinitrc"
#!/bin/sh
export HOME=/home/xiqi
export USER=xiqi
export DISPLAY="${DISPLAY:-:0}"
export XIQI_URL="http://127.0.0.1:3000"
export XIQI_FULLSCREEN="1"
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export WEBKIT_DISABLE_DMABUF_RENDERER=1
export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
export LIBGL_ALWAYS_SOFTWARE=1

if command -v xset >/dev/null 2>&1; then
  xset s off -dpms s noblank 2>/dev/null || true
fi

# Gerenciador de janelas mínimo xfwm4 (sem painéis, sem rodapés externos)
xfwm4 --compositor=off >/dev/null 2>&1 &

exec /usr/bin/python3 /opt/xiqi/app/xiqi-browser.py
EOF
  chmod 755 "${ROOT_PREFIX}/home/xiqi/.xinitrc"

  if [ -z "${ROOT_PREFIX}" ]; then
    chown -R xiqi:xiqi /home/xiqi 2>/dev/null || true
  elif command -v chroot >/dev/null 2>&1 && [ -x "${ROOT_PREFIX}/bin/sh" ]; then
    chroot "${ROOT_PREFIX}" chown -R xiqi:xiqi /home/xiqi 2>/dev/null || true
  fi

  # Serviços nativos OpenRC (/etc/init.d/xiqios e /etc/init.d/xiqi-display)
  mkdir -p "${ROOT_PREFIX}/etc/init.d"
  cat << 'EOF' > "${ROOT_PREFIX}/etc/init.d/xiqios"
#!/sbin/openrc-run

name="xiqios"
description="XIQI OS Corporate Server (Corporação Engecema)"

resolve_node() {
  for n in /usr/local/bin/node /usr/bin/node /opt/xiqi/runtime/bin/node; do
    if [ -x "$n" ]; then
      echo "$n"
      return 0
    fi
  done
  command -v node 2>/dev/null || echo "/usr/local/bin/node"
}

command="$(resolve_node)"
command_args="/opt/xiqi/app/server.js"
supervisor="supervise-daemon"
pidfile="/run/xiqios.pid"
output_log="/opt/xiqi/logs/xiqios.log"
error_log="/opt/xiqi/logs/xiqios.log"
respawn_delay="1"
respawn_max="0"

export PORT="${PORT:-3000}"
export XIQI_CONFIG_DIR="${XIQI_CONFIG_DIR:-/opt/xiqi/config}"
if [ -f "${XIQI_CONFIG_DIR}/xiqi.env" ]; then
  set -a
  . "${XIQI_CONFIG_DIR}/xiqi.env"
  set +a
fi
export XIQI_AI_KEY="${XIQI_AI_KEY:-}"

depend() {
  need localmount
  after loopback
}

start_pre() {
  mkdir -p /opt/xiqi/logs /opt/xiqi/config
  chown -R xiqi:xiqi /opt/xiqi/logs 2>/dev/null || true
  touch /opt/xiqi/logs/xiqios.log
  chown xiqi:xiqi /opt/xiqi/logs/xiqios.log 2>/dev/null || true

  if [ ! -x /usr/local/bin/node ]; then
    FOUND_NODE="$(resolve_node)"
    if [ -x "${FOUND_NODE}" ]; then
      mkdir -p /usr/local/bin
      ln -sf "${FOUND_NODE}" /usr/local/bin/node 2>/dev/null || true
    fi
  fi

  KILLED=0
  if pkill -f "node.*/opt/xiqi/app/server\\.js" 2>/dev/null || pkill -f "node.*server\\.js" 2>/dev/null; then
    KILLED=1
  fi
  if command -v fuser >/dev/null 2>&1; then
    if fuser -k "${PORT}/tcp" 2>/dev/null; then
      KILLED=1
    fi
  fi
  if [ "${KILLED}" -eq 1 ]; then
    sleep 1
  fi
}

stop_post() {
  pkill -f "node.*/opt/xiqi/app/server\\.js" 2>/dev/null || true
  if command -v fuser >/dev/null 2>&1; then
    fuser -k "${PORT}/tcp" 2>/dev/null || true
  fi
}
EOF
  chmod 755 "${ROOT_PREFIX}/etc/init.d/xiqios"

  cat << 'EOF' > "${ROOT_PREFIX}/etc/init.d/xiqi-display"
#!/sbin/openrc-run

name="xiqi-display"
description="XIQI OS Direct Browser Display (Corporação Engecema)"
pidfile="/run/xiqi-display.pid"

depend() {
  need localmount
  after xiqios
}

start() {
  ebegin "Iniciando interface gráfica direta XIQI OS (usuário neutro xiqi)"
  mkdir -p /opt/xiqi/logs /tmp/.X11-unix
  chmod 1777 /tmp/.X11-unix
  chown xiqi:xiqi /home/xiqi /home/xiqi/.xinitrc 2>/dev/null || true
  touch /opt/xiqi/logs/xiqi-display.log
  chown xiqi:xiqi /opt/xiqi/logs/xiqi-display.log 2>/dev/null || true

  start-stop-daemon --start --background --make-pidfile \
    --pidfile "${pidfile}" \
    --user xiqi --group xiqi \
    --env HOME=/home/xiqi \
    --env USER=xiqi \
    --env XIQI_URL=http://127.0.0.1:3000 \
    --env XIQI_FULLSCREEN=1 \
    --stdout /opt/xiqi/logs/xiqi-display.log \
    --stderr /opt/xiqi/logs/xiqi-display.log \
    --exec /bin/sh -- -c 'exec /usr/bin/startx /home/xiqi/.xinitrc -- :0 vt7 -nolisten tcp'
  eend $?
}

stop() {
  ebegin "Encerrando interface gráfica direta XIQI OS"
  start-stop-daemon --stop --quiet --pidfile "${pidfile}"
  eend $?
}
EOF
  chmod 755 "${ROOT_PREFIX}/etc/init.d/xiqi-display"

  if [ -z "${ROOT_PREFIX}" ] && command -v rc-update >/dev/null 2>&1; then
    for old_dm in lightdm gdm sddm; do
      rc-update del "${old_dm}" default 2>/dev/null || true
    done
    rc-update add xiqios default || true
    rc-update add xiqi-display default || true
  elif [ -n "${ROOT_PREFIX}" ] && command -v chroot >/dev/null 2>&1 && [ -x "${ROOT_PREFIX}/sbin/rc-update" ]; then
    for old_dm in lightdm gdm sddm; do
      chroot "${ROOT_PREFIX}" rc-update del "${old_dm}" default 2>/dev/null || true
    done
    chroot "${ROOT_PREFIX}" rc-update add xiqios default || true
    chroot "${ROOT_PREFIX}" rc-update add xiqi-display default || true
  fi

  # Units systemd para compatibilidade em servidores systemd
  mkdir -p "${ROOT_PREFIX}/etc/systemd/system"
  cat << 'EOF' > "${ROOT_PREFIX}/etc/systemd/system/xiqios.service"
[Unit]
Description=XIQI OS Corporate Server (Corporação Engecema)
After=local-fs.target

[Service]
Type=simple
WorkingDirectory=/opt/xiqi/app
Environment=PORT=3000
Environment=XIQI_CONFIG_DIR=/opt/xiqi/config
Environment=XIQI_AI_KEY=
ExecStart=/usr/local/bin/node /opt/xiqi/app/server.js
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

  cat << 'EOF' > "${ROOT_PREFIX}/etc/systemd/system/xiqi-display.service"
[Unit]
Description=XIQI OS Direct Browser Display (Corporação Engecema)
After=xiqios.service
Wants=xiqios.service

[Service]
Type=simple
User=xiqi
Group=xiqi
WorkingDirectory=/home/xiqi
Environment=HOME=/home/xiqi
Environment=USER=xiqi
Environment=XIQI_URL=http://127.0.0.1:3000
Environment=XIQI_FULLSCREEN=1
ExecStart=/usr/bin/startx /home/xiqi/.xinitrc -- :0 vt7 -nolisten tcp
Restart=always
RestartSec=3

[Install]
WantedBy=graphical.target
EOF

  if [ -z "${ROOT_PREFIX}" ] && command -v systemctl >/dev/null 2>&1; then
    for old_dm in lightdm gdm sddm; do
      systemctl disable "${old_dm}" 2>/dev/null || true
    done
    systemctl daemon-reload || true
    systemctl enable xiqios.service || true
    systemctl enable xiqi-display.service || true
    systemctl restart xiqios.service || true
  fi

  echo "[7/7] Aplicando identidade oficial XIQI OS..."
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

  if [ "${BOOT_MODE}" = "auto" ]; then
    if [ -d /sys/firmware/efi ]; then
      BOOT_MODE="uefi"
    else
      BOOT_MODE="bios"
    fi
  fi

  REQ_TOOLS="parted mkfs.ext4 blkid mount umount"
  if [ "${BOOT_MODE}" = "uefi" ]; then
    REQ_TOOLS="${REQ_TOOLS} mkfs.vfat"
  fi
  for tool in ${REQ_TOOLS}; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      echo "Erro: utilitário de disco obrigatório ausente no ambiente de instalação: ${tool}" >&2
      exit 1
    fi
  done

  if [ "${AUTO_YES}" != "true" ]; then
    echo "ATENÇÃO: Todos os dados em ${TARGET_DISK} serão apagados para instalar o XIQI OS (modo ${BOOT_MODE})!"
    printf "Digite 'INSTALAR' para confirmar: "
    read -r CONFIRM
    if [ "${CONFIRM}" != "INSTALAR" ]; then
      echo "Instalação cancelada pelo operador."
      exit 1
    fi
  fi

  for part_mounted in "${TARGET_DISK}"*; do
    umount "${part_mounted}" 2>/dev/null || true
  done

  MNT_DIR="/mnt/xiqi-target"
  cleanup_disk_mounts() {
    umount "${MNT_DIR}/dev" 2>/dev/null || true
    umount "${MNT_DIR}/proc" 2>/dev/null || true
    umount "${MNT_DIR}/sys" 2>/dev/null || true
    umount "${MNT_DIR}/boot/efi" 2>/dev/null || true
    umount "${MNT_DIR}" 2>/dev/null || true
  }
  trap cleanup_disk_mounts EXIT INT TERM

  if [ "${BOOT_MODE}" = "uefi" ]; then
    echo "Particionando ${TARGET_DISK} (GPT UEFI: EFI 512MB + Raiz XIQI ext4)..."
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
  else
    echo "Particionando ${TARGET_DISK} (MBR Legacy BIOS / Dell OptiPlex 380: Raiz XIQI ext4 inicializável)..."
    parted -s "${TARGET_DISK}" mklabel msdos
    parted -s "${TARGET_DISK}" mkpart primary ext4 1MiB 100%
    parted -s "${TARGET_DISK}" set 1 boot on

    case "${TARGET_DISK}" in
      *nvme*|*mmcblk*)
        PART_ROOT="${TARGET_DISK}p1"
        ;;
      *)
        PART_ROOT="${TARGET_DISK}1"
        ;;
    esac
    PART_EFI=""
  fi

  sleep 2
  if [ -n "${PART_EFI}" ]; then
    mkfs.vfat -F32 -n XIQIEFI "${PART_EFI}"
  fi
  mkfs.ext4 -F -L XIQIROOT "${PART_ROOT}"

  mkdir -p "${MNT_DIR}"
  mount "${PART_ROOT}" "${MNT_DIR}"
  mkdir -p "${MNT_DIR}/boot" "${MNT_DIR}/etc" "${MNT_DIR}/dev" "${MNT_DIR}/proc" "${MNT_DIR}/sys" "${MNT_DIR}/tmp" "${MNT_DIR}/run" "${MNT_DIR}/mnt" "${MNT_DIR}/root" "${MNT_DIR}/home" "${MNT_DIR}/var"
  chmod 1777 "${MNT_DIR}/tmp"
  if [ -n "${PART_EFI}" ]; then
    mkdir -p "${MNT_DIR}/boot/efi"
    mount "${PART_EFI}" "${MNT_DIR}/boot/efi"
  fi

  echo "Replicando sistema base para o disco do servidor..."
  for d in bin etc lib lib64 sbin usr var; do
    if [ -d "/${d}" ]; then
      cp -a "/${d}" "${MNT_DIR}/"
    fi
  done
  if [ -d /boot ]; then
    cp -a /boot/* "${MNT_DIR}/boot/" 2>/dev/null || true
  fi
  rm -f "${MNT_DIR}/etc/mtab" "${MNT_DIR}/run/"*.pid 2>/dev/null || true

  UUID_ROOT="$(blkid -s UUID -o value "${PART_ROOT}")"
  if [ -n "${PART_EFI}" ]; then
    UUID_EFI="$(blkid -s UUID -o value "${PART_EFI}")"
    cat << EOF > "${MNT_DIR}/etc/fstab"
UUID=${UUID_ROOT}  /          ext4  defaults,noatime,errors=remount-ro  0  1
UUID=${UUID_EFI}   /boot/efi  vfat  umask=0077                          0  2
EOF
  else
    cat << EOF > "${MNT_DIR}/etc/fstab"
UUID=${UUID_ROOT}  /          ext4  defaults,noatime,errors=remount-ro  0  1
EOF
  fi

  mount --bind /dev "${MNT_DIR}/dev" 2>/dev/null || true
  mount --bind /proc "${MNT_DIR}/proc" 2>/dev/null || true
  mount --bind /sys "${MNT_DIR}/sys" 2>/dev/null || true

  install_xiqi_stack "${MNT_DIR}"

  if [ -f "${MNT_DIR}/boot/extlinux.conf" ] && [ -n "${UUID_ROOT}" ]; then
    sed -i "s|root=UUID=[^[:space:]]*|root=UUID=${UUID_ROOT}|g" "${MNT_DIR}/boot/extlinux.conf" 2>/dev/null || true
  fi
  if [ -f "${MNT_DIR}/boot/grub/grub.cfg" ] && [ -n "${UUID_ROOT}" ]; then
    sed -i "s|root=UUID=[^[:space:]]*|root=UUID=${UUID_ROOT}|g" "${MNT_DIR}/boot/grub/grub.cfg" 2>/dev/null || true
  fi

  if [ "${BOOT_MODE}" = "uefi" ]; then
    if command -v grub-install >/dev/null 2>&1; then
      grub-install --target=x86_64-efi --efi-directory="${MNT_DIR}/boot/efi" --boot-directory="${MNT_DIR}/boot" --removable "${TARGET_DISK}" || true
    fi
  else
    INSTALLED_BOOT="false"
    if command -v extlinux >/dev/null 2>&1 && [ -f "${MNT_DIR}/boot/extlinux.conf" ]; then
      for mbr_cand in /usr/share/syslinux/mbr.bin /usr/lib/syslinux/mbr/mbr.bin /usr/lib/EXTLINUX/mbr.bin; do
        if [ -f "${mbr_cand}" ]; then
          dd if="${mbr_cand}" of="${TARGET_DISK}" bs=440 count=1 conv=notrunc 2>/dev/null || true
          break
        fi
      done
      if extlinux --install "${MNT_DIR}/boot"; then
        INSTALLED_BOOT="true"
      fi
    fi
    if [ "${INSTALLED_BOOT}" != "true" ] && command -v grub-install >/dev/null 2>&1; then
      grub-install --target=i386-pc --boot-directory="${MNT_DIR}/boot" "${TARGET_DISK}" || true
    fi
  fi

  sync
  cleanup_disk_mounts
  trap - EXIT INT TERM
  echo "=================================================================="
  echo "   XIQI OS INSTALADO NO DISCO ${TARGET_DISK} (${BOOT_MODE}) COM SUCESSO!"
  echo "   Reinicie o servidor (Dell OptiPlex 380) para iniciar pelo XIQI OS."
  echo "=================================================================="
elif [ "${MODE}" = "update-disk" ]; then
  if [ -z "${TARGET_DISK}" ] || [ ! -b "${TARGET_DISK}" ]; then
    echo "Erro: especifique uma partição válida existente com --update-disk (ex: /dev/sdb1 ou /dev/sda1)." >&2
    exit 1
  fi

  MNT_DIR="/mnt/xiqi-update"
  cleanup_update_mounts() {
    umount "${MNT_DIR}/dev" 2>/dev/null || true
    umount "${MNT_DIR}/proc" 2>/dev/null || true
    umount "${MNT_DIR}/sys" 2>/dev/null || true
    umount "${MNT_DIR}" 2>/dev/null || true
  }
  trap cleanup_update_mounts EXIT INT TERM

  mkdir -p "${MNT_DIR}"
  mount -o rw "${TARGET_DISK}" "${MNT_DIR}"

  if [ ! -d "${MNT_DIR}/etc" ] || [ ! -d "${MNT_DIR}/opt" ]; then
    echo "Erro: a partição ${TARGET_DISK} não contém uma instalação raiz válida (/etc e /opt ausentes)." >&2
    exit 1
  fi

  echo "Partição existente montada com segurança (sem formatação; dados e AreiaPreta preservados)."
  mount --bind /dev "${MNT_DIR}/dev" 2>/dev/null || true
  mount --bind /proc "${MNT_DIR}/proc" 2>/dev/null || true
  mount --bind /sys "${MNT_DIR}/sys" 2>/dev/null || true

  install_xiqi_stack "${MNT_DIR}"

  sync
  cleanup_update_mounts
  trap - EXIT INT TERM
  echo "=================================================================="
  echo "   ATUALIZAÇÃO APLICADA NA PARTIÇÃO ${TARGET_DISK} COM SUCESSO!"
  echo "   Banco AreiaPreta e configurações existentes foram preservados."
  echo "=================================================================="
elif [ "${MODE}" = "target-root" ]; then
  if [ -z "${TARGET_ROOT_DIR}" ] || [ ! -d "${TARGET_ROOT_DIR}/etc" ]; then
    echo "Erro: especifique um diretório raiz montado válido com --target-root (ex: /mnt/380)." >&2
    exit 1
  fi
  install_xiqi_stack "${TARGET_ROOT_DIR%/}"
  sync
  echo "=================================================================="
  echo "   CONFIGURAÇÕES APLICADAS EM ${TARGET_ROOT_DIR} COM SUCESSO!"
  echo "   Banco AreiaPreta e configurações existentes foram preservados."
  echo "=================================================================="
else
  install_xiqi_stack ""
  echo "=================================================================="
  echo "   XIQI OS CONFIGURADO COM SUCESSO NO SERVIDOR LOCAL!"
  echo "   Iniciar serviço: xiqictl start (ou service xiqi-display start)"
  echo "=================================================================="
fi
