#!/usr/bin/env bash
# Live progress: vhs-monitor.sh [refresh_seconds]   (Ctrl+C quits)
# Read only: it never touches the queue, the workers or any video.
source "$(dirname "$(readlink -f "$0")")/vhs-lib.sh"
INT=${1:-10}
CACHE=$DIR/.remaining_cache   # "epoch files bytes" for the unprocessed queue, refreshed every 5 min

hb() { numfmt --to=iec --suffix=B --format=%.1f "${1:-0}"; }
hms() { local s=${1:-0}; printf '%dd %02dh%02dm' $((s/86400)) $((s%86400/3600)) $((s%3600/60)); }
bar() { local p=$1 w=${2:-50} f; f=$((p*w/1000)); ((f>w)) && f=$w; printf '['; printf '%*s' "$f" '' | tr ' ' '#'; printf '%*s' $((w-f)) '' | tr ' ' '.'; printf ']'; }
short() { local s=$1; [ -n "$MEDIA_ROOT" ] && s=${s#"${MEDIA_ROOT%/}"/}; ((${#s}>95)) && s="${s:0:40}…${s: -54}"; printf '%s' "$s"; }

remaining() {  # files and bytes still waiting in the queue (not done, not in flight)
  local now; now=$(date +%s)
  if [[ -f $CACHE ]] && (( now - $(cut -d' ' -f1 "$CACHE") < 300 )); then cut -d' ' -f2- "$CACHE"; return; fi
  local r
  # files, bytes and seconds of video still waiting (sizes and durations from probe.tsv, written by vhs-enqueue.sh)
  r=$(grep -vxF -f "$DIR/done_abs.txt" -f "$DIR/claimed.txt" "$DIR/queue.txt" | awk -F'\t' -v P="$DIR/probe.tsv" '
      BEGIN{while((getline l < P)>0){split(l,c,"\t"); sz[c[3]]=c[1]; du[c[3]]=c[2]}}
      {n++; b+=sz[$0]; d+=du[$0]} END{printf "%d %d %d\n", n, b, d}')
  echo "$now $r" > "$CACHE"; echo "$r"
}

REMOTE="J=~/$RJ; "'for d in $J/j*; do [ -d $d ] || continue; i=$(ls $d/in.* 2>/dev/null | head -1); o=$(ls $d/out.* 2>/dev/null | head -1)
  echo "job ${d##*/} $( [ -n "$i" ] && stat -c %s $i || echo 0) $( [ -n "$o" ] && stat -c "%s %Y" $o || echo "0 0")"; done
for p in $(pgrep -x ffmpeg); do c=$(readlink /proc/$p/cwd); case $c in $J/*) ;; *) continue;; esac
  m=$(tr "\0" " " </proc/$p/cmdline); case "$m" in *samp_src.mkv*) st=sample;; *" -i in."*) st=encode;; *) st=cut;; esac; pos=0
  for fd in /proc/$p/fd/*; do case $(readlink $fd) in */in.*) pos=$(awk "/^pos/{print \$2}" /proc/$p/fdinfo/${fd##*/});; esac; done
  echo "ff ${c##*/} $st $pos $(stat -c %Y /proc/$p)"; done
echo "BOXDISK $(du -sb $J 2>/dev/null | cut -f1) $(df -B1 --output=avail ~ | tail -1)"
echo "GPU $(nvidia-smi --query-gpu=utilization.encoder,utilization.decoder,temperature.gpu,power.draw --format=csv,noheader,nounits | tr -d " ")"'
P=$DIR/pipe
jget(){ sed -n "s/^$2=//p" "$1" | head -1; }
jsrc(){ local v; v=$(jget "$1" src); eval "printf %s $v"; }

FRAME=$(mktemp); trap 'rm -f "$FRAME"; printf "\033[?25h"' EXIT; trap 'exit' INT TERM
printf '\033[2J\033[?25l'   # clear once, hide cursor
while :; do
  now=$(date +%s)
  # Totals from the log
  read -r nok s1 s2 < <(awk -F'\t' '$1=="ok"{n++;a+=$2;b+=$3} END{print n+0, a+0, b+0}' "$LOG")
  nskip=$(grep -c '^skip_' "$LOG"); nfail=$(grep -c '^fail_final' "$LOG")
  # Throughput from the last 30 ok lines: original bytes and seconds of video per worker second, times active workers
  read -r rb rv rs < <(awk -F'\t' -v P="$DIR/probe.tsv" '
      BEGIN{while((getline l < P)>0){split(l,c,"\t"); du[c[3]]=c[2]}}
      $1=="ok" && ($6 in du){sub("s","",$4); k=n++%30; a[k]=$2; v[k]=du[$6]; t[k]=$4}
      END{for(i in a){x+=a[i]; z+=v[i]; y+=t[i]} printf "%d %d %d\n", x, z, y}' "$LOG")
  workers=$(pgrep -fc 'vhs-encoder[.]sh')
  rate=$(( rs>0 ? rb*workers/rs : 0 ))
  vrate100=$(( rs>0 ? rv*workers*100/rs : 0 ))   # video seconds per wall second, x100
  qtot=$(wc -l < "$DIR/queue.txt"); ndone=$(wc -l < "$DIR/done_abs.txt")
  read -r rfiles rbytes rvid < <(remaining)
  eta=$(( vrate100>0 ? rvid*100/vrate100 : 0 ))
  ratio=$(( s1>0 ? s2*100/s1 : 0 ))
  doneb=$s1; allb=$((s1+rbytes)); pct=$(( allb>0 ? doneb*1000/allb : 0 ))
  free=$(df -B1 --output=avail "${MEDIA_ROOT:-$DIR}" | tail -1)

  rem=$(ssh -n -o BatchMode=yes -o ConnectTimeout=4 $BOX "bash -c '$REMOTE'" 2>/dev/null)

  {
  printf 'vidhevcshrink monitor   %s   (refresh %ss, Ctrl+C quits)   encoders running: %s\n\n' "$(date +%H:%M:%S)" "$INT" "$workers"
  printf '  %s %3d.%d%% by size\n\n' "$(bar $pct)" $((pct/10)) $((pct%10))
  printf '  Files       %d handled of %d queued (%d shrunk, %d skipped, %d failed), %d waiting\n' "$ndone" "$qtot" "$nok" "$nskip" "$nfail" "$rfiles"
  printf '  Shrunk      %s -> %s (%d%% of original), saved %s\n' "$(hb $s1)" "$(hb $s2)" "$ratio" "$(hb $((s1-s2)))"
  printf '  Waiting     %s of originals, %d h of video; at this ratio that frees about %s more\n' "$(hb $rbytes)" $((rvid/3600)) "$(hb $((rbytes*(100-ratio)/100)))"
  printf '  Speed       %s/s of originals, %d.%dx real time (last 30 files, %s workers)\n' "$(hb $rate)" $((vrate100/100)) $((vrate100%100/10)) "$workers"
  printf '  ETA         %s (about %s), from hours of video left; skips will shorten it\n' "$(hms $eta)" "$(date -d @$((now+eta)) '+%a %d %b %H:%M')"
  printf '  Disk free   %s\n' "$(hb $free)"
  gpu=$(grep '^GPU' <<<"$rem" | cut -d' ' -f2)
  [[ -n $gpu ]] && IFS=, read -r ge gd gt gp <<<"$gpu" && printf '  GPU box     NVENC %s%%, NVDEC %s%%, %s C, %s W\n' "$ge" "$gd" "$gt" "$gp"
  [[ -z $rem ]] && printf '  GPU box     unreachable\n'
  echo

  read -r _ bj bf < <(grep '^BOXDISK' <<<"$rem")
  nst=$(find "$P/staged" -name 'j*' ! -name '*.tmp' | wc -l)
  printf '  Pipeline    %d uploaded and ready, box holds %s for this job (cap %d GiB), box free %s\n\n' "$nst" "$(hb $bj)" $((BOX_JOBS_MAX/1024**3)) "$(hb $bf)"
  # Manager
  printf '  Manager     '
  up=$(pgrep -af "scp -q .* $BOX:$RJ/" | head -1); down=$(pgrep -af "scp -q $BOX:$RJ/" | head -1)
  samp=$(grep '^ff .* sample ' <<<"$rem" | head -1)
  if [[ -n $down ]]; then
    id=$(grep -o 'jobs/j[0-9]*' <<<"$down" | cut -d/ -f2); f=$(ls "$P"/encoded/$id 2>/dev/null)
    t=$(sed -E "s|.*:$RJ/[^ ]* ||" <<<"$down"); got=$(stat -c %s "$t" 2>/dev/null)
    read -r _ _ _ osz _ < <(grep "^job $id " <<<"$rem")
    p=$(( osz>0 && got>0 ? got*1000/osz : 0 ))
    printf 'downloading %s %d.%d%%  %s of %s\n            %s\n' "$(bar $p 30)" $((p/10)) $((p%10)) "$(hb $got)" "$(hb $osz)" "$(short "$(jsrc "$f")")"
  elif [[ -n $up ]]; then
    f=$(sed -E "s|^[0-9]+ scp -q (.*) [^ ]+:$RJ/.*|\\1|" <<<"$up"); tot=$(stat -c %s "$f" 2>/dev/null)
    id=$(grep -o 'jobs/j[0-9]*' <<<"$up" | cut -d/ -f2); read -r _ _ isz _ < <(grep "^job $id " <<<"$rem")
    p=$(( tot>0 && isz>0 ? isz*1000/tot : 0 ))
    printf 'uploading   %s %d.%d%%  %s of %s\n            %s\n' "$(bar $p 30)" $((p/10)) $((p%10)) "$(hb $isz)" "$(hb $tot)" "$(short "$f")"
  elif [[ -n $samp ]]; then
    printf "test-encoding a $SAMPLE_SECONDS s sample (skips the file if it saves under $MIN_GAIN_PCT%%)\n            %s\n" "$(short "$(sed -n 1p "$P/staging" 2>/dev/null)")"
  elif [[ -s $P/staging ]]; then
    printf 'probing, or waiting for box room / a free ready slot\n            %s\n' "$(short "$(sed -n 1p "$P/staging")")"
  elif pgrep -f 'vhs-manager[.]sh' >/dev/null; then
    printf 'idle (ready slots full, nothing to download)\n'
  else printf 'not running\n'; fi
  echo
  # Encoders
  for w in $(seq 1 "$ENCODERS"); do
    printf '  Encoder %d   ' "$w"
    f=$(grep -lx "enc=e$w" "$P"/encoding/j* 2>/dev/null | head -1)
    if [[ -z $f ]]; then pgrep -f "vhs-encoder[.]sh $w" >/dev/null && printf 'waiting for a ready file\n' || printf 'not running\n'; echo; continue; fi
    id=${f##*/}; read -r _ _ isz osz _ < <(grep "^job $id " <<<"$rem"); read -r _ _ st pos pst < <(grep "^ff $id " <<<"$rem")
    mode=$(jget "$f" mode)
    p=$(( isz>0 && pos>0 ? pos*1000/isz : 0 )); el=$(( pst>0 ? now-pst : 0 )); e=$(( p>20 ? el*(1000-p)/p : 0 ))
    printf 'encoding%s %s %d.%d%%  out %s so far, %s elapsed, about %s left\n            %s\n' "$([[ $mode == retry ]] && echo ' (retry, CPU decode)')" "$(bar $p 30)" $((p/10)) $((p%10)) "$(hb $osz)" "$(hms $el)" "$(hms $e)" "$(short "$(jsrc "$f")")"
    echo
  done

  echo '  Last results:'
  tail -n 40 "$LOG" | awk -F'\t' '$1=="ok"{printf "    ok    %7.0f MB -> %6.0f MB (%2d%%) %6s  %s\n", $2/2^20, $3/2^20, $3*100/$2, $4, substr($6, length($6)>70?length($6)-69:1)} $1!="ok" && $1!="" && $1!~/^(started|stopped|finished|switch)/{printf "    %-5s %s\n", substr($1,1,12), substr($NF, length($NF)>90?length($NF)-89:1)}' | tail -6
  [[ -e $DIR/STOP ]] && echo && echo '  STOP file present: workers stop after their current file.'
  } > "$FRAME"
  printf '\033[H'; sed 's/$/\x1b[K/' "$FRAME"; printf '\033[J'
  sleep "$INT"
done
