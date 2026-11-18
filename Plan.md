# Aura OS — Development Plan

> Status: Active bring-up
> Project: aura_os
> Last updated: 2026-11-18

## 1. Vision

Aura OS is a general-purpose desktop operating system designed as one coherent product across x86-64, RISC-V RV64GC, and ARM 64-bit (AArch64). The product identity is defined by its system integration, userspace, desktop, developer experience, security, and update model—not solely by its kernel.

Aura OS has selected the upstream Linux kernel as its foundation. The project will focus its engineering effort on a lean, secure, maintainable Aura userspace and product experience rather than developing a kernel from scratch.

## 2. Product and platform decisions

### First-class native architectures

All three architectures are strategic priorities from the beginning:

- **x86-64** — first-class native target for PCs and virtual machines.
- **RISC-V RV64GC** — first-class native target, with a defined ISA and firmware/platform baseline.
- **ARM 64-bit (AArch64)** — first-class native target, beginning with a clearly defined reference platform.

The goal is one Aura OS product with architecture-specific builds, shared userspace interfaces, common release policies, and a shared test suite. Native support does not imply support for every board or peripheral on day one.

### Boot and firmware

- Support UEFI on platforms that provide it.
- Support device-tree-based boot where required, especially on RISC-V and ARM platforms.
- Isolate firmware, bootloader, and architecture-specific code from shared product components.
- Define a minimum reference hardware profile for each architecture before claiming compatibility.

### Kernel strategy — Linux selected

**Decision: Aura OS will use the upstream Linux kernel as its kernel foundation.** This is the project direction, not merely a temporary prototype choice.

- Use upstream Linux for CPU architecture support, drivers, memory management, scheduling, networking, security infrastructure, and hardware enablement across x86-64, RV64GC, and AArch64.
- Prefer an actively maintained upstream stable/LTS kernel line appropriate to the release and hardware-support requirements; record the exact version and support lifecycle for every release.
- Maintain Aura-specific kernel configuration separately and keep patches minimal, documented, and rebased against upstream. Upstream generally useful fixes whenever practical.
- Do not maintain a private kernel fork or build a replacement kernel as part of the initial product roadmap.
- Build Aura OS identity in its userspace, service model, desktop, installer/images, developer tools, security policy, and update/recovery experience.
- Keep product-level interfaces and services modular so that implementation details of the Linux kernel do not unnecessarily leak into applications.
- Track Linux licensing, required source availability, notices, and firmware redistribution obligations for shipped components.

A custom kernel is out of initial scope. Reconsidering that decision would require a documented, repeatable kernel-level limitation that cannot reasonably be addressed through Linux configuration, upstream fixes, or a small maintainable patch, plus a credible security, driver, and long-term maintenance plan.

### Product principles

1. Reliability, security, maintainability, and recoverability are foundational.
2. x86-64, RV64GC, and AArch64 are first-class product targets.
3. Keep platform-specific code behind explicit interfaces.
4. Prefer upstream components and reproducible builds where practical.
5. Distinguish compile support, boot support, and usable hardware support.
6. Document decisions, trade-offs, and limitations.

## 3. Scope and non-goals

### Initial scope

- Bootable Aura OS images for all three target architectures.
- A common base userspace and system configuration.
- A documented upstream Linux kernel strategy with a defined release and support policy.
- Basic storage, networking, services, logging, and package/update workflows.
- A consistent desktop experience after the base system is reliable.
- Automated builds and smoke tests using emulators and reference hardware.

### Non-goals for the first milestone

- Supporting every device, board, and peripheral.
- Perfect feature parity across all hardware immediately.
- Maintaining a private Linux fork without a demonstrated need.
- Reimplementing mature kernel subsystems solely for ownership.
- Building a complete application ecosystem before the base platform is stable.

## 4. Proposed system architecture

1. **Platform and boot** — UEFI or device-tree handoff, boot configuration, firmware interfaces, and image boot process.
2. **Architecture support** — low-level CPU/platform support for x86-64, RV64GC, and AArch64.
3. **Kernel** — upstream Linux (selected foundation); maintain documented configuration and minimal patches.
4. **Hardware integration** — graphics, input, storage, networking, audio, firmware, and power management, tracked by reference platform.
5. **System base** — init/service management, libraries, users, permissions, logging, and core utilities.
6. **Storage and packages** — filesystem layout, package repositories, installation, verified updates, and rollback.
7. **Aura services and APIs** — stable product-level interfaces for applications and system components.
8. **Desktop** — compositor, window management, settings, shell, input, and accessibility.
9. **Developer tooling** — multi-architecture builds, image creation, CI, tests, emulators, symbols, and diagnostics.

