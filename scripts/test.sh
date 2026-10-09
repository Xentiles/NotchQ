#!/bin/zsh
set -euo pipefail
NOTCHQ_ROOT="${0:A:h:h}"
zsh "$NOTCHQ_ROOT/scripts/build.sh" test
NOTCHQ_TEST="$NOTCHQ_ROOT/dist/NotchQTests.app/Contents/MacOS/NotchQ"
"$NOTCHQ_TEST" --self-test
"$NOTCHQ_TEST" --transport-test "$NOTCHQ_ROOT/Tests/mock-server.py"
"$NOTCHQ_TEST" --lifecycle-test "$NOTCHQ_ROOT/Tests/mock-server.py"
"$NOTCHQ_TEST" --claude-poll-test "$NOTCHQ_ROOT/Tests/mock-claude-usage.py"
# Finder and login-item launches get launchd's minimal PATH; detection must still work.
echo "Detection with a minimal launch PATH:"
env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin:/usr/sbin:/sbin "$NOTCHQ_TEST" --detection-report
# Exercise the Intel slice of the universal binary when Rosetta is available.
# The Python fixture servers cannot start from a translated parent (the Command Line
# Tools python3 shim is arm64-only), so the process-fixture suites run natively only.
if /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
  echo "Intel (Rosetta) pass:"
  /usr/bin/arch -x86_64 "$NOTCHQ_TEST" --self-test
  env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/arch -x86_64 "$NOTCHQ_TEST" --detection-report
fi
