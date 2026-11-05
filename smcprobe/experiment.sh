#!/bin/zsh
# Snapshot every SMC key, let you change ONE thing (e.g. AlDente "Pause charging"),
# snapshot again, and show which keys changed. Read-only: only runs `smcprobe dump`.
#
#   ./experiment.sh "aldente-pause"
#
# Noisy keys (temperatures, currents, voltages, fan rpm) change on their own, so the
# script takes five baseline dumps first and ignores keys that change between them.
set -e
cd "${0:A:h}"
name=${1:-experiment}
dir=runs/$name; mkdir -p $dir
for i in 1 2 3 4 5; do echo "Baseline $i/5..."; ./smcprobe dump > $dir/base$i.txt; sleep 2; done
read "?Now make your ONE change (wait ~5 s after it takes effect), then press Enter... "
./smcprobe dump > $dir/after.txt
# Keys that change by themselves between the two baselines.
noisy=$(for i in 2 3 4 5; do diff <(awk '{print $1, $4}' $dir/base1.txt) <(awk '{print $1, $4}' $dir/base$i.txt) | awk '/^[<>]/{print $2}'; done | sort -u)
echo "\n== Keys changed by your action (excluding $(echo $noisy | wc -w | tr -d ' ') noisy keys) =="
echo "$noisy" > $dir/noisy.txt
awk '
  FILENAME == ARGV[1] { skip[$1] = 1; next }
  FILENAME == ARGV[2] { before[$1] = $4; type[$1] = $2; next }
  !($1 in skip) && ($1 in before) && before[$1] != $4 { printf "  %-4s %-4s  %s -> %s\n", $1, type[$1], before[$1], $4; hit = 1 }
  END { if (!hit) print "  (no non-noisy key changed)" }
' $dir/noisy.txt $dir/base5.txt $dir/after.txt
echo "\nRaw dumps saved in $dir/"
