#!/usr/bin/env bash

set -u

usage() {
  printf 'Usage: %s <file> [timeout_s=540] [interval_s=2]\n' "${0##*/}" >&2
}

[ "$#" -ge 1 ] && [ "$#" -le 3 ] || {
  usage
  exit 2
}

file=$1
timeout_s=${2:-540}
interval_s=${3:-2}

case "$timeout_s" in
  ''|*[!0-9]*) usage; exit 2 ;;
esac
case "$interval_s" in
  ''|0|*[!0-9]*) usage; exit 2 ;;
esac

started=$SECONDS
while [ ! -e "$file" ]; do
  if [ $((SECONDS - started)) -ge "$timeout_s" ]; then
    exit 3
  fi
  sleep "$interval_s"
done

exit 0
