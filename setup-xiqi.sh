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
  for f in package.json package-lock.json server.js index.html admin.html xiqi-browser.py .env.example .env; do
    if [ -f "${SCRIPT_DIR}/${f}" ]; then
      cp -f "${SCRIPT_DIR}/${f}" "${XIQI_BASE}/app/${f}"
    fi
  done
  if [ -f "${XIQI_BASE}/app/.env" ]; then
    chmod 600 "${XIQI_BASE}/app/.env" 2>/dev/null || true
  fi
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
  if [ -f "${XIQI_APP}/.env" ]; then
    set -a
    . "${XIQI_APP}/.env"
    set +a
  fi
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

  # Configuração de teclado ABNT2 (pt-BR), vídeo estável e sessão gráfica direta via startx + xfwm4 + xiqi-browser.py
  mkdir -p "${ROOT_PREFIX}/etc/X11" "${ROOT_PREFIX}/etc/X11/xorg.conf.d" "${ROOT_PREFIX}/etc/default" "${ROOT_PREFIX}/home/xiqi"
  cat << 'EOF' > "${ROOT_PREFIX}/etc/X11/Xwrapper.config"
allowed_users=anybody
needs_root_rights=yes
EOF
  chmod 644 "${ROOT_PREFIX}/etc/X11/Xwrapper.config"

  cat << 'EOF' > "${ROOT_PREFIX}/etc/X11/xorg.conf.d/00-keyboard.conf"
Section "InputClass"
  Identifier "system-keyboard"
  MatchIsKeyboard "on"
  Option "XkbModel" "abnt2"
  Option "XkbLayout" "br"
EndSection
EOF
  chmod 644 "${ROOT_PREFIX}/etc/X11/xorg.conf.d/00-keyboard.conf"

  cat << 'EOF' > "${ROOT_PREFIX}/etc/default/keyboard"
XKBMODEL="abnt2"
XKBLAYOUT="br"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF
  chmod 644 "${ROOT_PREFIX}/etc/default/keyboard"

  cat << 'EOF' > "${ROOT_PREFIX}/etc/X11/xorg.conf.d/10-xiqi-video.conf"
Section "ServerFlags"
  Option "BlankTime" "0"
  Option "StandbyTime" "0"
  Option "SuspendTime" "0"
  Option "OffTime" "0"
  Option "DontVTSwitch" "false"
EndSection

Section "Monitor"
  Identifier "DefaultMonitor"
  Option "DPMS" "false"
EndSection
EOF
  chmod 644 "${ROOT_PREFIX}/etc/X11/xorg.conf.d/10-xiqi-video.conf"

  cat << 'EOF' > "${XIQI_BASE}/bin/xiqi-keyboard"
#!/bin/sh
MODEL="${1:-abnt2}"
LAYOUT="${2:-br}"
VARIANT="${3:-}"
if command -v setxkbmap >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
  if [ -n "${VARIANT}" ]; then
    setxkbmap -model "${MODEL}" -layout "${LAYOUT}" -variant "${VARIANT}" 2>/dev/null || setxkbmap -layout "${LAYOUT}" 2>/dev/null || true
  else
    setxkbmap -model "${MODEL}" -layout "${LAYOUT}" 2>/dev/null || setxkbmap -layout "${LAYOUT}" 2>/dev/null || true
  fi
fi
if command -v loadkeys >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
  loadkeys br-abnt2 2>/dev/null || true
fi
EOF
  chmod 755 "${XIQI_BASE}/bin/xiqi-keyboard"
  ln -sf "/opt/xiqi/bin/xiqi-keyboard" "${ROOT_PREFIX}/usr/local/bin/xiqi-keyboard"

  if [ -z "${ROOT_PREFIX}" ] && command -v loadkeys >/dev/null 2>&1; then
    loadkeys br-abnt2 2>/dev/null || true
  fi

  cat << 'EOF' > "${ROOT_PREFIX}/home/xiqi/.xinitrc"
#!/bin/sh
export HOME=/home/xiqi
export USER=xiqi
export DISPLAY="${DISPLAY:-:0}"
export XIQI_URL="http://127.0.0.1:3000"
export XIQI_FULLSCREEN="1"
export GDK_BACKEND=x11
export GSK_RENDERER=cairo
export GTK_THEME="Adwaita:light"
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export WEBKIT_DISABLE_DMABUF_RENDERER=1
export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
export WEBKIT_FORCE_SANDBOX=0
export LIBGL_ALWAYS_SOFTWARE=1

if command -v setterm >/dev/null 2>&1; then
  setterm -blank 0 -powerdown 0 2>/dev/null || true
