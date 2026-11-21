#!/usr/bin/env bash
# Manager (run one copy). Keeps the encoders fed and does everything except encoding:
#   staging:   claim the next file, probe it, upload it to the box, test-encode a sample from the middle
#              (SAMPLE_SECONDS long, for files over SAMPLE_MIN_DURATION) and skip files that save under MIN_GAIN_PCT
#   finishing: download the result, check duration, tail decode and size, replace the original, clean the box
#   failures:  first failure goes to retry.txt (CPU decode, no B-frames); a second failure keeps the original
# Box disk: at most READY_MAX staged files, at most BOX_JOBS_MAX bytes, never below BOX_FREE_MIN free,
# and every job dir is deleted on the box as soon as its result is downloaded or it fails.
set -u
source "$(dirname "$(readlink -f "$0")")/vhs-lib.sh"
exec 8>"$P/mgr.lock"; flock -n 8 || { echo "manager already running"; exit 1; }
PENDING=""; PMODE=""; EXHAUSTED=0

njobs(){ find "$@" -maxdepth 1 -name 'j*' ! -name '*.tmp' | wc -l; }
jobwrite(){ local k; for k in id src lext oext mux acodec dur s1 mode; do printf '%s=%q\n' "$k" "${!k}"; done; }

fail(){  # fail <reason text> ; uses $src $mode $id
  rsh "rm -rf ~/$RJ/$id"
  if [ "$mode" = normal ]; then locked push_retry "$src"; log "retry_queued\t$1\t$src"
  else log "fail_final\t$1\t$src"; markdone "$src"; fi
}

recover(){
  if ! pgrep -f 'vhs-encoder[.]sh' >/dev/null; then
    for j in "$P"/encoding/j*; do [ -e "$j" ] && sed -i '/^enc=/d' "$j" && mv "$j" "$P/staged/"; done
  fi
  if [ -s "$P/staging" ]; then
    src=$(sed -n 1p "$P/staging"); mode=$(sed -n 2p "$P/staging")
    if [ "$mode" = retry ]; then locked push_retry "$src"; else locked unclaim "$src"; fi
  fi
  rm -f "$P/staging"
  keep=$(ls "$P"/staged "$P"/encoding "$P"/encoded "$P"/failed 2>/dev/null | grep '^j' | tr '\n' ' ')
  rsh "mkdir -p ~/$RJ && cd ~/$RJ && for d in *; do [ -d \"\$d\" ] || continue; case \" $keep \" in *\" \$d \"*) ;; *) rm -rf \"\$d\";; esac; done"
}

box_room(){  # box_room <bytes>
  local used free
  read -r used free < <(rsh "du -sb ~/$RJ | cut -f1; df -B1 --output=avail ~ | tail -1" | tr '\n' ' ')
  [ -n "${free:-}" ] && (( used + $1 <= BOX_JOBS_MAX && free - $1 >= BOX_FREE_MIN ))
}

stage_step(){  # returns 0 if it did something
  local src mode lext ext oext mux acodec codec ch abr tab dur s1 id gain a b ok i
  if [ -n "$PENDING" ]; then src=$PENDING; mode=$PMODE
  else
    src=$(locked pop_retry); mode=retry
    [ -z "$src" ] && { src=$(locked claim_next); mode=normal; }
    [ -z "$src" ] && { EXHAUSTED=1; return 1; }
    EXHAUSTED=0; printf '%s\n%s\n' "$src" "$mode" >"$P/staging"
  fi
  PENDING=""
  [ -f "$src" ] || { log "missing\t$src"; markdone "$src"; rm -f "$P/staging"; return 0; }
  ext="${src##*.}"; lext="${ext,,}"
  case "$lext" in mp4|m4v|mov) mux="-movflags +faststart -tag:v hvc1"; oext=$lext;; mkv) mux=""; oext=mkv;; ts) mux="-movflags +faststart -tag:v hvc1"; oext=mp4;; *) log "skip_container\t$src"; markdone "$src"; rm -f "$P/staging"; return 0;; esac
  codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$src" </dev/null | head -1 | tr -d "[:space:]")
  case " $SOURCE_CODECS " in *" $codec "*) ;; *) log "skip_codec_$codec\t$src"; markdone "$src"; rm -f "$P/staging"; return 0;; esac
  s1=$(stat -c%s "$src")
  box_room "$s1" || { PENDING=$src; PMODE=$mode; return 1; }   # wait for room; finishing frees it
  ch=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of default=nw=1:nk=1 "$src" </dev/null | head -1 | tr -d "[:space:]")
  abr=$(ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of default=nw=1:nk=1 "$src" </dev/null | head -1 | tr -d "[:space:]")
  [ "${ch:-2}" = 1 ] && tab=$AUDIO_MONO_BITRATE || tab=$AUDIO_STEREO_BITRATE
  if [ -z "${ch:-}" ]; then acodec=""; elif [[ "${abr:-N/A}" =~ ^[0-9]+$ ]] && [ "$abr" -le $((tab+16000)) ]; then acodec="-c:a copy"; else acodec="-c:a aac -b:a $tab"; fi
  dur=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$src" </dev/null | head -1 | tr -d "[:space:]")
  id=j$(date +%s%N)
  rsh "mkdir -p ~/$RJ/$id"
  ok=0; for i in 1 2 3; do scp -q "$src" "$BOX:$RJ/$id/in.$lext" </dev/null && { ok=1; break; }; sleep 10; done
  [ $ok = 1 ] || { fail scp_up_fail; rm -f "$P/staging"; return 0; }
  if [ "$mode" = normal ] && awk -v d="$dur" -v m="$SAMPLE_MIN_DURATION" 'BEGIN{exit !(d>m)}'; then
    mid=$(awk -v d="$dur" 'BEGIN{printf "%d", d/2}')
    gain=$(rsh "cd ~/$RJ/$id; ffmpeg -nostdin -v error -y -ss $mid -i in.$lext -t $SAMPLE_SECONDS -map 0:v:0 -c copy samp_src.mkv && (ffmpeg -nostdin -v error -y $HW -i samp_src.mkv -map 0:v:0 $ENC samp_out.mkv || ffmpeg -nostdin -v error -y -i samp_src.mkv -map 0:v:0 $ENC samp_out.mkv) && echo \$(stat -c%s samp_src.mkv) \$(stat -c%s samp_out.mkv); rm -f samp_*")
    read -r a b <<<"$gain"
    if [ -n "${a:-}" ] && [ -n "${b:-}" ] && [ $((b*100)) -gt $((a*(100-MIN_GAIN_PCT))) ]; then
      rsh "rm -rf ~/$RJ/$id"; log "skip_lowgain\t$a\t$b\t$src"; markdone "$src"; rm -f "$P/staging"; return 0
    fi
  fi
  jobwrite >"$P/staged/$id.tmp" && mv "$P/staged/$id.tmp" "$P/staged/$id"
  rm -f "$P/staging"; return 0
}

