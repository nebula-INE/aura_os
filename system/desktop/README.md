# Aura OS optional Wayland desktop profile

This is the first installable desktop-session foundation. It is opt-in so the
small base image remains suitable for rescue, headless use, and early hardware
bring-up.

## Initial stack

- Wayland compositor/window manager: **labwc**
- Panel: **Waybar**
- Application launcher: **Wofi**
- Terminal: **foot**
- File manager: **PCManFM-Qt**
- Login manager / greeter: **greetd / tuigreet**
- X11 application compatibility: **Xwayland**
- Desktop integration: **D-Bus user session and XDG desktop portals**
- Audio session: **PipeWire / WirePlumber**
- Authorization prompts: **polkitd / LXQt PolicyKit agent**

The package set in `packages.txt` is shared by amd64, arm64, and riscv64.
Every package must continue to resolve on all three Debian architectures.

## Build

The default base remains unchanged. To build a separate desktop rootfs:

```sh
sudo env TARGET_ARCH=x86_64 AURA_DESKTOP_PROFILE=1 \
  OUTPUT_DIR="$PWD/build/base-userspace/x86_64/desktop" \
  bash scripts/build-base-rootfs.sh
```

Repeat with `TARGET_ARCH=aarch64` and `TARGET_ARCH=riscv64`.
The desktop build installs the Wayland session, enables greetd for
`graphical.target`, and selects `graphical.target` as its default target.
It does not change the base image or existing serial-only QEMU workflows.

## Initial shortcuts

- `Super+D`: application launcher
- `Super+Enter`: terminal
- `Super+E`: file manager
- `Alt+F4`: close focused window
- `Super+Shift+Q`: exit desktop session

The greeter is terminal-based for this first bring-up. It is not the final
Aura graphical login experience.

## Validation and limitations

CI builds the profile independently for all three architectures, validates
its package and systemd/session contract, and starts the target-architecture
labwc binary with wlroots' headless/pixman backend. That verifies the
compositor can initialize without a physical display; it does not establish
GPU acceleration, physical monitor modes, input, suspend/resume, audio devices,
Wi-Fi, Bluetooth, or touchscreen support.

The 512 MiB idle-memory goal remains an unmeasured stretch target. Measure the
complete desktop session on representative hardware before making performance
claims or enabling this profile by default.


## Aura launcher and Settings

- `Super+D` opens the Aura application search. It uses XDG desktop entries
  and Wofi's fuzzy matching.
- The Waybar **Aura** entry opens the same application search.
- `Super+F10` opens Aura Settings. The Settings app is also available from
  the application search as **Aura Settings**.
- Appearance offers built-in solid-color backgrounds and saves the selection
  in `~/.config/aura/desktop.conf`.
- Display offers connected-output selection, the modes exposed by the active
  compositor, output scaling, and orientation. Changes apply immediately to
  the current session; saved per-monitor profiles are a follow-up.
- Sound provides default-output volume and mute controls through PipeWire.
- Network provides an interactive Wi-Fi setup entry backed by iwd/iwctl, plus
  Wi-Fi device, wired-interface, and DNS status. `iwctl` scans and connects to
  networks and asks for protected-network credentials in its own terminal prompt.
  systemd-networkd remains responsible for DHCP/IP configuration and
  systemd-resolved remains the DNS service.
- Power provides lock, suspend, restart, and shutdown actions with a second
  confirmation for power operations.

The controls use the existing Wofi, labwc, swaybg, PipeWire, and wlr-randr
components rather than adding a large desktop toolkit. The Settings app runs
as the logged-in user and does not invoke sudo or edit system networking
configuration.


Wi-Fi is optional and is installed only with this desktop profile. The profile
ships the regulatory database, but does not bundle proprietary or
device-specific firmware. A Wi-Fi device still needs a supported upstream
Linux driver and any firmware required by that hardware; this must be checked
on physical reference devices. QEMU's headless desktop tests do not validate
radio, antenna, regulatory-domain, or real access-point behavior.