fi
if command -v xset >/dev/null 2>&1; then
  xset s off -dpms s noblank 2>/dev/null || true
fi
if command -v xrandr >/dev/null 2>&1; then
  xrandr --auto 2>/dev/null || true
fi
if command -v xsetroot >/dev/null 2>&1; then
  xsetroot -solid "#ffffff" 2>/dev/null || true
fi
if command -v setxkbmap >/dev/null 2>&1; then
  setxkbmap -model abnt2 -layout br 2>/dev/null || setxkbmap br 2>/dev/null || true
fi

# Gerenciador de janelas mínimo xfwm4 (sem painéis, sem rodapés externos)
xfwm4 --compositor=off >/dev/null 2>&1 &

exec /usr/bin/python3 /opt/xiqi/app/xiqi-browser.py
EOF
  chmod 755 "${ROOT_PREFIX}/home/xiqi/.xinitrc"

  # Hook de retorno de suspensão para evitar tela escura/travada ao acordar o monitor
  for sleep_dir in "${ROOT_PREFIX}/etc/elogind/system-sleep" "${ROOT_PREFIX}/etc/systemd/system-sleep"; do
    mkdir -p "${sleep_dir}"
    cat << 'EOF' > "${sleep_dir}/90-xiqi-video.sh"
#!/bin/sh
case "${1:-}" in
  post|thaw)
    export DISPLAY=":0"
    export XAUTHORITY="/home/xiqi/.Xauthority"
    if command -v xrandr >/dev/null 2>&1; then
      xrandr --auto 2>/dev/null || true
    fi
    if command -v xset >/dev/null 2>&1; then
      xset dpms force on 2>/dev/null || true
      xset s off -dpms s noblank 2>/dev/null || true
    fi
    if command -v setxkbmap >/dev/null 2>&1; then
      setxkbmap -model abnt2 -layout br 2>/dev/null || true
    fi
    ;;
esac
EOF
    chmod 755 "${sleep_dir}/90-xiqi-video.sh"
  done

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
if [ -f "/opt/xiqi/app/.env" ]; then
  set -a
  . "/opt/xiqi/app/.env"
  set +a
fi
if [ -f "${XIQI_CONFIG_DIR}/xiqi.env" ]; then
  set -a
  . "${XIQI_CONFIG_DIR}/xiqi.env"
  set +a
fi
export XIQI_AI_KEY="${XIQI_AI_KEY:-}"

depend() {
  need localmount net
  after loopback net
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
  need localmount net
  after net xiqios
}

