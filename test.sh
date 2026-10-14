#!/bin/sh
# Runs the whole test suite. Extra arguments are passed to odin test.
# Set ODIN to use another odin compiler.
set -e
cd "$(dirname "$0")"
./build.sh
# The end-to-end tests render the compiled form of tests/templates.
./bin/frigg -r -import:./frigg tests/templates
"${ODIN:-odin}" test compiler "$@"
"${ODIN:-odin}" test tests "$@"
