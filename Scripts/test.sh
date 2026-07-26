#!/bin/zsh
# Runs the tests. As long as the Xcode license is not accepted, falls back to
# the Command Line Tools — there, Swift Testing needs explicit
# framework/rpath settings.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! swift --version >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

# Determine the active toolchain — with CLT, Swift Testing needs explicit paths.
ACTIVE="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ "$ACTIVE" != *CommandLineTools* ]]; then
  exec swift test "$@"
fi

FW="$ACTIVE/Library/Developer/Frameworks"
LIB="$ACTIVE/Library/Developer/usr/lib"
exec swift test \
  -Xswiftc -F"$FW" \
  -Xlinker -F"$FW" \
  -Xlinker -rpath -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$@"
