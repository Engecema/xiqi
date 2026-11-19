#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "Erro: branding-xiqi.sh deve ser executado como root." >&2
  exit 1
fi

TARGET_ROOT="${1:-}"
XIQI_TITLE="XIQI OS v1.0 - Engecema"
QUIET_PARAMS="quiet loglevel=0 console=tty3 vt.global_cursor_default=0 rd.udev.log_level=0 systemd.show_status=false fbcon=nodefer consoleblank=0 acpi_sleep=nonvs nohz=off nohibernate"

mkdir -p "${TARGET_ROOT}/etc" "${TARGET_ROOT}/etc/conf.d" "${TARGET_ROOT}/etc/default" "${TARGET_ROOT}/etc/sysctl.d" "${TARGET_ROOT}/boot" "${TARGET_ROOT}/opt/xiqi/config"

# 1. Identidade oficial do sistema (/etc/os-release e /etc/xiqi-release)
rm -f "${TARGET_ROOT}/etc/os-release"
cat << 'EOF' > "${TARGET_ROOT}/etc/os-release"
NAME="XIQI OS"
ID=xiqi
VERSION="1.0.0"
VERSION_ID=1.0.0
PRETTY_NAME="XIQI OS v1.0 - Corporação Engecema"
HOME_URL="https://xiqios.local"
SUPPORT_URL="https://xiqios.local"
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

# 4. Silenciar console do sistema e acelerar inicialização paralela (/etc/rc.conf e /etc/sysctl.d/99-xiqi-quiet.conf)
if [ -f "${TARGET_ROOT}/etc/rc.conf" ]; then
  grep -vE '^(rc_quiet|rc_verbose|rc_logger|rc_log_path|rc_parallel)=' "${TARGET_ROOT}/etc/rc.conf" > "${TARGET_ROOT}/etc/rc.conf.tmp" || true
  mv "${TARGET_ROOT}/etc/rc.conf.tmp" "${TARGET_ROOT}/etc/rc.conf"
fi
cat << 'EOF' >> "${TARGET_ROOT}/etc/rc.conf"
rc_quiet="YES"
rc_verbose="NO"
rc_logger="YES"
rc_parallel="YES"
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

cat << 'EOF' > "${TARGET_ROOT}/etc/conf.d/fsck"
fsck_args="-y -T -C 0"
rc_fsck_quiet="YES"
EOF
chmod 644 "${TARGET_ROOT}/etc/conf.d/fsck"

# 5. Bootloader GRUB 100% silencioso e remoção segura de resíduos do extlinux
resolve_root_partition() {
  PREFIX_DIR="${1:-}"
  MNT_POINT="${PREFIX_DIR:-/}"
  SRC_DEV=""
  if command -v findmnt >/dev/null 2>&1; then
    SRC_DEV="$(findmnt -n -o SOURCE "${MNT_POINT}" 2>/dev/null || true)"
  fi
  if [ -z "${SRC_DEV}" ] && command -v df >/dev/null 2>&1; then
    SRC_DEV="$(df -P "${MNT_POINT}" 2>/dev/null | awk 'NR==2{print $1}')"
  fi
  case "${SRC_DEV}" in
    /dev/*) [ -b "${SRC_DEV}" ] && printf '%s\n' "${SRC_DEV}" && return 0 ;;
  esac
  return 1
}

resolve_parent_disk() {
  PART_DEV="${1:-}"
  [ -n "${PART_DEV}" ] || return 1
  if command -v lsblk >/dev/null 2>&1; then
    PK="$(lsblk -no PKNAME "${PART_DEV}" 2>/dev/null | head -n 1 || true)"
    if [ -n "${PK}" ] && [ -b "/dev/${PK}" ]; then
      printf '/dev/%s\n' "${PK}"
      return 0
    fi
  fi
  case "${PART_DEV}" in
    /dev/nvme*p[0-9]*|/dev/mmcblk*p[0-9]*|/dev/loop*p[0-9]*)
      DISK_CAND="$(printf '%s' "${PART_DEV}" | sed -E 's/p[0-9]+$//')"
      ;;
    *)
      DISK_CAND="$(printf '%s' "${PART_DEV}" | sed -E 's/[0-9]+$//')"
      ;;
  esac
  if [ -b "${DISK_CAND}" ]; then
    printf '%s\n' "${DISK_CAND}"
    return 0
  fi
  return 1
}

resolve_root_uuid() {
  PREFIX_DIR="${1:-}"
  PART_DEV="${2:-}"
  UUID_VAL=""
  if [ -n "${PART_DEV}" ] && [ -b "${PART_DEV}" ] && command -v blkid >/dev/null 2>&1; then
    UUID_VAL="$(blkid -s UUID -o value "${PART_DEV}" 2>/dev/null || true)"
  fi
  if [ -z "${UUID_VAL}" ] && command -v findmnt >/dev/null 2>&1; then
    UUID_VAL="$(findmnt -n -o UUID "${PREFIX_DIR:-/}" 2>/dev/null || true)"
  fi
  if [ -z "${UUID_VAL}" ] && [ -f "${PREFIX_DIR}/etc/fstab" ]; then
    UUID_VAL="$(awk '$2 == "/" && $1 ~ /^UUID=/ { sub(/^UUID=/, "", $1); print $1; exit }' "${PREFIX_DIR}/etc/fstab" 2>/dev/null || true)"
  fi
  if [ -z "${UUID_VAL}" ] && [ -f "${PREFIX_DIR}/boot/extlinux.conf" ]; then
    UUID_VAL="$(sed -n 's/.*root=UUID=\([^[:space:]]*\).*/\1/p' "${PREFIX_DIR}/boot/extlinux.conf" 2>/dev/null | head -n 1 || true)"
  fi
  printf '%s\n' "${UUID_VAL}"
}