start() {
  ebegin "Iniciando interface gráfica direta XIQI OS (usuário neutro xiqi)"
  mkdir -p /opt/xiqi/logs /tmp/.X11-unix
  chmod 1777 /tmp/.X11-unix
  rm -f /tmp/.X0-lock /tmp/.X11-unix/X0 2>/dev/null || true
  chown xiqi:xiqi /home/xiqi /home/xiqi/.xinitrc 2>/dev/null || true
  touch /opt/xiqi/logs/xiqi-display.log
  chown xiqi:xiqi /opt/xiqi/logs/xiqi-display.log 2>/dev/null || true

  i=0
  while [ "$i" -lt 20 ]; do
    if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 1 "http://127.0.0.1:3000/api/system" >/dev/null 2>&1; then
      break
    fi
    i=$((i + 1))
    sleep 0.5
  done

  if command -v chvt >/dev/null 2>&1; then
    chvt 7 2>/dev/null || true
  fi

  start-stop-daemon --start --background --make-pidfile \
    --pidfile "${pidfile}" \
    --user xiqi --group xiqi \
    --env HOME=/home/xiqi \
    --env USER=xiqi \
    --env GDK_BACKEND=x11 \
    --env GSK_RENDERER=cairo \
    --env GTK_THEME=Adwaita:light \
    --env WEBKIT_DISABLE_COMPOSITING_MODE=1 \
    --env WEBKIT_DISABLE_DMABUF_RENDERER=1 \
    --env WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 \
    --env WEBKIT_FORCE_SANDBOX=0 \
    --env LIBGL_ALWAYS_SOFTWARE=1 \
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
  rm -f /tmp/.X0-lock /tmp/.X11-unix/X0 2>/dev/null || true
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
After=local-fs.target network.target

[Service]
Type=simple
WorkingDirectory=/opt/xiqi/app
Environment=PORT=3000
Environment=XIQI_CONFIG_DIR=/opt/xiqi/config
EnvironmentFile=-/opt/xiqi/app/.env
EnvironmentFile=-/opt/xiqi/config/xiqi.env
ExecStart=/usr/local/bin/node /opt/xiqi/app/server.js
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

  cat << 'EOF' > "${ROOT_PREFIX}/etc/systemd/system/xiqi-display.service"
[Unit]
Description=XIQI OS Direct Browser Display (Corporação Engecema)
After=network-online.target xiqios.service
Wants=network-online.target xiqios.service
Conflicts=getty@tty1.service

[Service]
Type=simple
User=xiqi
Group=xiqi
WorkingDirectory=/home/xiqi
Environment=HOME=/home/xiqi
Environment=USER=xiqi
Environment=GDK_BACKEND=x11
Environment=GSK_RENDERER=cairo
Environment=GTK_THEME=Adwaita:light
Environment=WEBKIT_DISABLE_COMPOSITING_MODE=1
Environment=WEBKIT_DISABLE_DMABUF_RENDERER=1
Environment=WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
Environment=WEBKIT_FORCE_SANDBOX=0
Environment=LIBGL_ALWAYS_SOFTWARE=1
Environment=XIQI_URL=http://127.0.0.1:3000
Environment=XIQI_FULLSCREEN=1
ExecStartPre=-/bin/sh -c 'rm -f /tmp/.X0-lock /tmp/.X11-unix/X0; command -v chvt >/dev/null 2>&1 && chvt 7 || true'
ExecStart=/usr/bin/startx /home/xiqi/.xinitrc -- :0 vt7 -nolisten tcp
Restart=always
RestartSec=2

[Install]
WantedBy=graphical.target
EOF

  if [ -z "${ROOT_PREFIX}" ] && command -v systemctl >/dev/null 2>&1; then
    for old_dm in lightdm gdm sddm; do
      systemctl disable "${old_dm}" 2>/dev/null || true
    done
    systemctl daemon-reload || true
    systemctl set-default graphical.target 2>/dev/null || true
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

  configure_silent_boot_and_fsck "${ROOT_PREFIX}"
  configure_https_reverse_proxy "${ROOT_PREFIX}"
  configure_fast_network_and_ntp "${ROOT_PREFIX}"
}

