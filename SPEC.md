# Thermal: temperature monitor and fan control for M5 Pro (spec v0.3)

| | |
|---|---|
| Status | M3 done (branch `m3/fan-helper`, built on `m2/monitoring-app`). M2 leftovers: full-day run, CPU/GPU mapping. |
| Date | 2026-11-05 |
| Target machine | MacBook Pro, Apple M5 Pro (Mac17,9), macOS 27.3 |
| Evidence | `smcprobe/` (read-only probe, experiment scripts and the findings in [smcprobe/README.md](smcprobe/README.md)) |

## 1. Goal

**What it is:** a general temperature monitoring and fan control app for the menu bar. It replaces Fandy and works alongside AlDente.
1. **Monitor** every relevant temperature (chip, GPU, battery, storage, case), plus the fans and battery state, with history.
2. **Control the fans** for any purpose: profiles, custom curves on any sensor, and rules.
3. **Flagship rule:** keep the battery cool while charging. AlDente remains responsible for the charging itself.

**Temperature targets** (the reasoning is in §5.4):

| Component | Target | Act at | Hard ceiling |
|---|---|---|---|
| Battery | 15–30 °C | ≥ 30 °C on the charger | 36 °C → fans at maximum |
| CPU and GPU dies | Leave to Apple up to about 90 °C sustained | Only as an early warning for the battery, or if you pick a cooler profile | 95 °C → fans at maximum |
| Case surface (estimated from case-area sensors) | ≤ 40 °C | Profile-dependent | – |

**Fan philosophy:**
- **Quiet by default.** Apple controls the fans, and Thermal steps in only when a profile, curve or rule asks for it.
- Every boost has a minimum hold time and a gap between its "on" and "off" temperatures, so the fans don't toggle constantly.

**Non-goals for v1:**
- Our own charge control (AlDente owns charging).
- App Store distribution.
- Supporting any Mac other than this one. The code should detect capabilities at runtime, but only this machine is tested.

## 2. What we know from the probe

### 2.1 Reading (no admin rights needed)

| Data | Source | Notes |
|---|---|---|
| Battery temperature | SMC `TB0T`, `TB1T`, `TB2T` (`flt`, °C) | Matches the HID "gas gauge battery" sensors. The IORegistry `Temperature` field is not reliable on macOS 27. |
| Die temperatures | HID sensors `PMU tdie1…14` (×3 PMUs) | Drop readings outside −40…150 °C. The `PMU tdevN` channels report about −9200 °C (unused). |
| Other temperatures | HID `NAND CH0 temp`, `PMU tcal`. 285 SMC `T*` keys. | Mapping SMC `T*` keys to physical locations is not done yet. |
| Fan speed | `F0Ac`/`F1Ac` actual rpm, `F0Tg` target rpm, `F0Mn` = 2317 min, `F0Mx` = 7826 max | 2 fans. Apple runs them at **0 rpm** when the machine is cool. |
| Fan state | `F0St`: 1 = starting, 5 = running, 2 = spinning down, 3 = stopped | |
| Battery state | IORegistry `AppleSmartBattery` | `CurrentCapacity`, `IsCharging`, `ExternalConnected`, `InstantAmperage`, `Voltage`, `CycleCount`, `BatteryData.{DesignCapacity, AppleRawMaxCapacity}`, `AdapterDetails.Watts` |
| Why not charging | `ChargerData.NotChargingReason` | 4096 means held by a charge limit, which is how AlDente pauses. |

**SMC encoding:** integers are little-endian. Only `#KEY` is big-endian.

**Duplicate die sensors (found in M2):**
- Each `PMU tdieN` appears as three HID services with the same name and the same `LocationID`. Their readings agree within about 1 °C.
- Thermal polls only the first copy of each, giving 14 die sensors. Sensor ids are `hid:<name>` and `smc:<key>`, stable across launches.

