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
