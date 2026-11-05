#!/bin/zsh
# Hands-free version of experiment.sh for charging control. Read-only.
# 1. takes baselines while charging,
# 2. waits until charging stops (you press "Pause charging" in AlDente) and dumps,
# 3. waits until charging resumes (you resume in AlDente) and dumps again.
# Reports keys that flipped on pause AND flipped back on resume — the strongest signal.
cd "${0:A:h}"
dir=runs/auto-charge; rm -rf $dir; mkdir -p $dir
charging() { ioreg -rn AppleSmartBattery | grep -q '"IsCharging" = Yes'; }
waitfor() { # $1 = yes|no, $2 = timeout seconds
  local t=0
  while (( t < $2 )); do
    if [[ $1 == yes ]] && charging; then return 0; fi
    if [[ $1 == no ]] && ! charging; then return 0; fi
    sleep 1; (( t++ ))
  done
  return 1
}
charging || { echo "Not charging right now — plug in / resume charging first."; exit 1; }
for i in 1 2 3 4 5; do ./smcprobe dump > $dir/base$i.txt; sleep 2; done
echo "BASELINES DONE — press Pause charging in AlDente now (waiting up to 10 min)"
waitfor no 600 || { echo "Timed out waiting for charging to stop"; exit 1; }
echo "Charging stopped at $(date +%T)"; sleep 4
./smcprobe dump > $dir/paused.txt
ioreg -rn AppleSmartBattery | grep -o '"NotChargingReason"=[0-9]*' > $dir/paused-reason.txt
echo "PAUSED SNAPSHOT DONE — now resume charging in AlDente (waiting up to 10 min)"
waitfor yes 600 || { echo "Timed out waiting for charging to resume"; exit 1; }
echo "Charging resumed at $(date +%T)"; sleep 4
./smcprobe dump > $dir/resumed.txt

noisy=$(for i in 2 3 4 5; do diff <(awk '{print $1, $4}' $dir/base1.txt) <(awk '{print $1, $4}' $dir/base$i.txt) | awk '/^[<>]/{print $2}'; done | sort -u)
echo "$noisy" > $dir/noisy.txt
echo "\nNotChargingReason while paused: $(cat $dir/paused-reason.txt)"
echo "\n== Keys changed on pause (non-noisy) — '*' = reverted on resume =="
awk '
  FILENAME == ARGV[1] { skip[$1] = 1; next }
  FILENAME == ARGV[2] { b[$1] = $4; ty[$1] = $2; next }
  FILENAME == ARGV[3] { p[$1] = $4; next }
  FILENAME == ARGV[4] { r[$1] = $4; next }
  END {
    for (k in b) if (!(k in skip) && (k in p) && b[k] != p[k]) {
      printf "  %s %-4s %-4s  %s -> %s -> %s\n", (r[k] == b[k] ? "*" : " "), k, ty[k], b[k], p[k], r[k]; hit = 1
    }
    if (!hit) print "  (none)"
  }
' $dir/noisy.txt $dir/base5.txt $dir/paused.txt $dir/resumed.txt | sort -k2
