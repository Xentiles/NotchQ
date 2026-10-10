# Privacy

NotchQ is a local usage display. It has no analytics, advertising SDK or NotchQ account service. Its only own network request is the optional daily update check described below.

## Codex

NotchQ starts one instance of your installed Codex CLI and calls the documented
`account/rateLimits/read` endpoint every 10 seconds while awake. Codex owns authentication and contacts its
own service. NotchQ does not copy tokens or start model requests. CLI analytics
are disabled for the helper process. Server errors use fixed messages instead
of displaying raw responses that could contain credentials.

## Claude

Claude checks start automatically when Claude Code is found and Claude is
enabled; they do not change Claude Code settings. For regular checks, NotchQ starts a fresh background Claude Code terminal process
every minute while awake (less often after a rate limit), reads one complete
`/usage` response, and closes it.
Model tools, hooks and MCP connections are disabled for that checker. It uses a
private empty folder and stores no raw terminal output. Authentication stays
with Claude Code; NotchQ does not read its credentials or call private endpoints.
The terminal output parser keeps only allowance percentages/windows and reported reset text. No model
prompt is generated to refresh usage.

Diagnostics retain up to 128 timestamped events in memory, containing fixed event
codes, provider names, percentages, request durations and window visibility flags.
The optional `--diagnostics` launch flag prints those events locally. Raw terminal
output, account identifiers and authentication data are excluded.

The optional status-line fallback is installed only after the user chooses it
in Settings. It wraps the existing user status-line command and stores a backup,
and is used only when a local CLI cannot be resolved. The bridge receives Claude Code's documented JSON input, forwards that input to
the previous command, and saves only normalized usage windows and freshness
counters for NotchQ. Workspace paths and session identifiers are discarded.

The local cache and backup live in the user's Application Support/NotchQ folder.
New support directories are created with owner-only permissions; an existing
directory retains its current permissions. Written cache and backup files are
set to owner read/write permissions. The bridge never extracts OAuth tokens, cookies or passwords and
does not call private Claude usage endpoints. It does not generate model traffic.

**Remove fallback** restores the earlier status-line object if its command still matches
the installed bridge. A changed command is preserved. Other status-line fields
are restored from the backup, while unrelated top-level settings are preserved.

## Finding installed tools

To find `codex` and `claude`, NotchQ checks whether files exist in their usual
install folders. Once per launch it also starts your login shell to read its
`PATH` setting, so tools installed through Homebrew, npm or nvm are found even
when NotchQ starts from Finder. Only `PATH` is read; it is kept in memory and
never stored, logged or sent anywhere. The tool folders are added to the `PATH`
of the Codex and Claude Code processes NotchQ starts.

## Update checks

Shortly after launch and then once a day, NotchQ asks GitHub's public API for
the list of NotchQ releases. The request carries only NotchQ's version in its
User-Agent; no account, identifier or usage data is sent, and no cookies are
kept. Turn off **Check for updates automatically** in Settings to stop these
checks; **Check now** then runs one only when you click it.

An update is installed only after you click **Update** in Settings. The
download must carry a valid Ed25519 signature from the NotchQ maintainer's
key, which is kept off GitHub, and must be the expected NotchQ version with an
intact code signature. Otherwise it is discarded. Downloads and the previous
version are kept temporarily in Application Support/NotchQ/Updates and removed
after the new version has started.

## App visibility and settings

NotchQ reads running application identifiers to decide which enabled providers
to display. It does not read other apps' documents, windows, conversations,
screenshots, camera or microphone. Preferences are stored locally. Login startup
uses macOS ServiceManagement and is opt-in for new installations.
