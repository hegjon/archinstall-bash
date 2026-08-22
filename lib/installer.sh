# shellcheck shell=bash
# Port of lib/installer.py (Installer) for the steps guided installs use:
# mounting the layout, key files, minimal installation (pacstrap + base
# configuration), swap, users, services, timezone, fstab, kernel parameters.
# LVM, FIDO2 and the systemd-boot/GRUB/efistub/rEFInd bootloaders are not ported.

INST_TARGET=/mnt
INST_BASE_PACKAGES=()
INST_KERNELS=()
INST_HOOKS=()
INST_MODULES=() INST_BINARIES=() INST_FILES=()
INST_KERNEL_PARAMS=()
INST_FSTAB_ENTRIES=()
INST_ZRAM_ENABLED=0
INST_DISABLE_FSTRIM=0
INST_INIT_TIME=''
declare -gA INST_HELPER_FLAGS=()
INST_SILENT=1

# Installer.__init__(target, disk_config, kernels=...)
installer_init() {
  INST_TARGET=${1:-/mnt}
  shift || true
  INST_KERNELS=("$@")
  ((${#INST_KERNELS[@]})) || INST_KERNELS=(linux)
  INST_BASE_PACKAGES=(base sudo linux-firmware mkinitcpio "${INST_KERNELS[@]}")
  if accessibility_tools_in_use; then
    INST_BASE_PACKAGES+=(brltty espeakup alsa-utils)
  fi
  INST_HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block filesystems fsck)
  INST_MODULES=() INST_BINARIES=() INST_FILES=()
  INST_KERNEL_PARAMS=()
  INST_FSTAB_ENTRIES=()
  INST_ZRAM_ENABLED=0
  INST_DISABLE_FSTRIM=0
  INST_INIT_TIME=$(date '+%Y-%m-%d_%H-%M-%S')
  INST_HELPER_FLAGS=([base]=false [bootloader]='')
  PACMAN_SYNCED=0
  PACMAN_OPTIONAL_REPOS=()
  mkdir -p "$INST_TARGET"
}

# Installer.__exit__(): sync and report steps that never completed.
installer_finish() {
  info 'Syncing the system...'
  sync
  local missing=() step
  for step in "${!INST_HELPER_FLAGS[@]}"; do
    [[ ${INST_HELPER_FLAGS[$step]} == false ]] && missing+=("$step")
  done
  if ((${#missing[@]} == 0)); then
    info "Installation completed without any errors. Log files temporarily available at $ARCHINSTALL_LOG_DIR. You may reboot when ready."
    return 0
  fi
  warn 'Some required steps were not successfully installed/configured before leaving the installer:'
  for step in "${missing[@]}"; do
    warn " - $step"
  done
  return 1
}

# ── sanity checks ─────────────────────────────────────────────────────────────

installer_service_state() {
  local service=$1
  [[ $service == *.service || $service == *.target || $service == *.timer ]] || service+=.service
  SYSTEMD_COLORS=0 systemctl show --no-pager -p SubState --value "$service" 2>/dev/null
}

installer_service_started() {
  local service=$1 ts
  [[ $service == *.service || $service == *.target || $service == *.timer ]] || service+=.service
  ts=$(SYSTEMD_COLORS=0 systemctl show --property=ActiveEnterTimestamp --no-pager "$service" 2>/dev/null)
  ts=${ts#ActiveEnterTimestamp=}
  [[ -n $ts ]]
}

# Installer.sanity_check(offline, skip_ntp, skip_wkd) → _verify_service_stop()
installer_sanity_check() {
  local offline=${1:-0} skip_ntp=${2:-0} skip_wkd=${3:-0} started notified=0 i
  if ((!skip_ntp)); then
    info 'Waiting for time sync (timedatectl show) to complete.'
    started=$SECONDS
    while [[ $(timedatectl show --property=NTPSynchronized --value 2>/dev/null) != yes ]]; do
      if ((!notified && SECONDS - started > 5)); then
        notified=1
        warn 'Time synchronization not completing, while you wait - check the docs for workarounds: https://archinstall.readthedocs.io/'
      fi
      sleep 1
    done
  else
    info 'Skipping waiting for automatic time sync (this can cause issues if time is out of sync during installation)'
  fi

  if ((!offline)); then
    info 'Waiting for automatic mirror selection (reflector) to complete.'
    for ((i = 0; i < 60; i++)); do
      case $(installer_service_state reflector) in dead|failed|exited) break ;; esac
      sleep 1
    done
    ((i == 60)) && warn 'Reflector did not complete within 60 seconds, continuing anyway...'
  else
    info 'Skipped reflector...'
  fi

  if ((!skip_wkd)); then
    info 'Waiting for Arch Linux keyring sync (archlinux-keyring-wkd-sync) to complete.'
    until installer_service_started archlinux-keyring-wkd-sync.timer; do sleep 1; done
    while :; do
      case $(installer_service_state archlinux-keyring-wkd-sync.service) in dead|failed|exited) break ;; esac
      sleep 1
    done
    [[ $(installer_service_state archlinux-keyring-wkd-sync.service) == failed ]] &&
      warn 'archlinux-keyring-wkd-sync failed, keyring may need reinit during pacman sync'
  fi
  return 0
}

# ── mounting ──────────────────────────────────────────────────────────────────

# Installer.mount_ordered_layout()
installer_mount_ordered_layout() {
  debug 'Mounting ordered layout'
  case $ENC_TYPE in
    no_encryption) ;;
    luks) installer_prepare_luks_partitions ;;
    *) die "encryption type $ENC_TYPE is not supported by this port" ;;
  esac
  installer_mount_partition_layout
}

# Installer._prepare_luks_partitions(): unlock every encrypted partition.
installer_prepare_luks_partitions() {
  local i mapper
  for i in "${ENC_PARTS[@]}"; do
    mapper=$(part_mapper_name "$i")
    [[ -n $mapper && -n ${PART_DEVPATH[i]} ]] || continue
    luks_unlock_if_needed "${PART_DEVPATH[i]}" "$mapper" "$ENC_PASSWORD"
  done
}

# Installer._mount_partition_layout(): the device holding root first, then
# partitions ordered by mountpoint (btrfs partitions without one sort as /).
installer_mount_partition_layout() {
  debug 'Mounting partition layout'
  local -a order=()
  local d i root_dev=''
  for d in "${!DEV_PATH[@]}"; do
    for i in "${!PART_DEV[@]}"; do
      [[ ${PART_DEV[i]} == "$d" ]] && part_is_root "$i" && root_dev=$d
    done
  done
  [[ -n $root_dev ]] && order+=("$root_dev")
  for d in "${!DEV_PATH[@]}"; do
    [[ $d == "$root_dev" ]] || order+=("$d")
  done

  for d in "${order[@]}"; do
    for i in $(installer_partitions_by_mountpoint "$d"); do
      if part_is_encrypted "$i"; then
        installer_mount_luks_partition "$i"
      else
        installer_mount_partition "$i"
      fi
    done
  done
}

installer_partitions_by_mountpoint() {
  local d=$1 i
  for i in "${!PART_DEV[@]}"; do
    [[ ${PART_DEV[i]} == "$d" ]] || continue
    printf '%s\t%s\n' "${PART_MOUNTPOINT[i]:-/}" "$i"
  done | sort -t$'\t' -k1,1 | cut -f2
}

# Installer._mount_partition()
installer_mount_partition() {
  local i=$1 dev=${PART_DEVPATH[$1]} options
  [[ -n $dev ]] || return 0
  if [[ -n ${PART_MOUNTPOINT[i]} ]]; then
    options=${PART_MOUNT_OPTIONS[i]}
    if part_is_efi "$i"; then
      options=$(installer_merge_options "$options" fmask=0077 dmask=0077)
    fi
    disk_mount "$dev" "$INST_TARGET/$(relative_path "${PART_MOUNTPOINT[i]}")" "$options"
  elif [[ ${PART_FS[i]} == btrfs ]]; then
    installer_mount_btrfs_subvol "$dev" "$i"
  elif part_is_swap "$i"; then
    disk_swapon "$dev"
  fi
}

# Installer._mount_luks_partition()
installer_mount_luks_partition() {
  local i=$1 mapper_dev
  mapper_dev=$(part_mapper_dev "$i")
  [[ -e $mapper_dev ]] || return 0
  if [[ ${PART_FS[i]} == btrfs && -n ${PART_SUBVOLS[i]} ]]; then
    installer_mount_btrfs_subvol "$mapper_dev" "$i"
  elif [[ -n ${PART_MOUNTPOINT[i]} ]]; then
    disk_mount "$mapper_dev" "$INST_TARGET/$(relative_path "${PART_MOUNTPOINT[i]}")" "${PART_MOUNT_OPTIONS[i]}"
  fi
}

# Installer._mount_btrfs_subvol(): subvolumes with a mountpoint, shallowest first.
installer_mount_btrfs_subvol() {
  local dev=$1 i=$2 sv name mp options
  for sv in $(printf '%s\n' ${PART_SUBVOLS[i]} | awk -F= '{ print $2 "\t" $0 }' | sort -t$'\t' -k1,1 | cut -f2); do
    name=${sv%%=*}
    mp=${sv#*=}
    options=$(installer_merge_options "${PART_MOUNT_OPTIONS[i]}" "subvol=$name")
    disk_mount "$dev" "$INST_TARGET/$(relative_path "$mp")" "$options"
  done
}

# list(dict.fromkeys(options + extra)) as a comma list.
installer_merge_options() {
  local base=$1 out='' o
  shift
  for o in ${base//,/ } "$@"; do
    [[ -n $o ]] || continue
    list_contains "${out//,/ }" "$o" || out+="${out:+,}$o"
  done
  printf '%s' "$out"
}

# ── encryption key files ─────────────────────────────────────────────────────

# Installer.generate_key_files() for LUKS partitions.
installer_generate_key_files() {
  [[ $ENC_TYPE == luks ]] || return 0
  local root_is_encrypted=0 i gen
  for i in "${ENC_PARTS[@]}"; do
    part_is_root "$i" && root_is_encrypted=1
  done
  for i in "${ENC_PARTS[@]}"; do
    # DiskEncryption.should_generate_encryption_file(): anything but /
    gen=1
    [[ ${PART_MOUNTPOINT[i]} == / ]] && gen=0
    if ((gen)) && ! part_is_root "$i"; then
      if ((root_is_encrypted)); then
        debug "Creating key-file: ${PART_DEVPATH[i]}"
        luks_create_keyfile "${PART_DEVPATH[i]}" "$(part_mapper_name "$i")" "$ENC_PASSWORD" "$INST_TARGET"
      else
        debug "Adding passphrase-based crypttab entry for ${PART_DEVPATH[i]}"
        luks_create_crypttab_entry "${PART_DEVPATH[i]}" "$(part_mapper_name "$i")" "$INST_TARGET"
      fi
    fi
  done
}

# ── base system ───────────────────────────────────────────────────────────────

# Installer._prepare_fs_type()
installer_prepare_fs_type() {
  local pkg
  if pkg=$(fs_installation_pkg "$1"); then
    list_contains "${INST_BASE_PACKAGES[*]}" "$pkg" || INST_BASE_PACKAGES+=("$pkg")
  fi
  # https://github.com/archlinux/archinstall/issues/1837
  [[ $1 == btrfs ]] && INST_DISABLE_FSTRIM=1
  return 0
}

# Installer._prepare_encrypt(): the encrypt hook before `filesystems`.
installer_prepare_encrypt() {
  local before=${1:-filesystems} hook
  list_contains "${INST_HOOKS[*]}" encrypt && return 0
  local -a hooks=()
  for hook in "${INST_HOOKS[@]}"; do
    [[ $hook == "$before" ]] && hooks+=(encrypt)
    hooks+=("$hook")
  done
  INST_HOOKS=("${hooks[@]}")
}

# Installer.minimal_installation(). Options: --no-mkinitcpio --no-hostname
# --no-locale (the Python keyword arguments); optional repositories, pacman
# and locale settings come from the loaded configuration.
installer_minimal_installation() {
  local run_mkinitcpio=1 set_hostname=1 set_locale=1 arg i ucode
  for arg in "$@"; do
    case $arg in
      --no-mkinitcpio) run_mkinitcpio=0 ;;
      --no-hostname) set_hostname=0 ;;
      --no-locale) set_locale=0 ;;
      *) die "installer_minimal_installation: unknown option $arg" ;;
    esac
  done

  for i in "${!PART_DEV[@]}"; do
    [[ -n ${PART_FS[i]} ]] || continue
    installer_prepare_fs_type "${PART_FS[i]}"
    part_is_encrypted "$i" && installer_prepare_encrypt
  done

  if ucode=$(installer_get_microcode); then
    rm -f "$INST_TARGET/boot/$ucode.img"
    INST_BASE_PACKAGES+=("$ucode")
  else
    debug 'Archinstall will not install any ucode.'
  fi

  debug "Optional repositories: ${CFG_MIRROR_OPTIONAL_REPOS[*]}"
  pacman_config_enable "${CFG_MIRROR_OPTIONAL_REPOS[@]}"
  pacman_config_apply

  ((set_locale)) && installer_set_vconsole

  pacman_strap "${INST_BASE_PACKAGES[@]}"
  INST_HELPER_FLAGS[base-strapped]=true

  pacman_config_persist
  [[ $CFG_HAS_PACMAN_CONFIG == true ]] && pacman_config_configure "$CFG_PARALLEL_DOWNLOADS" "$CFG_PACMAN_COLOR"

  # https://github.com/archlinux/archinstall/issues/880 / #1837 / #1841
  ((INST_DISABLE_FSTRIM)) || installer_enable_periodic_trim

  ((set_hostname)) && [[ -n $CFG_HOSTNAME ]] && installer_set_hostname "$CFG_HOSTNAME"

  if ((set_locale)); then
    installer_set_locale || true
    installer_set_keyboard_language "$CFG_LOCALE_KB" || true
  fi

  if ((run_mkinitcpio)) && ! installer_mkinitcpio -P; then
    error 'Error generating initramfs (continuing anyway)'
  fi

  INST_HELPER_FLAGS[base]=true
  return 0
}

