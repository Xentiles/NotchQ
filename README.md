<p align="center">
  <img src="Assets/Demo/notchq-ad-v5-1280.gif" width="1280" alt="NotchQ demo: remaining Codex (white) and Claude (orange) allowance beside the MacBook notch, the dropdown with each provider's allowance, reset times and next check, then the NotchQ Settings window with usage sources and updates">
</p>
<p align="center"><em>A simple way of knowing what's left. Demo readings are illustrative.</em></p>

# NotchQ

**Bv0.5.0 Beta** · [Download for Mac](https://github.com/Xentiles/NotchQ/releases/tag/Bv0.5.0)

A small native Mac app that keeps your remaining AI allowance beside the camera notch. **NotchQ** combines *notch* and *quota*: **AI Notch Quota**.

**New in Bv0.5.0** ([full notes](https://github.com/Xentiles/NotchQ/releases/tag/Bv0.5.0)):

- **Low-limit warnings.** When a limit has 10% or less left, its figure on the badge blinks. You can set the threshold to 5–25% in Settings.
- **Two rhythms.** Short limits (5-hour and other limits shorter than a week) fade softly every 2 seconds; long limits (weekly, monthly) dip sharply twice every 1.4 seconds. A low weekly or longer limit takes over the badge, because it is the one that will stop you first.
- **Reminder cards.** The first time a limit gets low, a card drops from the notch with the figure and the reset time. It stays until you close it with its ✕, once per limit until it resets. An optional macOS notification can come with it; NotchQ then shows a one-time tip for choosing the **Alerts** style so it stays on screen too.
- **The same rules for every plan.** Whatever windows Codex or Claude reports (5-hour, weekly, the monthly window Codex shows without a subscription, or others), NotchQ shows, warns and reminds the same way, and names the real window ("Codex monthly limit almost used up").
- **Clearer dropdown colours.** The NotchQ title is drawn in full white, Codex's figures in a light grey and Claude's in its orange, so the information stands apart from the clickable items.
- **Dynamic Island support (untested).** MacBook Pro models with the camera hole-punch are handled through the same macOS screen-area APIs as the notch; see [Compatibility](#compatibility).

Earlier: [Bv0.4.1](https://github.com/Xentiles/NotchQ/releases/tag/Bv0.4.1) kept Claude updating with Claude Code 2.1.331, and [Bv0.4.0](https://github.com/Xentiles/NotchQ/releases/tag/Bv0.4.0) added the Claude sign-in action, the status-line bridge, the live dropdown and native Apple silicon.

NotchQ is an independent project, not affiliated with OpenAI or Anthropic. Codex and Claude are their respective trademarks.

**Unsigned beta:** this release is locally ad-hoc signed, without Developer ID signing or Apple notarization. macOS may block a downloaded copy. Source visibility and GitHub stars do not replace those checks. See [Apple's guidance](https://support.apple.com/en-us/102445). Signing can be added to a later release.

## Install

1. Download the universal DMG from the [Releases page](https://github.com/Xentiles/NotchQ/releases) and open it.
2. Drag **NotchQ** onto **Applications**.
3. Open NotchQ from Applications. macOS says it **cannot verify** NotchQ. Click **Done**, not Move to Bin.
4. Open **System Settings → Privacy & Security**, scroll to **Security**, and click **Open Anyway** next to the NotchQ message. Confirm with **Open Anyway**, and your password if asked. On macOS 13–14 you can instead Control-click NotchQ in Applications and choose **Open**.
5. The first-run Settings window opens. **Codex and Claude are on by default**, and NotchQ finds their installed command-line tools automatically. **Notch position** is on by default; **Start at login** is your choice. Under **Low-limit warnings** you can change the threshold (10% by default) and choose the reminder card and an optional macOS notification.

Step 4 is needed once per version because this beta is not notarized by Apple. Advanced users can instead clear the download flag in Terminal: `xattr -dr com.apple.quarantine /Applications/NotchQ.app`.

No developer tools are needed to run the downloaded app. Open NotchQ again from Applications to reach Settings at any time.

### Updates

From Bv0.3.0, NotchQ updates itself. It checks GitHub for a newer release shortly after launch and then once a day. When one exists, **Settings → Updates** and the dropdown say so, and the **Update** button next to **Check now** turns blue; otherwise it stays greyed out. **Update** downloads the new version, checks its signature, quits NotchQ, replaces the app in place and reopens it. If anything fails, the current version stays. Updated copies don't need **Open Anyway** again.

- Turn off **Check for updates automatically** in Settings to stop the daily check; **Check now** still works.
- If NotchQ can't replace itself (for example, a standard macOS user in `/Applications`), it offers the download page instead.
- Earlier versions (Bv0.2.0 and before) need one manual download of Bv0.3.0 or later.

### Codex and Claude detection

NotchQ looks for the `codex` and `claude` command-line tools where their installers put them: the Codex/ChatGPT app, Claude Desktop's bundled Claude Code, `~/.local/bin`, Homebrew, npm, nvm, Volta and Bun folders, and the `PATH` your login shell sets up. Detection works even when NotchQ starts from Finder or at login. It uses each tool's existing sign-in.

- **Not detected?** In Settings, click **Choose CLI…** under the provider and select its executable (`which codex` or `which claude` in Terminal shows the path). **Use automatic** returns to detection.
- **Terminal says `claude: command not found`?** Claude Code’s installer puts the tool in `~/.local/bin`, which is not always on your shell’s `PATH`. NotchQ finds it there anyway and always runs it by its full path, so the badge and **Sign in to Claude Code…** work regardless. To use it yourself, type the full path (`~/.local/bin/claude`) or add that folder to your `PATH`.
- **Not using one?** Untick it in Settings.
- Sources that are not installed stay hidden. An installed source that cannot read usage shows **—%**, and the dropdown explains why.

## How it works

- Fixed 14-point Libron percentages on a shared baseline: **white for Codex**, **orange for Claude**. Natural glyph overshoot and color contrast can affect their apparent size.
- Headlines use the five-hour allowance when reported, otherwise weekly, then the lowest other available allowance (for example the monthly window Codex reports without a subscription).
- **Low-limit warnings.** A limit with **10% or less** left (5–25% in **Settings → Low-limit warnings**) is nearly used up, and its figure blinks without changing colour. Every plan follows the same rules, by the length of the window:
  - **Short limits** (shorter than a week: 5-hour, 1-hour, or a limit of unknown length) fade softly to a quarter of their strength and back every 2 seconds.
  - **Long limits** (a week or longer: weekly, monthly) dip sharply twice every 1.4 seconds, and **take over the badge**, because that limit will stop you first, even when a short limit is low too. If several limits of the same kind are low, the one with the least left is shown.
  - Only the affected provider’s figure blinks. With macOS **Reduce Motion** on, it is shown steadily dimmed instead. All reported windows remain in the dropdown; the tooltip and the dropdown say which window is on the badge and that it is nearly used up.
- **Reminders.** The first time a limit reaches the threshold, a card drops from the notch (or from under the menu bar) naming the real limit ("Claude weekly limit almost used up"), with the figure and the reset time. It stays until you close it with its ✕, and each limit is reminded only once per reset; a card closes by itself when its limit is no longer low. Settings can switch the card off and add a macOS notification; turning that on shows a one-time tip about choosing the **Alerts** style in System Settings → Notifications, so the notification also stays until closed.
- Enabled providers that are installed (or whose desktop app is running) appear. A detected provider stays visible as **—%** while awaiting a fresh reading or temporarily unavailable, so its dropdown can explain why. Retained values are shown only as last-known details; valid 0% and 100% remain visible.
- Six-point padding measured from visible glyph bounds, with gentle size and fade transitions respecting macOS Reduce Motion.
- Default placement follows macOS-reported unobscured screen areas. A standard menu-bar item is used when no suitable notch area exists.
- Native Settings for provider connections, placement, visibility, low-limit warnings and optional login startup.
- The dropdown starts with the NotchQ title in full white. Each provider's heading, figures and reset times are drawn in its colour (a light grey for Codex, Claude's orange), a step below the clickable items, while update times and status lines stay faded.
- Matching dropdown sections show available allowance windows from shortest to longest, their labeled resets, each with a countdown (“in 1 h 54 min”), then the last successful update in `HH:mm:ss` with its age (“35 s ago”). While the dropdown is open these times, the wait until the next check and the percentages keep updating every second. Absent windows stay hidden. Reset times for both providers are shown in your Mac’s current time zone and date format; Claude’s reset text is converted from the zone Claude Code reports. Missing reset information is marked unavailable.

### Usage sources

| Provider | Connection | Update behavior |
| --- | --- | --- |
| Codex | Your installed Codex app or CLI, found automatically, and its existing sign-in | **Every 10 seconds** while enabled and awake; failures back off. |
| Claude | Claude Code’s read-only `/usage` command, found automatically, and its existing Pro/Max sign-in | **Every 2 minutes** while enabled and awake. After a rate limit NotchQ waits until the time Claude Code states, otherwise 4, 8, then up to 15 minutes. No Claude Code settings are changed. With the optional **status-line bridge**, the figures Claude Code reports after each reply are also shown, within 10 seconds; such snapshots older than three minutes are not shown as new. |

### Update frequency: why Claude is every 2 minutes

**Claude updates at most once every 2 minutes.** Each check starts Claude Code and runs `/usage`, which asks Anthropic’s usage service for your allowance. That service rate-limits frequent checks, and its exact limit isn’t published:

- At NotchQ’s first 10-second cadence, it refused checks entirely. Claude Code then showed figures up to 20 minutes old, marked “rate limited”, which NotchQ never shows as current.
- At 60 seconds, a 4-hour test was still rate limited about every 5 minutes. The service tolerated roughly one check every 80–90 seconds.
- At 2 minutes, NotchQ stays under that.

If a limit happens anyway, NotchQ keeps showing the last Claude reading for up to 5 minutes. The dropdown says which time it’s from, so short limits don’t flicker to **—%**. When Claude Code says when the limit ends (“rate limited until 3:14am”), NotchQ waits until then (at least 1 minute, at most 1 hour). Otherwise it backs off (4 → 8 → 15 minutes) and only steps back down after five clean readings in a row. **Refresh** does not bypass a rate limit.

#### Two Claude sources: `/usage` and the optional status line

`/usage` is always the regular check, because it is the only place that also counts usage from claude.ai and Claude Desktop. Claude Code’s documented status line reports the same two limits (`rate_limits`: 5-hour and 7-day) after each reply in a terminal session. If you add the **status-line bridge** in Settings, NotchQ uses both:

| Situation | What the badge shows |
| --- | --- |
| Claude Code replied since the last `/usage` check | The status-line figures, within 10 seconds |
| `/usage` checked more recently | The `/usage` figures |
| `/usage` is rate limited or failing, and the status line reported in the last three minutes | The status-line figures; Settings and the dropdown still state the `/usage` problem |
| A window’s reset time has passed | Nothing for that window until a new reading arrives; NotchQ asks `/usage` right away unless a rate limit is active |

The two sources round differently (`/usage` prints whole percentages, the status line has decimals) and are captured at different moments, which on their own would make the badge step between, say, 85% and 86%. NotchQ compares readings per window: while both describe the same period (reset times within two minutes of each other), the newer reading wins but remaining does not step back up by a rounding-sized amount (1–2 points); a larger rise, or a later reset time, is a real change and is shown as is. The dropdown’s **Source** row and the Settings status line say where the shown value came from.

Without the bridge, `/usage` is the only source and the badge can be up to 2 minutes behind. The status line only runs in Claude Code terminal sessions, only for Pro/Max, and has no figures until a session’s first reply.

**Codex doesn’t have this limit in practice.** Codex offers a structured `account/rateLimits/read` request through its app server, designed for apps to call. NotchQ keeps one Codex connection open and sends that request every 10 seconds, rather than starting a new terminal session each time. Codex has not rate limited that cadence in testing. If it ever reports throttling, NotchQ waits as long as Codex asks (60 seconds if it doesn’t say).

**Claude Free does not provide a verified remaining-percentage feed in this release.** An unavailable marker is shown instead; no percentage is invented. Claude Pro/Max usage needs Claude Code to be signed in; Claude Desktop sign-in alone may not authenticate the CLI. If it is signed out, NotchQ offers **Sign in to Claude Code…**, which starts Claude Code’s own sign-in in Terminal. The optional **Status-line bridge…** in Settings backs up and wraps the user's existing status-line command; **Remove bridge** restores the saved status-line object when its command still matches the bridge. Independently changed commands and unrelated top-level settings are preserved; other status-line fields revert to the backup.

The read-only Claude checker starts a fresh private terminal process for each check and closes it after one complete English `/usage` response. This avoids reused terminal state and session caches. It is less stable than a structured API: NotchQ accepts the older (“Current session”) and newer (“5-hour limit”) wording, and a screen it cannot read fails visibly with its own message (“layout is not recognized”, or “Claude Code is signed out” with a **Sign in to Claude Code…** action when `/usage` shows no plan limits) and backs off. Authentication remains with Claude Code, and usage values have the precision supplied by its terminal display.

Manual refresh requests one follow-up check if a provider is already busy. A provider that is being rate limited is skipped rather than queued; its status shows when it will be checked next. Codex manual checks reconnect its app server so the vendor-owned sign-in is reloaded. Wake and Spaces events restore the nonactivating badge without taking keyboard focus or adding usage requests on every desktop switch. NotchQ writes fixed event and reason codes to the macOS log (see [Beta feedback](#beta-feedback)). Only failures, state changes and the first success after a failure are kept; routine checks are not stored. Launching with `--diagnostics` also prints events to Terminal. Neither ever includes credentials, file paths or terminal transcripts.

NotchQ does not bundle vendor CLIs, call private Claude usage endpoints, extract passwords/cookies, or run model prompts to obtain readings. See [privacy details](PRIVACY.md).

## Compatibility

The universal app contains **Apple silicon and Intel** binaries and has a **macOS 13 or later minimum build target**. That target is not a claim that every older macOS release or physical Mac has been tested.

| Component | Requirements |
| --- | --- |
| NotchQ | macOS 13+; Apple silicon or Intel. On Apple silicon it always runs natively, never through Rosetta. Verified on an Apple silicon Mac, with Intel fixture checks under Rosetta. Physical Intel Macs and older macOS installations have not been independently tested. |
| Codex desktop integration | An Apple silicon Mac and an existing Codex sign-in. The [current Codex desktop download](https://learn.chatgpt.com/docs/app) is for Apple silicon. |
| Codex percentages | A ChatGPT plan with Codex usage limits, such as Plus, Pro or Business ([OpenAI's plan overview](https://learn.chatgpt.com/docs/pricing)). Pro currently has no 5-hour window, so NotchQ shows the weekly allowance. Without a subscription (Free and Go), Codex can report a single monthly window; NotchQ shows it and warns on it like a weekly one. Credit-based workspaces and API-key sign-ins may not report limits; NotchQ then shows **—%** and says why. |
| Claude usage connection | [Claude Code on macOS 13+](https://code.claude.com/docs/en/setup), on Intel or Apple silicon, signed in with a Pro or Max account. The status-line bridge is optional. Claude Desktop sign-in alone may not authenticate Claude Code. |

Provider requirements can change independently of NotchQ. To show a provider only while its desktop app is open, turn on **Show only running desktop apps**. Claude Free percentages are unavailable. Physical Intel and older-macOS testing remain outstanding.

Placement uses screen geometry rather than model names or a fixed notch width. External displays and Macs without a notch use the standard menu bar.

**MacBook Pro with the Dynamic Island.** Models with a small camera hole-punch instead of a notch are supported through the same standard macOS screen-area APIs (the unobscured areas either side of the camera), so the badge sits just left of the island and reminder cards drop from it. This has not been tested on that hardware yet: if you have one, please [report how it looks](https://github.com/Xentiles/NotchQ/issues/new/choose). System animations from the island, such as Siri or Now Playing, may briefly overlap the badge. If macOS reports no usable area beside the camera, NotchQ uses the standard menu bar.

## Build

Install Apple's Command Line Tools, then run:

```sh
zsh scripts/build.sh
zsh scripts/test.sh
zsh scripts/package-dmg.sh
```

NotchQ runs natively on Apple silicon; it does not need Rosetta. `build.sh` refuses to produce an app without an arm64 slice, and `Info.plist` tells macOS to prefer arm64 and never to translate the app. To also exercise the Intel slice on an Apple silicon Mac, run `NOTCHQ_TEST_ROSETTA=1 zsh scripts/test.sh` before a release. That pass is off by default: it starts the test app through Rosetta, and macOS 26 then shows its “Intel-based apps” notice naming NotchQ, although the app you install is not affected.

The app is built in `dist/NotchQ.app`; release images and checksums are written under `releases/`. Packaging always rebuilds, then checks that the binary is universal, targets macOS 13, is validly signed and contains its resources. The shipping app excludes the check-only Swift sources. Tests use local fixtures and do not consume AI quota.

The repository contains application source, its required resources, selected SVG branding masters, the README demo animation, essential checks, packaging scripts and user documentation. Concept boards, old versions, development caches and local notes are not part of the repository or DMG.

## Remove

If you added the optional Claude status-line bridge, click **Remove bridge** in Settings first. Turn off **Start at login**, quit NotchQ, and move the app from Applications to Trash. You can also remove its entry in macOS **System Settings → General → Login Items**. Optional cached readings and the status-line backup are in `~/Library/Application Support/NotchQ`; delete that folder only after removing the bridge.

## No percentage appears

A wide notch does not prevent a reading from being received. If there is no usable notch area, NotchQ falls back to the standard menu bar. A detected source shows **—%** when no current reading is available; open the dropdown for the reason. Disabled or undetected sources stay hidden. If NotchQ finds neither Codex nor Claude Code (or both are switched off), a small gauge icon stays in the menu bar; click it to see what's missing and to open Settings.

1. Enable the provider’s checkbox. A disabled Codex source does not poll usage.
2. Check the path line under the provider in Settings. If it says **Not found**, install the tool or use **Choose CLI…**.
3. For Claude, sign in to **Claude Code** with a Pro or Max account. This is needed once, and signing in to Claude Desktop does not sign in the command-line tool. When NotchQ says “Claude Code is signed out”, click **Sign in to Claude Code…** in the dropdown or in Settings: NotchQ opens Terminal with Claude Code’s own sign-in, your browser asks for the account, and the badge fills in a few seconds after you finish. NotchQ runs the tool by its full path, so this works even when typing `claude` in Terminal does not. To do it by hand, run `claude auth login` in Terminal (or `claude`, then `/login`). NotchQ’s background CLI checks read account usage without sending AI prompts.
4. If **Show only running desktop apps** is on, the provider appears only while its desktop app is open. Turn it off for terminal-only use.
5. Claude updates at most once every 2 minutes (see [Update frequency](#update-frequency-why-claude-is-every-2-minutes)). If Claude’s usage service is rate limiting checks, NotchQ shows that with the time of the next check, and **Refresh** cannot bypass it. Status-line readings older than three minutes are not shown as new. **Refresh** performs a read-only check; it does not run an AI prompt.

The badge shows **remaining account allowance**, not a session’s token count or context-window percentage.

## Beta feedback

Report bugs and compatibility results through [GitHub Issues](https://github.com/Xentiles/NotchQ/issues/new/choose); the forms ask for the NotchQ version (shown in **About**, e.g. Bv0.5.0 build 15), macOS version, Mac processor and provider. Remove credentials, private conversations and personal paths from anything you share. See [CONTRIBUTING.md](CONTRIBUTING.md) for what helps most. Pull requests aren't accepted without prior agreement.

The quickest way is **Report a Bug…**, in NotchQ's dropdown or at the bottom of Settings. It opens the bug form with your NotchQ version, macOS version, processor and recent log already filled in, and copies the full log to your clipboard in case the form's copy had to be shortened.

**Attach NotchQ's log** to make a report much easier to solve. To copy it yourself instead, run this in Terminal:

```sh
/usr/bin/log show --last 2h --style compact --predicate 'subsystem == "io.github.xentiles.NotchQ"'
```

Copy the output into your issue. It contains only NotchQ's version, macOS version, event and reason codes (for example `reason=signedOut`) and percentages. It never contains file paths, terminal text, tokens or account details. Type the full `/usr/bin/log`: in the default zsh shell, plain `log` is a different command.

Security problems: report privately as described in [SECURITY.md](SECURITY.md). Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## License and branding

**All rights reserved.** You may download and run unmodified official release binaries on your own devices. Source reuse, modification or redistribution requires permission; see [LICENSE](LICENSE). Libron has its separate [SIL Open Font License](Resources/Libron-LICENSE.txt).

The selected **Quiet Signal** identity uses clean SVG geometry and outlined lettering. Its larger right node represents the native notch; the smaller left node represents NotchQ. SVG masters are in `Assets/Brand`; PNG and ICNS files are platform derivatives. The brand's clay accent never replaces the provider-specific white/orange percentage colors.
