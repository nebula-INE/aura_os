# ADR 0003: Initial upstream Linux kernel bring-up baseline

- **Status:** Accepted for initial development
- **Date:** 2026-11-18

## Decision

Pin upstream Linux **6.18.64**, from the 6.18 longterm series, as the initial reproducible x86-64 bring-up baseline. Build the kernel from the official kernel.org release archive. The pin must be reviewed and advanced when upstream security/stable updates are published; it is not a permanent version choice.

Use the upstream `x86_64_defconfig` plus the Aura-maintained fragment at `kernel/configs/x86_64_qemu.fragment`. Build out of tree into `build/kernel`. The first artifact is the kernel `bzImage`, not yet a complete bootable OS image.

## Rationale

- A longterm series provides a more appropriate maintenance baseline than a development release.
- A pinned patch release makes the initial build repeatable.
- Starting with upstream defaults and a small QEMU-focused fragment limits configuration drift.
- A single x86-64 build path lets the project validate source acquisition, configuration, compilation, and artifact retention before adding other architectures.

## Security and release constraints

- Verify upstream detached signatures against independently trusted stable-maintainer keys before promoting source to a release.
- Review kernel security advisories and stable updates; do not automatically float the version.
- Preserve the exact source version, configuration, toolchain, and build logs for release artifacts.
- Do not install the development kernel onto the developer host.
- The current CI job validates compilation only. It does not yet prove bootability or userspace readiness.

## Next milestone

Add a minimal initramfs with an `/init` program, boot the kernel in QEMU `q35`, capture serial output, and assert a machine-detectable Aura boot success marker. Then extend the build matrix to RV64GC and AArch64.