finish_one(){  # finish_one <jobfile in encoded/>
  local j=$1 id src lext oext mux acodec dur s1 mode enc dec enc_s tmp d2 s2 okdur tailerr ok i final
  source "$j"
  tmp="${src%.*}.shrink-tmp.$oext"
  ok=0; for i in 1 2 3; do scp -q "$BOX:$RJ/$id/out.$oext" "$tmp" </dev/null && { ok=1; break; }; sleep 10; done
  if [ $ok = 0 ]; then rm -f "$tmp"; fail scp_down_fail; rm -f "$j"; return; fi
  rsh "rm -rf ~/$RJ/$id"
  d2=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$tmp" </dev/null | head -1 | tr -d "[:space:]")
  s2=$(stat -c%s "$tmp")
  okdur=$(awk -v a="$dur" -v b="$d2" -v t="$DURATION_TOLERANCE" 'BEGIN{print (a-b<t && b-a<t)?1:0}')
  tailerr=$(ffmpeg -nostdin -v error -sseof -20 -i "$tmp" -f null - 2>&1 | head -3 | tr '\n\t' '  ')
  if [ "$okdur" = 1 ] && [ -z "$tailerr" ] && [ "$s2" -lt "$s1" ]; then
    touch -r "$src" "$tmp"; final="${src%.*}.$oext"
    mv "$tmp" "$final" && { [ "$final" = "$src" ] || rm -f "$src"; }
    log "ok\t$s1\t$s2\t${enc_s}s\t$enc/$dec\t$src"; markdone "$src"
  elif [ "$okdur" = 1 ] && [ -z "$tailerr" ]; then
    rm -f "$tmp"; log "skip_nogain\t$s1\t$s2\t$src"; markdone "$src"
  else
    rm -f "$tmp"; fail "check_fail dur=$dur/$d2 size=$s1/$s2 err=$tailerr"
  fi
  rm -f "$j"
}

release_staged(){  # on STOP: give back files that were uploaded but not started
  local j id src mode
  for j in "$P"/staged/j*; do [ -e "$j" ] || continue; source "$j"; rsh "rm -rf ~/$RJ/$id"
    if [ "$mode" = retry ]; then locked push_retry "$src"; else locked unclaim "$src"; fi; rm -f "$j"; done
  if [ -n "$PENDING" ]; then if [ "$PMODE" = retry ]; then locked push_retry "$PENDING"; else locked unclaim "$PENDING"; fi; PENDING=""; rm -f "$P/staging"; fi
}

log "started_mgr\t$(date)"
recover
while :; do
  did=0
  for j in "$P"/encoded/j*; do [ -e "$j" ] || continue; finish_one "$j"; did=1; done
  for j in "$P"/failed/j*; do [ -e "$j" ] || continue
    ( source "$j"; fail "encode_fail" ); rm -f "$j"; did=1; done
  if stopping; then
    if ! pgrep -f 'vhs-encoder[.]sh' >/dev/null; then
      release_staged
      [ "$(njobs "$P"/encoded "$P"/failed "$P"/encoding)" = 0 ] && { log "stopped_mgr\t$(date)"; exit 0; }
    fi
  elif (( $(njobs "$P/staged") < READY_MAX )); then
    stage_step && did=1
  fi
  if [ $EXHAUSTED = 1 ] && [ -z "$PENDING" ] && [ "$(njobs "$P"/staged "$P"/encoding "$P"/encoded "$P"/failed)" = 0 ] && [ ! -s "$P/retry.txt" ]; then
    log "finished_mgr\t$(date)"; exit 0
  fi
  (( did )) || sleep 5
done