configure_silent_boot_and_fsck() {
  ROOT_PREFIX="${1:-}"
  QUIET_OPTS="quiet loglevel=0 vt.global_cursor_default=0 rd.udev.log_level=0 systemd.show_status=false rd.systemd.show_status=false fsck.mode=skip fastboot fbcon=nodefer"

  mkdir -p "${ROOT_PREFIX}/etc/conf.d" "${ROOT_PREFIX}/etc/default" "${ROOT_PREFIX}/boot"

  # Suprimir logs e barras de fsck na inicialização e no reinício
  cat << 'EOF' > "${ROOT_PREFIX}/etc/conf.d/fsck"
fsck_args="-p -C0"
rc_fsck_quiet="YES"
EOF
  chmod 644 "${ROOT_PREFIX}/etc/conf.d/fsck"

  # Forçar TIMEOUT 0 real e parâmetros silenciosos no extlinux e GRUB após branding-xiqi.sh
  if [ -f "${ROOT_PREFIX}/etc/update-extlinux.conf" ]; then
    sed -i 's|^timeout=.*|timeout=0|g' "${ROOT_PREFIX}/etc/update-extlinux.conf" 2>/dev/null || true
    if grep -q '^default_kernel_opts=' "${ROOT_PREFIX}/etc/update-extlinux.conf"; then
      sed -i "s|^default_kernel_opts=.*|default_kernel_opts=\"${QUIET_OPTS}\"|g" "${ROOT_PREFIX}/etc/update-extlinux.conf"
    else
      echo "default_kernel_opts=\"${QUIET_OPTS}\"" >> "${ROOT_PREFIX}/etc/update-extlinux.conf"
    fi
  fi

  if [ -f "${ROOT_PREFIX}/boot/extlinux.conf" ]; then
    TMP_EXT_ZERO="${ROOT_PREFIX}/boot/extlinux.conf.zero"
    awk -v qopts="${QUIET_OPTS}" '
      /^TIMEOUT / { print "TIMEOUT 0"; next; }
      /^TOTALTIMEOUT / { print "TOTALTIMEOUT 0"; next; }
      /^PROMPT / { print "PROMPT 0"; next; }
      /^[[:space:]]*APPEND / {
        line=$0
        gsub(/[[:space:]]+(quiet|loglevel=[0-9]+|vt\.global_cursor_default=[0-9]+|rd\.udev\.log_level=[0-9]+|systemd\.show_status=[a-z]+|rd\.systemd\.show_status=[a-z]+|fsck\.mode=[a-z]+|fastboot|fbcon=nodefer|debug|verbose)/, "", line)
        print line " " qopts
        next
      }
      { print }
    ' "${ROOT_PREFIX}/boot/extlinux.conf" > "${TMP_EXT_ZERO}"
    mv "${TMP_EXT_ZERO}" "${ROOT_PREFIX}/boot/extlinux.conf"
    chmod 644 "${ROOT_PREFIX}/boot/extlinux.conf"
  fi

  if [ -z "${ROOT_PREFIX}" ] && command -v update-extlinux >/dev/null 2>&1 && [ -f /etc/update-extlinux.conf ]; then
    update-extlinux >/dev/null 2>&1 || true
  fi

  cat << EOF > "${ROOT_PREFIX}/etc/default/grub"
GRUB_DEFAULT=0
GRUB_TIMEOUT=0
GRUB_RECORDFAIL_TIMEOUT=0
GRUB_TIMEOUT_STYLE=hidden
GRUB_HIDDEN_TIMEOUT=0
GRUB_HIDDEN_TIMEOUT_QUIET=true
GRUB_DISTRIBUTOR="XIQI OS v1.0 - Corporação Engecema"
GRUB_CMDLINE_LINUX_DEFAULT="${QUIET_OPTS}"
GRUB_CMDLINE_LINUX="${QUIET_OPTS}"
EOF
  chmod 644 "${ROOT_PREFIX}/etc/default/grub"

  if [ -z "${ROOT_PREFIX}" ]; then
    if command -v update-grub >/dev/null 2>&1; then
      update-grub >/dev/null 2>&1 || true
    elif command -v grub-mkconfig >/dev/null 2>&1 && [ -d /boot/grub ]; then
      grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
    fi
  elif command -v chroot >/dev/null 2>&1 && [ -x "${ROOT_PREFIX}/bin/sh" ] && [ -d "${ROOT_PREFIX}/boot/grub" ]; then
    chroot "${ROOT_PREFIX}" sh -c 'if command -v update-grub >/dev/null 2>&1; then update-grub >/dev/null 2>&1 || true; elif command -v grub-mkconfig >/dev/null 2>&1; then grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true; fi' || true
  fi

  if [ -f "${ROOT_PREFIX}/boot/grub/grub.cfg" ]; then
    sed -i "s|set timeout=[0-9-]*|set timeout=0|g; s|set timeout_style=[^[:space:]]*|set timeout_style=hidden|g" "${ROOT_PREFIX}/boot/grub/grub.cfg" 2>/dev/null || true
  fi
}

configure_https_reverse_proxy() {
  ROOT_PREFIX="${1:-}"
  XIQI_BASE="${ROOT_PREFIX}/opt/xiqi"
  CERT_DIR="${XIQI_BASE}/config/certs"
  mkdir -p "${CERT_DIR}" "${ROOT_PREFIX}/etc"
  chmod 750 "${CERT_DIR}"

  # Garantir resolução local para xiqios e xiqios.local sem alterar entradas existentes
  if [ -f "${ROOT_PREFIX}/etc/hosts" ]; then
    if ! grep -qw 'xiqios' "${ROOT_PREFIX}/etc/hosts" 2>/dev/null; then
      printf '\n127.0.0.1 xiqios xiqios.local\n' >> "${ROOT_PREFIX}/etc/hosts"
    fi
  else
    cat << 'EOF' > "${ROOT_PREFIX}/etc/hosts"
127.0.0.1   localhost xiqios xiqios.local
::1         localhost xiqios xiqios.local
EOF
  fi

  # Gerar Autoridade Certificadora local + certificado TLS confiável para xiqios e IPs da máquina
  if command -v openssl >/dev/null 2>&1; then
    SAN_LIST="DNS:xiqios,DNS:xiqios.local,DNS:localhost,IP:127.0.0.1,IP:192.168.1.5"
    if [ -z "${ROOT_PREFIX}" ] && command -v ip >/dev/null 2>&1; then
      for ip4 in $(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1); do
        case ",${SAN_LIST}," in
          *",IP:${ip4},"*) ;;
          *) SAN_LIST="${SAN_LIST},IP:${ip4}" ;;
        esac
      done
    fi

    if [ ! -f "${CERT_DIR}/xiqi-ca.crt" ] || [ ! -f "${CERT_DIR}/xiqi-ca.key" ]; then
      openssl genrsa -out "${CERT_DIR}/xiqi-ca.key" 2048 >/dev/null 2>&1
      openssl req -x509 -new -nodes -key "${CERT_DIR}/xiqi-ca.key" -sha256 -days 3650 \
        -subj "/O=Corporacao Engecema/OU=XIQI OS/CN=XIQI OS Local Root CA" \
        -out "${CERT_DIR}/xiqi-ca.crt" >/dev/null 2>&1
    fi

    cat << EOF > "${CERT_DIR}/xiqios-san.cnf"
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
O = Corporacao Engecema
OU = XIQI OS
CN = xiqios

