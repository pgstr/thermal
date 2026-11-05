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
| M2 Read-only monitoring app | 🚧 Running: menu bar, popover, history and raw SMC view. Still to do: a full-day run, and mapping dies to CPU or GPU. |
| M3 Fan helper plus Cool charging | ✅ Tested live: follows AlDente's state; crash, hang and sleep fail-safes |
| M4 to M6 | Planned (M5 gets profiles and more rules) |

## Build and run

```bash
scripts/bundle-app.sh --run    # builds build/Thermal.app, signs it and (re)launches it
swift run thermal -v           # one snapshot in the terminal (add --watch or --bench)
swift test                     # unit tests plus one live-hardware test
```

History is stored in `~/Library/Application Support/Thermal/history.sqlite`.

**Fan control (M3):**
1. Install with `scripts/bundle-app.sh --install`. This needs a valid Apple Development identity, including Apple's WWDR **G3** intermediate certificate.
2. In the popover, turn on **Cool charging**, click **Enable…** and approve Thermal in System Settings › Login Items.

For exact AlDente integration, create a shortcut named **AlDente State** containing AlDente's **Get State** action.

- **Test hook:** `defaults write dev.streller.thermal debug.forceRPM 3000`. Remove it with `defaults delete dev.streller.thermal debug.forceRPM`.
- **Emergency hand-back:** `sudo ./smcprobe/fantest auto`.

## Layout

```
SPEC.md            the spec
Package.swift      SwiftPM package: CSMC, SMCKit, thermal (CLI), ThermalApp
Sources/CSMC/      C layer: AppleSMC structures and private HID sensor calls (read-only)
Sources/SMCKit/    Swift API: SMCClient, HIDTemperatureReader, BatteryStatus, SensorCatalog, SensorReader
Sources/ThermalCLI/  `thermal` command-line tool (same code as the app)
Sources/ThermalApp/  menu bar app: Monitor, HistoryStore (SQLite), popover, history charts, raw SMC view
scripts/bundle-app.sh  turns the build into an .app bundle
smcprobe/          M0/M1 diagnostic tools (C, Command Line Tools only)
  smcprobe.c       read-only: battery, SMC keys, HID sensors
  fantest.c        M1 guarded fan write test (sudo)
  *.sh             experiment scripts (AlDente pause, Fandy quit, ...)
  README.md        detailed findings
docs/evidence/     logs from the experiments that the spec relies on
```

Fan control (M3):
- `Sources/FanHelper/`: the root launchd daemon.
- `Sources/CFanWrite/`: allowlisted SMC fan writes, linked only by the helper.
- `Sources/FanHelperProtocol/`: the XPC interface.
- `Resources/dev.streller.thermal.fanhelper.plist`: the daemon's launchd plist.

## Diagnostic tools

```bash
make -C smcprobe
./smcprobe/smcprobe            # summary: battery, fan and charger keys, sensors
./smcprobe/smcprobe dump       # every SMC key
./smcprobe/fantest status      # one-line fan status
sudo ./smcprobe/fantest auto   # emergency: hand the fans back to Apple
```

`fantest run` writes to the fan hardware. Quit Fandy before running it.