**Cost of reading:**
- Every HID read is a round trip to a system service: about 0.85 ms, mostly waiting.
- A full snapshot costs about 0.2% of one core per second.
- **Menu bar updates cost about 20 ms each.** The label therefore smooths the die value and only changes on a 2 °C move, or after 15 s for smaller drifts.

### 2.2 Fan control (confirmed by the M1 write test, `smcprobe/fantest.c`)

- **Manual:** `F{n}md = 1` plus `F{n}Tg = <rpm>`. Both must be written as root, and nothing else is needed.
- **Back to Apple's automatic control:** `F{n}md = 0`. The target drops to 0 and the fans stop about 6 s later if the machine is cool.
- **No unlock step:** there is no `Ftst`-style unlock on M5.
- **`FEna`/`FPSt` are status set by the firmware.** Do not write them.
- **`md = 1` on its own already starts the fans,** at a target the firmware picks (3758 rpm). So the helper must write `Tg` straight after `md`, within the same call.
- **Speed control is accurate:** actual rpm is within ±10 rpm of target, settling in 1–2 s. Fans start from 0 in about 4 s.
- **The firmware applies speed changes almost immediately** (3000→4500 in about 1 s). Gradual ramping is Thermal's job.
- **Minimum and maximum:** 2317 / 7826 rpm, holding steady at the minimum.
- **Still open:**
  - Whether manual mode survives sleep and wake. To test in M3.
  - Whether manual mode stays after the controlling process dies. Assume yes, which is why the helper has a lease.

### 2.3 Charging

- **On macOS 27 the SMC cannot stop charging.** The settings older tools used (`CHTE`, `CH0B`, `CH0C`, `CHWA`) are gone.
- **AlDente's route:** it sends an XPC request to `com.apple.powerui.smartChargeManager`, a service of `PowerUIAgent`, which runs as root. It asks for a "Manual Charge Limit" (MCL) equal to the current charge level. `powerd` then enforces it.
  - `PowerUIAgent` logs *"Client does not have necessary entitlement"* for AlDente but still honours the request, so this route is fragile.
- **Discharge while plugged in:** still possible through the SMC setting `CHIE`.
- **AlDente's Shortcuts actions:**
  - Control: `StopCharging`, `StartCharging`, `SetPercentage`, `Discharge`.
  - Read: `GetState`, `GetTemperature`, `GetPercentage`, `GetChargeLimit`.
  - Other: `Calibrate`, `SetMagsafeLED`, `SetHighPowerMode`, `SetLowPowerMode`.
  - AlDente also registers the URL scheme `aldente://`, which is not explored yet.

**Found live in M3 (2026-11-05):**
- **How AlDente's heat pause works:** when the battery is at or above its `maxTemperature` (28 °C), AlDente sets the macOS charge limit to the *current* level (e.g. 81%).
- **The "not charging" code is ambiguous.** Within seconds, macOS reports the same "limit reached" reason (`0x1000000`) as a real charge limit. The reason code cannot tell a heat pause from a reached limit.
- **AlDente re-checks about 10 minutes after pausing.**
  - Paused 19:45:15 at about 29.8 °C; the battery was below 28 °C from 19:50:58; AlDente resumed 19:55:17 at 25.6 °C.
  - So every heat pause costs at least about 10 minutes of charging.
- **AlDente's settings are readable** (read-only) from its preferences domain `com.apphousekitchen.aldente-pro`:
  - `chargeVal`: charge limit %.
  - `sailingMode` and `sailingLevel`: charging resumes at limit − level.
  - `heatProtectMode` and `maxTemperature`: heat protection on/off and its threshold.
- **AlDente's live state** is only available through its Shortcuts "Get State" action.
  - Thermal runs a user-created shortcut named **"AlDente State"** with `/usr/bin/shortcuts run`, which takes about 0.3 s.
  - Observed values: `Charging`, `HeatProtect`, `Sailing`. `Discharging` and `Calibration` also exist in the binary.

## 3. Ownership rules (prevents apps fighting each other)

