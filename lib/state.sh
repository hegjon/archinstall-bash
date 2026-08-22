# shellcheck shell=bash
# Persisting the parsed configuration and installer state between processes,
# so a driver in another language (Omarchy's Python orchestrator) can run an
# install as a sequence of `archinstall-step` invocations. The file is bash:
# `declare -p` output, sourced back at the top level of the next process.

STATE_VAR_PATTERN='^(CONFIG_JSON|CFG_|USER_|DISK_|DEV_|PART_|ENC_|INST_|PACMAN_SYNCED$|PACMAN_OPTIONAL_REPOS$)'

state_vars() {
  compgen -v | grep -E "$STATE_VAR_PATTERN"
}

# state_save <file>: written 0600 (it carries the encryption passphrase).
state_save() {
  local file=$1 tmp
  mkdir -p "${file%/*}"
  tmp=$(umask 077 && mktemp "$file.XXXXXX")
  # shellcheck disable=SC2046
  declare -p $(state_vars) >"$tmp"
  mv "$tmp" "$file"
}