installer_set_hostname() {
  printf '%s\n' "$1" >"$INST_TARGET/etc/hostname"
}

# Installer.mkinitcpio(flags...): rewrite MODULES/BINARIES/FILES/HOOKS and run.
installer_mkinitcpio() {
  local conf="$INST_TARGET/etc/mkinitcpio.conf" hooks=() hook
  # Without an HSM archinstall reverts to the classic busybox hooks.
  for hook in "${INST_HOOKS[@]}"; do
    case $hook in
      systemd) hooks+=(udev) ;;
      sd-vconsole) hooks+=(keymap consolefont) ;;
      *) hooks+=("$hook") ;;
    esac
  done
  INST_HOOKS=("${hooks[@]}")
  local tmp
  tmp=$(mktemp)
  awk -v modules="${INST_MODULES[*]}" -v binaries="${INST_BINARIES[*]}" -v files="${INST_FILES[*]}" -v hooks="${INST_HOOKS[*]}" '
    /^MODULES=/ { print "MODULES=(" modules ")"; next }
    /^BINARIES=/ { print "BINARIES=(" binaries ")"; next }
    /^FILES=/ { print "FILES=(" files ")"; next }
    /^HOOKS=/ { print "HOOKS=(" hooks ")"; next }
    { print }
  ' "$conf" >"$tmp" && cat "$tmp" >"$conf"
  rm -f "$tmp"
  chroot_cmd_peek mkinitcpio "$@"
}