## 5. Development phases

### Phase 0 — Architecture and repository foundation

- [x] Select upstream Linux as the kernel foundation for Aura OS.
- [ ] Record requirements and a minimum reference platform for each architecture.
- [x] Record the initial upstream Linux longterm baseline and x86-64 bring-up configuration in architecture decision records.
- [x] Build the pinned upstream Linux 6.18.64 x86-64 kernel in CI; generate a minimal initramfs and verify first boot through OVMF UEFI in QEMU (AURA_INIT_OK / AURA_QEMU_TEST_PASS; CI run 44301482434).
- [x] Add target-specific kernel, static initramfs, and QEMU smoke-test workflows for RV64GC and AArch64 (initial emulator profiles; hardware support is not implied).
- [ ] Pass both new cross-architecture CI jobs and inspect their boot artifacts.
- [ ] Choose base userspace, init/service model, build system, and packaging direction.
- [ ] Establish repository layout, conventions, and pinned toolchains.
- [x] Add CI for the initial pinned x86-64 Linux kernel build.
- [ ] Add CI for formatting, static checks, userspace builds, and boot smoke tests.
- [ ] Define a benchmark harness and capture initial Linux baselines on each reference architecture.
- [ ] Record idle-service, memory, CPU, startup, and I/O measurements before tuning.

**Exit criteria:** documented Linux kernel policy, defined platform profiles, a reproducible x86-64 kernel build, and a verified QEMU first boot.

### Phase 1 — Three-architecture bootable base

- [ ] Produce a bootable x86-64 image.
- [ ] Produce a bootable RV64GC image for the selected emulator/reference platform.
- [ ] Produce a bootable AArch64 image for the selected emulator/reference platform.
- [ ] Document platform-specific boot and firmware requirements.
- [ ] Capture boot logs in automated smoke tests.
- [ ] Publish known limitations for each target.

**Exit criteria:** all three architectures boot a minimal Aura OS base through repeatable documented workflows.

### Phase 2 — Shared system foundation

- [ ] Establish common userspace and service startup.
- [ ] Define users, groups, permissions, and privilege boundaries.
- [ ] Establish storage layout and filesystem support.
- [ ] Add logging, diagnostics, crash reporting, and recovery.
- [ ] Establish networking and time configuration.
- [ ] Define package installation, updates, and rollback.
- [ ] Add architecture-independent integration tests.

**Exit criteria:** core system workflows behave consistently across all three targets.

### Phase 3 — Hardware enablement

- [ ] Maintain a hardware compatibility matrix per architecture.
- [ ] Validate storage, USB/input, display, networking, audio, and power by priority.
- [ ] Prefer upstream Linux drivers when using Linux.
- [ ] Track firmware licensing and redistribution constraints.
- [ ] Add real-hardware smoke tests in addition to emulator coverage.

**Exit criteria:** each architecture has at least one documented, usable reference device.

### Phase 4 — Aura desktop experience

#### Desktop interaction and responsive layout requirements

- Make the application launcher and unified search the primary entry point for applications, settings, and common system actions.
- Design common tasks so that at least 90% of audited everyday workflows can be completed in three user actions or fewer from the desktop entry point; direct search results and keyboard navigation count as actions and must be measured consistently.
- Keep advanced controls available without forcing novice users through complex nested menus.
- Build responsive layouts for the planned future device sizes: 12-inch and 13.2-inch entry devices, plus 14.5-inch and 16-inch standard/higher-tier devices. These are future product design targets only; hardware development is not part of the current scope.
- Validate usable layouts at representative resolutions and scaling factors, not diagonal size alone.

#### Desktop implementation

- [ ] Select the desktop/compositor and graphics stack.
- [ ] Establish consistent windowing, settings, input, and accessibility.
- [ ] Integrate launcher, file manager, terminal, and system settings.
- [ ] Verify desktop behavior on all three architectures.
- [ ] Define startup, memory, graphics, and responsiveness budgets.

**Exit criteria:** users can boot into the Aura desktop, use basic applications, and shut down or reboot cleanly on each reference target.

### Phase 5 — Security, updates, and release engineering

- [ ] Define secure boot and image-signing policy per platform.
- [ ] Harden default services, permissions, and network exposure.
- [ ] Establish vulnerability tracking and kernel/userspace update cadence.
- [ ] Verify update integrity, failure recovery, and rollback.
- [ ] Publish reproducible build instructions, component notices, and support matrix.
- [ ] Run regression, compatibility, and performance tests on all targets.
- [ ] Publish reproducible per-architecture performance comparisons against the defined Linux reference.

