# PowerFuzz research intake

Date: 2026-07-13

## Source

[PowerFuzz: Power-Based Black-Box Firmware Fuzzing](https://arxiv.org/abs/2606.24692) proposes using power-trace measurements as feedback when firmware internals and coverage instrumentation are unavailable. The paper evaluates that approach on embedded hardware and firmware benchmarks.

## WIZP fit assessment

PowerFuzz does not map to WIZP's current product risk:

- WIZP is a desktop editor and extension host, not a firmware or embedded-device target.
- WIZP already has direct host/runtime observations: JSON-RPC results, process lifecycle, terminal bytes, UI events, diagnostics, and artifact-backed parity lanes.
- There is no supported power-measurement device, firmware target, or hardware test fixture in this repository.
- Introducing power-trace collection would add hardware and privacy/measurement complexity without improving the current Linux alpha blockers.

## Decision

Do not promote PowerFuzz or power-trace instrumentation into the WIZP backlog. Retire this research signal as not applicable to the current product surface.

The reusable lesson is narrower: when direct internal coverage is unavailable, define an explicit observable feedback signal before prioritizing expensive probes. WIZP already applies that principle through artifact-backed runtime, UI, process, and parity evidence; future work should improve those signals before adding a new measurement domain.

## Proof boundary

This is a research-fit decision, not evidence that WIZP has firmware fuzzing capability. No hardware experiment was run or claimed.
