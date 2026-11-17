# Aura OS — Development Plan

> Status: Planning
> Project: `aura_os`
> Last updated: 2026-11-17

## 1. Vision

Aura OS is a from-scratch, general-purpose desktop operating system. It should grow into a coherent, maintainable platform rather than a collection of unrelated experiments.

The first objective is a reliably booting and debuggable system. Desktop usability, application compatibility, and polished user experience follow on top of a stable kernel and userspace foundation.

## 2. Product and platform decisions

### Initial architecture

- **Primary target: x86-64.** The initial supported hardware and development target is x86-64.
- **Boot: UEFI.** Prefer a modern UEFI boot path; keep bootloader responsibilities small and explicit.
- **Kernel: own implementation.** Build Aura OS kernel functionality incrementally, keeping hardware-dependent code isolated from architecture-independent subsystems.
- **RISC-V: future architecture.** RV64GC is a possible future port and potential in-house hardware target. Do not let this delay the first x86-64 release.
- **ARM: not an initial priority.** Revisit only when there is a concrete product or hardware reason.

### Product principles

1. A usable, predictable desktop is more important than feature count.
2. Reliability, security, and recoverability are foundational requirements.
3. Keep interfaces between boot, kernel, drivers, services, and applications explicit.
4. Prefer small milestones that can be built, booted, tested, and debugged independently.
5. Avoid premature multi-architecture abstractions; preserve clean boundaries so a later port remains possible.
6. Document design decisions and known limitations as they are made.

## 3. Scope and non-goals

### Initial scope

- Bootable x86-64 image under an emulator.
- Basic kernel initialization, diagnostics, and panic handling.
- Physical and virtual memory management.
- Interrupt and timer handling.
- Basic scheduling and process isolation.
- Minimal storage and filesystem access.
- Kernel-to-userspace interface and initial userland.
- Basic input, display, and a minimal graphical desktop in a later milestone.
- Repeatable build, test, and image-generation workflow.

### Explicit non-goals for the first milestone

- Supporting every PC and peripheral.
- ARM or RISC-V parity.
- Full POSIX or Windows compatibility.
- A production-ready application ecosystem.
- Advanced GPU acceleration, networking, audio, or power management before the core platform is stable.

## 4. Proposed system architecture

Keep the implementation divided into layers with documented contracts:

1. **Boot layer** — UEFI handoff, memory map acquisition, boot configuration, and kernel loading.
2. **Architecture layer** — x86-64 CPU setup, page tables, descriptor tables, interrupt entry, and low-level context switching.
3. **Kernel core** — memory allocators, synchronization primitives, scheduler, timers, and kernel diagnostics.
4. **Drivers** — begin with emulator-friendly devices; isolate device-specific code behind stable interfaces.
5. **Storage layer** — block-device abstraction, an initial simple filesystem, and mount/interface boundaries.
6. **Process and syscall layer** — user/kernel boundary, process lifecycle, permissions, and system calls.
7. **Userland** — init/service manager, system utilities, libraries, and application launch.
8. **Desktop layer** — display server/compositor, window management, input routing, settings, and shell.
9. **Developer tooling** — cross-build environment, image builder, automated tests, emulator launch scripts, and debug symbols.

These are logical boundaries, not a requirement to implement every layer immediately.

## 5. Development phases

### Phase 0 — Repository and build foundation

- [ ] Define the language/toolchain and pin supported versions.
- [ ] Establish repository layout and coding conventions.
- [ ] Add a reproducible x86-64 build.
- [ ] Generate a bootable disk image.
- [ ] Add an emulator launch configuration (QEMU is the initial reference environment).
- [ ] Document how to build, boot, debug, and clean the project.
- [ ] Add CI for formatting, static checks, build, and basic tests.

**Exit criteria:** A clean checkout can produce an image and boot it in the documented emulator environment.

### Phase 1 — Boot and kernel diagnostics

- [ ] Implement UEFI boot and a documented boot handoff structure.
- [ ] Enter the kernel in a known CPU state.
- [ ] Initialize serial/debug output and an early panic path.
- [ ] Read and validate the firmware memory map.
- [ ] Add a minimal kernel self-test mechanism.

**Exit criteria:** The kernel boots repeatedly, reports its environment, and fails in a diagnosable way.

### Phase 2 — Core kernel

- [ ] Physical page/frame allocator.
- [ ] Kernel virtual memory and page-table management.
- [ ] Interrupt descriptor table and exception handlers.
- [ ] Timer source and monotonic clock.
- [ ] Basic heap allocator.
- [ ] Synchronization primitives.
- [ ] Preemptive or cooperative scheduler (choose and document the initial model).
- [ ] Kernel-level tests for memory and scheduling invariants.

**Exit criteria:** Multiple kernel tasks can run reliably, and memory/exception failures are diagnosable.

### Phase 3 — User mode and storage

