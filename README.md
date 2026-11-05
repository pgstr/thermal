# Thermal

A macOS menu bar app for temperature monitoring and fan control, built for a MacBook Pro M5 Pro (Mac17,9) on macOS 27.
It replaces Fandy for fan control. Charging stays with AlDente.

**The full plan is in [SPEC.md](SPEC.md):**
- goals and temperature targets
- architecture
- fan profiles and rules
- milestones and decisions

## Status

| Milestone | State |
|---|---|
| M0 Read-only probe | ✅ |
| M1 Fan write test | ✅ Mode plus target is enough, and handing back to Apple works |
| M2 Read-only monitoring app | Next (needs Xcode) |
| M3 to M6 | Planned |

## Layout

```
SPEC.md            the spec
smcprobe/          M0/M1 diagnostic tools (C, Command Line Tools only)
  smcprobe.c       read-only: battery, SMC keys, HID sensors
  fantest.c        M1 guarded fan write test (sudo)
  *.sh             experiment scripts (AlDente pause, Fandy quit, ...)
  README.md        detailed findings
docs/evidence/     logs from the experiments that the spec relies on
```

Planned from M2 on (see SPEC §4 and §7): `ThermalApp/` (SwiftUI menu bar app), `FanHelper/` (background helper with admin rights) and `Packages/SMCKit/` (shared SMC and sensor code).

## Diagnostic tools

```bash
make -C smcprobe
./smcprobe/smcprobe            # summary: battery, fan and charger keys, sensors
./smcprobe/smcprobe dump       # every SMC key
./smcprobe/fantest status      # one-line fan status
sudo ./smcprobe/fantest auto   # emergency: hand the fans back to Apple
```

`fantest run` writes to the fan hardware. Quit Fandy before running it.
