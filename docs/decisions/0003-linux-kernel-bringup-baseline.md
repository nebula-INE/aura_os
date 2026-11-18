# ADR 0003: Initial upstream Linux kernel bring-up baseline

- **Status:** Accepted for initial development
- **Date:** 2026-11-18

## Decision

Pin upstream Linux **6.18.64**, from the 6.18 longterm series, as the initial reproducible bring-up baseline. Fetch the exact signed tag `v6.18.64` from Greg Kroah-Hartman's read-only stable-tree GitHub mirror because CI connectivity to git.kernel.org is not dependable. The mirror is only a transport source: independently verify the annotated tag signature and require the pinned stable-maintainer fingerprint `647F28654894E3BD457199BE38DBBDC86092693E` before compiling any source.

The pin must be reviewed and advanced when upstream security/stable updates are published; it is not a permanent version choice.

For x86-64, use upstream `x86_64_defconfig` plus `kernel/configs/x86_64_qemu.fragment`. The first verified reference platform is QEMU q35 with OVMF UEFI, a fixed `qemu64` CPU model, a generated initramfs, and a serial console. The test must execute `/init` and emit `AURA_INIT_OK` and `AURA_QEMU_TEST_PASS`.

Build out of tree into `build/kernel`. The x86-64 kernel image is `arch/x86/boot/bzImage`; it is a kernel payload and initramfs, not yet a complete installable Aura OS image.

## Rationale

- A longterm series provides a more appropriate maintenance baseline than a development release.
- A pinned patch release makes the initial build repeatable.
- Verifying the signed annotated tag protects source integrity independently of the mirror used for transport.
- Starting with upstream defaults and a small QEMU-focused fragment limits configuration drift.
- Establishing a deterministic x86-64 build and first userspace boot validates source acquisition, configuration, compilation, image assembly, firmware handoff, and serial diagnostics before broadening the platform matrix.

## Security and release constraints

- Verify the signed upstream tag against the pinned full stable-maintainer fingerprint before compilation.
- Review kernel security advisories and stable updates; do not automatically float the version.
- Preserve the exact source version, source commit, signing fingerprint, kernel configuration, compiler identity, image checksums, firmware provenance, and boot logs in CI artifacts.
- Do not install the development kernel onto the developer host.
- A successful emulator smoke test is not evidence of physical hardware compatibility or a complete operating system.

## Validation status

The x86-64 OVMF/UEFI first-boot path passed CI run [44301482434](https://github.com/nebula-INE/aura_os/actions/runs/44301482434) on code commit `3dfd2e861ec329a70069f7bc472c20e6f4dd58a3`. Its serial output included both required Aura success markers and the artifact contained the kernel configuration, kernel image, initramfs, checksums, and firmware/boot provenance.

RV64GC and AArch64 cross-build and emulator smoke-test paths are being added separately; their CI results must pass before those emulator profiles are marked verified.

## Next milestone

Pass the RV64GC and AArch64 QEMU build/first-boot jobs, then add firmware-mediated boot validation where appropriate (including AArch64 UEFI) and move from kernel/initramfs payloads to complete bootable disk images.