[v3_req]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = ${SAN_LIST}
EOF

    openssl genrsa -out "${CERT_DIR}/xiqios.key" 2048 >/dev/null 2>&1
    openssl req -new -key "${CERT_DIR}/xiqios.key" -out "${CERT_DIR}/xiqios.csr" \
      -config "${CERT_DIR}/xiqios-san.cnf" >/dev/null 2>&1
    openssl x509 -req -in "${CERT_DIR}/xiqios.csr" \
      -CA "${CERT_DIR}/xiqi-ca.crt" -CAkey "${CERT_DIR}/xiqi-ca.key" -CAcreateserial \
      -out "${CERT_DIR}/xiqios.crt" -days 3650 -sha256 \
      -extensions v3_req -extfile "${CERT_DIR}/xiqios-san.cnf" >/dev/null 2>&1
    rm -f "${CERT_DIR}/xiqios.csr"
    chmod 600 "${CERT_DIR}/xiqi-ca.key" "${CERT_DIR}/xiqios.key" 2>/dev/null || true
    chmod 644 "${CERT_DIR}/xiqi-ca.crt" "${CERT_DIR}/xiqios.crt" "${CERT_DIR}/xiqios-san.cnf" 2>/dev/null || true

    # Instalar CA raiz confiável no sistema e no banco NSS do usuário xiqi
    if [ -d "${ROOT_PREFIX}/usr/local/share/ca-certificates" ] || [ -z "${ROOT_PREFIX}" ]; then
      mkdir -p "${ROOT_PREFIX}/usr/local/share/ca-certificates"
      cp -f "${CERT_DIR}/xiqi-ca.crt" "${ROOT_PREFIX}/usr/local/share/ca-certificates/xiqi-ca.crt"
    fi
    if [ -d "${ROOT_PREFIX}/etc/pki/ca-trust/source/anchors" ]; then
      cp -f "${CERT_DIR}/xiqi-ca.crt" "${ROOT_PREFIX}/etc/pki/ca-trust/source/anchors/xiqi-ca.crt"
    fi
    if [ -d "${ROOT_PREFIX}/etc/ssl/certs" ]; then
      cp -f "${CERT_DIR}/xiqi-ca.crt" "${ROOT_PREFIX}/etc/ssl/certs/xiqi-ca.pem"
    fi

    if [ -z "${ROOT_PREFIX}" ]; then
      if command -v update-ca-certificates >/dev/null 2>&1; then
        update-ca-certificates >/dev/null 2>&1 || true
      elif command -v update-ca-trust >/dev/null 2>&1; then
        update-ca-trust extract >/dev/null 2>&1 || true
      fi
      if command -v certutil >/dev/null 2>&1; then
        mkdir -p /home/xiqi/.pki/nssdb
        certutil -N --empty-password -d sql:/home/xiqi/.pki/nssdb >/dev/null 2>&1 || true
        certutil -D -n "XIQI OS Local Root CA" -d sql:/home/xiqi/.pki/nssdb >/dev/null 2>&1 || true
        certutil -A -t "C,," -n "XIQI OS Local Root CA" -i "${CERT_DIR}/xiqi-ca.crt" -d sql:/home/xiqi/.pki/nssdb >/dev/null 2>&1 || true
        chown -R xiqi:xiqi /home/xiqi/.pki 2>/dev/null || true
      fi
    elif command -v chroot >/dev/null 2>&1 && [ -x "${ROOT_PREFIX}/bin/sh" ]; then
      chroot "${ROOT_PREFIX}" sh -c 'command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates >/dev/null 2>&1 || true' || true
    fi
  fi

  # Proxy reverso HTTPS nativo em Node.js (porta 80 -> 443 e 443 -> 127.0.0.1:3000) como fallback universal
  cat << 'EOF' > "${XIQI_BASE}/bin/xiqi-https-proxy.js"
'use strict';
const fs = require('fs');
const http = require('http');
const https = require('https');
const net = require('net');

