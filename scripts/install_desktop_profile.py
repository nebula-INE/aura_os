#!/usr/bin/env python3
"""Install the optional Aura OS desktop profile into a target Debian rootfs."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

DESKTOP_PACKAGES = {
    "dbus-user-session", "foot", "fonts-dejavu-core", "fonts-noto-cjk",
    "greetd", "labwc", "lxqt-policykit", "pcmanfm-qt", "pipewire",
    "pipewire-bin", "pipewire-pulse", "polkitd", "swaybg", "swayidle", "swaylock",
    "tuigreet", "waybar", "wlr-randr", "wireplumber", "wofi", "xwayland",
    "xdg-desktop-portal", "xdg-desktop-portal-gtk",
    "xdg-desktop-portal-wlr", "xdg-user-dirs", "xdg-utils",
}

FILE_MAP = {
    "bin/aura-launcher": "/usr/bin/aura-launcher",
    "bin/aura-settings": "/usr/bin/aura-settings",
    "bin/aura-wallpaper": "/usr/lib/aura/desktop/aura-wallpaper",
    "defaults/applications/aura-settings.desktop": "/usr/share/applications/aura-settings.desktop",
    "defaults/greetd/config.toml": "/etc/greetd/config.toml",
    "defaults/wayland-sessions/aura.desktop": "/usr/share/wayland-sessions/aura.desktop",
    "defaults/labwc/rc.xml": "/etc/xdg/labwc/rc.xml",
    "defaults/labwc/autostart": "/etc/xdg/labwc/autostart",
    "defaults/waybar/config": "/etc/xdg/waybar/config",
    "defaults/waybar/style.css": "/etc/xdg/waybar/style.css",
    "defaults/wofi/config": "/etc/xdg/wofi/config",
    "defaults/wofi/style.css": "/etc/xdg/wofi/style.css",
    "defaults/foot/foot.ini": "/etc/xdg/foot/foot.ini",
    "defaults/xdg-desktop-portal/labwc-portals.conf":
        "/usr/share/xdg-desktop-portal/labwc-portals.conf",
    "defaults/xdg-user-dirs.defaults": "/etc/xdg/user-dirs.defaults",
}
EXECUTABLE_DESTINATIONS = {
    "/usr/bin/aura-launcher", "/usr/bin/aura-settings",
    "/usr/lib/aura/desktop/aura-wallpaper",
    "/etc/xdg/labwc/autostart", "/usr/lib/aura/desktop/session",
}


def installed_packages(status_path: Path) -> set[str]:
    result: set[str] = set()
    if not status_path.is_file():
        return result
    for paragraph in status_path.read_text(
        encoding="utf-8", errors="replace"
    ).split("\n\n"):
        fields = {}
        for line in paragraph.splitlines():
            if not line or line[0].isspace() or ":" not in line:
                continue
            key, value = line.split(":", 1)
            fields[key] = value.strip()
        if fields.get("Status") == "install ok installed" and fields.get("Package"):
            result.add(fields["Package"])
    return result


def is_debian_rootfs(root: Path) -> bool:
    release = root / "etc/os-release"
    if not release.is_file():
        return False
    for line in release.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.strip() in ('ID=debian', 'ID="debian"'):
            return True
    return False


def replace_symlink(root: Path, absolute_path: str, target: str) -> None:
    link = root / absolute_path.lstrip("/")
    if link.exists() and link.is_dir() and not link.is_symlink():
        raise ValueError(f"refusing to replace directory with a symlink: {link}")
    link.parent.mkdir(parents=True, exist_ok=True)
    if link.is_symlink() or link.exists():
        link.unlink()
    link.symlink_to(target)


def install_desktop_profile(
    rootfs: str | Path, source_root: str | Path | None = None
) -> dict[str, object]:
    root = Path(rootfs).resolve(strict=True)
    if not root.is_dir():
        raise ValueError(f"root filesystem is not a directory: {root}")
    if root == Path("/"):
        raise ValueError("refusing to install into the host root filesystem")
    if not is_debian_rootfs(root):
        raise ValueError("target must be a Debian root filesystem")

    repository = (
        Path(source_root).resolve(strict=True)
        if source_root is not None
        else Path(__file__).resolve().parents[1]
    )
    source_directory = repository / "system/desktop"
    installed = installed_packages(root / "var/lib/dpkg/status")
    missing = sorted(DESKTOP_PACKAGES - installed)
    if missing:
        raise ValueError("desktop packages are missing: " + ", ".join(missing))

    greetd_unit = root / "usr/lib/systemd/system/greetd.service"
    graphical_target = root / "usr/lib/systemd/system/graphical.target"
    if not greetd_unit.is_file():
        raise ValueError("target rootfs is missing greetd.service")
    if not graphical_target.is_file():
        raise ValueError("target rootfs is missing graphical.target")

    sources = {source_directory / name: destination
               for name, destination in FILE_MAP.items()}
    sources[source_directory / "session"] = "/usr/lib/aura/desktop/session"
    for source in sources:
        if not source.is_file():
            raise ValueError(f"desktop profile source is missing: {source}")

    for source, destination in sources.items():
        target = root / destination.lstrip("/")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        target.chmod(0o755 if destination in EXECUTABLE_DESTINATIONS else 0o644)

    replace_symlink(
        root, "/etc/systemd/system/graphical.target.wants/greetd.service",
        "/usr/lib/systemd/system/greetd.service",
    )
    replace_symlink(
        root, "/etc/systemd/system/default.target",
        "/usr/lib/systemd/system/graphical.target",
    )
    return {
        "status": "ok",
        "profile": "labwc-wayland",
        "packages": sorted(DESKTOP_PACKAGES),
        "default_target": "graphical.target",
        "session": "/usr/share/wayland-sessions/aura.desktop",
        "launcher": "/usr/bin/aura-launcher",
        "settings": "/usr/bin/aura-settings",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rootfs", required=True, type=Path)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        result = install_desktop_profile(args.rootfs)
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(result, sort_keys=True))
    else:
        print("Installed Aura OS optional labwc/Wayland desktop profile.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
