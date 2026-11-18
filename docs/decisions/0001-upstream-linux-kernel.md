# ADR 0001: Use the upstream Linux kernel

- **Status:** Accepted
- **Date:** 2026-11-18
- **Decision owners:** Aura OS project

## Context

Aura OS targets x86-64, RISC-V RV64GC, and AArch64. Maintaining a new kernel would multiply driver, security, architecture, and long-term maintenance work before the project has a usable system. The project needs broad hardware enablement and a sustainable update path.

## Decision

Use the upstream Linux kernel as the kernel foundation for Aura OS.

- Track an actively maintained upstream stable/LTS series appropriate to each release.
- Pin the exact kernel source revision, configuration, compiler/toolchain, and build inputs for every reproducible image.
- Keep Aura kernel configuration in version control and local patches minimal.
- Prefer upstreaming generally useful fixes.
- Do not create or maintain a private kernel fork as part of the initial roadmap.
- Treat kernel version selection and update cadence as release engineering decisions; do not silently float to an untested kernel.

## Consequences

### Benefits

- Reuse mature architecture support, drivers, memory management, networking, and security infrastructure.
- Concentrate project effort on Aura userspace, integration, desktop, updates, recovery, and diagnostics.
- Reduce the long-term burden of carrying a divergent kernel.

### Costs and constraints

- Aura must track upstream security and stable updates.
- Hardware support depends on upstream drivers, firmware, and documented reference platforms.
- Kernel configuration and any local patch must be tested against every supported release target.

## Reconsideration criteria

Reopen this decision only when a repeatable product requirement cannot reasonably be met through upstream Linux configuration, an upstreamable fix, or a small maintainable patch, and when a credible security and maintenance plan exists.