- [ ] Define the syscall ABI and user/kernel transition.
- [ ] Load and start a minimal user process.
- [ ] Define process, thread, handle, and permission models.
- [ ] Add a block-device interface and emulator-backed storage driver.
- [ ] Implement an initial filesystem and basic file operations.
- [ ] Add process termination and fault isolation.

**Exit criteria:** A user process can start, use basic syscalls, read/write files, and fail without crashing the whole system under expected fault conditions.

### Phase 4 — Usable command environment

- [ ] Start an init process and essential system services.
- [ ] Provide a basic shell and core utilities.
- [ ] Add configuration and logging conventions.
- [ ] Add a repeatable installation or image deployment workflow.
- [ ] Document recovery and troubleshooting.

**Exit criteria:** A user can boot Aura OS and perform basic tasks from a command environment.

### Phase 5 — Desktop foundation

- [ ] Select and document the initial display model.
- [ ] Add framebuffer/display output and input-device support.
- [ ] Define window, surface, and input-routing interfaces.
- [ ] Implement a minimal compositor/window manager.
- [ ] Add a basic shell/desktop and settings surface.
- [ ] Test keyboard-only operation and common display sizes.

**Exit criteria:** A user can log in or enter the desktop, launch a basic application, interact with windows, and shut down/reboot cleanly.

### Phase 6 — Platform hardening

- [ ] Review privilege boundaries and default permissions.
- [ ] Add robust error handling and recovery paths.
- [ ] Expand hardware coverage based on actual target devices.
- [ ] Add performance and resource-usage benchmarks.
- [ ] Establish compatibility and regression test suites.
- [ ] Define release, update, and rollback strategy.

**Exit criteria:** A documented x86-64 preview can be installed or run by testers with known limitations and reproducible diagnostics.

### Phase 7 — Future architecture expansion

- [ ] Reassess RISC-V RV64GC readiness against the architecture boundaries.
- [ ] Separate architecture-specific boot and CPU code from common kernel code.
- [ ] Port only after x86-64 has stable kernel and userspace contracts.
- [ ] Reconsider ARM only if a concrete target justifies the engineering cost.

**Exit criteria:** A second architecture boots and passes a defined shared kernel test suite without destabilizing x86-64.

## 6. Quality gates

Every phase should meet these gates before being considered complete:

- A clean, documented build succeeds.
- The emulator boot path is reproducible.
- Tests cover the critical behavior introduced by the phase.
- Failures produce useful diagnostics rather than silent hangs where practical.
- No known data-loss or privilege-boundary regression is accepted without an explicit decision.
- Documentation reflects the implementation, not merely the intended design.

## 7. Repository organization (provisional)

Adjust this structure to the chosen language and boot strategy; do not create empty directories just to match the diagram.

```text
aura_os/
├── boot/          # UEFI loader and boot handoff
├── kernel/
│   ├── arch/
│   │   └── x86_64/
│   ├── mm/        # Memory management
│   ├── interrupt/
│   ├── sched/
│   ├── drivers/
│   └── core/
├── userland/      # Init, services, shell, utilities
├── libraries/     # User-space libraries and shared interfaces
├── desktop/       # Compositor, window manager, shell
├── tools/         # Image/build/debug tools
├── tests/
├── docs/          # Architecture decisions and design notes
├── scripts/
└── Plan.md
```

## 8. Immediate next actions

1. Confirm the implementation language, compiler/toolchain, and bootloader approach.
2. Create the minimal build that emits a UEFI-bootable x86-64 image.
3. Boot it in QEMU and capture serial output in CI.
4. Add a short architecture decision record for the boot handoff and kernel execution model.
5. Only then begin memory management and interrupt implementation.

## 9. Open design decisions

These decisions should be made when the corresponding phase is near, rather than guessed prematurely:

- Kernel language and compiler/toolchain.
- Monolithic kernel versus a more separated service architecture.
- Bootloader choice and ownership of UEFI responsibilities.
- Syscall ABI and executable format.
- Filesystem choice for the first usable image.
- Display/compositor protocol and graphics API.
- Package/application distribution and update model.
- Security model, signing, and secure-boot strategy.

## 10. Risk register

| Risk | Mitigation |
|---|---|
| Scope grows before the first boot | Keep x86-64/QEMU boot as the first hard milestone |
| Hardware-specific code spreads through the kernel | Define narrow driver and architecture interfaces |
| Debugging becomes difficult | Serial logs, symbols, panic diagnostics, and emulator snapshots early |
| Multi-architecture work delays usability | Defer RISC-V until x86-64 contracts are stable |
| Desktop work hides kernel instability | Require phase exit criteria and regression tests |
| Toolchain drift breaks builds | Pin versions and validate clean builds in CI |

---

**Planning rule:** Keep this file as the high-level roadmap. Put detailed subsystem designs in separate documents under `docs/`, and update this plan when a milestone or major architectural decision changes.
