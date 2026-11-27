#!/usr/bin/env python3
"""Start target-architecture labwc with wlroots' headless backend."""

from __future__ import annotations

import argparse
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def run_smoke(rootfs: Path, timeout: float = 25.0) -> None:
    root = rootfs.resolve(strict=True)
    if not root.is_dir() or root == Path("/"):
        raise ValueError("rootfs must be a non-host root filesystem directory")
    labwc = root / "usr/bin/labwc"
    if not labwc.is_file() or not os.access(labwc, os.X_OK):
        raise ValueError("desktop rootfs is missing executable /usr/bin/labwc")
    if os.geteuid() != 0:
        raise PermissionError("run the headless desktop smoke test as root")
    chroot = shutil.which("chroot")
    if not chroot:
        raise RuntimeError("host chroot utility is missing")

    # The test does not boot systemd, so tmpfiles never mounts or creates the
    # normal /dev/shm runtime directory. wlroots needs it to allocate keyboard
    # keymap shared-memory files even with the headless/pixman backend.
    dev = root / "dev"
    if dev.is_symlink():
        raise ValueError(f"refusing to use symlink device directory: {dev}")
    dev.mkdir(exist_ok=True)
    if not dev.is_dir():
        raise ValueError(f"rootfs device path is not a directory: {dev}")
    shm = dev / "shm"
    if shm.is_symlink():
        raise ValueError(f"refusing to use symlink shared-memory path: {shm}")
    shm.mkdir(mode=0o1777, exist_ok=True)
    if not shm.is_dir():
        raise ValueError(f"rootfs shared-memory path is not a directory: {shm}")
    os.chmod(shm, 0o1777)

    runtime = root / "run/user/65534"
    if runtime.is_symlink():
        raise ValueError(f"refusing to use symlink runtime path: {runtime}")
    if runtime.exists():
        if not runtime.is_dir() or any(runtime.iterdir()):
            raise ValueError(f"desktop test runtime directory is not empty: {runtime}")
    else:
        runtime.mkdir(parents=True, mode=0o700)
    os.chown(runtime, 65534, 65534)
    os.chmod(runtime, 0o700)

    fd, name = tempfile.mkstemp(prefix="aura-labwc-", suffix=".log")
    os.close(fd)
    log_path = Path(name)
    env = os.environ.copy()
    env.update({
        "HOME": "/tmp",
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "XDG_RUNTIME_DIR": "/run/user/65534",
        "XDG_CONFIG_HOME": "/tmp/.config",
        "XDG_CACHE_HOME": "/tmp/.cache",
        "XDG_CURRENT_DESKTOP": "Aura:labwc",
        "XDG_SESSION_TYPE": "wayland",
        "WLR_BACKENDS": "headless",
        "LIBSEAT_BACKEND": "noop",
        "WLR_RENDERER": "pixman",
        "WLR_HEADLESS_OUTPUTS": "1",
        "WLR_LIBINPUT_NO_DEVICES": "1",
        "WAYLAND_DISPLAY": "wayland-0",
        "LC_ALL": "C",
    })
    socket_path = runtime / "wayland-0"
    process = None
    try:
        with log_path.open("wb") as log:
            process = subprocess.Popen(
                [chroot, "--userspec=65534:65534", str(root),
                 "/usr/bin/labwc", "--config-dir", "/etc/xdg/labwc"],
                env=env, stdout=log, stderr=subprocess.STDOUT,
            )
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if socket_path.exists() and socket_path.is_socket():
                    break
                status = process.poll()
                if status is not None:
                    raise RuntimeError(
                        f"labwc exited before creating its Wayland socket (status {status})"
                    )
                time.sleep(0.1)
            else:
                raise TimeoutError(f"labwc did not create its Wayland socket within {timeout}s")
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
            status = process.wait(timeout=10)
            if status != 0:
                raise RuntimeError(f"labwc exited with status {status}")
    except Exception as exc:
        try:
            details = log_path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            details = ""
        raise RuntimeError(f"{exc}\nlabwc log:\n{details}") from exc
    finally:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        shutil.rmtree(runtime, ignore_errors=True)
        log_path.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rootfs", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=25.0)
    args = parser.parse_args()
    try:
        run_smoke(args.rootfs, args.timeout)
    except (OSError, RuntimeError, ValueError, PermissionError, TimeoutError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print("Aura Wayland headless compositor smoke test passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