| Resource | Owner | Others |
|---|---|---|
| Fans (SMC `F*` writes) | **Our app** | Fandy must be quit or uninstalled. The app checks for a running `Fandy` or `FandyFanHelper` and refuses manual mode while either is present. |
| Charging | **AlDente** | Our app only *asks* AlDente to act, through Shortcuts. It never writes charging settings. |
| Charge limit (for example 80%) | AlDente's settings | Our app shows the limit and does not change it in v1. |
| Battery heat protection | **AlDente** (its 28 °C setting stays on) | Our app never pauses or resumes charging in v1. It reacts to a warm battery only with the fans. |

## 4. Architecture

```
┌────────────────────────────── user session ──────────────────────────────┐
│  ThermalApp (menu bar, SwiftUI, starts at login)                          │
│   ├─ SensorService      SMC reads + HID sensors + IORegistry, 1 Hz        │
│   ├─ HistoryStore       SQLite (system libsqlite3), downsampled           │
│   ├─ RuleEngine         fan curves + combined rules, hysteresis           │
│   ├─ ChargingBackend    protocol; v1 = AlDenteShortcutsBackend            │
│   │                       → /usr/bin/shortcuts run "<name>"               │
│   └─ FanClient ──XPC──┐                                                   │
└───────────────────────┼───────────────────────────────────────────────────┘
                        ▼
┌──────────────────────── root (launchd daemon) ───────────────────────────┐
│  FanHelper (as small as possible)                                         │
│   - accepts ONLY: setManual(fan, rpm, leaseSeconds), setAuto(fan),        │
│     status()                                                              │
│   - writes ONLY keys on an allowlist: F{n}md, F{n}Tg (M1: nothing else    │
│     is needed; FEna/FPSt are firmware status)                             │
│   - clamps rpm to [F{n}Mn, F{n}Mx]                                        │
│   - lease: no renewal within the lease time → setAuto                     │
│   - on start, on SIGTERM, before sleep and after wake → setAuto           │
│   - checks the XPC caller's code signature (team ID / signing             │
│     requirement)                                                          │
└───────────────────────────────────────────────────────────────────────────┘
```

Design decisions:
- **The rule engine lives in the user-session app, not in the root helper.** Shortcuts can only run as the user, and the helper should stay small. The lease makes this safe: if the app crashes or hangs, the fans return to Apple's control within the lease time (default 10 s).
- **Leave fans on automatic when nothing is wrong.** A curve that would want "fans off" hands control back to Apple instead of writing 0 rpm. This keeps Apple's own thermal behaviour as the baseline.
- **`ChargingBackend` is an interface.** That leaves room for a later `PowerUIBackend` (our own charge control) and an `SMCDischargeBackend` (`CHIE`) without touching the rules.
- **Capability detection at startup:** the probe logic checks which keys and sensors exist. Anything missing or changed after a macOS update turns that feature off and shows why in the UI. It must never guess.

## 5. Features

### 5.1 Monitoring (M2)
- **Menu bar readout**, configurable. Default: battery °C · hottest die °C · fan rpm.
- **Popover:**
  - Battery: charge, charging state and the reason for "not charging", watts in and out, temperature, cycles, health = raw max capacity ÷ design capacity.
  - Sensor groups: **CPU**, **GPU**, **Battery**, **Storage**, **Case/other**. Each shows max and average, and expands to individual sensors. Sensors can be renamed or hidden.
    - We don't yet know which `PMU tdieN` sensors are CPU and which are GPU. **M2 task:** map them with a CPU-only load test and a GPU-only load test, then store the mapping. Also map the case-area SMC `T*` keys.
  - Alerts on any sensor or group, for example "GPU > 95 °C for 30 s".
  - Fans: rpm, target, mode, and which app owns them.
  - AlDente: current state, read through Shortcuts.
- **History window:** Swift Charts for battery temperature, hottest die, fan rpm, charge %, and charging state as a shaded band. Time ranges: 1 h, 24 h and 7 d.
- **Storage:**
  - 1 Hz samples kept for 24 h.
  - 1-minute averages kept for 30 days.
