#!/bin/zsh

set -euo pipefail

if [[ $# -lt 4 ]]; then
    print -u2 "Usage: $0 <pid> <duration-seconds> <interval-seconds> <output.csv>"
    exit 64
fi

pid="$1"
duration="$2"
interval="$3"
output="$4"

if [[ ! "$pid" =~ '^[0-9]+$' ]] || ! kill -0 "$pid" 2>/dev/null; then
    print -u2 "Koji PID is not running: $pid"
    exit 65
fi
if [[ ! "$duration" =~ '^[1-9][0-9]*$' ]] || [[ ! "$interval" =~ '^[1-9][0-9]*$' ]]; then
    print -u2 "Duration and interval must be positive whole seconds."
    exit 64
fi

mkdir -p "${output:h}"
print 'timestamp,elapsed_seconds,rss_bytes,cpu_percent' > "$output"

start_epoch="$(date +%s)"
deadline=$((start_epoch + duration))

while true; do
    now="$(date +%s)"
    elapsed=$((now - start_epoch))
    process_sample="$(ps -o rss= -o %cpu= -p "$pid" | awk 'NF == 2 { print $1 "," $2 }')"
    if [[ -z "$process_sample" ]]; then
        print -u2 "Koji exited after ${elapsed}s."
        exit 66
    fi

    rss_kib="${process_sample%%,*}"
    cpu_percent="${process_sample#*,}"
    print "${now},${elapsed},$((rss_kib * 1024)),${cpu_percent}" >> "$output"

    if (( now >= deadline )); then
        break
    fi

    remaining=$((deadline - now))
    sleep_seconds="$interval"
    if (( remaining < interval )); then
        sleep_seconds="$remaining"
    fi
    sleep "$sleep_seconds"
done

print "$output"
