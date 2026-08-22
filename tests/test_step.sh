#!/usr/bin/env bash
# The archinstall-step runner: state round-trips between processes and the
# query output the Omarchy orchestrator consumes. Unprivileged: load-config
# is exercised through the library with stubbed device probes, the runner's
# query/kernel-params commands read the saved state.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export ARCHINSTALL_LOG_DIR="$work/log"
# shellcheck disable=SC1091
source "$here/../lib/archinstall.sh"

failures=0
assert_eq() {
  if [[ $2 == "$3" ]]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$3" "$2"; failures=$((failures + 1)); fi
}

disk_size_bytes() { printf '%s' $((10 * 1024 * 1024 * 1024)); }
disk_sector_size() { printf '512'; }
sysinfo_has_uefi() { return 0; }
locale_get_kb_layout() { :; }

config_load "$here/../examples/omarchy-full-disk.json" "$here/../examples/omarchy-credentials.json"
installer_init /mnt "${CFG_KERNELS[@]}"
# What perform-filesystem-operations would have recorded.
PART_DEVPATH=(/dev/loop9p1 /dev/loop9p2)
PART_PARTN=(1 2)
PART_PARTUUID=(aaaa-1 bbbb-2)
PART_UUID=(AAAA-1111 cccc-3)
INST_ZRAM_ENABLED=1
state="$work/state.sh"
state_save "$state"

assert_eq 'state file mode' "$(stat -c %a "$state")" 600
q=$("$here/../bin/archinstall-step" --state "$state" query)
assert_eq 'query: flags' "$(jq -r '[.pre_mount, .encrypted, .bootloader, .bootloader_removable, .swap, .zram_enabled, .mirror_config, .app_config, .ntp, .root_password] | map(tostring) | join(",")' <<<"$q")" \
  'false,true,limine,false,true,true,true,true,true,true'
assert_eq 'query: identity' "$(jq -r '[.target, .hostname, .timezone, .kb_layout, (.kernels | join(" ")), (.users | join(" "))] | join("|")' <<<"$q")" \
  '/mnt|omarchy|Europe/Oslo|no|linux|jonny'
assert_eq 'query: root partition' "$(jq -r '.root | [.dev_path, .fs_type, .partuuid, .mapper_name, (.btrfs_subvols | map(.name) | join(" "))] | join("|")' <<<"$q")" \
  '/dev/loop9p2|btrfs|bbbb-2|root|@ @home @log @pkg'
assert_eq 'query: efi partition' "$(jq -r '.efi | [.dev_path, .mountpoint, (.partn | tostring), .fs_type] | join("|")' <<<"$q")" '/dev/loop9p1|/boot|1|fat32'
assert_eq 'query: boot == efi' "$(jq -r '.boot.dev_path' <<<"$q")" /dev/loop9p1
assert_eq 'query: kernel params' "$(jq -r '.kernel_params' <<<"$q")" \
  'cryptdevice=PARTUUID=bbbb-2:root root=/dev/mapper/root zswap.enabled=0 rootflags=subvol=@ rw rootfstype=btrfs'
assert_eq 'kernel-params command' "$("$here/../bin/archinstall-step" --state "$state" kernel-params)" "$(jq -r '.kernel_params' <<<"$q")"
assert_eq 'has-uefi is stateless' "$("$here/../bin/archinstall-step" has-uefi; echo "rc=$?")" "rc=$([[ -d /sys/firmware/efi ]] && echo 0 || echo 1)"
out=$("$here/../bin/archinstall-step" --state "$work/nope" query 2>&1)
assert_eq 'missing state refused' "$out" "error: state file $work/nope missing; run load-config first"
out=$("$here/../bin/archinstall-step" dry-run --config "$here/../examples/omarchy-pre-mounted.json" | head -n1)
assert_eq 'dry-run stateless' "$out" 'Hostname:   omarchy'

# A second process must see exactly the state the first saved.
(
  # shellcheck disable=SC1090
  source "$state"
  assert_eq 'state round-trip: arrays' "${PART_DEVPATH[*]}|${ENC_PARTS[*]}|${INST_HOOKS[*]:0:1}" '/dev/loop9p1 /dev/loop9p2|1|base'
  assert_eq 'state round-trip: assoc' "${INST_HELPER_FLAGS[base]}" false
  assert_eq 'state round-trip: config json' "$(jq -r .hostname <<<"$CONFIG_JSON")" omarchy
  exit $failures
) || failures=$((failures + $?))

# The streaming runner under the step runner's own shell options (-euo pipefail):
# output reaches stdout and the log, the command's status is preserved, and
# nothing references $! (bash does not set it for process substitutions).
out=$(bash -euo pipefail -c '
  source "$1/lib/archinstall.sh"
  sys_cmd_peek sh -c "echo streamed; exit 3" && echo "rc=0" || echo "rc=$?"
  sys_cmd_peek echo fine && echo "rc=0"
' _ "$here/.." 2>&1)
assert_eq 'sys_cmd_peek under set -euo pipefail' "$(tr '\n' '|' <<<"$out")" 'streamed|rc=3|fine|rc=0|'
assert_eq 'sys_cmd_peek logs the output' "$(grep -cx 'streamed' "$ARCHINSTALL_LOG_DIR/install.log")" 1

if ((failures)); then printf '%d failure(s)\n' "$failures"; exit 1; fi
printf 'all step tests passed\n'
