#!/usr/bin/env bash
# Adds videos to the queue: vhs-enqueue.sh <folder or file>...
# Finds .mp4 .m4v .mov .mkv .ts files, skips ones already queued, and records size and duration for the monitor's ETA.
# The manager decides later which ones to shrink (codec, sample test); queueing never changes a file.
set -u
source "$(dirname "$(readlink -f "$0")")/vhs-lib.sh"
[ $# -gt 0 ] || { echo "usage: $0 <folder or file>..." >&2; exit 1; }
found=$(mktemp); new=$(mktemp); trap 'rm -f "$found" "$new"' EXIT
for a in "$@"; do
  find "$(readlink -f "$a")" -type f \( -iname '*.mp4' -o -iname '*.m4v' -o -iname '*.mov' -o -iname '*.mkv' -o -iname '*.ts' \) \
    ! -name '*.shrink-tmp.*' -print
done | sort -u >"$found"
locked bash -c 'grep -vxF -f "$1" "$2" >"$3"; cat "$3" >>"$1"' _ "$DIR/queue.txt" "$found" "$new"
n=0
while IFS= read -r f <&3; do
  d=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$f" </dev/null | head -1 | tr -d '[:space:]')
  printf '%s\t%s\t%s\n' "$(stat -c%s "$f")" "${d:-0}" "$f" >>"$DIR/probe.tsv"; n=$((n+1))
done 3<"$new"
echo "queued $n new files ($(wc -l <"$found") found, $(wc -l <"$DIR/queue.txt") in the queue)"
