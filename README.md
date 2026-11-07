# Thermal

A macOS menu bar app that monitors temperatures, fans and the battery, and can control the fans. Its main feature, **Cool charging**, keeps the battery below AlDente's heat-protection temperature while charging. Built and tested on a MacBook Pro M5 Pro running macOS 27.

## Requirements

- An Apple Silicon Mac, Xcode, and an **Apple Development** signing certificate. A free Apple ID works: add it in Xcode › Settings › Accounts.
- If signing fails with "unable to build chain", install Apple's [WWDR G3 intermediate](https://www.apple.com/certificateauthority/).
- Optional: AlDente for charging. Quit Fandy or any other fan app; only one app can control the fans.

## Build and run

```bash
scripts/bundle-app.sh --install   # build, sign, copy to /Applications/Thermal.app, launch
scripts/bundle-app.sh --run       # same, but run from build/ (monitoring only; no fan control)
```

Fan control needs the copy in `/Applications`.

**First time only:**
1. In the menu bar popover, turn on **Cool charging** and click **Enable…**.
2. Allow Thermal in System Settings › General › Login Items & Extensions.

**For exact AlDente integration:** create a shortcut named **AlDente State** containing AlDente's **Get State** action.

**Recommended:** turn on **Launch at Login** in the popover's `…` menu, so Cool charging keeps working after a restart.

**Updates:** reinstalling is enough; the app replaces an outdated fan helper by itself.

## Development

```bash
swift build                # build everything
swift test                 # unit tests, plus one test against the live hardware
swift run thermal -v       # print one sensor snapshot (--watch, --bench)
```

## Safety

- The fan helper only writes fan mode and target speed.
- It hands the fans back to Apple when the app quits, crashes, hangs (10 s lease) or the Mac sleeps.
- It exits after 60 s idle (launchd restarts it on demand).
- Emergency reset: `make -C smcprobe && sudo ./smcprobe/fantest auto`.

## Layout

| Path | Contents |
|---|---|
| `Sources/ThermalApp/` | Menu bar app (SwiftUI) |
| `Sources/FanHelper/` | Root helper for fan writes, over XPC |
| `Sources/SMCKit/` | Sensors, battery, fan policy |
| `Sources/CSMC/`, `Sources/CFanWrite/` | C layers for reading and writing |
| `smcprobe/` | Diagnostic tools and hardware findings ([README](smcprobe/README.md)) |
| [SPEC.md](SPEC.md) | Design, decisions and milestones |

History is stored in `~/Library/Application Support/Thermal/history.sqlite`.
