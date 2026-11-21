#!/usr/bin/env bash
# Asks everything to stop. Encoders finish the file they are on; the manager downloads and checks those results,
# hands unstarted files back to the queue, cleans the box and exits. Run vhs-start.sh to continue later.
set -u
source "$(dirname "$(readlink -f "$0")")/vhs-lib.sh"
touch "$DIR/STOP"
echo "Stopping after the current encodes. Running: manager $(pgrep -fc 'vhs-manager[.]sh'), encoders $(pgrep -fc 'vhs-encoder[.]sh')"
