# archinstall-bash

A bash port of [archinstall](https://github.com/archlinux/archinstall)
(tracked at upstream commit `ede2bd3`, 2026-08-20), reduced to what installing
[Omarchy](https://omarchy.org) needs: the non-interactive guided install driven
by `--config` / `--creds` JSON, with the disk, encryption, pacstrap, user,
locale, swap, network, audio and Limine steps that Omarchy's ISO orchestrator
(`omarchy-iso`, `orchestrator/archinstall_adapter.py`) calls into.

There is no menu: the configuration is supplied by Omarchy's configurator (or
any archinstall `user_configuration.json` / `user_credentials.json`).

```
bin/archinstall --config user_configuration.json --creds user_credentials.json --silent --offline --skip-ntp --skip-wkd
bin/archinstall --config user_configuration.json --dry-run      # parse + validate only, unprivileged
```

or, as a library:

```bash
source /path/to/archinstall-bash/lib/archinstall.sh
config_load user_configuration.json user_credentials.json
fs_perform_filesystem_operations
installer_init /mnt "${CFG_KERNELS[@]}"
installer_mount_ordered_layout
...
```

`examples/omarchy-install-sequence.sh` is the orchestrator's
`arch_install_system` phase written against this library.

## Requirements

bash ≥ 5, jq, gawk, util-linux (sfdisk, lsblk, wipefs, findmnt, mount,
blockdev), coreutils, cryptsetup, arch-install-scripts (pacstrap, genfstab,
arch-chroot), systemd (udevadm, systemctl, localectl, systemd-firstboot),
dosfstools / btrfs-progs / e2fsprogs for the filesystems in the layout,
efibootmgr and limine for the bootloader, `mkpasswd` (whois) or openssl for
hashing plaintext `!password` entries. All of these are on the Arch ISO and
the Omarchy ISO.

## What is ported

| archinstall | here |
|---|---|
| `lib/args.py` `ArchConfigHandler` / `ArchConfig.from_config` | `lib/config.sh` `config_load`, `CFG_*`, `USER_*` |
| `lib/models/device.py` `DiskLayoutConfiguration.parse_arg`, `PartitionModification`, `DiskEncryption` | `config_parse_disk`, `PART_*`/`DEV_*`/`ENC_*` arrays, `part_*` helpers |
| `DeviceHandler.detect_pre_mounted_mods` | `disk_detect_pre_mounted_mods` |
| `lib/disk/filesystem.py` `FilesystemHandler.perform_filesystem_operations` | `fs_perform_filesystem_operations` |
| `DeviceHandler.partition` / `wipe_dev` / `format` / `format_encrypted` / `create_btrfs_volumes` / `umount_all_existing` | `fs_partition_device` (sfdisk instead of pyparted), `fs_wipe_dev`, `fs_format`, `fs_format_encrypted`, `fs_create_btrfs_volumes`, `fs_umount_all_existing` |
| `lib/disk/luks.py` `Luks2` | `lib/luks.sh` `luks_format`, `luks_unlock`, `luks_lock`, `luks_create_keyfile`, `luks_create_crypttab_entry`, `luks_erase` |
| `lib/disk/utils.py` | `lib/disk.sh` `disk_mount`, `disk_umount_dev`, `udev_sync`, `get_parent_device_path`, `get_unique_path_for_device` |
| `lib/hardware.py` `SysInfo` | `lib/hardware.sh` `sysinfo_has_uefi`, `sysinfo_is_vm`, `installer_get_microcode`, `sysinfo_requires_sof_fw`, `sysinfo_requires_alsa_fw` |
| `Installer.mount_ordered_layout` | `installer_mount_ordered_layout` |
| `Installer.sanity_check` | `installer_sanity_check offline skip_ntp skip_wkd` |
| `Installer.generate_key_files` | `installer_generate_key_files` |
| `Installer.set_mirrors` + `MirrorConfiguration` rendering | `installer_set_mirrors live|on_target` (`lib/mirrors.sh`) |
| `Installer.minimal_installation` | `installer_minimal_installation [--no-mkinitcpio] [--no-hostname] [--no-locale]` |
| `Installer._prepare_fs_type` / `_prepare_encrypt` / `_get_microcode` | `installer_prepare_fs_type`, `installer_prepare_encrypt`, `installer_get_microcode` |
| `PacmanConfig.enable/apply/persist/configure`, `Pacman.strap` | `lib/pacman.sh` `pacman_config_*`, `pacman_strap` |
| `Installer.set_vconsole` / `set_hostname` / `set_locale` / `set_keyboard_language` | `lib/locale.sh` + `installer_set_hostname` |
| `Installer.setup_swap` | `installer_setup_swap [algo]` |
| `Installer.setup_btrfs_snapshot` (snapper/timeshift) | `installer_setup_btrfs_snapshot` |
| `Installer.create_users` / `set_user_password` / `enable_sudo` | `installer_create_users`, `installer_create_user`, `installer_set_user_password`, `installer_enable_sudo` |
| `Installer.add_additional_packages` / `enable_service` / `disable_service` / `set_timezone` / `activate_time_synchronization` / `enable_periodic_trim` / `genfstab` / `mkinitcpio` | same names with the `installer_` prefix |
| `Installer._get_kernel_params` / `_get_root` / `_get_boot_partition` / `_get_efi_partition` | `installer_get_kernel_params root [id_root] [partuuid]`, `installer_get_root`, `installer_get_boot_partition`, `installer_get_efi_partition` (return partition indexes) |
| `Installer.add_bootloader` → Limine, `_config_uki`, `_install_plymouth` | `lib/bootloader.sh` |
| `install_network_config` (iso / nm / nm_iwd / iwd) | `lib/network.sh` `network_install_config` |
| `ApplicationHandler.install_applications` (audio, bluetooth) | `lib/applications.sh` `applications_install` |
| `scripts/guided.py` `perform_installation` / `main` | `lib/guided.sh` `guided_perform_installation`, `guided_main`; `bin/archinstall` |
| `Installer.__exit__` post-install check | `installer_finish` |

Omarchy-specific conveniences that upstream lacks:

* `INSTALLER_STRAP_ONLY_MISSING=1` makes `pacman_strap` install only packages
  the target does not already hold (the adapter's `install_base_delta`).
* `target_has_package <target> <name>` (the adapter's helper of the same name).
* `installer_set_keyboard_language` writes the keymap with `systemd-firstboot`
  instead of booting the target in a container (what `keyboard.py` does).

## Deliberate differences

* Partitioning uses `sfdisk` rather than pyparted. Partition type GUIDs are set
  the way parted flags + the Linux root GUID would set them; sizes are taken
  exactly from the configuration (which must be 1 MiB aligned, as upstream
  validates). A kernel that fails to re-read the table straight away is asked
  again after `udevadm settle` instead of aborting.
* A `disk_encryption` block without an `encryption_password` is an error.
  Upstream silently installs unencrypted in that case.
* LUKS passphrases are passed as `--key-file -` (byte for byte, no newline),
  equivalent to upstream feeding the plaintext on stdin.
* Plaintext `!password` / `!root-password` entries are hashed with
  `mkpasswd -m yescrypt` (sha512-crypt via openssl as fallback).
* Mirror regions are served from the live `/etc/pacman.d/mirrorlist` (upstream's
  offline behaviour); no mirror-status download or speed sorting.

## Not ported

The interactive TUI, profiles, LVM layouts, FIDO2/HSM encryption, encrypted
credential files, systemd-boot / GRUB / efistub / rEFInd, manual network
configuration, the power-management / print / firewall / fonts application
installers, plugins, and the `--creds-decryption-key` flow. Using any of these
in a configuration fails with a clear message (or a warning where upstream
would merely skip).

## Tests

```
tests/test_config.sh              # parser, layout validation, kernel params (unprivileged)
sudo tests/test_disk_loop.sh      # partition + LUKS + btrfs + mount on a loop device
```