const CERT_FILE = '/opt/xiqi/config/certs/xiqios.crt';
const KEY_FILE = '/opt/xiqi/config/certs/xiqios.key';
const TARGET_HOST = '127.0.0.1';
const TARGET_PORT = Number(process.env.PORT) || 3000;

function forwardHttp(req, res) {
  const headers = Object.assign({}, req.headers, {
    'x-forwarded-proto': 'https',
    'x-forwarded-for': (req.headers['x-forwarded-for'] ? req.headers['x-forwarded-for'] + ', ' : '') + (req.socket.remoteAddress || '127.0.0.1'),
    'x-forwarded-host': req.headers.host || 'xiqios'
  });
  const proxyReq = http.request({
    hostname: TARGET_HOST,
    port: TARGET_PORT,
    path: req.url,
    method: req.method,
    headers
  }, (proxyRes) => {
    res.writeHead(proxyRes.statusCode || 502, proxyRes.headers);
    proxyRes.pipe(res);
  });
  proxyReq.on('error', () => {
    if (!res.headersSent) {
      res.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8' });
    }
    res.end('XIQI OS indisponível no momento.');
  });
  req.pipe(proxyReq);
}

function forwardUpgrade(req, socket, head) {
  const upstream = net.connect(TARGET_PORT, TARGET_HOST, () => {
    let raw = `${req.method} ${req.url} HTTP/${req.httpVersion}\r\n`;
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      raw += `${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}\r\n`;
    }
    raw += 'X-Forwarded-Proto: https\r\n\r\n';
    upstream.write(raw);
    if (head && head.length) upstream.write(head);
    upstream.pipe(socket);
    socket.pipe(upstream);
  });
  upstream.on('error', () => socket.destroy());
  socket.on('error', () => upstream.destroy());
}

if (fs.existsSync(CERT_FILE) && fs.existsSync(KEY_FILE)) {
  const tlsServer = https.createServer({
    cert: fs.readFileSync(CERT_FILE),
    key: fs.readFileSync(KEY_FILE)
  }, forwardHttp);
  tlsServer.on('upgrade', forwardUpgrade);
  tlsServer.listen(443, '0.0.0.0');
}

const redirectServer = http.createServer((req, res) => {
  const host = String(req.headers.host || 'xiqios').split(':')[0];
  res.writeHead(301, { Location: `https://${host}${req.url || '/'}` });
  res.end();
});
redirectServer.listen(80, '0.0.0.0');
EOF
  chmod 755 "${XIQI_BASE}/bin/xiqi-https-proxy.js"

  mkdir -p "${ROOT_PREFIX}/etc/init.d" "${ROOT_PREFIX}/etc/systemd/system"
  cat << 'EOF' > "${ROOT_PREFIX}/etc/init.d/xiqi-https"
#!/sbin/openrc-run

name="xiqi-https"
description="XIQI OS Local HTTPS Reverse Proxy (443 -> 3000)"
command="/usr/local/bin/node"
command_args="/opt/xiqi/bin/xiqi-https-proxy.js"
supervisor="supervise-daemon"
pidfile="/run/xiqi-https.pid"
output_log="/opt/xiqi/logs/xiqi-https.log"
error_log="/opt/xiqi/logs/xiqi-https.log"

depend() {
  need localmount net
  after net xiqios
}
EOF
  chmod 755 "${ROOT_PREFIX}/etc/init.d/xiqi-https"

  cat << 'EOF' > "${ROOT_PREFIX}/etc/systemd/system/xiqi-https.service"
[Unit]
Description=XIQI OS Local HTTPS Reverse Proxy (443 -> 3000)
After=network.target xiqios.service
Wants=xiqios.service

[Service]
Type=simple
ExecStart=/usr/local/bin/node /opt/xiqi/bin/xiqi-https-proxy.js
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  PROXY_ENGINE="node"
  if command -v caddy >/dev/null 2>&1 || [ -x "${ROOT_PREFIX}/usr/bin/caddy" ] || [ -x "${ROOT_PREFIX}/usr/sbin/caddy" ]; then
    PROXY_ENGINE="caddy"
    mkdir -p "${ROOT_PREFIX}/etc/caddy"
    cat << 'EOF' > "${ROOT_PREFIX}/etc/caddy/Caddyfile"
:80 {
  redir https://{host}{uri} permanent
}

