# shellcheck shell=bash
# Port of lib/models/bootloader.py and Installer.add_bootloader() for Limine,
# the bootloader Omarchy installs. UKI setup (Installer._config_uki) and
# Plymouth are ported with it; systemd-boot, GRUB, efistub and rEFInd are not.

# Bootloader.from_arg()
bootloader_from_arg() {
  case ${1,,} in
    '') printf '' ;;
    systemd-boot|systemd) printf 'systemd' ;;
    grub) printf 'grub' ;;
    efistub) printf 'efistub' ;;
    limine) printf 'limine' ;;
    refind) printf 'refind' ;;
    'no bootloader'|no_bootloader|none) printf 'no_bootloader' ;;
    *) die "Invalid bootloader value \"$1\". Allowed values: Systemd-boot, Grub, Efistub, Limine, Refind, No bootloader" ;;
  esac
}

bootloader_has_uki_support() {
  [[ -n $1 && $1 != no_bootloader ]]
}

bootloader_has_removable_support() {
  [[ $1 == grub || $1 == limine ]]
}

# Installer.add_bootloader(bootloader, uki, removable, plymouth)
installer_add_bootloader() {
  local bootloader=$1 uki=${2:-false} removable=${3:-false} plymouth=${4:-}
  local efi boot root
  efi=$(installer_get_efi_partition) || efi=''
  boot=$(installer_get_boot_partition) || die "Could not detect boot at mountpoint $INST_TARGET"
  root=$(installer_get_root) || die "Could not detect root at mountpoint $INST_TARGET"

  info "Adding bootloader $bootloader to ${PART_DEVPATH[boot]}"

  if [[ $uki == true ]] && ! bootloader_has_uki_support "$bootloader"; then
    warn "Bootloader $bootloader does not support UKI; disabling."
    uki=false
  fi
  if [[ $removable == true ]]; then
    if ! sysinfo_has_uefi; then
      warn 'Removable install requested but system is not UEFI; disabling.'
      removable=false
    elif ! bootloader_has_removable_support "$bootloader"; then
      warn "Bootloader $bootloader lacks removable support; disabling."
      removable=false
    fi
  fi

  [[ -n $plymouth ]] && installer_install_plymouth "$plymouth"

  [[ $uki == true ]] && installer_config_uki "$root" "$efi"

  case $bootloader in
    limine) installer_add_limine_bootloader "$boot" "$efi" "$root" "$uki" "$removable" ;;
    *) die "bootloader $bootloader is not supported by this port (Limine only)" ;;
  esac
}

# Installer._add_limine_bootloader()
installer_add_limine_bootloader() {
  local boot=$1 efi=$2 root=$3 uki=${4:-false} removable=${5:-false}
  local limine_path="$INST_TARGET/usr/share/limine" config_path hook_command arch
  debug 'Installing Limine bootloader'
  pacman_strap limine
  info "Limine boot partition: ${PART_DEVPATH[boot]}"
  arch=$(machine_arch)

  if sysinfo_has_uefi; then
    pacman_strap efibootmgr
    [[ -n $efi ]] || die 'Could not detect efi partition'
    [[ -n ${PART_MOUNTPOINT[efi]} ]] || die 'EFI partition is not mounted'
    info "Limine EFI partition: ${PART_DEVPATH[efi]}"

    local parent_dev efi_dir efi_dir_target efi_binaries=() file
    parent_dev=$(get_parent_device_path "${PART_DEVPATH[efi]}")
    efi_dir="$INST_TARGET/$(relative_path "${PART_MOUNTPOINT[efi]}")/EFI"
    efi_dir_target="${PART_MOUNTPOINT[efi]%/}/EFI"
    if [[ $removable == true ]]; then
      efi_dir+=/BOOT
      efi_dir_target+=/BOOT
    else
      efi_dir+=/arch-limine
      efi_dir_target+=/arch-limine
    fi
    config_path="$efi_dir/limine.conf"
    mkdir -p "$efi_dir"

    if [[ $arch == aarch64 ]]; then
      efi_binaries=(BOOTAA64.EFI)
    else
      efi_binaries=(BOOTIA32.EFI BOOTX64.EFI)
    fi
    hook_command=''
    for file in "${efi_binaries[@]}"; do
      cp -p "$limine_path/$file" "$efi_dir/" || die "Failed to install Limine in $INST_TARGET${PART_MOUNTPOINT[efi]}"
      hook_command+="${hook_command:+ && }/usr/bin/cp /usr/share/limine/$file $efi_dir_target/"
    done

    if [[ $removable != true ]]; then
      local bitness loader
      bitness=$(cat /sys/firmware/efi/fw_platform_size 2>/dev/null) || die 'Could not open or read /sys/firmware/efi/fw_platform_size to determine EFI bitness'
      case $bitness in
        64) loader="\\EFI\\arch-limine\\$([[ $arch == aarch64 ]] && printf 'BOOTAA64.EFI' || printf 'BOOTX64.EFI')" ;;
        32) loader='\EFI\arch-limine\BOOTIA32.EFI' ;;
        *) die "EFI bitness is neither 32 nor 64 bits. Found \"$bitness\"." ;;
      esac
      sys_cmd efibootmgr --create --disk "$parent_dev" --part "${PART_PARTN[efi]}" --label 'Arch Linux Limine Bootloader' \
        --loader "$loader" --unicode --verbose || die "SysCommand for efibootmgr failed: $SYS_CMD_OUTPUT"
    fi
  else
    local boot_limine="$INST_TARGET/boot/limine" parent_dev unique
    mkdir -p "$boot_limine"
    config_path="$boot_limine/limine.conf"
    parent_dev=$(get_parent_device_path "${PART_DEVPATH[boot]}")
    unique=$(get_unique_path_for_device "$parent_dev") && parent_dev=$unique
    cp -p "$limine_path/limine-bios.sys" "$boot_limine/" || die "Failed to install Limine on $parent_dev"
    chroot_cmd_peek limine bios-install "$parent_dev" || die "Failed to install Limine on $parent_dev"
    hook_command="/usr/bin/limine bios-install $parent_dev && /usr/bin/cp /usr/share/limine/limine-bios.sys /boot/limine/"
  fi

  mkdir -p "$INST_TARGET/etc/pacman.d/hooks"
  cat >"$INST_TARGET/etc/pacman.d/hooks/99-limine.hook" <<HOOK
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = limine

