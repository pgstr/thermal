#!/bin/zsh
# Hands-free fan experiment. Read-only.
# Logs fan keys + whether Fandy's app/helper run, once per second, while you:
#   1. quit Fandy,  2. wait ~30 s,  3. reopen Fandy.
# Ends 30 s after Fandy's app is back (or after 10 min). Also dumps all SMC keys
# in each phase so any other fan-related key that flips can be found.
cd "${0:A:h}"
dir=runs/auto-fan; rm -rf $dir; mkdir -p $dir
keys=(F0md F1md F0Tg F1Tg F0Ac F1Ac F0Mn F0St F1St FEna FPSt F0Dc)
state() {
  local app=no helper=no
  pgrep -xq Fandy && app=yes
  pgrep -xq FandyFanHelper && helper=yes
  local vals=$(./smcprobe read $keys | awk '{v = ($5 != "" ? $5 : $4); printf "%s=%s ", $1, v}')
  echo "$(date +%T) app=$app helper=$helper $vals"
}
app_running() { pgrep -xq Fandy; }
for i in 1 2 3; do ./smcprobe dump > $dir/base$i.txt; sleep 1; done
state | tee -a $dir/log.txt
echo "READY — quit Fandy now"
t=0; phase=with-fandy; quit_at=-1; back_at=-1
while (( t < 600 )); do
  s=$(state); echo "$s" >> $dir/log.txt
  if [[ $phase == with-fandy ]] && ! app_running; then phase=quit; quit_at=$t; echo "Fandy quit at $(date +%T)"; fi
  if [[ $phase == quit ]] && (( t - quit_at == 20 )); then ./smcprobe dump > $dir/quit.txt; echo "snapshot without Fandy taken"; fi
  if [[ $phase == quit ]] && (( t - quit_at > 20 )) && app_running; then phase=back; back_at=$t; echo "Fandy back at $(date +%T)"; fi
  if [[ $phase == back ]] && (( t - back_at == 30 )); then ./smcprobe dump > $dir/back.txt; break; fi
  sleep 1; (( t++ ))
done
echo "\n== Fan key timeline (only lines where something other than rpm changed) =="
awk '{ key = $2 " " $3; for (i = 4; i <= NF; i++) if ($i !~ /^F[01](Ac|Dc)=/) key = key " " $i; if (key != prev) print; prev = key }' $dir/log.txt
if [[ -f $dir/quit.txt ]]; then
  noisy=$(for i in 2 3; do diff <(awk '{print $1, $4}' $dir/base1.txt) <(awk '{print $1, $4}' $dir/base$i.txt) | awk '/^[<>]/{print $2}'; done | sort -u)
  echo "$noisy" > $dir/noisy.txt
  echo "\n== Non-noisy keys that differ with vs without Fandy ('*' = back to original after reopening) =="
  awk '
    FILENAME == ARGV[1] { skip[$1] = 1; next }
    FILENAME == ARGV[2] { b[$1] = $4; ty[$1] = $2; next }
    FILENAME == ARGV[3] { q[$1] = $4; next }
    FILENAME == ARGV[4] { r[$1] = $4; next }
    END { for (k in b) if (!(k in skip) && (k in q) && b[k] != q[k])
            printf "  %s %-4s %-4s  %s -> %s -> %s\n", ((k in r) && r[k] == b[k] ? "*" : " "), k, ty[k], b[k], q[k], (k in r ? r[k] : "?") }
  ' $dir/noisy.txt $dir/base3.txt $dir/quit.txt ${dir}/back.txt(N) | sort -k2
fi
