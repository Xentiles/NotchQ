# Security policy

## Supported versions

Only the **latest release** receives fixes. Please check that you are on it (NotchQ Settings → **About**) before reporting.

| Version | Supported |
| --- | --- |
| Bv0.3.2 (latest) | Yes |
| Bv0.3.1 and earlier | No (update in Settings) |

## Reporting a vulnerability

**Please don't open a public issue.** Report privately through GitHub:

1. Go to the repository's **[Security](https://github.com/Xentiles/NotchQ/security)** tab.
2. Click **Report a vulnerability**.
3. Describe the problem, the NotchQ and macOS versions, and the steps to reproduce it.

Only the maintainer can see the report. You'll get a reply as soon as possible. NotchQ is maintained by one person, so this is best effort. Please allow time for a fix before sharing details publicly.

## Scope

NotchQ is a local macOS app with no NotchQ server or account. Areas where a report is especially valuable:

- anything that could expose Codex or Claude **credentials, tokens or session data**;
- the Codex and Claude Code **processes NotchQ starts**, and the folders and `PATH` it gives them;
- the optional **Claude status-line fallback** and its edits to `~/.claude/settings.json`;
- files NotchQ writes under `~/Library/Application Support/NotchQ`;
- the **in-app updater**: release checks, signature verification and replacing the app.

These are known and not vulnerabilities by themselves: the beta is **not notarized** (macOS asks you to approve it in Privacy & Security), and it is **ad-hoc signed**. See the [README](README.md#install) and [privacy details](PRIVACY.md).
