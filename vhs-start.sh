#!/usr/bin/env bash
# Starts the manager and ENCODERS encoders in the background. Safe to run again: parts already running are left alone.
set -u
source "$(dirname "$(readlink -f "$0")")/vhs-lib.sh"
rm -f "$DIR/STOP"
cd "$DIR"
if ! pgrep -f 'vhs-manager[.]sh' >/dev/null; then
  setsid nohup "$ROOT/vhs-manager.sh" >"$DIR/manager.out" 2>&1 </dev/null &
  sleep 2
fi
for w in $(seq 1 "$ENCODERS"); do
  pgrep -f "vhs-encoder[.]sh $w\$" >/dev/null || setsid nohup "$ROOT/vhs-encoder.sh" "$w" >"$DIR/encoder$w.out" 2>&1 </dev/null &
done
sleep 1
echo "manager: $(pgrep -fc 'vhs-manager[.]sh'), encoders: $(pgrep -fc 'vhs-encoder[.]sh'). Watch with $ROOT/vhs-monitor.sh"
