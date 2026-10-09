<p align="center">
  <img src="Assets/Demo/notchq-ad-v2-1280.gif" width="1280" alt="NotchQ demo: remaining Codex (white) and Claude (orange) allowance beside the MacBook notch, the dropdown with each provider's allowance windows and reset times, then the NotchQ Settings window">
</p>
<p align="center"><em>A simple way of knowing what's left. Demo readings are illustrative.</em></p>

# NotchQ

**Bv0.2.0 Beta** · [Download for Mac](https://github.com/Xentiles/NotchQ/releases/tag/Bv0.2.0)

A small native Mac app that keeps your remaining AI allowance beside the camera notch. **NotchQ** combines *notch* and *quota*: **AI Notch Quota**.

**Unsigned beta:** this release is locally ad-hoc signed, without Developer ID signing or Apple notarization. macOS may block a downloaded copy. Source visibility and GitHub stars do not replace those checks. See [Apple's guidance](https://support.apple.com/en-us/102445). Signing can be added to a later release.

## Install

1. Download the universal DMG from the [Releases page](https://github.com/Xentiles/NotchQ/releases) and open it.
2. Drag **NotchQ** onto **Applications**.
3. Open NotchQ from Applications. macOS says it **cannot verify** NotchQ. Click **Done**, not Move to Bin.
4. Open **System Settings → Privacy & Security**, scroll to **Security**, and click **Open Anyway** next to the NotchQ message. Confirm with **Open Anyway**, and your password if asked. On macOS 13–14 you can instead Control-click NotchQ in Applications and choose **Open**.
5. The first-run Settings window opens. **Codex and Claude are on by default**, and NotchQ finds their installed command-line tools automatically. **Notch position** is on by default; **Start at login** is your choice.

Step 4 is needed once per version because this beta is not notarized by Apple. Advanced users can instead clear the download flag in Terminal: `xattr -dr com.apple.quarantine /Applications/NotchQ.app`.

No developer tools are needed to run the downloaded app. Open NotchQ again from Applications to reach Settings at any time.

### Codex and Claude detection

NotchQ looks for the `codex` and `claude` command-line tools where their installers put them: the Codex/ChatGPT app, Claude Desktop's bundled Claude Code, `~/.local/bin`, Homebrew, npm, nvm, Volta and Bun folders, and the `PATH` your login shell sets up. Detection works even when NotchQ starts from Finder or at login. It uses each tool's existing sign-in.

- **Not detected?** In Settings, click **Choose CLI…** under the provider and select its executable (`which codex` or `which claude` in Terminal shows the path). **Use automatic** returns to detection.
- **Not using one?** Untick it in Settings.
- Sources that are not installed stay hidden. An installed source that cannot read usage shows **—%**, and the dropdown explains why.

## How it works

- Fixed 14-point Libron percentages on a shared baseline: **white for Codex**, **orange for Claude**. Natural glyph overshoot and color contrast can affect their apparent size.
- Headlines use the five-hour allowance when reported, otherwise weekly, then the lowest other available allowance. All reported windows remain in the dropdown; the tooltip identifies the selected window.
- Enabled providers that are installed (or whose desktop app is running) appear. A detected provider stays visible as **—%** while awaiting a fresh reading or temporarily unavailable, so its dropdown can explain why. Retained values are shown only as last-known details; valid 0% and 100% remain visible.
- Six-point padding measured from visible glyph bounds, with gentle size and fade transitions respecting macOS Reduce Motion.
- Default placement follows macOS-reported unobscured screen areas. A standard menu-bar item is used when no suitable notch area exists.
- Native Settings for provider connections, placement, visibility and optional login startup.
- Matching dropdown sections show available allowance windows from shortest to longest, their labeled resets, then the last successful update in `HH:mm:ss`. Absent windows stay hidden. Reset times for both providers are shown in your Mac’s current time zone and date format; Claude’s reset text is converted from the zone Claude Code reports. Missing reset information is marked unavailable.

### Usage sources

| Provider | Connection | Update behavior |
| --- | --- | --- |
| Codex | Your installed Codex app or CLI, found automatically, and its existing sign-in | **Every 10 seconds** while enabled and awake; failures back off. |
| Claude | Claude Code’s read-only `/usage` command, found automatically, and its existing Pro/Max sign-in | **Every 60 seconds** while enabled and awake; after a rate limit, 2, 4, 8, then up to 15 minutes. No Claude Code settings are changed. An optional status-line fallback is used only when no local CLI can be run; its snapshots older than three minutes are hidden. |

### Update frequency: why Claude is once a minute

**Claude can update at most once every 60 seconds.** Each check starts Claude Code and runs `/usage`, which asks Anthropic’s usage service for your allowance. That service rate-limits frequent checks. At NotchQ’s earlier 10-second cadence it began refusing them. Claude Code then showed figures up to 20 minutes old, marked “rate limited”. NotchQ never shows such figures as current, so the badge waited at **—%**. The exact limit isn’t published; checking every 60 seconds asks six times less often. If a limit still happens, NotchQ says so in the dropdown and Settings, backs off (2 → 4 → 8 → 15 minutes), then steps back to 60 seconds after successful readings. **Refresh** does not bypass a rate limit.

When Claude Code can run, NotchQ deliberately uses `/usage` as its only Claude source. Claude Code’s status line also reports usage after each reply. Combining the two would make the badge jump between them, for example 85% then back to 86%: the sources round differently (decimal vs. whole percentages) and are captured at different moments. With one source, the number only moves down while you work, and only rises when your allowance actually resets. The cost is up to a minute of delay.

**Codex doesn’t have this limit in practice.** Codex offers a structured `account/rateLimits/read` request through its app server, designed for apps to call. NotchQ keeps one Codex connection open and sends that request every 10 seconds, rather than starting a new terminal session each time. Codex has not rate limited that cadence in testing. If it ever reports throttling, NotchQ waits as long as Codex asks (60 seconds if it doesn’t say).

**Claude Free does not provide a verified remaining-percentage feed in this release.** An unavailable marker is shown instead; no percentage is invented. Claude Pro/Max usage needs Claude Code to be signed in; Claude Desktop sign-in alone may not authenticate the CLI. The optional **Status-line fallback…** in Settings backs up and wraps the user's existing status-line command; **Remove fallback** restores the saved status-line object when its command still matches the bridge. Independently changed commands and unrelated top-level settings are preserved; other status-line fields revert to the backup.

The read-only Claude checker starts a fresh private terminal process for each check and closes it after one complete English `/usage` response. This avoids reused terminal state and session caches. It is less stable than a structured API: incompatible CLI versions fail visibly and back off. Authentication remains with Claude Code, and usage values have the precision supplied by its terminal display.

Manual refresh requests one follow-up check if a provider is already busy. A provider that is being rate limited is skipped rather than queued; its status shows when it will be checked next. Codex manual checks reconnect its app server so the vendor-owned sign-in is reloaded. Wake and Spaces events restore the nonactivating badge without taking keyboard focus or adding usage requests on every desktop switch. Diagnostics retain at most 128 fixed events in memory; launching with `--diagnostics` prints timestamps, event codes and numeric measurements, without credentials or terminal transcripts.

NotchQ does not bundle vendor CLIs, call private Claude usage endpoints, extract passwords/cookies, or run model prompts to obtain readings. See [privacy details](PRIVACY.md).

## Compatibility

The universal app contains **Apple silicon and Intel** binaries and has a **macOS 13 or later minimum build target**. That target is not a claim that every older macOS release or physical Mac has been tested.

| Component | Requirements |
| --- | --- |
| NotchQ | macOS 13+; Apple silicon or Intel. Verified on an Apple silicon Mac, with Intel fixture checks under Rosetta. Physical Intel Macs and older macOS installations have not been independently tested. |
| Codex desktop integration | An Apple silicon Mac and an existing Codex sign-in. The [current Codex desktop download](https://learn.chatgpt.com/docs/app) is for Apple silicon. |
| Claude usage connection | [Claude Code on macOS 13+](https://code.claude.com/docs/en/setup), on Intel or Apple silicon, signed in with a Pro or Max account. The status-line fallback is optional. Claude Desktop sign-in alone may not authenticate Claude Code. |

Provider requirements can change independently of NotchQ. To show a provider only while its desktop app is open, turn on **Show only running desktop apps**. Claude Free percentages are unavailable. Physical Intel and older-macOS testing remain outstanding.

Placement uses screen geometry rather than model names or a fixed notch width. External displays and Macs without a notch use the standard menu bar. Unreleased hardware and hypothetical future Dynamic Island APIs have not been tested or certified; safe fallback remains available.

## Build

Install Apple's Command Line Tools, then run:

```sh
zsh scripts/build.sh
zsh scripts/test.sh
zsh scripts/package-dmg.sh
```

The app is built in `dist/NotchQ.app`; release images and checksums are written under `releases/`. Packaging always rebuilds, then checks that the binary is universal, targets macOS 13, is validly signed and contains its resources. The shipping app excludes the check-only Swift sources. Tests use local fixtures and do not consume AI quota.

The repository contains application source, its required resources, selected SVG branding masters, the README demo animation, essential checks, packaging scripts and user documentation. Concept boards, old versions, development caches and local notes are not part of the repository or DMG.

## Remove

If you added the optional Claude status-line fallback, click **Remove fallback** in Settings first. Turn off **Start at login**, quit NotchQ, and move the app from Applications to Trash. You can also remove its entry in macOS **System Settings → General → Login Items**. Optional cached readings and the status-line backup are in `~/Library/Application Support/NotchQ`; delete that folder only after removing the fallback.

## No percentage appears

A wide notch does not prevent a reading from being received. If there is no usable notch area, NotchQ falls back to the standard menu bar. A detected source shows **—%** when no current reading is available; open the dropdown for the reason. Disabled or undetected sources stay hidden.

1. Enable the provider’s checkbox. A disabled Codex source does not poll usage.
2. Check the path line under the provider in Settings. If it says **Not found**, install the tool or use **Choose CLI…**.
3. For Claude, sign into **Claude Code** with a supported Pro/Max account (run `claude` once in Terminal). NotchQ’s background CLI checks read account usage without sending AI prompts.
4. If **Show only running desktop apps** is on, the provider appears only while its desktop app is open. Turn it off for terminal-only use.
5. Claude updates at most once every 60 seconds (see [Update frequency](#update-frequency-why-claude-is-once-a-minute)). If Claude’s usage service is rate limiting checks, NotchQ shows that with the time of the next check, and **Refresh** cannot bypass it. The status-line fallback hides readings older than three minutes. **Refresh** performs a read-only check; it does not run an AI prompt.

The badge shows **remaining account allowance**, not a session’s token count or context-window percentage.

## Beta feedback

Report bugs and compatibility results through [GitHub Issues](https://github.com/Xentiles/NotchQ/issues/new/choose); the forms ask for the NotchQ version (shown in **About**, e.g. Bv0.2.0 build 7), macOS version, Mac processor and provider. Remove credentials, private conversations and personal paths from anything you share. See [CONTRIBUTING.md](CONTRIBUTING.md) for what helps most. Pull requests aren't accepted without prior agreement.

Security problems: report privately as described in [SECURITY.md](SECURITY.md). Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## License and branding

**All rights reserved.** You may download and run unmodified official release binaries on your own devices. Source reuse, modification or redistribution requires permission; see [LICENSE](LICENSE). Libron has its separate [SIL Open Font License](Resources/Libron-LICENSE.txt).

The selected **Quiet Signal** identity uses clean SVG geometry and outlined lettering. Its larger right node represents the native notch; the smaller left node represents NotchQ. SVG masters are in `Assets/Brand`; PNG and ICNS files are platform derivatives. The brand's clay accent never replaces the provider-specific white/orange percentage colors.
