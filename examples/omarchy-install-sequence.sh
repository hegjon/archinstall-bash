#!/usr/bin/env bash
# The archinstall call sequence of Omarchy's ISO orchestrator
# (omarchy-iso: orchestrator/archinstall_adapter.py + phases_impl.py
# arch_install_system), expressed against this library. Everything Omarchy
# layers on top (root image unpack, Limine files, omarchy-apply-system, …) is
# left as comments where it slots in.
#
#   OMARCHY_INSTALL_CONFIG=/root/user_configuration.json \
#   OMARCHY_INSTALL_CREDS=/root/user_credentials.json \
#   examples/omarchy-install-sequence.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$here/../lib/archinstall.sh"

# prepare_live: load_arch_config(config, creds); make_mirror_handler(offline=True)
# The orchestrator strips the omarchy_install block first; extra keys are ignored here.
config_load "${OMARCHY_INSTALL_CONFIG:?}" "${OMARCHY_INSTALL_CREDS:?}"
target=${OMARCHY_TARGET:-${DISK_MOUNTPOINT:-/mnt}}

# arch_install_system
if ! disk_is_pre_mount; then
  # perform_filesystem_operations(): partition + format + encrypt
  fs_perform_filesystem_operations
fi

# open_installer(config, target)
installer_init "$target" "${CFG_KERNELS[@]}"
disk_is_pre_mount || installer_mount_ordered_layout
# sanity_check(offline=True, skip_ntp=True, skip_wkd=True): nothing to wait for

# _install_root_image(ctx): btrfs receive the image and make it @ (Omarchy)

# generate_key_files(): a no-op for Omarchy's layout (only root is encrypted)

[[ $CFG_HAS_MIRROR_CONFIG == true ]] && installer_set_mirrors live

# _mount_offline_package_cache / _mask_mkinitcpio_pacman_hooks (Omarchy)

# install_base_delta(): minimal_installation with the pacstrap reduced to what
# the root image lacks; mkinitcpio deferred to the final Limine UKI build.
INSTALLER_STRAP_ONLY_MISSING=1
installer_minimal_installation --no-mkinitcpio

[[ $CFG_HAS_MIRROR_CONFIG == true ]] && installer_set_mirrors on_target

if [[ $CFG_SWAP_ENABLED == true ]]; then
  # setup_zram_swap(): the package is in the image; Omarchy drops the .conf
  installer_setup_swap "$CFG_SWAP_ALGO"
  rm -f "$INST_TARGET/etc/systemd/zram-generator.conf"
fi

# _configure_limine_boot(ctx): Omarchy installs its own Limine files, using
#   installer_get_boot_partition / installer_get_efi_partition / installer_get_root,
#   get_parent_device_path, PART_PARTN[...], sysinfo_has_uefi and
#   installer_get_kernel_params "$(installer_get_root)" for the cmdline.

((${#USER_NAME[@]})) && installer_create_users

# install_applications(): audio firmware + PipeWire user units
[[ $CFG_HAS_APP_CONFIG == true ]] && applications_install

# tailscale when an auth key was staged: installer_add_additional_packages tailscale

# _unmask_mkinitcpio_pacman_hooks / _unmount_offline_package_cache (Omarchy)

[[ -n $CFG_TIMEZONE ]] && installer_set_timezone "$CFG_TIMEZONE"
[[ $CFG_NTP == true ]] && installer_activate_time_synchronization
[[ -n $CFG_ROOT_ENC_PASSWORD ]] && installer_set_user_password root "$CFG_ROOT_ENC_PASSWORD"

if disk_is_pre_mount; then
  : # _write_pre_mounted_fstab(ctx) (Omarchy)
else
  installer_genfstab
fi

installer_finish