:443 {
  tls /opt/xiqi/config/certs/xiqios.crt /opt/xiqi/config/certs/xiqios.key
  reverse_proxy 127.0.0.1:3000 {
    header_up X-Forwarded-Proto https
    header_up X-Forwarded-Host {host}
  }
}
EOF
    chmod 644 "${ROOT_PREFIX}/etc/caddy/Caddyfile"
  elif command -v nginx >/dev/null 2>&1 || [ -x "${ROOT_PREFIX}/usr/sbin/nginx" ]; then
    PROXY_ENGINE="nginx"
    mkdir -p "${ROOT_PREFIX}/etc/nginx/http.d" "${ROOT_PREFIX}/etc/nginx/sites-available" "${ROOT_PREFIX}/etc/nginx/sites-enabled"
    NGINX_CONF='server {
  listen 80 default_server;
  server_name _;
  return 301 https://$host$request_uri;
}

server {
  listen 443 ssl default_server;
  server_name _;
  ssl_certificate /opt/xiqi/config/certs/xiqios.crt;
  ssl_certificate_key /opt/xiqi/config/certs/xiqios.key;
  ssl_protocols TLSv1.2 TLSv1.3;
  client_max_body_size 25m;

  location / {
    proxy_pass http://127.0.0.1:3000;
    proxy_http_version 1.1;
    proxy_set_header Host $http_host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
  }
}
'
    printf '%s\n' "${NGINX_CONF}" > "${ROOT_PREFIX}/etc/nginx/http.d/xiqi.conf"
    printf '%s\n' "${NGINX_CONF}" > "${ROOT_PREFIX}/etc/nginx/sites-available/xiqi.conf"
    rm -f "${ROOT_PREFIX}/etc/nginx/http.d/default.conf" "${ROOT_PREFIX}/etc/nginx/sites-enabled/default" 2>/dev/null || true
    ln -sf /etc/nginx/sites-available/xiqi.conf "${ROOT_PREFIX}/etc/nginx/sites-enabled/xiqi.conf"
  fi

  if [ -z "${ROOT_PREFIX}" ]; then
    if command -v rc-update >/dev/null 2>&1; then
      if [ "${PROXY_ENGINE}" = "caddy" ]; then
        rc-update add caddy default 2>/dev/null || true
        rc-service caddy restart 2>/dev/null || true
      elif [ "${PROXY_ENGINE}" = "nginx" ]; then
        rc-update add nginx default 2>/dev/null || true
        rc-service nginx restart 2>/dev/null || true
      else
        rc-update add xiqi-https default 2>/dev/null || true
        rc-service xiqi-https restart 2>/dev/null || true
      fi
    elif command -v systemctl >/dev/null 2>&1; then
      systemctl daemon-reload 2>/dev/null || true
      if [ "${PROXY_ENGINE}" = "caddy" ]; then
        systemctl enable caddy 2>/dev/null || true
        systemctl restart caddy 2>/dev/null || true
      elif [ "${PROXY_ENGINE}" = "nginx" ]; then
        systemctl enable nginx 2>/dev/null || true
        systemctl restart nginx 2>/dev/null || true
      else
        systemctl enable xiqi-https.service 2>/dev/null || true
        systemctl restart xiqi-https.service 2>/dev/null || true
      fi
    fi
  elif command -v chroot >/dev/null 2>&1 && [ -x "${ROOT_PREFIX}/sbin/rc-update" ]; then
    if [ "${PROXY_ENGINE}" = "caddy" ]; then
      chroot "${ROOT_PREFIX}" rc-update add caddy default 2>/dev/null || true
    elif [ "${PROXY_ENGINE}" = "nginx" ]; then
      chroot "${ROOT_PREFIX}" rc-update add nginx default 2>/dev/null || true
    else
      chroot "${ROOT_PREFIX}" rc-update add xiqi-https default 2>/dev/null || true
    fi
  fi
}

