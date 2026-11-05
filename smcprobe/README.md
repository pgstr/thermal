# smcprobe

Diagnostic tools for the battery, the SMC and the HID temperature sensors on Apple Silicon:
- **`smcprobe`** is read-only. Its code has no write path at all.
- **`fantest`** is the M1 fan write test. It can write only `F0md`, `F1md`, `F0Tg`, `F1Tg` and `FEna`, and it always hands the fans back to Apple when it exits.

Raw dumps from the experiment scripts go to `runs/`, which git ignores because they contain device serial numbers. The summaries are in [../docs/evidence/](../docs/evidence/).

```bash
make                      # builds smcprobe and fantest
./smcprobe                # summary
./smcprobe dump           # every SMC key: KEY TYPE SIZE HEX DECODED
./smcprobe read CHIE F0md # specific keys
./smcprobe watch CHIE CHSC CHCC F0md F0Tg   # print on change, Ctrl-C to stop
./smcprobe hid            # named temperature sensors
./experiment.sh aldente-pause   # which keys does one action change?
```

## Findings on Mac17,9 (M5 Pro), macOS 27.3, 2026-11-05

**System**
- 3613 SMC keys. Integers are little-endian (B0DC = 6249 = DesignCapacity). Only `#KEY` is big-endian.
- No admin rights are needed to read anything.

**Battery**
- Battery temperature comes from `TB0T`, `TB1T` and `TB2T` (`flt`, °C). These match the HID "gas gauge battery" sensors.
- The IORegistry `Temperature` field is no longer reliable on macOS 27.

**Charging control**
- `CHTE`, `CH0B`, `CH0C`, `CHWA` and `BCLM` are **absent**.
- `CHIE` (force discharge) is present.
- **AlDente does not pause charging through the SMC on this Mac.** Observed in the system log while pressing Pause charging (`auto-charge-experiment.sh` plus `log show`):
  1. AlDente sends a request over XPC to `com.apple.powerui.smartChargeManager`. That is `/usr/libexec/PowerUIAgent`, which runs as root and comes from the private `PowerUI.framework`.
  2. AlDente requests a "Manual Charge Limit" (MCL). It first asks for 80, then PowerUIAgent logs "Limiting charging to 26% SoC", which is the current charge level and so acts as a pause.
  3. PowerUIAgent passes an "SOC limit" to `powerd`. `powerd` then reports the state "Charging Completed Limited" with `CHNC:1000`, which shows up in the IORegistry as `NotChargingReason = 4096`.
  4. On resume, AlDente requests MCL 100 and PowerUIAgent clears the limit token.
- PowerUIAgent logs **"Client does not have necessary entitlement"** for AlDente but still honours the request. A future macOS update could start enforcing this, so the route is fragile.
- AlDente's own strings agree:
  - It contains several backends: `PowerUIBackend`, `TahoeSMCBackend`, `GoldenGateSMCBackend` and `LegacyIntelSMCBackend`.
  - One message reads: "Tahoe SMC backend only supports discharge on macOS 27 or newer".
- While paused, `CHSC` goes 1→0 and `CHNC` becomes `…01…`. These are most likely status that reflects the pause, not the switch that causes it.

**Fans**
- 2 fans. Min 2317 rpm, max 7826 rpm.
- `F0Md` and `Ftst` are absent. The mode key is lowercase `F0md`/`F1md` (`ui8`).
- **Confirmed with `auto-fan-experiment.sh`** (quit Fandy at 17:16:36, reopened at 17:17:37):

  | Key | Fandy running (manual) | Fandy quit (Apple auto) |
  |---|---|---|
  | `F0md`/`F1md` | 1 | 0 |
  | `F0Tg`/`F1Tg` | Fandy's curve, 3600–5000 rpm | 0 |
  | `FEna` | 07 | 00 |
  | `FPSt` | 3 | 0 (1 while starting) |
  | `F0St`/`F1St` | 5 (running) | 2 (spinning down), then 3 (stopped) |

- **Quitting:** within 1 s of quitting, the fans go back to Apple's control. At these temperatures Apple **stops the fans completely**: 0 rpm within 5 s. Fandy's background helper keeps running but releases the fans, so the hand-back is clean.
- **Reopening:** Fandy takes control again about 6 s after opening. It raises the target speed by about 240 rpm per second, from 2516 to 5038. The fans start from standstill in about 4 s.
- **No unlock step:** there is no `Ftst`-style unlock on M5. Taking over is mode 1 plus a target speed.
- **M1 write test (`sudo ./fantest run`, 17:29–17:31, Fandy quit). Log: [../docs/evidence/m1-fantest.log](../docs/evidence/m1-fantest.log).**
  - **Mode plus target is enough.** Writing `F{n}md = 1` and `F{n}Tg = <rpm>` works with no unlock step.
  - **`FEna`/`FPSt` are status set by the firmware.** Within 1 s of `md = 1` they changed by themselves to 07 and 3. Never write them.
  - **Mode alone starts the fans.** `md = 1` without a target makes the firmware pick its own target (3758 rpm). The fans spin up from standstill in about 4 s.
  - **Speed tracking is fast and accurate.** Actual rpm follows the target within ±10 rpm, and settles 1–2 s after a change: 3000→4500 took about 1 s, 4500→2317 about 3 s. The firmware does not smooth changes much, so Thermal must do its own gradual ramping.
  - **Clamping works.** A request for 1000 rpm, clamped to the 2317 minimum, held steady at about 2317.
  - **Hand-back is immediate.** `md = 0` → the target goes to 0 and `FEna`/`FPSt` go to 0 within 1 s. The fans spin down (`St` 2) and stop (`St` 3) after about 6 s.
  - Fandy's background helper (with the app quit) did not interfere.
- **Not tested yet:**
  - **Sleep and wake:** does manual mode survive sleep?
  - **Process exit without hand-back:** does manual mode stay when the controlling process dies? Assume yes. This is why the helper needs the lease.
  - **Writes without root:** not tried, and expected to fail.
- **Recovery:** if the fans ever stay in manual mode, `sudo ./fantest auto` hands them back to Apple.

**HID sensors**
- 76 temperature services:
  - PMU `tdie1..14` (CPU/GPU die areas)
  - `tcal`
  - NAND
  - gas gauge battery
- The `PMU tdevN` channels report about −9200 °C (unused) and are filtered out.
