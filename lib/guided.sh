# shellcheck shell=bash
# Port of scripts/guided.py: the installation sequence driven by a loaded
# configuration. The interactive menu is not ported — a configuration file is
# required.

ARGS_MOUNTPOINT=/mnt
ARGS_OFFLINE=0
ARGS_SKIP_NTP=0
ARGS_SKIP_WKD=0
ARGS_SKIP_BOOT=0
ARGS_DRY_RUN=0

# perform_installation()
guided_perform_installation() {
  local start=$SECONDS
  info 'Starting installation...'

  if [[ $DISK_CONFIG_PRESENT != true ]]; then
    error 'No disk configuration provided'
    return 1
  fi

  local mountpoint=${DISK_MOUNTPOINT:-$ARGS_MOUNTPOINT}
  local -a minimal_opts=()
  [[ -n $CFG_BOOTLOADER && $CFG_BOOT_UKI == true ]] && minimal_opts+=(--no-mkinitcpio)

  installer_init "$mountpoint" "${CFG_KERNELS[@]}"

  disk_is_pre_mount || installer_mount_ordered_layout

  installer_sanity_check "$ARGS_OFFLINE" "$ARGS_SKIP_NTP" "$ARGS_SKIP_WKD"

  if ! disk_is_pre_mount && disk_is_encrypted; then
    installer_generate_key_files
  fi

  [[ $CFG_HAS_MIRROR_CONFIG == true ]] && installer_set_mirrors live

  installer_minimal_installation "${minimal_opts[@]}"

  [[ $CFG_HAS_MIRROR_CONFIG == true ]] && installer_set_mirrors on_target

  [[ $CFG_SWAP_ENABLED == true ]] && installer_setup_swap "$CFG_SWAP_ALGO"

  if [[ -n $CFG_BOOTLOADER && $CFG_BOOTLOADER != no_bootloader && $ARGS_SKIP_BOOT != 1 ]]; then
    installer_add_bootloader "$CFG_BOOTLOADER" "$CFG_BOOT_UKI" "$CFG_BOOT_REMOVABLE" "$CFG_BOOT_PLYMOUTH"
  fi

  [[ -n $CFG_NETWORK_TYPE ]] && network_install_config "$CFG_NETWORK_TYPE"

  ((${#USER_NAME[@]})) && installer_create_users

  [[ $CFG_HAS_APP_CONFIG == true ]] && applications_install

  if ((${#CFG_PACKAGES[@]})) && [[ -n ${CFG_PACKAGES[0]} ]]; then
    installer_add_additional_packages "${CFG_PACKAGES[@]}"
  fi

  [[ -n $CFG_TIMEZONE ]] && { installer_set_timezone "$CFG_TIMEZONE" || true; }

  [[ $CFG_NTP == true ]] && installer_activate_time_synchronization

  accessibility_tools_in_use && installer_enable_espeakup

  [[ -n $CFG_ROOT_ENC_PASSWORD ]] && { installer_set_user_password root "$CFG_ROOT_ENC_PASSWORD" || true; }

  ((${#CFG_SERVICES[@]})) && installer_enable_service "${CFG_SERVICES[@]}"

  if disk_has_default_btrfs_vols && [[ -n $BTRFS_SNAPSHOT_TYPE ]]; then
    installer_setup_btrfs_snapshot "$BTRFS_SNAPSHOT_TYPE"
  fi

  ((${#CFG_CUSTOM_COMMANDS[@]})) && installer_run_custom_user_commands "${CFG_CUSTOM_COMMANDS[@]}"

  installer_genfstab

  debug "Disk states after installing:"$'\n'"$(lsblk 2>/dev/null)"

  local rc=0
  installer_finish || rc=$?
  info "Installation took $((SECONDS - start)) seconds."
  return $rc
}

# validate_bootloader_layout(): Limine + UKI wants the ESP to hold /boot.
guided_validate_bootloader_layout() {
  [[ -n $CFG_BOOTLOADER && $CFG_BOOTLOADER != no_bootloader ]] || return 0
  [[ $DISK_CONFIG_PRESENT == true ]] || return 0
  disk_is_pre_mount && return 0
  local boot efi
  if sysinfo_has_uefi; then
    efi=$(installer_get_efi_partition) || { error 'No EFI system partition (flag esp with a mountpoint) in the disk layout'; return 1; }
    if [[ $CFG_BOOT_UKI == true && ${PART_MOUNTPOINT[efi]} != /boot && ${PART_MOUNTPOINT[efi]} != /efi ]]; then
      error "UKI requires the ESP to be mounted at /boot or /efi, not ${PART_MOUNTPOINT[efi]}"
      return 1
    fi
  fi
  boot=$(installer_get_boot_partition) || { error 'No boot partition (flag boot with a mountpoint) in the disk layout'; return 1; }
  return 0
}

# main()
guided_main() {
  config_save
  guided_validate_bootloader_layout || return 1

  if ((ARGS_DRY_RUN)); then
    info 'Dry run: configuration parsed, nothing was written to disk.'
    config_summary
    return 0
  fi

  if [[ $DISK_CONFIG_PRESENT == true ]]; then
    fs_perform_filesystem_operations
  fi

  guided_perform_installation
}