configure_fast_network_and_ntp() {
  ROOT_PREFIX="${1:-}"
  mkdir -p "${ROOT_PREFIX}/etc/sysctl.d" "${ROOT_PREFIX}/etc/udhcpc" "${ROOT_PREFIX}/etc/dhcp" "${ROOT_PREFIX}/etc/NetworkManager/conf.d" "${ROOT_PREFIX}/etc/chrony" "${ROOT_PREFIX}/etc/systemd/timesyncd.conf.d"

  # 1. DNS rápido (1.1.1.1 e 8.8.8.8) sem atrasos de lookup IPv6
  cat << 'EOF' > "${ROOT_PREFIX}/etc/resolv.conf"
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:1 attempts:2 single-request-reopen
EOF
  chmod 644 "${ROOT_PREFIX}/etc/resolv.conf"

  cat << 'EOF' > "${ROOT_PREFIX}/etc/udhcpc/udhcpc.conf"
RESOLV_CONF="no"
EOF
  chmod 644 "${ROOT_PREFIX}/etc/udhcpc/udhcpc.conf"

  cat << 'EOF' > "${ROOT_PREFIX}/etc/dhcp/dhclient.conf"
supersede domain-name-servers 1.1.1.1, 8.8.8.8;
EOF
  chmod 644 "${ROOT_PREFIX}/etc/dhcp/dhclient.conf"

  cat << 'EOF' > "${ROOT_PREFIX}/etc/NetworkManager/conf.d/90-xiqi-dns.conf"
[main]
dns=none
EOF
  chmod 644 "${ROOT_PREFIX}/etc/NetworkManager/conf.d/90-xiqi-dns.conf"

  cat << 'EOF' > "${ROOT_PREFIX}/etc/gai.conf"
precedence ::ffff:0:0/96  100
EOF
  chmod 644 "${ROOT_PREFIX}/etc/gai.conf"

  cat << 'EOF' > "${ROOT_PREFIX}/etc/sysctl.d/99-xiqi-network.conf"
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
  chmod 644 "${ROOT_PREFIX}/etc/sysctl.d/99-xiqi-network.conf"

  # 2. Sincronização de relógio NTP (chronyd / ntpd / timesyncd) para evitar atrasos em códigos 2FA
  CHRONY_CONF="server time.cloudflare.com iburst
server time.google.com iburst
pool pool.ntp.org iburst
makestep 1.0 3
rtcsync
driftfile /var/lib/chrony/chrony.drift"
  printf '%s\n' "${CHRONY_CONF}" > "${ROOT_PREFIX}/etc/chrony/chrony.conf"
  printf '%s\n' "${CHRONY_CONF}" > "${ROOT_PREFIX}/etc/chrony.conf"
  chmod 644 "${ROOT_PREFIX}/etc/chrony/chrony.conf" "${ROOT_PREFIX}/etc/chrony.conf"

  cat << 'EOF' > "${ROOT_PREFIX}/etc/ntp.conf"
server time.cloudflare.com iburst
server time.google.com iburst
pool pool.ntp.org iburst
EOF
  chmod 644 "${ROOT_PREFIX}/etc/ntp.conf"

  cat << 'EOF' > "${ROOT_PREFIX}/etc/systemd/timesyncd.conf.d/90-xiqi-ntp.conf"
[Time]
NTP=time.cloudflare.com time.google.com
FallbackNTP=pool.ntp.org
EOF
  chmod 644 "${ROOT_PREFIX}/etc/systemd/timesyncd.conf.d/90-xiqi-ntp.conf"

  if [ -z "${ROOT_PREFIX}" ]; then
    sysctl -q -p /etc/sysctl.d/99-xiqi-network.conf 2>/dev/null || true
    if command -v rc-update >/dev/null 2>&1; then
      if [ -x /etc/init.d/chronyd ]; then
        rc-update add chronyd default 2>/dev/null || true
        rc-service chronyd restart 2>/dev/null || true
      elif [ -x /etc/init.d/ntpd ]; then
        rc-update add ntpd default 2>/dev/null || true
        rc-service ntpd restart 2>/dev/null || true
      fi
    elif command -v systemctl >/dev/null 2>&1; then
      if systemctl list-unit-files chronyd.service >/dev/null 2>&1; then
        systemctl enable --now chronyd.service 2>/dev/null || true
      elif systemctl list-unit-files chrony.service >/dev/null 2>&1; then
        systemctl enable --now chrony.service 2>/dev/null || true
      elif systemctl list-unit-files systemd-timesyncd.service >/dev/null 2>&1; then
        systemctl enable --now systemd-timesyncd.service 2>/dev/null || true
      fi
    fi
    if command -v chronyc >/dev/null 2>&1; then
      chronyc makestep >/dev/null 2>&1 || true
    fi
  elif command -v chroot >/dev/null 2>&1 && [ -x "${ROOT_PREFIX}/sbin/rc-update" ]; then
    chroot "${ROOT_PREFIX}" sh -c '
      if [ -x /etc/init.d/chronyd ]; then rc-update add chronyd default 2>/dev/null || true;
      elif [ -x /etc/init.d/ntpd ]; then rc-update add ntpd default 2>/dev/null || true; fi
    ' || true
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
UUID=${UUID_ROOT}  /          ext4  defaults,noatime,errors=remount-ro  0  0
UUID=${UUID_EFI}   /boot/efi  vfat  umask=0077                          0  0
EOF
  else
    cat << EOF > "${MNT_DIR}/etc/fstab"
UUID=${UUID_ROOT}  /          ext4  defaults,noatime,errors=remount-ro  0  0
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
