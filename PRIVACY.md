# Privacy

NotchQ is a local usage display. It has no analytics, advertising SDK or NotchQ account service.

## Codex

NotchQ starts one instance of your installed Codex CLI and calls the documented
`account/rateLimits/read` endpoint. Codex owns authentication and contacts its
own service. NotchQ does not copy tokens or start model requests. CLI analytics
are disabled for the helper process. Server errors use fixed messages instead
of displaying raw responses that could contain credentials.

## Claude

The optional Claude Code connection is installed only after the user chooses it
in Settings. It wraps the existing user status-line command and stores a backup.
The bridge receives Claude Code's documented JSON input, forwards that input to
the previous command, and saves only normalized usage windows and freshness
counters for NotchQ. Workspace paths and session identifiers are discarded.

The local cache and backup live in the user's Application Support/NotchQ folder.
New support directories are created with owner-only permissions; an existing
directory retains its current permissions. Written cache and backup files are
set to owner read/write permissions. The bridge never extracts OAuth tokens, cookies or passwords and
does not call private Claude usage endpoints. It does not generate model traffic.

Disconnect restores the earlier status-line object if its command still matches
the installed bridge. A changed command is preserved. Other status-line fields
are restored from the backup, while unrelated top-level settings are preserved.

## App visibility and settings

NotchQ reads running application identifiers to decide which enabled providers
to display. It does not read other apps' documents, windows, conversations,
screenshots, camera or microphone. Preferences are stored locally. Login startup
uses macOS ServiceManagement and is opt-in for new installations.
