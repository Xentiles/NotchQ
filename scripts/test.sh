#!/bin/zsh
set -euo pipefail
NOTCHQ_ROOT="${0:A:h:h}"
zsh "$NOTCHQ_ROOT/scripts/build.sh" test
NOTCHQ_TEST="$NOTCHQ_ROOT/dist/NotchQTests.app/Contents/MacOS/NotchQ"
"$NOTCHQ_TEST" --self-test
"$NOTCHQ_TEST" --transport-test "$NOTCHQ_ROOT/Tests/mock-server.py"
"$NOTCHQ_TEST" --lifecycle-test "$NOTCHQ_ROOT/Tests/mock-server.py"
