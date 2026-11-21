# vidhevcshrink

Shrink a large H.264 video library to HEVC on an NVIDIA GPU in another machine, over SSH, and replace each original only when the smaller copy has passed its checks.

It was built to shrink about 1,800 lecture and course recordings (445 GB down to 161 GB) from a laptop, using an RTX 3060 in a box on the same network. The laptop keeps the videos and the queue; the GPU box only ever holds a few files at a time.

The encode is **lossy**. At the default quality (`CQ=33`) screen recordings measured VMAF 93 to 96, which is hard to tell from the original at normal viewing, but it is not lossless. Keep a backup of anything you cannot replace, and test a few files at your own `CQ` first.

## What it does with each file

1. Probes it. Only video codecs in `SOURCE_CODECS` (default `h264`) and containers mp4, m4v, mov, mkv and ts are considered; everything else is skipped untouched.
2. Uploads it to the GPU box, if the box has room (see the disk limits below).
3. For files longer than 3 minutes, encodes a 60 second sample from the middle. If the sample saves less than 25%, the file is skipped and the original kept.
4. Encodes the whole file with `hevc_nvenc` (GPU decode, falling back to CPU decode). Audio is copied when already small, otherwise re-encoded to AAC (64k mono, 96k stereo). Subtitles and metadata are copied.
5. Downloads the result next to the original as `name.shrink-tmp.ext` and checks it: duration within 2 seconds of the original, the last 20 seconds decode without errors, and the file is smaller.
6. Only then replaces the original, keeping its modification time. A `.ts` source becomes `.mp4`.
7. Deletes the job folder on the box.

A file that fails is retried once with CPU decode and no B frames. If it fails again, the original is kept and the file is logged as `fail_final`.

## How it is split

* `vhs-manager.sh` runs once and does everything except encoding: queue, probing, upload, the sample test, download, checks, replacing and cleanup.
* `vhs-encoder.sh` runs `ENCODERS` times (default 2) and only encodes. One NVENC chip gives the same total throughput with 1, 2, 3 or 4 encoders running, so the second one only removes the idle gap between files.
* `vhs-monitor.sh` shows live progress, ETA, box disk and GPU use. It only reads.
* `vhs-enqueue.sh`, `vhs-start.sh` and `vhs-stop.sh` are the controls.

## Requirements

**On the machine with the videos:** bash, ffmpeg and ffprobe, ssh and scp, flock (util-linux), awk.

**On the GPU box:** an NVIDIA GPU with NVENC HEVC support (any GeForce from the GTX 10 series on), the NVIDIA driver, ffmpeg built with `hevc_nvenc` and CUDA (`ffmpeg -encoders | grep hevc_nvenc`), and bash. Its login shell can be anything; commands are run through `bash -c`.

**Between them:** SSH key login with no password prompt (`ssh user@box true` must return at once). The network carries every file twice, so a wired gigabit link helps.

## Setup

```
git clone https://github.com/crxssrazr93/vidhevcshrink.git
cd vidhevcshrink
cp .env.example .env
nano .env        # at least REMOTE_HOST
```

Every setting is explained in `.env.example`. `.env` is ignored by git, so your host name and paths stay local.

## Use

```
./vhs-enqueue.sh "/mnt/videos/Course A" /mnt/videos/talks    # folders or single files, as many as you like
./vhs-start.sh
./vhs-monitor.sh                                              # Ctrl+C leaves it running
```

Queueing again is safe: files already in the queue are not added twice, and files already handled are never processed again.

To stop, run `./vhs-stop.sh`. The encoders finish the file they are on, the manager downloads and checks those results, hands files that were uploaded but not started back to the queue, and exits. `./vhs-start.sh` continues where it left off.

If the GPU box loses power or the network drops, uploads and downloads are tried three times, and an encode that was cut off is retried once with CPU decode, so nothing is replaced unchecked. Start the manager again (`./vhs-start.sh`) after a reboot of either machine; at start it removes job folders on the box that no local job refers to.

## Files in the state folder

`STATE_DIR` (default `./state`) holds:

| File | Holds |
| --- | --- |
| `queue.txt` | every queued path, one per line |
| `done_abs.txt` | paths that are finished, skipped or failed for good |
| `claimed.txt` | paths the manager has taken from the queue |
| `log.tsv` | one line per result: `ok`, `skip_codec_*`, `skip_lowgain`, `skip_nogain`, `skip_container`, `missing`, `retry_queued`, `fail_final` |
| `probe.tsv` | size and duration of queued files, for the ETA |
| `pipe/` | job files while a file is staged, encoding or encoded |

To shrink a file again later, remove its line from `done_abs.txt` and `claimed.txt`.

## Tuning

* **Quality and size:** `CQ` (lower is better and bigger). Try a few values on a typical file and compare before a large run.
* **Speed:** `PRESET` from `p1` (fastest) to `p7` (slowest). `p5` with `-multipass qres` was 23% faster than `p7` with full resolution multipass for the same size and almost the same VMAF.
* **What gets skipped:** `MIN_GAIN_PCT`, `SAMPLE_SECONDS`, `SAMPLE_MIN_DURATION`.
* **Box disk:** `REMOTE_JOBS_MAX_GB` caps what the pipeline holds on the box, and `REMOTE_FREE_MIN_GB` stops uploads before the box gets too full.

## License

MIT
