# Contributing to NotchQ

Thanks for helping improve NotchQ. It is a one-person beta, and the most useful help right now is **reports from real Macs**.

## What's welcome

- **Bug reports:** something doesn't work, shows the wrong value, or behaves unexpectedly.
- **Compatibility reports:** NotchQ on a Mac, macOS version or Codex/Claude setup we haven't covered. Reports that it works are useful too, especially from Intel Macs and macOS 13–14.
- **Feedback:** something confusing in the app, the README or the install steps.

Open an [issue](https://github.com/Xentiles/NotchQ/issues/new/choose) and pick the matching form. Quicker for bugs: choose **Report a Bug…** in NotchQ's dropdown or Settings. It fills in your versions, processor and recent log for you.

## Pull requests

NotchQ's source is shared for transparency under an **all-rights-reserved license** (see [LICENSE](LICENSE)). **Pull requests aren't accepted unless agreed in an issue first.** If you think you have a fix, open an issue describing it. Please don't send code you'd want credited or licensed separately.

## A good bug report

- **NotchQ version:** open NotchQ Settings → **About** (for example *Bv0.3.4 (build 12)*).
- **macOS version** and **Mac model / chip** (Apple silicon or Intel).
- **Provider:** Codex, Claude or both, and how it's installed (desktop app, Homebrew, npm, nvm…). The grey **Found automatically / Not found** line under each provider in Settings helps.
- **What happened and what you expected**, with steps to reproduce.
- The message shown in the NotchQ dropdown, if there is one.
- **NotchQ's log**, which contains no personal data. Run this in Terminal and paste the output:
  `/usr/bin/log show --last 2h --style compact --predicate 'subsystem == "io.github.xentiles.NotchQ"'`

**Never include** passwords, tokens, cookies, API keys, private conversations or personal file paths in an issue or screenshot.

## Security problems

Don't open a public issue. Follow [SECURITY.md](SECURITY.md) to report it privately.

## Conduct

Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