# Installer.setup_swap(): swap on zram.
installer_setup_swap() {
  local algo=${1:-zstd}
  info 'Setting up swap on zram'
  pacman_strap zram-generator
  info "Zram compression algorithm: $algo"
  printf '[zram0]\ncompression-algorithm = %s\n' "$algo" >"$INST_TARGET/etc/systemd/zram-generator.conf"
  installer_enable_service systemd-zram-setup@zram0.service
  INST_ZRAM_ENABLED=1
}

# Installer.setup_btrfs_snapshot(): snapper or timeshift (no GRUB integration).
installer_setup_btrfs_snapshot() {
  local snapshot_type=$1 name mp
  case $snapshot_type in
    snapper)
      debug 'Setting up Btrfs snapper'
      pacman_strap snapper
      for name in root home; do
        mp=/
        [[ $name == home ]] && mp=/home
        chroot_cmd_peek snapper --no-dbus -c "$name" create-config "$mp" || die "Could not setup Btrfs snapper: $SYS_CMD_OUTPUT"
      done
      installer_enable_service snapper-timeline.timer snapper-cleanup.timer
      ;;
    timeshift)
      debug 'Setting up Btrfs timeshift'
      pacman_strap cronie timeshift
      installer_enable_service cronie.service
      ;;
    *) die "Unsupported snapshot type: $snapshot_type" ;;
  esac
  [[ $CFG_BOOTLOADER == grub ]] && warn 'grub-btrfs integration is not ported'
  return 0
}

