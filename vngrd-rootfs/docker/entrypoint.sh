#!/bin/sh -e

: "${KISS_ROOT:=/out}"
: "${KISS_PATH:=/packages}"

export KISS_ROOT KISS_PATH

mkdir -p "$KISS_ROOT"

exec "$@"