**Exit criteria:** a preview release has documented support, update, and recovery procedures.

### Phase 6 — Long-term kernel and platform evolution

- [ ] Track upstream Linux security fixes, stable/LTS support, and hardware enablement for every supported architecture.
- [ ] Keep Aura kernel configuration reproducible and patches minimal; upstream generally useful fixes.
- [ ] Review kernel updates for regressions, bootability, performance, and recovery before release.
- [ ] Reconsider the kernel strategy only if a documented, repeatable requirement cannot reasonably be met with upstream Linux.
- [ ] Expand hardware coverage based on user demand and engineering capacity.

**Exit criteria:** kernel and platform direction is backed by product requirements and measured maintenance cost.

## 6. Architecture-specific validation

| Target | Initial baseline to define | Validation environment |
|---|---|---|
| x86-64 | UEFI PC profile, CPU baseline, graphics/storage expectations | QEMU + reference PC |
| RISC-V RV64GC | QEMU `virt`, RV64GC CPU model, OpenSBI firmware, generated device tree, 16550 UART; physical-board firmware remains to be selected | QEMU `qemu-system-riscv64` + later reference board |
| ARM AArch64 | QEMU `virt`, AArch64 `Image`, PL011 UART; current smoke test uses QEMU's direct Linux loader, not UEFI | QEMU `qemu-system-aarch64` + later UEFI/reference device |

Specify exact CPU extensions, firmware versions, and device models before claiming compatibility. Compilation alone is not support; boot and usable-device validation must be tracked separately.

## 7. Quality gates

- Clean, documented builds are reproducible.
- Every target has an explicit boot and test environment.
- Critical behavior is covered by automated tests.
- Failures produce useful diagnostics.
- Security updates and recovery are part of release design.
- Shared behavior is tested consistently across architectures.
- Performance claims are backed by reproducible same-hardware comparisons and raw measurement records.
- Documentation reflects actual implementation and support status.




## 8. Competitive advantage and product differentiation

Aura OS must be meaningfully better at a small number of important user outcomes, not merely be another Linux distribution with a different theme. The project will compete through a coherent, measurable product experience while reusing the upstream Linux kernel and mature open-source components.

### Strategic differentiators

1. **Low overhead without sacrificing usability**
   - Keep the default installation and background service set lean.
   - Make optional features installable or activatable on demand.
   - Optimize boot-to-ready time, idle CPU use, memory footprint, wakeups, and interactive latency.
   - Do not achieve low benchmark numbers by omitting basic security, accessibility, hardware support, or expected desktop functionality.

2. **One coherent system experience**
   - Provide one consistent place and interaction model for system settings, applications, permissions, updates, diagnostics, backup, and recovery.
   - Avoid exposing users to conflicting tools or distro-specific configuration fragments for common tasks.
   - Make common workflows understandable to non-expert users while retaining advanced controls for developers and administrators.

3. **Safe, predictable system lifecycle**
   - Make updates verifiable, staged, recoverable, and preferably rollback-capable.
   - Clearly communicate update state, failures, support status, and recovery options.
   - Keep security fixes timely and make the supported lifecycle explicit.
   - Treat backup and recovery as core system workflows, not optional afterthoughts.

4. **Practical compatibility and application access**
   - Prioritize reliable access to established Linux applications, development tools, common file formats, peripherals, and network services.
   - Publish an honest compatibility matrix and known limitations.
   - Do not claim Windows/macOS application compatibility unless a specific compatibility path has been tested.
   - Prefer established package formats and upstream ecosystems where they reduce user friction; avoid creating a proprietary app ecosystem before there is a compelling need.

5. **Consistent multi-architecture product**
   - Deliver the same core workflows and release quality on x86-64, AArch64, and RV64GC.
   - Use architecture-specific optimization only when it is measurable and does not fragment the product experience.
   - Publish hardware support separately for each reference platform; do not imply that every device on an architecture is supported.

6. **Excellent developer and troubleshooting experience**
   - Provide reproducible build/development environments, useful system diagnostics, clear logs, and documented APIs.
   - Make it straightforward to inspect resource usage, identify failing services, and recover from a bad configuration.
   - Keep system interfaces stable and documented so applications do not depend on Aura-internal implementation details.

### Competitive positioning

- **Against mainstream desktop operating systems:** prioritize lower background overhead, transparent system behavior, recoverable updates, and a simpler integrated system-management experience. Do not claim universal superiority in commercial application availability, peripheral support, or gaming.
- **Against other Linux distributions:** differentiate through the complete Aura workflow—installation, defaults, desktop integration, updates, recovery, diagnostics, and consistent multi-architecture releases—not through branding or a custom kernel alone.
- **Against minimal Linux distributions:** retain a polished, accessible, general-purpose desktop and safe lifecycle management rather than optimizing only for the smallest image or lowest idle memory number.

