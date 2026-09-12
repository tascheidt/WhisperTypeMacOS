#!/bin/sh
set -eu

parent_pid="$1"
shift
engine="$1"
shift

engine_pid=""
cleanup() {
    if [ -n "$engine_pid" ] && kill -0 "$engine_pid" 2>/dev/null; then
        kill -TERM "$engine_pid" 2>/dev/null || true
        wait "$engine_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

"$engine" "$@" &
engine_pid=$!

while kill -0 "$parent_pid" 2>/dev/null; do
    if ! kill -0 "$engine_pid" 2>/dev/null; then
        wait "$engine_pid"
        exit $?
    fi
    sleep 1
done
