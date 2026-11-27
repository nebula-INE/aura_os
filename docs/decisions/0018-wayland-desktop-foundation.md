# ADR 0018: Initial optional Wayland desktop foundation

- **Status:** Accepted for the first desktop bring-up milestone; real-hardware validation pending
- **Date:** 2026-11-27
- **Scope:** An installable desktop profile for x86-64, AArch64, and RV64GC

## Context

Aura OS has a tested Debian 13 base, first-boot administrator setup,
multi-architecture UEFI installation, and a versioned kernel lifecycle. It
does not yet ship a graphical session. The desktop must remain modular so the
headless/rescue base stays small, while the same session components can be
resolved by Debian on all three first-class architectures.

The 512 MiB idle-memory target is a stretch goal, not a measured result. The
desktop selection must be measured on comparable reference hardware before
the project makes performance claims.

## Decision

Use an optional, architecture-neutral Debian desktop profile for the first
graphical bring-up:

| Role | Initial component |
|---|---|
| Wayland compositor/window manager | labwc |
| Panel/status area | Waybar |
| Application launcher | Wofi |
| Terminal | foot |
| File manager | PCManFM-Qt |
| Login manager / greeter | greetd / tuigreet |
| X11 compatibility | Xwayland |
| PolicyKit authentication UI | polkitd / LXQt PolicyKit agent |
| Desktop portal | xdg-desktop-portal with GTK and wlroots backends |
| Audio session | PipeWire / WirePlumber |

The session uses systemd-logind and a D-Bus user session. It does not add a
second network manager; systemd-networkd remains responsible for wired
networking. Wi-Fi and Bluetooth enablement are separate hardware work.

The desktop profile is opt-in through `AURA_DESKTOP_PROFILE=1`. The desktop-
free base image remains unchanged for rescue, server/headless use, and the
existing serial-only QEMU tests. A desktop-profile build enables greetd under
`graphical.target` and selects `graphical.target` as the profile default.

The initial greeter is terminal-based. A graphical greeter can be evaluated
after display, GPU, and input compatibility is demonstrated on reference
hardware.

## User interaction baseline

- Super+D opens the application launcher.
- Super+Enter opens foot.
- Super+E opens PCManFM-Qt.
- Alt+F4 closes the focused window.
- Super+Shift+Q exits the graphical session.

The panel exposes time, network state, CPU, memory, battery (when present), and
the system tray. Application launching follows XDG desktop entries. Xwayland
is included for applications that still require X11.

## Security and lifecycle

- The normal first-boot wizard still creates the first sudo administrator;
  the root account remains password-locked.
- greetd authenticates through the existing PAM/systemd stack; the session is
  not launched as root.
- PolicyKit prompts use a per-user authentication agent.
- The desktop profile does not change the kernel update, signed installer
  media, backup, or recovery design.
- CI starts labwc as an unprivileged account inside the target rootfs using
  wlroots' headless/pixman backend.

## Validation requirements

CI builds the optional rootfs independently for amd64, arm64, and riscv64,
validates the package and session contract, and starts labwc until its
Wayland socket appears under the target architecture's QEMU user-mode binfmt
handler.

This validates package resolution and compositor initialization without a
physical display. It does not validate GPU acceleration, real monitors,
modesetting, input devices, suspend/resume, audio hardware, Wi-Fi, Bluetooth,
touchscreens, or the final Aura desktop design.

Before enabling the profile by default or making performance claims, validate
a documented physical reference device per architecture, measure idle
memory/CPU and interactive latency, and test recovery after a failed
graphical-session startup.

## Alternatives considered

- A full GNOME/KDE desktop: feature-rich but too large for the first
  low-overhead bring-up and adds more services and hardware integration at once.
- Xfce: mature and practical, but its primary session is X11-oriented; it can
  be evaluated as a compatibility fallback if Wayland hardware support blocks
  a target.
- Sway: a strong Wayland option, but tiling-first interaction is not the
  desired default stacking desktop model.
- A custom compositor/shell: deferred until a graphical baseline is proven.

## Revisit when

Revisit if a required reference GPU/input configuration is unsupported, if
headless/physical tests expose instability, or if repeated memory/latency
measurements show a better maintained stack.
