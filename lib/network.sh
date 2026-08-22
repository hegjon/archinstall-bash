# shellcheck shell=bash
# Port of lib/network/network_handler.py install_network_config() and
# Installer.copy_iso_network_config().

# install_network_config(network_config.type)
network_install_config() {
  local type=${1:-$CFG_NETWORK_TYPE}
  case $type in
    iso) installer_copy_iso_network_config enable_services ;;
    nm|nm_iwd)
      local -a packages=(networkmanager)
      if [[ $type == nm ]]; then packages+=(wpa_supplicant); else packages+=(iwd); fi
      installer_add_additional_packages "${packages[@]}"
      installer_enable_service NetworkManager.service
      if [[ $type == nm_iwd ]]; then
        mkdir -p "$INST_TARGET/etc/NetworkManager/conf.d"
        printf '[device]\nwifi.backend=iwd\n' >"$INST_TARGET/etc/NetworkManager/conf.d/wifi_backend.conf"
        installer_disable_service iwd.service
      fi
      ;;
    iwd)
      installer_add_additional_packages iwd
      mkdir -p "$INST_TARGET/etc/iwd" "$INST_TARGET/etc/systemd/network"
      printf '[General]\nEnableNetworkConfiguration=true\n\n[Network]\nNameResolvingService=systemd\n' >"$INST_TARGET/etc/iwd/main.conf"
      printf '[Match]\nType=ether\nKind=!*\n\n[Network]\nDHCP=yes\n' >"$INST_TARGET/etc/systemd/network/20-wired.network"
      installer_systemd_resolved_stub_mode
      installer_enable_service iwd.service systemd-networkd.service systemd-resolved.service
      ;;
    manual) die 'network_config type "manual" is not supported by this port' ;;
    '') ;;
    *) die "unknown network_config type: $type" ;;
  esac
}

# Installer.copy_iso_network_config(enable_services)
installer_copy_iso_network_config() {
  local enable_services=${1:-} f
  if compgen -G '/var/lib/iwd/*.psk' >/dev/null; then
    mkdir -p "$INST_TARGET/var/lib/iwd"
    for f in /var/lib/iwd/*.psk; do
      cp -p "$f" "$INST_TARGET/var/lib/iwd/"
    done
    if [[ -n $enable_services ]]; then
      pacman_strap iwd
      installer_enable_service iwd
    fi
  fi

  installer_systemd_resolved_stub_mode

  if compgen -G '/etc/systemd/network/*' >/dev/null; then
    mkdir -p "$INST_TARGET/etc/systemd/network"
    for f in /etc/systemd/network/*; do
      cp -p "$f" "$INST_TARGET/etc/systemd/network/"
    done
    [[ -n $enable_services ]] && installer_enable_service systemd-networkd systemd-resolved
  fi
  return 0
}
