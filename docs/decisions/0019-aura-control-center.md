# ADR 0019: Initial Aura launcher and Settings app

- **Status:** Accepted for the first control-center milestone
- **Date:** 2026-11-27
- **Scope:** Shared optional Wayland desktop profile on amd64, arm64, and riscv64

## Context

The first Aura desktop profile provides labwc, Waybar, Wofi, PipeWire, and
wlr-randr, but still exposes most interactions as unrelated upstream tools.
The first Aura-specific entrypoint should be keyboard accessible, low
overhead, architecture neutral, and usable without introducing a large GUI
toolkit or a privileged settings daemon.

## Decision

- Use a small `aura-launcher` wrapper around Wofi's XDG desktop-entry search.
  Super+D and the Waybar Aura button open this same fuzzy-search entrypoint.
- Add a keyboard-driven `aura-settings` control center using Wofi menus.
  Super+F10 and the Aura Settings desktop entry open it.
- Provide user-level appearance presets, live display mode/scale/orientation
  controls through wlr-randr, PipeWire default-output volume/mute controls,
  read-only network diagnostics, About information, screen lock, suspend,
  restart, and shutdown.
- Persist only the selected solid wallpaper color in the initial milestone.
  Display mode settings apply to the active session and are not yet persisted.
- Run all user interface actions as the logged-in user. Do not invoke sudo,
  directly rewrite system network configuration, or modify system files from
  the settings app.
- Keep the existing minimal desktop package model; add only the small
  architecture-independent CLI tools required for PipeWire controls and
  Wayland output management.

## Validation

The desktop rootfs installer copies each app and desktop entry, verifies the
executable contract, and checks that the base profile includes pipewire-bin
and wlr-randr. Unit tests validate shell syntax and installation of the app
entrypoints. The existing three-architecture rootfs build and labwc headless
test remain required.

## Limitations

The first Settings app does not provide Wi-Fi management, Bluetooth pairing,
a graphical account manager, persistent per-monitor profiles, or GPU vendor
controls. Network status is read-only because the current system base uses
systemd-networkd and does not yet include an interactive Wi-Fi connection
service. Physical display and audio device behavior still requires testing on
reference hardware.
