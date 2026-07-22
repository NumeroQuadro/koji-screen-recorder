#!/bin/zsh

set -euo pipefail

if [[ $# -ne 1 ]]; then
    print -u2 "Usage: $0 <recording.mov|recording.mp4>"
    exit 64
fi

recording="$1"
if [[ ! -f "$recording" ]]; then
    print -u2 "Recording does not exist: $recording"
    exit 66
fi

ffprobe_bin="${FFPROBE:-$(command -v ffprobe || true)}"
if [[ -z "$ffprobe_bin" ]]; then
    print -u2 "ffprobe is required for validation metadata. Set FFPROBE to its path."
    exit 69
fi

exec "$ffprobe_bin" \
    -v error \
    -show_entries 'format=format_name,duration,size:stream=index,codec_type,codec_name,width,height,r_frame_rate,avg_frame_rate,sample_rate,channels,duration' \
    -of json \
    "$recording"
