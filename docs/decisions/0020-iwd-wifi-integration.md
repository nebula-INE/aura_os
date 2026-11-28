# ADR 0020: Optional desktop Wi-Fi integration with iwd

- Status: Accepted
- Date: 2026-11-28

## Context

Aura OS keeps its small Debian base focused on wired networking through
systemd-networkd and DNS through systemd-resolved. The optional Wayland desktop
needs a Wi-Fi connection workflow without adding a second general-purpose
network manager or changing the headless/rescue base.

## Decision

- Add Debian's \`iwd\` and \`wireless-regdb\` packages only to the optional
  desktop profile. Enable \`iwd.service\` for the installed desktop system.
- Use iwd for wireless scanning, authentication, and association.
- Set \`EnableNetworkConfiguration=false\` so iwd does not compete for IP or
  DNS configuration.
- Add a systemd-networkd \`Type=wlan\`, \`WLANInterfaceType=station\` profile
  for DHCP, IPv6 router advertisements, and IPv6 link-local addressing.
- Keep systemd-resolved as the system DNS service.
- Expose Wi-Fi setup in Aura Settings by opening the upstream interactive
  \`iwctl\` client in foot. Protected-network credentials are entered in
  iwctl's own prompt rather than Aura-generated command-line arguments.
- Do not add NetworkManager, a privileged helper, or a new root-owned settings
  API for this initial iteration.

## Security and limitations

The desktop Settings process runs as the logged-in user. iwd's system service
performs privileged radio operations through its D-Bus interface. The Aura
shell does not request sudo, write Wi-Fi credentials, or edit global network
configuration.

The profile includes the regulatory database, but does not bundle
device-specific or proprietary firmware. A usable wireless device still
requires a supported Linux driver and any firmware needed by the hardware.
QEMU's headless compositor test validates packaging and configuration only;
it does not validate physical radios, antennas, access points, roaming,
suspend/resume, or regulatory behavior.

Graphical password entry, a native Wofi scan-result picker, enterprise
authentication, hotspot/AP mode, and per-device power controls remain future
work. Users can use iwctl's interactive help and commands for scan, connect,
disconnect, and saved-network operations.