# ── services, users, misc ─────────────────────────────────────────────────────

installer_enable_service() {
  local service
  for service in "$@"; do
    info "Enabling service $service"
    sys_cmd systemctl --root="$INST_TARGET" enable "$service" || die "Unable to start service $service: $SYS_CMD_OUTPUT"
  done
}

installer_disable_service() {
  local service
  for service in "$@"; do
    info "Disabling service $service"
    sys_cmd systemctl --root="$INST_TARGET" disable "$service" || die "Unable to disable service $service: $SYS_CMD_OUTPUT"
  done
}

installer_enable_periodic_trim() {
  info 'Enabling periodic TRIM'
  installer_enable_service fstrim.timer
}

installer_activate_time_synchronization() {
  info 'Activating systemd-timesyncd for time synchronization using Arch Linux and ntp.org NTP servers'
  installer_enable_service systemd-timesyncd
}

installer_enable_espeakup() {
  info 'Enabling espeakup.service for speech synthesis (accessibility)'
  installer_enable_service espeakup
}

installer_set_timezone() {
  local zone=$1
  [[ -n $zone ]] || return 0
  if [[ -e /usr/share/zoneinfo/$zone ]]; then
    rm -f "$INST_TARGET/etc/localtime"
    chroot_cmd ln -s "/usr/share/zoneinfo/$zone" /etc/localtime || die "could not set timezone: $SYS_CMD_OUTPUT"
    return 0
  fi
  warn "Time zone $zone does not exist, continuing with system default"
  return 1
}

