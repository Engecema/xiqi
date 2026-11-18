#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "Erro: branding-xiqi.sh deve ser executado como root." >&2
  exit 1
fi

TARGET_ROOT="${1:-}"
XIQI_TITLE="XIQI OS v1.0 - Corporação Engecema"
QUIET_PARAMS="quiet loglevel=0 vt.global_cursor_default=0 rd.udev.log_level=0 systemd.show_status=false fbcon=nodefer"

mkdir -p "${TARGET_ROOT}/etc" "${TARGET_ROOT}/etc/default" "${TARGET_ROOT}/etc/sysctl.d" "${TARGET_ROOT}/boot" "${TARGET_ROOT}/opt/xiqi/config"

# 1. Identidade oficial do sistema (/etc/os-release e /etc/xiqi-release)
rm -f "${TARGET_ROOT}/etc/os-release"
cat << 'EOF' > "${TARGET_ROOT}/etc/os-release"
NAME="XIQI OS"
ID=xiqi
VERSION="1.0.0"
VERSION_ID=1.0.0
PRETTY_NAME="XIQI OS v1.0 - Corporação Engecema"
HOME_URL="https://xiqios.local"
SUPPORT_URL="https://xiqios.local/admin"
XIQI_KERNEL="XIQI Core x86_64"
XIQI_EDITION="Data Center Bare-Metal"
EOF

cat << 'EOF' > "${TARGET_ROOT}/etc/xiqi-release"
XIQI OS v1.0 - Corporação Engecema
EOF

# 2. Hostname corporativo
echo "xiqios" > "${TARGET_ROOT}/etc/hostname"
if [ ! -f "${TARGET_ROOT}/etc/hosts" ]; then
  cat << 'EOF' > "${TARGET_ROOT}/etc/hosts"
127.0.0.1   localhost xiqios xiqios.local
::1         localhost xiqios xiqios.local
EOF
fi

# 3. Banners silenciosos (sem listas de pastas, partições ou nomes externos)
cat << 'EOF' > "${TARGET_ROOT}/etc/issue"
XIQI OS v1.0 - Corporação Engecema
EOF

cat << 'EOF' > "${TARGET_ROOT}/etc/motd"
XIQI OS v1.0 - Corporação Engecema
EOF

# 4. Silenciar console do sistema (/etc/rc.conf e /etc/sysctl.d/99-xiqi-quiet.conf)
if [ -f "${TARGET_ROOT}/etc/rc.conf" ]; then
  grep -vE '^(rc_quiet|rc_verbose|rc_logger|rc_log_path)=' "${TARGET_ROOT}/etc/rc.conf" > "${TARGET_ROOT}/etc/rc.conf.tmp" || true
  mv "${TARGET_ROOT}/etc/rc.conf.tmp" "${TARGET_ROOT}/etc/rc.conf"
fi
cat << 'EOF' >> "${TARGET_ROOT}/etc/rc.conf"
rc_quiet="YES"
rc_verbose="NO"
rc_logger="YES"
rc_log_path="/opt/xiqi/logs/rc.log"
EOF
chmod 644 "${TARGET_ROOT}/etc/rc.conf"

cat << 'EOF' > "${TARGET_ROOT}/etc/sysctl.d/99-xiqi-quiet.conf"
kernel.printk = 0 0 0 0
EOF
chmod 644 "${TARGET_ROOT}/etc/sysctl.d/99-xiqi-quiet.conf"

if [ -z "${TARGET_ROOT}" ]; then
  dmesg -n 1 2>/dev/null || true
  sysctl -q -p /etc/sysctl.d/99-xiqi-quiet.conf 2>/dev/null || true
fi

# 5. Bootloader 100% silencioso (/boot/extlinux.conf, /etc/update-extlinux.conf e /etc/default/grub)
if [ -f "${TARGET_ROOT}/etc/update-extlinux.conf" ]; then
  sed -i 's|^timeout=.*|timeout=0|g' "${TARGET_ROOT}/etc/update-extlinux.conf" 2>/dev/null || true
  if grep -q '^default_kernel_opts=' "${TARGET_ROOT}/etc/update-extlinux.conf"; then
    sed -i "s|^default_kernel_opts=.*|default_kernel_opts=\"${QUIET_PARAMS}\"|g" "${TARGET_ROOT}/etc/update-extlinux.conf"
  else
    echo "default_kernel_opts=\"${QUIET_PARAMS}\"" >> "${TARGET_ROOT}/etc/update-extlinux.conf"
  fi
