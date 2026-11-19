#!/usr/bin/env bash
set -Eeuo pipefail

TOTAL_WAIT_SECONDS="${AURA_NETWORK_TOTAL_WAIT_SECONDS:-120}"
PROBE_TIMEOUT_SECONDS="${AURA_NETWORK_PROBE_TIMEOUT_SECONDS:-3}"
DEADLINE=$((SECONDS + TOTAL_WAIT_SECONDS))

command -v timeout >/dev/null 2>&1 || { echo "error: timeout command is required" >&2; exit 1; }

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

terminate() {
  local signal="$1"
  trap - EXIT TERM INT
  report "AURA_NETWORK_FAIL: interrupted by $signal"
  /bin/systemctl --no-block poweroff >/dev/null 2>&1 || true
  exit 143
}

trap finish EXIT
trap 'terminate SIGTERM' TERM
trap 'terminate SIGINT' INT

wait_for() {
  local marker="$1"
  shift

  while ((SECONDS < DEADLINE)); do
    local remaining=$((DEADLINE - SECONDS))
    local probe_timeout="$PROBE_TIMEOUT_SECONDS"
    if ((probe_timeout > remaining)); then
      probe_timeout="$remaining"
    fi
    # Functions below apply this per-probe limit to every external command.
    local PROBE_TIMEOUT_SECONDS="$probe_timeout"
    if "$@"; then
      report "$marker"
      return 0
    fi
    sleep 1
  done

  report "AURA_NETWORK_FAIL: deadline reached waiting for ${marker}"
  dump_network_diagnostics
  return 1
}

dump_network_diagnostics() {
  report "AURA_NETWORK_DIAGNOSTICS_BEGIN"

  if command -v ip >/dev/null 2>&1; then
    timeout --foreground "${PROBE_TIMEOUT_SECONDS}s" ip -details -brief link show || true
    timeout --foreground "${PROBE_TIMEOUT_SECONDS}s" ip -brief address show || true
    timeout --foreground "${PROBE_TIMEOUT_SECONDS}s" ip -4 route show table all || true
    timeout --foreground "${PROBE_TIMEOUT_SECONDS}s" ip -6 route show table all || true
  fi

  if command -v networkctl >/dev/null 2>&1; then
    timeout --foreground "${PROBE_TIMEOUT_SECONDS}s" networkctl --no-pager --all list || true
    timeout --foreground "${PROBE_TIMEOUT_SECONDS}s" networkctl --no-pager --all status || true
  fi

  if command -v udevadm >/dev/null 2>&1; then
    timeout --foreground "${PROBE_TIMEOUT_SECONDS}s" udevadm info --query=property --path=/sys/class/net/eth0 || true
  fi

  if command -v journalctl >/dev/null 2>&1; then
    timeout --foreground "${PROBE_TIMEOUT_SECONDS}s" journalctl -b -u systemd-networkd.service --no-pager -n 60 || true
    timeout --foreground "${PROBE_TIMEOUT_SECONDS}s" journalctl -b -k --no-pager -n 100 |
      grep -Ei 'virtio|ethernet|network|link|carrier|firmware|failed|error' || true
  fi

  report "AURA_NETWORK_INTERFACES_BEGIN"
  for interface_path in /sys/class/net/*; do
    [[ -r "$interface_path/type" ]] || continue
    link_type="$(cat "$interface_path/type" 2>/dev/null || true)"
    oper_state="$(cat "$interface_path/operstate" 2>/dev/null || true)"
    printf 'AURA_NETWORK_INTERFACE name=%s type=%s operstate=%s\n' "${interface_path##*/}" "$link_type" "$oper_state"
  done
  report "AURA_NETWORK_INTERFACES_END"
  report "AURA_NETWORK_DIAGNOSTICS_END"
}

udevd_active() {
  timeout --foreground "${PROBE_TIMEOUT_SECONDS}s" systemctl is-active --quiet systemd-udevd.service
}

networkd_active() {
  timeout --foreground "${PROBE_TIMEOUT_SECONDS}s" systemctl is-active --quiet systemd-networkd.service
}

resolved_active() {
  timeout --foreground "${PROBE_TIMEOUT_SECONDS}s" systemctl is-active --quiet systemd-resolved.service
}

timesyncd_active() {
  timeout --foreground "${PROBE_TIMEOUT_SECONDS}s" systemctl is-active --quiet systemd-timesyncd.service
}

has_ethernet_interface() {
  local interface_path
  local link_type

  for interface_path in /sys/class/net/*; do
    [[ -r "$interface_path/type" ]] || continue
    IFS= read -r link_type < "$interface_path/type" || continue
    if [[ "$link_type" == "1" && "${interface_path##*/}" != "lo" ]]; then
      return 0
    fi
  done
  return 1
}

has_global_ipv4() {
  timeout --foreground "${PROBE_TIMEOUT_SECONDS}s" ip -o -4 address show scope global |
    grep -E ' inet ([0-9]{1,3}\.){3}[0-9]{1,3}/' >/dev/null
}

has_default_ipv4_route() {
  timeout --foreground "${PROBE_TIMEOUT_SECONDS}s" ip -4 route show default | grep -q '^default '
}

has_ipv6_link_local() {
  timeout --foreground "${PROBE_TIMEOUT_SECONDS}s" ip -o -6 address show scope link | grep -E ' inet6 fe80:' >/dev/null
}

resolves_debian_mirror() {
  timeout --foreground "${PROBE_TIMEOUT_SECONDS}s" getent ahostsv4 deb.debian.org >/dev/null 2>&1
}

ntp_is_enabled() {
  [[ "$(timeout --foreground "${PROBE_TIMEOUT_SECONDS}s" timedatectl show -p NTP --value)" == "yes" ]]
}

report "AURA_SYSTEMD_ROOTFS_OK"
wait_for "AURA_UDEV_OK" udevd_active
wait_for "AURA_NETWORK_NETWORKD_OK" networkd_active
wait_for "AURA_NETWORK_RESOLVED_OK" resolved_active
wait_for "AURA_NETWORK_TIMESYNCD_OK" timesyncd_active
wait_for "AURA_NETWORK_INTERFACE_OK" has_ethernet_interface
wait_for "AURA_NETWORK_IPV4_OK" has_global_ipv4
wait_for "AURA_NETWORK_DEFAULT_ROUTE_OK" has_default_ipv4_route
wait_for "AURA_NETWORK_IPV6_OK" has_ipv6_link_local
wait_for "AURA_NETWORK_DNS_OK" resolves_debian_mirror
wait_for "AURA_NETWORK_NTP_ENABLED_OK" ntp_is_enabled

report "AURA_ROOTFS_QEMU_PASS"