installer_add_additional_packages() {
  pacman_strap "$@"
}

# Installer.genfstab()
installer_genfstab() {
  local flags=${1:--pU} fstab="$INST_TARGET/etc/fstab" entry
  info "Updating $fstab"
  # shellcheck disable=SC2086
  genfstab $flags -f "$INST_TARGET" "$INST_TARGET" >>"$fstab" ||
    die 'Could not generate fstab, strapping in packages most likely failed (disk out of space?)'
  [[ -f $fstab ]] || die 'Could not create fstab file'
  for entry in "${INST_FSTAB_ENTRIES[@]}"; do
    printf '%s\n' "$entry" >>"$fstab"
  done
}

# Installer.systemd_resolved_stub_mode()
installer_systemd_resolved_stub_mode() {
  rm -f "$INST_TARGET/etc/resolv.conf"
  ln -s /run/systemd/resolve/stub-resolv.conf "$INST_TARGET/etc/resolv.conf"
}

# Installer.enable_sudo(): /etc/sudoers.d/NN_user
installer_enable_sudo() {
  local user=$1 group=${2:-} dir="$INST_TARGET/etc/sudoers.d" n safe
  info "Enabling sudo permissions for $user"
  if [[ ! -d $dir ]]; then
    mkdir -p "$dir"
    chmod 0440 "$dir"
    printf '@includedir /etc/sudoers.d\n' >>"$INST_TARGET/etc/sudoers"
  fi
  n=$(find "$dir" -mindepth 1 -maxdepth 1 | wc -l)
  safe=$(printf '%s' "$user" | tr -d '\\/:*?"<>|')
  printf '%s%s ALL=(ALL) ALL\n' "${group:+%}" "$user" >>"$dir/$(printf '%02d' "$n")_$safe"
  chmod 0440 "$dir/$(printf '%02d' "$n")_$safe"
}