fi

if [ -f "${TARGET_ROOT}/boot/extlinux.conf" ]; then
  TMP_EXT="${TARGET_ROOT}/boot/extlinux.conf.tmp"
  awk -v title="${XIQI_TITLE}" -v qopts="${QUIET_PARAMS}" '
    BEGIN { has_hidden=0; has_silent=0; has_title=0; }
    /^MENU TITLE / { print "MENU TITLE " title; has_title=1; next; }
    /^MENU LABEL / { print "MENU LABEL " title; next; }
    /^TIMEOUT / { print "TIMEOUT 0"; next; }
    /^PROMPT / { print "PROMPT 0"; next; }
    /^MENU HIDDEN/ { print "MENU HIDDEN"; has_hidden=1; next; }
    /^MENU SILENT/ { print "MENU SILENT"; has_silent=1; next; }
    /^[[:space:]]*APPEND / {
      line=$0
      gsub(/[[:space:]]+(quiet|loglevel=[0-9]+|vt\.global_cursor_default=[0-9]+|rd\.udev\.log_level=[0-9]+|systemd\.show_status=[a-z]+|fbcon=nodefer|debug|verbose)/, "", line)
      print line " " qopts
      next
    }
    { print }
    END {
      if (!has_title) print "MENU TITLE " title
      if (!has_hidden) print "MENU HIDDEN"
      if (!has_silent) print "MENU SILENT"
    }
  ' "${TARGET_ROOT}/boot/extlinux.conf" > "${TMP_EXT}"
  mv "${TMP_EXT}" "${TARGET_ROOT}/boot/extlinux.conf"
  chmod 644 "${TARGET_ROOT}/boot/extlinux.conf"
elif command -v extlinux >/dev/null 2>&1 || [ -f "${TARGET_ROOT}/etc/update-extlinux.conf" ]; then
  cat << EOF > "${TARGET_ROOT}/boot/extlinux.conf"
DEFAULT xiqios
PROMPT 0
TIMEOUT 0
MENU HIDDEN
MENU SILENT
MENU TITLE ${XIQI_TITLE}

LABEL xiqios
  MENU LABEL ${XIQI_TITLE}
  APPEND ${QUIET_PARAMS}
EOF
  chmod 644 "${TARGET_ROOT}/boot/extlinux.conf"
fi

cat << EOF > "${TARGET_ROOT}/etc/default/grub"
GRUB_DEFAULT=0
GRUB_TIMEOUT=0
GRUB_TIMEOUT_STYLE=hidden
GRUB_HIDDEN_TIMEOUT=0
GRUB_HIDDEN_TIMEOUT_QUIET=true
GRUB_DISTRIBUTOR="${XIQI_TITLE}"
GRUB_CMDLINE_LINUX_DEFAULT="${QUIET_PARAMS}"
GRUB_CMDLINE_LINUX="${QUIET_PARAMS}"
EOF
chmod 644 "${TARGET_ROOT}/etc/default/grub"

if [ -z "${TARGET_ROOT}" ]; then
  if command -v update-grub >/dev/null 2>&1; then
    update-grub >/dev/null 2>&1 || true
  elif command -v grub-mkconfig >/dev/null 2>&1 && [ -d /boot/grub ]; then
    grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
  fi
fi

if [ -f "${TARGET_ROOT}/boot/grub/grub.cfg" ]; then
  sed -i "s|menuentry '[^']*'|menuentry '${XIQI_TITLE}'|g; s|set timeout=[0-9]*|set timeout=0|g" "${TARGET_ROOT}/boot/grub/grub.cfg" 2>/dev/null || true
fi

# 6. Configuração interna neutra XIQI OS
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
SILENT_BOOT="true"
EOF

chmod 644 "${TARGET_ROOT}/etc/os-release" \
          "${TARGET_ROOT}/etc/xiqi-release" \
          "${TARGET_ROOT}/etc/issue" \
          "${TARGET_ROOT}/etc/motd" \
          "${TARGET_ROOT}/etc/hostname" \
          "${TARGET_ROOT}/opt/xiqi/config/system.conf"
