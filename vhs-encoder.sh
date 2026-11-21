#!/usr/bin/env bash
# Encoder: vhs-encoder.sh <n>. Only encodes. Takes the oldest staged job (already uploaded to the GPU box),
# encodes it there and hands it back to the manager. GPU decode first, CPU decode as fallback;
# retry jobs use CPU decode and no B-frames. Usually started by vhs-start.sh.
set -u
W=$1
source "$(dirname "$(readlink -f "$0")")/vhs-lib.sh"
exec 8>"$P/enc$W.lock"; flock -n 8 || { echo "encoder $W already running"; exit 1; }
log "started_e$W\t$(date)"
while :; do
  stopping && { log "stopped_e$W\t$(date)"; exit 0; }
  j=""
  for f in $(ls "$P/staged" | grep -v '\.tmp$' | sort); do
    mv "$P/staged/$f" "$P/encoding/$f" 2>/dev/null && { j=$P/encoding/$f; break; }
  done
  if [ -z "$j" ]; then
    pgrep -f 'vhs-manager[.]sh' >/dev/null || { log "finished_e$W\t$(date)"; exit 0; }
    sleep 2; continue
  fi
  echo "enc=e$W" >>"$j"
  unset id lext oext mux acodec mode; source "$j"
  t0=$(date +%s)
  if [ "$mode" = retry ]; then E=$ENC_RETRY; else E=$ENC; fi
  CMD="-map 0:v:0 -map 0:a? -map 0:s? $E $acodec -c:s copy $mux -map_metadata 0 out.$oext"
  dec=""
  if [ "$mode" != retry ] && rsh "cd ~/$RJ/$id && ffmpeg -nostdin -v error -y $HW -i in.$lext $CMD"; then dec=gpu
  elif rsh "cd ~/$RJ/$id && ffmpeg -nostdin -v error -y -i in.$lext $CMD"; then dec=cpu
  fi
  if [ -n "$dec" ]; then
    printf 'dec=%s\nenc_s=%s\n' "$dec" $(( $(date +%s)-t0 )) >>"$j"; mv "$j" "$P/encoded/"
  else
    mv "$j" "$P/failed/"
  fi
done
