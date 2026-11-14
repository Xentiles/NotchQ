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
# The app must run natively on Apple silicon: both slices present, arm64 preferred, Rosetta refused.
NOTCHQ_TEST_ARCHS=" $(xcrun lipo -archs "$NOTCHQ_TEST") "
[[ "$NOTCHQ_TEST_ARCHS" == *" arm64 "* && "$NOTCHQ_TEST_ARCHS" == *" x86_64 "* ]] || { echo "test build is not universal:$NOTCHQ_TEST_ARCHS" >&2; exit 1; }
[[ $(/usr/libexec/PlistBuddy -c 'Print :LSArchitecturePriority:0' "$NOTCHQ_ROOT/Info.plist") == arm64 ]] || { echo "Info.plist: LSArchitecturePriority must list arm64 first" >&2; exit 1; }
[[ $(/usr/libexec/PlistBuddy -c 'Print :LSRequiresNativeExecution' "$NOTCHQ_ROOT/Info.plist") == true ]] || { echo "Info.plist: LSRequiresNativeExecution must be true" >&2; exit 1; }
# build.sh refuses this before writing anything, so the check costs nothing and leaves no files.
if NOTCHQ_ALLOW_INTEL_ONLY= NOTCHQ_ARCHITECTURES=x86_64 zsh "$NOTCHQ_ROOT/scripts/build.sh" test >/dev/null 2>&1; then
  echo "build.sh accepted an Intel-only build" >&2; exit 1
fi
echo "Passed architecture checks: universal binary, arm64 preferred, Intel-only builds refused"
# Exercise the Intel slice of the universal binary through Rosetta, on request only:
#   NOTCHQ_TEST_ROSETTA=1 zsh scripts/test.sh
# It is off by default because macOS 26 shows its "Intel-based apps" (Rosetta) notice each time
# an app named NotchQ starts translated, which looks as if NotchQ itself needed Rosetta. Run it
# before a release. The Python fixture servers cannot start from a translated parent (the Command
# Line Tools python3 shim is arm64-only), so the process-fixture suites run natively only.
if [[ -n "${NOTCHQ_TEST_ROSETTA:-}" ]] && /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
  echo "Intel (Rosetta) pass:"
  /usr/bin/arch -x86_64 "$NOTCHQ_TEST" --self-test
  env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/arch -x86_64 "$NOTCHQ_TEST" --detection-report
fi
# "Report a Bug…" prefills these issue-form text fields (GitHub can't prefill dropdowns); keep them in sync.
for NOTCHQ_FIELD in "id: version" "id: macos" "id: chip" "id: log" "Apple silicon (M-series)"; do
  grep -q -- "$NOTCHQ_FIELD" "$NOTCHQ_ROOT/.github/ISSUE_TEMPLATE/bug_report.yml" || { echo "bug_report.yml is missing: $NOTCHQ_FIELD" >&2; exit 1; }
done
echo "Passed bug-form field checks"