### Primary desktop Linux benchmark: Linux Mint

Linux Mint is the primary reference distribution for Aura OS desktop efficiency and everyday usability. The objective is to reach parity with, then measurably exceed, Linux Mint on selected user-relevant efficiency measures without sacrificing equivalent functionality, security, hardware support, or reliability.

- Compare against maintained Linux Mint releases and record the exact edition (Cinnamon, MATE, or Xfce), release, kernel, image checksum, installed packages, services, and configuration. Use the edition that best matches Aura's intended desktop experience; use other editions as additional context, not as a substitute for the primary comparison.
- Run both systems on identical reference hardware with equivalent display resolution, graphics settings, power profile, network state, and background workload.
- Measure idle memory, idle CPU and wakeups, boot-to-ready, application launch and interactive latency, battery/energy use where measurable, and performance under memory pressure.
- Publish the full test method and raw results. Report both total system memory accounting and process-level proportional set size (PSS), and separately identify reclaimable page cache, shared memory, kernel memory, and reserved memory. Do not present a single ambiguous “RAM used” number as the whole result.
- First establish a reproducible Linux Mint baseline. Then set per-metric Aura budgets and require repeated-run evidence before claiming parity or superiority.
- A result counts as a product improvement only when common workflows remain equally usable and there is no unacceptable regression in security, stability, compatibility, accessibility, or responsiveness.

### Evidence and acceptance criteria

- Choose named, maintained comparison systems for each reference hardware profile. Record exact OS image, kernel, configuration, software versions, hardware, power mode, and test procedure.
- Establish baseline measurements before setting numerical targets. Set explicit budgets for idle memory/CPU, boot-to-ready, interactive latency, update/recovery time, and supported application workflows.
- Compare equivalent functionality and security settings. Publish raw results, repeated-run distributions, and known limitations; do not compare a fully featured Aura installation with a stripped-down competitor.
- Require measurable improvement in at least one user-important dimension without unacceptable regressions in reliability, security, compatibility, or usability before making a superiority claim.
- Validate product workflows with task-based tests (for example: install an app, connect to a network, update, recover from a failed update, and diagnose a service failure), not benchmarks alone.
- Revisit priorities using user feedback and observed usage. Do not expand scope simply to match every feature of Windows, macOS, or another Linux distribution.

## 9. Performance and efficiency engineering

Performance is a product requirement, not a late-stage polish task. Aura OS should aim to outperform a clearly defined Linux reference on selected workloads while preserving reliability, security, and maintainability. Do not claim that Aura is "faster than Linux" based on a single benchmark or an uncontrolled comparison.

### Explicit efficiency targets

The following are engineering targets, not current measured results:

- **Idle memory stretch target: 512 MiB or less** for the complete base desktop session, including the Linux kernel, compositor/window manager, shell, and essential system services. AI models, application processes, and optional services are not part of this idle baseline.
- Report a second, stricter accounting view that includes kernel allocations and non-reclaimable system memory; document treatment of reclaimable page cache, shared pages, firmware reservations, and graphics memory so the 512 MiB figure cannot be achieved through accounting exclusions.
- Treat 512 MiB as a stretch target to validate on defined reference hardware, not as a promise for every driver, architecture, or desktop configuration. If it cannot be met without weakening security or usability, publish the measured result and explain the trade-off.
- Ensure an 8 GiB RAM system remains practical for ordinary workloads such as web browsing, document editing, media playback, and multitasking. Test actual applications and memory pressure; idle footprint alone is insufficient.
- Aim for parity with Linux Mint first, then exceed it on clearly specified measures. Never trade away equivalent functionality or security merely to win an idle-memory comparison.

### Optimization priorities

Apply optimizations in this order, measuring each change:

1. **Reduce idle resource use**
   - Start only services required for the current system role.
   - Use dependency-aware and on-demand service activation where practical.
   - Remove duplicate daemons, unnecessary polling, and redundant background work.
   - Keep the base system separate from optional desktop and application services.
2. **Reduce CPU overhead**
   - Prefer event-driven waits over busy loops and frequent polling.
   - Avoid repeated parsing, allocation, context switching, and needless wakeups.
   - Profile scheduler behavior, lock contention, interrupt load, and system-call overhead before changing low-level policies.
