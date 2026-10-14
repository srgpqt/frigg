#!/bin/sh
# Builds the frigg compiler into bin/frigg. Extra arguments are passed to odin,
# e.g. ./build.sh -o:speed. Set ODIN to use another odin compiler.
set -e
cd "$(dirname "$0")"
mkdir -p bin
"${ODIN:-odin}" build compiler -out:bin/frigg "$@"