# Installer.create_users(): every user from the credentials.
installer_create_users() {
  local i
  for i in "${!USER_NAME[@]}"; do
    installer_create_user "${USER_NAME[i]}" "${USER_ENC_PASSWORD[i]}" "${USER_SUDO[i]}" "${USER_GROUPS[i]}"
  done
}

# Installer._create_user(username, enc_password, sudo, groups)
installer_create_user() {
  local user=$1 enc=$2 sudo=${3:-false} groups=${4:-} group
  info "Creating user $user"
  local -a cmd=(useradd -m)
  [[ $sudo == true ]] && cmd+=(-G wheel)
  cmd+=(-- "$user")
  chroot_cmd "${cmd[@]}" || die "Could not create user inside installation: $SYS_CMD_OUTPUT"
  installer_set_user_password "$user" "$enc"
  for group in $groups; do
    chroot_cmd gpasswd -a "$user" "$group" || warn "Failed to add $user to group $group: $SYS_CMD_OUTPUT"
  done
  [[ $sudo == true ]] && installer_enable_sudo "$user"
  return 0
}

# Installer.set_user_password(): chpasswd --encrypted
installer_set_user_password() {
  local user=$1 enc=$2
  info "Setting password for $user"
  if [[ -z $enc ]]; then
    debug 'User password is empty'
    return 1
  fi
  sys_cmd_input "$user:$enc" arch-chroot -S "$INST_TARGET" chpasswd --encrypted || {
    debug "Error setting user password: $SYS_CMD_OUTPUT"
    return 1
  }
}

installer_user_set_shell() {
  info "Setting shell for $1 to $2"
  chroot_cmd chsh -s "$2" "$1"
}

installer_chown() {
  chroot_cmd chown "${@:3}" -- "$1" "$2"
}

# run_custom_user_commands()
installer_run_custom_user_commands() {
  local index=0 command script
  for command in "$@"; do
    script="/var/tmp/user-command.$index.sh"
    info "Executing custom command \"$command\" ..."
    printf '%s' "$command" >"$INST_TARGET$script"
    chroot_cmd bash "$script" || die "custom command failed: $SYS_CMD_OUTPUT"
    rm -f "$INST_TARGET$script"
    index=$((index + 1))
  done
}

# ── kernel parameters ────────────────────────────────────────────────────────

# Installer._get_kernel_params(root_index, id_root=1, partuuid=1)
installer_get_kernel_params() {
  local root=$1 id_root=${2:-1} partuuid=${3:-1} params=() subvol
  if part_is_encrypted "$root"; then
    if ((partuuid)); then
      debug "Root partition is an encrypted device, identifying by PARTUUID: ${PART_PARTUUID[root]}"
      params+=("cryptdevice=PARTUUID=${PART_PARTUUID[root]}:root")
    else
      debug "Root partition is an encrypted device, identifying by UUID: ${PART_UUID[root]}"
      params+=("cryptdevice=UUID=${PART_UUID[root]}:root")
    fi
    ((id_root)) && params+=('root=/dev/mapper/root')
  elif ((id_root)); then
    if ((partuuid)); then
      debug "Identifying root partition by PARTUUID: ${PART_PARTUUID[root]}"
      params+=("root=PARTUUID=${PART_PARTUUID[root]}")
    else
      debug "Identifying root partition by UUID: ${PART_UUID[root]}"
      params+=("root=UUID=${PART_UUID[root]}")
    fi
  fi

  # Zswap should be disabled when using zram (#881).
  ((INST_ZRAM_ENABLED)) && params+=('zswap.enabled=0')

  if ((id_root)); then
    subvol=$(part_root_subvol "$root") && params+=("rootflags=subvol=$subvol")
    params+=(rw)
  fi
  params+=("rootfstype=$(part_safe_fs_type "$root")")
  params+=("${INST_KERNEL_PARAMS[@]}")
  debug "kernel parameters: ${params[*]}"
  printf '%s\n' "${params[*]}"
}