3. **Improve memory efficiency**
   - Track resident memory by process and service, not only total RAM.
   - Reduce duplicate libraries and data copies where safe.
   - Evaluate allocator behavior, cache policy, memory mapping, compression, and reclaim behavior using real workloads.
   - Preserve memory headroom; do not optimize idle RAM at the expense of severe latency under pressure.
4. **Improve I/O and storage paths**
   - Use asynchronous and batched I/O where workloads benefit.
   - Reduce avoidable copies and metadata operations.
   - Measure throughput and tail latency; do not optimize throughput alone.
5. **Improve startup and responsiveness**
   - Make service dependencies explicit and parallelize only independent startup work.
   - Make essential functions ready early and defer nonessential work.
   - Measure boot-to-ready and interactive response latency.
6. **Use architecture-aware builds**
   - Establish safe baseline compiler targets for x86-64, RV64GC, and AArch64.
   - Evaluate LTO, PGO, and architecture-specific tuning only with repeatable tests.
   - Keep portable fallbacks and verify that tuning does not break binary compatibility or reliability.

### Measurement and Linux comparison

- Establish a reproducible baseline before setting numeric improvement targets.
- Compare against a named, documented Linux distribution and kernel configuration on the same hardware.
- Keep workload, data, application versions, toolchain, power mode, and background services controlled.
- Repeat runs and report median, spread/variance, and relevant tail latency.
- Track at least:
  - idle and workload resident memory, including per-service breakdown;
  - boot-to-ready time and service startup cost;
  - CPU time and energy per fixed workload;
  - interactive and scheduler latency under load;
  - storage and network throughput plus latency;
  - behavior under memory pressure and sustained load.
- Report results separately for x86-64, RV64GC, and AArch64. Never generalize a result from one architecture to all three.
- Keep benchmark scripts, workload definitions, raw results, and environment metadata in the repository so results can be reproduced.

### Kernel and userspace decision rule

First optimize Aura's service set, userspace, build configuration, and hardware integration while using upstream Linux. If profiling identifies a kernel-level bottleneck, test a minimal configuration change or a small, maintainable patch and compare it with upstream. Consider a custom kernel or custom subsystem only when repeatable measurements show a material unmet requirement and the project can sustain its security, driver, and maintenance burden.

## 10. Repository organization (provisional)

~~~text
aura_os/
├── platform/
│   ├── x86_64/
│   ├── riscv64/
│   └── aarch64/
├── boot/
├── kernel/             # Kernel config, patches, or custom kernel work
├── system/             # Base userspace and system integration
├── services/
├── desktop/
├── packages/
├── images/             # Image definitions and manifests
├── tools/              # Build, image, test, and debug tools
├── tests/
├── docs/               # Architecture decisions and platform support
├── scripts/
└── Plan.md
~~~

Adjust this structure to the selected kernel and build system. Do not create empty directories just to match the diagram.

## 11. Immediate next actions

1. Record the selected upstream Linux kernel policy and first-boot reference platform in architecture decision records.
2. Bring up x86-64 in QEMU first, with serial boot logs and a minimal initramfs.
3. Validate the new RV64GC and AArch64 cross-build/first-boot jobs, then add firmware-mediated boot paths (including AArch64 UEFI) and complete disk-image assembly.
4. Define the shared userspace, init/service model, desktop, package, and update strategy.
5. Establish per-architecture kernel security-update and regression-test workflows.

## 12. Open design decisions

- Linux distribution/base userspace versus a minimal custom userspace.
- Init/service manager and system library choices.
- Desktop/compositor and graphics stack.
- Package format, repositories, installation, and atomic update model.
- Exact reference hardware and minimum CPU/ISA baselines for all three targets.
- Firmware and boot strategy per platform.
- Secure boot, signing, and component update policy.
- Exact upstream Linux kernel line and update cadence for each Aura OS release.

## 13. Risk register

| Risk | Mitigation |
|---|---|
| Three architectures expand scope | Define one reference platform per architecture and prioritize shared workflows |
| Hardware support differs widely | Publish per-device support matrix; distinguish compile, boot, and usable support |
| Kernel maintenance falls behind upstream | Track stable/LTS lifecycle, security advisories, and test updates continuously; keep local patches minimal |
| Linux fork becomes hard to maintain | Keep patches small, track upstream, and upstream useful changes |
| Firmware differences leak into product code | Isolate boot and architecture-specific components |
| Updates cause data loss or an unbootable system | Design verification, rollback, and recovery before preview release |
| Desktop work hides base instability | Require base-system quality gates before desktop milestones |

---

**Planning rule:** Keep this file as the high-level roadmap. Put detailed designs and trade-off records in docs/. Update the plan when a major platform, kernel, or release decision changes.