[Action]
Description = Deploying Limine after upgrade...
When = PostTransaction
Exec = /bin/sh -c "$hook_command"
HOOK

  local kernel_params path_root='boot()' kernel
  kernel_params=$(installer_get_kernel_params "$root")
  if [[ -n $efi && $boot != "$efi" ]]; then
    path_root="uuid(${PART_PARTUUID[boot]})"
  fi
  {
    printf 'timeout: 5\n'
    for kernel in "${INST_KERNELS[@]}"; do
      printf '\n/Arch Linux (%s)\n' "$kernel"
      if [[ $uki == true ]]; then
        printf '    protocol: efi\n    path: boot():/EFI/Linux/arch-%s.efi\n    cmdline: %s\n' "$kernel" "$kernel_params"
      else
        printf '    protocol: linux\n    path: %s:/vmlinuz-%s\n    cmdline: %s\n    module_path: %s:/initramfs-%s.img\n' \
          "$path_root" "$kernel" "$kernel_params" "$path_root" "$kernel"
      fi
    done
  } >"$config_path"

  INST_HELPER_FLAGS[bootloader]=limine
}

# Installer._config_uki(): kernel cmdline + mkinitcpio presets producing UKIs.
installer_config_uki() {
  local root=$1 efi=$2 keep_initramfs=${3:-0} kernel preset diff_mountpoint=''
  [[ -n $efi && -n ${PART_MOUNTPOINT[efi]} ]] || die "Could not detect ESP at mountpoint $INST_TARGET"
  mkdir -p "$INST_TARGET/etc/kernel"
  installer_get_kernel_params "$root" >"$INST_TARGET/etc/kernel/cmdline"

  [[ ${PART_MOUNTPOINT[efi]} != /efi ]] && diff_mountpoint=${PART_MOUNTPOINT[efi]}

  for kernel in "${INST_KERNELS[@]}"; do
    preset="$INST_TARGET/etc/mkinitcpio.d/$kernel.preset"
    [[ -f $preset ]] || continue
    local tmp
    tmp=$(mktemp)
    awk -v keep="$keep_initramfs" -v target="$INST_TARGET" -v esp="$diff_mountpoint" '
      match($0, /^(.+_image="\/)([^"]+)(.*)$/, m) {
        if (!keep) { system("rm -f \"" target "/" m[2] "\""); print "#" $0; next }
      }
      match($0, /^#((.+_uki=")\/[^\/]+(.*))$/, m) {
        if (esp != "") print m[2] esp m[3]; else print m[1]
        next
      }
      /^#default_options=/ { sub(/^#/, ""); print; next }
      { print }
    ' "$preset" >"$tmp" && cat "$tmp" >"$preset"
    rm -f "$tmp"
  done

  mkdir -p "$INST_TARGET/$(relative_path "${PART_MOUNTPOINT[efi]}")/EFI/Linux"
  installer_mkinitcpio -P || error 'Error generating initramfs (continuing anyway)'
}

# Installer._install_plymouth()
installer_install_plymouth() {
  local theme=$1 param hook idx=-1 insert_after=0 i
  debug "Installing plymouth with theme: $theme"
  installer_add_additional_packages plymouth
  for param in quiet splash; do
    list_contains "${INST_KERNEL_PARAMS[*]}" "$param" || INST_KERNEL_PARAMS+=("$param")
  done
  if ! list_contains "${INST_HOOKS[*]}" plymouth; then
    for hook in encrypt:0 sd-encrypt:0 systemd:1 filesystems:0 keyboard:1; do
      for i in "${!INST_HOOKS[@]}"; do
        [[ ${INST_HOOKS[i]} == "${hook%:*}" ]] && { idx=$i; insert_after=${hook#*:}; break 2; }
      done
    done
    if ((idx < 0)); then
      INST_HOOKS+=(plymouth)
    else
      INST_HOOKS=("${INST_HOOKS[@]:0:idx+insert_after}" plymouth "${INST_HOOKS[@]:idx+insert_after}")
    fi
  fi
  chroot_cmd plymouth-set-default-theme "$theme" || die "plymouth-set-default-theme failed: $SYS_CMD_OUTPUT"
  installer_mkinitcpio -P
}