- **Debug view:** raw SMC key list (the same output as `smcprobe dump`).

### 5.2 Fan control (M3)

**How the fan speed is decided:** every second, each active *source* proposes a minimum rpm, or nothing. Thermal applies the **highest** proposal. If nothing proposes anything, the fans are handed back to Apple (`F{n}md = 0`). The sources are:
1. **Safety overrides** (always on, cannot be turned off): any die ≥ 95 °C or battery ≥ 36 °C → maximum rpm.
2. **Rules** (§5.3), such as the battery guard.
3. **The active profile's curve**, if it has one.

Apple's own fan logic still runs underneath whenever Thermal hands back. "Highest wins" means Thermal can only add cooling, never remove it.

**Profiles** (selectable from the menu bar; can be switched automatically by power source):

| Profile | Behaviour |
|---|---|
| **Quiet** (default) | No curve. Only rules and safety overrides. Fans are off whenever Apple would have them off. |
| **Balanced** | A curve on the hottest CPU or GPU die: Apple below 70 °C, then 2500 → 4500 rpm between 70 and 90 °C. |
| **Cool** | A curve on the maximum of all dies: Apple below 60 °C, then 3000 → 6000 rpm between 60 and 85 °C. For long renders or gaming. |
| **Fixed** | A set rpm, for testing or for maximum cooling on demand. |
| **Custom** | A user-defined curve on any sensor, group or formula, such as the maximum of GPU and battery. |

**Curve behaviour:**
- Piecewise-linear points, including a "hand back to Apple below X °C" point.
- The "on" and "off" temperatures are 2 °C apart.
- Changes are spread out: at most 250 rpm/s up and 150 rpm/s down.
- Each speed step is held for at least 60 s before going lower.

**Failures:**
- A sensor read fails → that source proposes nothing. If every source fails → hand back to Apple.
- The helper is unreachable → the lease runs out → hand back to Apple.

### 5.3 Rules (M5)
Rules are triggers that propose a minimum rpm. All thresholds are adjustable. These are the defaults.

**Battery guard** (the flagship rule, on the charger only):

| Trigger | Minimum rpm | Release |
|---|---|---|
| Battery ≥ 30 °C | 3000 | ≤ 28 °C, hold at least 60 s |
| Battery ≥ 33 °C | 4500 | ≤ 31 °C |
| Battery ≥ 36 °C (any power source) | Maximum (safety override) | ≤ 33 °C |

**Pre-emptive battery guard:**
- **Trigger:** on the charger, hottest die ≥ 85 °C for 60 s **and** battery ≥ 28 °C → 3000 rpm.
- **Release:** die < 75 °C or battery ≤ 27 °C.
- **Why the battery condition:** heavy load only matters for the battery once heat is actually reaching it. A long compile with the battery at 25 °C does not trigger it.

**How it fits with AlDente:** AlDente's 28 °C heat protection pauses charging, and Thermal's battery guard cools the battery, so charging resumes sooner.

**Cool charging** (a toggle in the popover, requested 2026-11-05; ✅ shipped in M3):
- **Goal:** keep the battery below AlDente's heat-protection temperature (28 °C) whenever AlDente *would charge if not for the temperature*. Charging then stays cool and AlDente's 10-minute heat pauses are avoided, or at least shortened.
- **When it cools** (toggle on, on the charger, battery not full):

  | AlDente state (from the "AlDente State" shortcut) | Thermal |
  |---|---|
  | `HeatProtect` | Cool. Keep **at least the minimum rpm until AlDente resumes**: AlDente only re-checks about 10 min after pausing, so the battery must still be below 28 °C then. |
  | `Charging` | Follow the curve with a **1 °C lead** (acts at 25.5 °C instead of 26.5 °C). Preventing a pause is worth more than recovering from one. |
  | `Sailing` | Fans stay with Apple. Pre-cool only at **resume level + 1%** (e.g. 81% with limit 85% and sailing 5%), so charging can start straight away. |
  | Other (`Discharging`, `Calibration`, …) | Fans stay with Apple. |
  | Shortcut missing or failing | Fallback that infers the state: a charging session lasts from "charging seen or charge ≤ resume level" until the limit is reached or the Mac is unplugged. Not charging inside a session counts as a heat pause. At launch, a battery at or above `maxTemperature` below the limit counts as a heat pause. |

