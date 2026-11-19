#!/usr/bin/env bash
set -Eeuo pipefail

TIMEOUT_SECONDS="${AURA_NETWORK_WAIT_SECONDS:-60}"

report() {
  printf '%s\n' "$1" > /dev/console
}

finish() {
  local status="$?"
  if [[ "$status" -ne 0 ]]; then
    report "AURA_NETWORK_FAIL: smoke script exited with status $status"
  fi
  /bin/systemctl --no-block poweroff >/dev/null 2>&1 || true
}
trap finish EXIT

wait_for() {
  local marker="$1"
  shift

  for ((attempt = 0; attempt < TIMEOUT_SECONDS; attempt++)); do
    if "$@"; then
      report "$marker"
      return 0
    fi
    sleep 1
  done

  report "AURA_NETWORK_FAIL: ${marker}"
  return 1
}

networkd_active() {
  systemctl is-active --quiet systemd-networkd.service
}

resolved_active() {
  systemctl is-active --quiet systemd-resolved.service
}

timesyncd_active() {
  systemctl is-active --quiet systemd-timesyncd.service
}

has_global_ipv4() {
  ip -o -4 address show scope global | grep -qE ' inet [0-9]+\.'
}

has_default_ipv4_route() {
  ip -4 route show default | grep -q '^default '
}

has_ipv6_link_local() {
  ip -o -6 address show scope link | grep -qE ' inet6 fe80:'
}

resolves_debian_mirror() {
  getent ahostsv4 deb.debian.org >/dev/null 2>&1
}

ntp_is_enabled() {
  [[ "$(timedatectl show -p NTP --value)" == "yes" ]]
}

report "AURA_SYSTEMD_ROOTFS_OK"
wait_for "AURA_NETWORK_NETWORKD_OK" networkd_active
wait_for "AURA_NETWORK_RESOLVED_OK" resolved_active
wait_for "AURA_NETWORK_TIMESYNCD_OK" timesyncd_active
wait_for "AURA_NETWORK_IPV4_OK" has_global_ipv4
wait_for "AURA_NETWORK_DEFAULT_ROUTE_OK" has_default_ipv4_route
wait_for "AURA_NETWORK_IPV6_OK" has_ipv6_link_local
wait_for "AURA_NETWORK_DNS_OK" resolves_debian_mirror
wait_for "AURA_NETWORK_NTP_ENABLED_OK" ntp_is_enabled

report "AURA_ROOTFS_QEMU_PASS"