sanitize_grub_cfg() {
  CFG_PATH="${1:-}"
  [ -f "${CFG_PATH}" ] || return 0
  TMP_CFG="${CFG_PATH}.xiqi.tmp"
  awk -v title="${XIQI_TITLE}" '
    /^[[:space:]]*echo[[:space:]]+/ { next }
    /^[[:space:]]*menuentry[[:space:]]+/ {
      sub(/menuentry[[:space:]]+\047[^\047]*\047/, "menuentry \047" title "\047")
      sub(/menuentry[[:space:]]+"[^"]*"/, "menuentry \"" title "\"")
      print
      next
    }
    /^[[:space:]]*submenu[[:space:]]+/ {
      sub(/submenu[[:space:]]+\047[^\047]*\047/, "submenu \047" title "\047")
      sub(/submenu[[:space:]]+"[^"]*"/, "submenu \"" title "\"")
      print
      next
    }
    {
      gsub(/Alpine Linux|Alpine|SYSLINUX|extlinux|GNU\/Linux/, "XIQI OS")
      gsub(/Loading Linux[^"\047]*/, "XIQI OS Core x86_64")
      if ($0 ~ /^[[:space:]]*#/) { gsub(/Linux/, "XIQI OS") }
      if ($0 ~ /^[[:space:]]*set[[:space:]]+timeout=/) { print "set timeout=0"; next }
      if ($0 ~ /^[[:space:]]*set[[:space:]]+timeout_style=/) { print "set timeout_style=hidden"; next }
      print
    }
  ' "${CFG_PATH}" > "${TMP_CFG}"
  mv "${TMP_CFG}" "${CFG_PATH}"
  chmod 644 "${CFG_PATH}"
}

verify_grub_default_entry() {
  CFG_PATH="${1:-}"
  REQ_UUID="${2:-}"
  [ -s "${CFG_PATH}" ] || return 1
  awk -v req_uuid="${REQ_UUID}" '
    BEGIN { in_entry=0; idx=0; has_kern=0; has_initrd=0; has_uuid=0; }
    /^[[:space:]]*menuentry[[:space:]]+/ {
      idx++
      if (idx == 1) { in_entry=1 }
      next
    }
    in_entry && /^[[:space:]]*\}/ { in_entry=0; exit }
    in_entry {
      if ($0 ~ /vmlinuz-lts/) has_kern=1
      if ($0 ~ /initramfs-lts/) has_initrd=1
      if (req_uuid == "" || index($0, "root=UUID=" req_uuid) > 0) has_uuid=1
    }
    END {
      if (idx >= 1 && has_kern == 1 && has_initrd == 1 && has_uuid == 1) exit 0
      exit 1
    }
  ' "${CFG_PATH}"
}

ROOT_PART="$(resolve_root_partition "${TARGET_ROOT}" || true)"
DISK_DEV="$(resolve_parent_disk "${ROOT_PART}" || true)"
ROOT_UUID="$(resolve_root_uuid "${TARGET_ROOT}" "${ROOT_PART}")"
if [ -z "${DISK_DEV}" ] && [ -z "${TARGET_ROOT}" ] && [ -b /dev/sda ]; then
  DISK_DEV="/dev/sda"
fi

BOOT_MODE_GRUB="bios"
if [ -d /sys/firmware/efi ] && [ -d "${TARGET_ROOT}/boot/efi" ]; then
  BOOT_MODE_GRUB="uefi"
fi

if [ -z "${TARGET_ROOT}" ]; then
  if command -v apk >/dev/null 2>&1; then
    if [ "${BOOT_MODE_GRUB}" = "uefi" ] && [ ! -d /usr/lib/grub/x86_64-efi ]; then
      apk add --no-cache grub grub-efi >/dev/null 2>&1 || true
    elif [ ! -d /usr/lib/grub/i386-pc ] || ! command -v grub-install >/dev/null 2>&1; then
      apk add --no-cache grub grub-bios >/dev/null 2>&1 || true
    fi
  fi
elif command -v chroot >/dev/null 2>&1 && [ -x "${TARGET_ROOT}/sbin/apk" ]; then
  if [ "${BOOT_MODE_GRUB}" = "uefi" ] && [ ! -d "${TARGET_ROOT}/usr/lib/grub/x86_64-efi" ]; then
    chroot "${TARGET_ROOT}" apk add --no-cache grub grub-efi >/dev/null 2>&1 || true
  elif [ ! -d "${TARGET_ROOT}/usr/lib/grub/i386-pc" ] || [ ! -x "${TARGET_ROOT}/usr/sbin/grub-install" ]; then
    chroot "${TARGET_ROOT}" apk add --no-cache grub grub-bios >/dev/null 2>&1 || true
  fi
fi

mkdir -p "${TARGET_ROOT}/boot/grub"

cat << EOF > "${TARGET_ROOT}/etc/default/grub"
GRUB_DEFAULT=0
GRUB_TIMEOUT=0
GRUB_RECORDFAIL_TIMEOUT=0
GRUB_TIMEOUT_STYLE=hidden
GRUB_HIDDEN_TIMEOUT=0
GRUB_HIDDEN_TIMEOUT_QUIET=true
GRUB_DISTRIBUTOR="XIQI OS"
GRUB_CMDLINE_LINUX_DEFAULT="${QUIET_PARAMS}"
GRUB_CMDLINE_LINUX="${QUIET_PARAMS}"
GRUB_DISABLE_OS_PROBER=true
GRUB_DISABLE_RECOVERY=true
GRUB_TERMINAL_OUTPUT="console"
EOF
chmod 644 "${TARGET_ROOT}/etc/default/grub"

MOUNTED_DEV_B="false"
MOUNTED_PROC_B="false"
MOUNTED_SYS_B="false"
cleanup_branding_chroot_mounts() {
  if [ "${MOUNTED_SYS_B}" = "true" ]; then umount "${TARGET_ROOT}/sys" 2>/dev/null || true; fi
  if [ "${MOUNTED_PROC_B}" = "true" ]; then umount "${TARGET_ROOT}/proc" 2>/dev/null || true; fi
  if [ "${MOUNTED_DEV_B}" = "true" ]; then umount "${TARGET_ROOT}/dev" 2>/dev/null || true; fi
}

if [ -n "${TARGET_ROOT}" ]; then
  if [ -d "${TARGET_ROOT}/dev" ] && [ ! -e "${TARGET_ROOT}/dev/null" ]; then
    mount --bind /dev "${TARGET_ROOT}/dev" 2>/dev/null && MOUNTED_DEV_B="true" || true
  fi
  if [ -d "${TARGET_ROOT}/proc" ] && [ ! -e "${TARGET_ROOT}/proc/cmdline" ]; then
    mount --bind /proc "${TARGET_ROOT}/proc" 2>/dev/null && MOUNTED_PROC_B="true" || true
  fi
  if [ -d "${TARGET_ROOT}/sys" ] && [ ! -d "${TARGET_ROOT}/sys/kernel" ]; then
    mount --bind /sys "${TARGET_ROOT}/sys" 2>/dev/null && MOUNTED_SYS_B="true" || true
  fi
fi

GRUB_INSTALL_OK="false"
if [ -n "${DISK_DEV}" ] && [ -b "${DISK_DEV}" ]; then
  if [ -z "${TARGET_ROOT}" ] && command -v grub-install >/dev/null 2>&1; then
    if [ "${BOOT_MODE_GRUB}" = "uefi" ]; then
      if grub-install --target=x86_64-efi --efi-directory=/boot/efi --boot-directory=/boot --removable "${DISK_DEV}" >/dev/null 2>&1; then
        GRUB_INSTALL_OK="true"
      fi
    else
      if grub-install --target=i386-pc --boot-directory=/boot "${DISK_DEV}" >/dev/null 2>&1; then
        GRUB_INSTALL_OK="true"
      fi
    fi
  elif [ -n "${TARGET_ROOT}" ]; then
    if command -v chroot >/dev/null 2>&1 && [ -x "${TARGET_ROOT}/usr/sbin/grub-install" ]; then
      if [ "${BOOT_MODE_GRUB}" = "uefi" ]; then
        if chroot "${TARGET_ROOT}" grub-install --target=x86_64-efi --efi-directory=/boot/efi --boot-directory=/boot --removable "${DISK_DEV}" >/dev/null 2>&1; then
          GRUB_INSTALL_OK="true"
        fi
      else
        if chroot "${TARGET_ROOT}" grub-install --target=i386-pc --boot-directory=/boot "${DISK_DEV}" >/dev/null 2>&1; then
          GRUB_INSTALL_OK="true"
        fi
      fi
    fi
    if [ "${GRUB_INSTALL_OK}" != "true" ] && command -v grub-install >/dev/null 2>&1; then
      if [ "${BOOT_MODE_GRUB}" = "uefi" ]; then
        if grub-install --target=x86_64-efi --efi-directory="${TARGET_ROOT}/boot/efi" --boot-directory="${TARGET_ROOT}/boot" --removable "${DISK_DEV}" >/dev/null 2>&1; then
          GRUB_INSTALL_OK="true"
        fi
      else
        if grub-install --target=i386-pc --boot-directory="${TARGET_ROOT}/boot" "${DISK_DEV}" >/dev/null 2>&1; then
          GRUB_INSTALL_OK="true"
        fi
      fi
    fi
  fi
fi

if [ -z "${TARGET_ROOT}" ]; then
  if command -v grub-mkconfig >/dev/null 2>&1; then
    grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
  elif command -v update-grub >/dev/null 2>&1; then
    update-grub >/dev/null 2>&1 || true
  fi
elif command -v chroot >/dev/null 2>&1 && [ -x "${TARGET_ROOT}/bin/sh" ]; then
  chroot "${TARGET_ROOT}" sh -c 'if command -v grub-mkconfig >/dev/null 2>&1; then grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true; elif command -v update-grub >/dev/null 2>&1; then update-grub >/dev/null 2>&1 || true; fi' || true
fi

cleanup_branding_chroot_mounts

GRUB_CFG="${TARGET_ROOT}/boot/grub/grub.cfg"
BOOT_PREFIX="/boot"
BOOT_SEARCH_UUID="${ROOT_UUID}"
BOOT_PART="$(resolve_root_partition "${TARGET_ROOT}/boot" || true)"
if [ -n "${BOOT_PART}" ] && [ -n "${ROOT_PART}" ] && [ "${BOOT_PART}" != "${ROOT_PART}" ]; then
  BOOT_PREFIX=""
  if command -v blkid >/dev/null 2>&1; then
    BOOT_SEARCH_UUID="$(blkid -s UUID -o value "${BOOT_PART}" 2>/dev/null || printf '%s' "${ROOT_UUID}")"
  fi
fi

if [ -f "${TARGET_ROOT}/boot/vmlinuz-lts" ] && [ -f "${TARGET_ROOT}/boot/initramfs-lts" ] && [ -n "${ROOT_UUID}" ]; then
  if ! verify_grub_default_entry "${GRUB_CFG}" "${ROOT_UUID}"; then
    cat << EOF > "${GRUB_CFG}"
set default="0"
set timeout=0
set timeout_style=hidden
insmod part_msdos
insmod part_gpt
insmod ext2
search --no-floppy --fs-uuid --set=root ${BOOT_SEARCH_UUID}

menuentry '${XIQI_TITLE}' {
  linux ${BOOT_PREFIX}/vmlinuz-lts root=UUID=${ROOT_UUID} ro ${QUIET_PARAMS}
  initrd ${BOOT_PREFIX}/initramfs-lts
}
EOF
    chmod 644 "${GRUB_CFG}"
  fi
fi

sanitize_grub_cfg "${GRUB_CFG}"

# Remover resíduos do extlinux somente após confirmar GRUB funcional com vmlinuz-lts, initramfs-lts e UUID raiz
GRUB_CORE_OK="false"
if [ -f "${TARGET_ROOT}/boot/grub/i386-pc/core.img" ] || [ -f "${TARGET_ROOT}/boot/grub/x86_64-efi/core.efi" ] || [ -f "${TARGET_ROOT}/boot/grub/x86_64-efi/grub.efi" ] || [ -f "${TARGET_ROOT}/boot/efi/EFI/BOOT/BOOTX64.EFI" ]; then
  GRUB_CORE_OK="true"
fi
if [ -n "${DISK_DEV}" ] && [ -b "${DISK_DEV}" ] && [ "${GRUB_INSTALL_OK}" != "true" ]; then
  GRUB_CORE_OK="false"
fi

if [ "${GRUB_CORE_OK}" = "true" ] && verify_grub_default_entry "${GRUB_CFG}" "${ROOT_UUID}"; then
  for ext_res in "${TARGET_ROOT}/boot/ldlinux.sys" "${TARGET_ROOT}/boot/ldlinux.c32" "${TARGET_ROOT}/boot/extlinux.conf" "${TARGET_ROOT}/etc/update-extlinux.conf"; do
    if [ -e "${ext_res}" ]; then
      chattr -i "${ext_res}" 2>/dev/null || true
      rm -f "${ext_res}"
    fi
  done
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

# 7. Bloqueio de enrolamento (shade/rollup) do xfwm4 e garantia de fundo branco no X11
mkdir -p \
  "${TARGET_ROOT}/home/xiqi/.config/xfce4/xfconf/xfce-perchannel-xml" \
  "${TARGET_ROOT}/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"

cat << 'EOF' > "${TARGET_ROOT}/home/xiqi/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml"
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="mousewheel_rollup" type="bool" value="false"/>
    <property name="button_layout" type="string" value="|HMC"/>
    <property name="double_click_action" type="string" value="maximize"/>
    <property name="use_compositing" type="bool" value="false"/>
    <property name="theme" type="string" value="Default"/>
  </property>
</channel>
EOF
cp -f "${TARGET_ROOT}/home/xiqi/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml" \
  "${TARGET_ROOT}/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml"
chmod 644 "${TARGET_ROOT}/home/xiqi/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml" \
  "${TARGET_ROOT}/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml"

if [ -f "${TARGET_ROOT}/home/xiqi/.xinitrc" ]; then
  if ! grep -q 'mousewheel_rollup' "${TARGET_ROOT}/home/xiqi/.xinitrc" 2>/dev/null; then
    awk '
      /^xfwm4 / {
        print "if command -v xfconf-query >/dev/null 2>&1; then"
        print "  xfconf-query -c xfwm4 -p /general/mousewheel_rollup -n -t bool -s false 2>/dev/null || xfconf-query -c xfwm4 -p /general/mousewheel_rollup -s false 2>/dev/null || true"
        print "  xfconf-query -c xfwm4 -p /general/button_layout -n -t string -s \"|HMC\" 2>/dev/null || xfconf-query -c xfwm4 -p /general/button_layout -s \"|HMC\" 2>/dev/null || true"
        print "  xfconf-query -c xfwm4 -p /general/double_click_action -n -t string -s \"maximize\" 2>/dev/null || xfconf-query -c xfwm4 -p /general/double_click_action -s \"maximize\" 2>/dev/null || true"
        print "fi"
        print $0
        print "(sleep 1 && DISPLAY=:0 xsetroot -solid \"#ffffff\" >/dev/null 2>&1) &"
        next
      }
      { print }
    ' "${TARGET_ROOT}/home/xiqi/.xinitrc" > "${TARGET_ROOT}/home/xiqi/.xinitrc.tmp" && \
    mv "${TARGET_ROOT}/home/xiqi/.xinitrc.tmp" "${TARGET_ROOT}/home/xiqi/.xinitrc" && \
    chmod 755 "${TARGET_ROOT}/home/xiqi/.xinitrc"
  fi
fi

if [ -z "${TARGET_ROOT}" ]; then
  chown -R xiqi:xiqi /home/xiqi/.config 2>/dev/null || true
elif command -v chroot >/dev/null 2>&1 && [ -x "${TARGET_ROOT}/bin/sh" ]; then
  chroot "${TARGET_ROOT}" chown -R xiqi:xiqi /home/xiqi/.config 2>/dev/null || true
fi

chmod 644 "${TARGET_ROOT}/etc/os-release" \
          "${TARGET_ROOT}/etc/xiqi-release" \
          "${TARGET_ROOT}/etc/issue" \
          "${TARGET_ROOT}/etc/motd" \
          "${TARGET_ROOT}/etc/hostname" \
          "${TARGET_ROOT}/opt/xiqi/config/system.conf"