- **Target:** AlDente's `maxTemperature` when its heat protection is on, otherwise the user's setting.
- **Curve** (re-evaluated every 10 s, *t* = target, 28 °C):

  | Battery | Minimum fan speed |
  |---|---|
  | ≤ t − 1.5 (26.5 °C) | Hand back to Apple, after at least 60 s at this level (not during `HeatProtect`) |
  | t − 1.5 → t | 2317 (min) → 4000 rpm, linear |
  | t → t + 1.5 | 4000 → *cap* rpm, linear |
  | ≥ t + 1.5 | *cap* (default 6000 rpm, adjustable) |

  Changes are gradual: 250 rpm/s up, 150 rpm/s down.
- **When the target can't be reached:** if Thermal has been at the cap for 15 minutes and the battery is still at or above the target, it shows "Can't reach the target here" in the popover. A system notification is planned for M5.
- **Status in the popover:**
  - for example "Cool charging: battery 28.4 °C → 27 °C · 3400 rpm";
  - "AlDente: limit 85% · charges again at 80% · heat protection 28 °C";
  - "AlDente now: Paused by heat protection".
- **Combining with other rules:** like every source, it proposes a minimum fan speed and the highest wins (§5.2).

**Notifications:** a notification when a rule or safety override fires, at most once per rule every 30 minutes.

**Later, not in v1:** charging rules that call AlDente's `StopCharging`/`StartCharging`. They would only come in if we ever take heat protection over from AlDente. (Reading AlDente's state through Shortcuts arrived early, with Cool charging in M3.)

### 5.4 Why these targets

**Battery:**
- Ageing roughly doubles with every 10 °C, and it is worst at a high charge level.
- 15–30 °C is the target range; long periods above 35 °C are what we want to avoid.
- Charging below about 10–15 °C risks metal building up inside the cell, but that never happens in practice on this machine.
- The highest-value fan time is **on the charger, at a high charge, under load**.

**CPU and GPU:**
- Designed for junction temperatures around 100 °C or more. Apple only slows the chip down at around 100–105 °C.
- Wear-out at 85 °C versus 95 °C is negligible over a laptop's life. Running cooler only gains a bit of efficiency and sustained clock speed.
- So the die temperature mainly matters as a warning that the battery and case are about to warm up, or when you pick a cooler profile.

**Fans:**
- Rated lives are in the tens of thousands of hours. Wear and dust grow with speed and running time.
- The real costs are noise, dust and start/stop cycling, not sudden failure.
- Hence: fans off at idle, boosts only when they help, hold times, and a gap between "on" and "off" temperatures.

## 6. Milestones

