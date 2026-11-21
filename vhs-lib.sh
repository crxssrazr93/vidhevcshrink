# Shared settings and helpers for vidhevcshrink. Sourced by the other scripts, not run.
# Every value comes from .env (see .env.example); the defaults below apply when a value is left out.
ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
ENV_FILE=${VHS_ENV:-$ROOT/.env}
[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE: copy .env.example to .env and edit it" >&2; exit 1; }
set -a; source "$ENV_FILE"; set +a
: "${REMOTE_HOST:?set REMOTE_HOST in $ENV_FILE}"

BOX=$REMOTE_HOST
DIR=${STATE_DIR:-$ROOT/state}; DIR=${DIR/#\~/$HOME}   # local state: queue, logs, job files
P=$DIR/pipe                                           # job state: staged/ encoding/ encoded/ failed/ retry.txt
LOG=$DIR/log.tsv
RJ=${REMOTE_JOBS_DIR:-vidhevcshrink/jobs}             # job folders on the GPU box, relative to its home
ENCODERS=${ENCODERS:-2}
CQ=${CQ:-33}
PRESET=${PRESET:-p5}
SOURCE_CODECS=${SOURCE_CODECS:-h264}
MIN_GAIN_PCT=${MIN_GAIN_PCT:-25}
SAMPLE_SECONDS=${SAMPLE_SECONDS:-60}
SAMPLE_MIN_DURATION=${SAMPLE_MIN_DURATION:-180}
DURATION_TOLERANCE=${DURATION_TOLERANCE:-2}
AUDIO_MONO_BITRATE=${AUDIO_MONO_BITRATE:-64000}
AUDIO_STEREO_BITRATE=${AUDIO_STEREO_BITRATE:-96000}
READY_MAX=${READY_MAX:-2}
BOX_JOBS_MAX=$(( ${REMOTE_JOBS_MAX_GB:-30} * 1024**3 ))
BOX_FREE_MIN=$(( ${REMOTE_FREE_MIN_GB:-40} * 1024**3 ))
MEDIA_ROOT=${MEDIA_ROOT:-}

ENC="-c:v hevc_nvenc -preset $PRESET -tune hq -rc vbr -cq $CQ -b:v 0 -multipass qres -spatial-aq 1 -temporal-aq 1 -rc-lookahead 32 -bf 4 -b_ref_mode middle -g 250"
ENC_RETRY="-c:v hevc_nvenc -preset $PRESET -tune hq -rc vbr -cq $CQ -b:v 0 -multipass qres -spatial-aq 1 -temporal-aq 1 -rc-lookahead 32 -bf 0 -g 250"
HW="-hwaccel cuda -hwaccel_output_format cuda"

mkdir -p "$P"/staged "$P"/encoding "$P"/encoded "$P"/failed
touch "$P/retry.txt" "$DIR/queue.txt" "$DIR/done_abs.txt" "$DIR/claimed.txt" "$DIR/probe.tsv" "$LOG"

log(){ printf '%b\n' "$*" >>"$LOG"; }
rsh(){ ssh -n -o BatchMode=yes -o ServerAliveInterval=30 "$BOX" "bash -c '$1'"; }
stopping(){ [ -e "$DIR/STOP" ]; }
locked(){ exec 9>"$DIR/queue.lock"; flock 9; "$@"; local r=$?; flock -u 9; exec 9>&-; return $r; }
markdone(){ grep -qxF "$1" "$DIR/done_abs.txt" || echo "$1" >>"$DIR/done_abs.txt"; }
claim_next(){  # first queued path not done and not claimed; marks it claimed
  local f; f=$(awk 'FILENAME!=Q{s[$0]=1;next} !($0 in s){print;exit}' Q="$DIR/queue.txt" "$DIR/done_abs.txt" "$DIR/claimed.txt" "$DIR/queue.txt")
  [ -n "$f" ] && echo "$f" >>"$DIR/claimed.txt"; printf '%s' "$f"; }
unclaim(){ grep -vxF "$1" "$DIR/claimed.txt" >"$DIR/claimed.tmp"; mv "$DIR/claimed.tmp" "$DIR/claimed.txt"; }
pop_retry(){ local f; f=$(head -1 "$P/retry.txt"); [ -n "$f" ] && sed -i 1d "$P/retry.txt"; printf '%s' "$f"; }
push_retry(){ echo "$1" >>"$P/retry.txt"; }