| # | Milestone | Done when |
|---|---|---|
| M0 | ✅ Read-only probe | Done (`smcprobe/`) |
| M1 | ✅ Fan write test (`smcprobe/fantest.c`, run with sudo, 2026-11-05) | Done: mode plus target is enough, `FEna`/`FPSt` are firmware status, clamping and hand-back work. Sleep/wake moved to M3. |
| M2 | 🚧 Read-only monitoring app | **Done:** menu bar readout, popover, history (SQLite, 1 h/24 h/7 d/30 d charts) and raw SMC view. Measured 0.5% of one core at 1 Hz, about 75 MB of memory. **Still to do:** a full-day run without gaps, and the CPU/GPU die mapping test. Alerts move to M5, configurable menu bar text to later. |
| M3 | ✅ Helper plus fan control, cool charging (branch `m3/fan-helper`) | **Done and tested live (2026-11-05):**<br>• Fan helper running as root, approved in Login Items.<br>• Cool charging following AlDente's live state.<br>• Safety overrides.<br>• Highest request wins, with gradual ramps.<br>• Fandy check.<br>**Fail-safes, all measured live:**<br>• `kill -9` → fans back to Apple in 0.03 s.<br>• Frozen app → lease expiry after 10.0 s.<br>• Sleep → handed back before sleep, taken over again within 1 s of wake.<br>**Moved to M5:** profiles (Balanced, Cool, Fixed, Custom curves), the battery guard tiers and the pre-emptive rule. |
| M4 | AlDente status (read-only) | The popover shows AlDente's state and charge limit, read through its `GetState`/`GetChargeLimit` Shortcuts. If those are unavailable, it falls back to `NotChargingReason`. It shows "paused by AlDente (heat or limit)" when relevant. |
| M5 | Combined rules plus notifications | The rules in 5.3 run for a week. Fans are back under Apple's control whenever no rule is active. |
| M6 | *(optional)* Own charging | `PowerUIBackend` and `CHIE` discharge behind the same `ChargingBackend` interface. Only after M5 is stable, and only if we choose to stop depending on AlDente. |

## 7. Build and tooling

- Swift 6 and SwiftUI. Requires macOS 27.
- Three parts:
  - `ThermalApp`
  - `FanHelper`
  - `SMCKit`, a shared Swift package holding the probe code ported to Swift.
  - Optionally a `thermctl` command-line tool for debugging.
- **Currently installed:** only the Command Line Tools. No Xcode, and **no code-signing identity**.
- **Chosen (decision Q4):**
  - Install Xcode, sign with a free Apple ID personal team, and register the helper with `SMAppService.daemon`.
  - You approve the helper once in System Settings › Login Items.
  - Free-team certificates expire after a while, so expect to rebuild and re-sign occasionally.
- **Fallback if signing gets in the way:** an install script places the helper plist in `/Library/LaunchDaemons` using `sudo`. The XPC caller check then uses code-directory hashes instead of a team ID.
- **M1 does not need Xcode.** It is a command-line tool built with `clang` and run with `sudo`, like the probe.
- Development happens in a git repository. The session needs to move to a real folder first.

## 8. Risks

| Risk | Mitigation |
|---|---|
| A macOS update renames SMC keys again | Capability detection, features turn off instead of guessing, the probe is kept as a diagnostic |
| Apple starts enforcing the entitlement on `PowerUIAgent` | Charging control fails inside AlDente, not our app. Our app checks charging state and reports when a request doesn't take effect. |
| AlDente's own logic overrides our Stop/Start requests | Test in M4. The fallback is that AlDente keeps heat protection and our app only handles fans. |
| Fans stuck in manual mode after a crash | Lease plus hand-back on helper start, exit and sleep |
| Fans wearing out from constant high speeds | Default to Apple's control. Boost only through the rules. |

## 9. Decisions (2026-11-05)

| # | Question | Decision |
|---|---|---|
| Q1 | Name | **Thermal**. Bundle ID placeholder `dev.streller.thermal`, helper `dev.streller.thermal.fanhelper`. |
| Q2 | Heat protection owner | **AlDente keeps it** (28 °C). Thermal does not control charging in v1. |
| Q3 | Fan approach | **Quiet.** Apple controls the fans by default. Thermal steps in only through rules or curves, then hands back. |
| Q4 | Signing | **Xcode with a free Apple ID personal team.** Fallback: install script. |
| Q5 | History and export | Default: 1 Hz for 24 h, 1-minute averages for 30 days. No export in v1. |
| Q6 | Sleep | Default: always hand the fans back to Apple before sleep. Rules re-evaluate after wake. |

Q5 and Q6 were not asked explicitly and use the defaults. Change them here if you disagree.

**Before M3:** quit Fandy and remove it from Login Items (or uninstall it). Its helper takes the fans back as soon as the Fandy app runs.
