#!/usr/bin/python3
import pathlib,sys,time,os
mode=pathlib.Path(__file__+'.mode').read_text().strip()
if mode=='timeout':time.sleep(20);raise SystemExit
if mode=='exit':raise SystemExit(1)
if mode=='auth':print('Not logged in · Please run /login',flush=True);time.sleep(20);raise SystemExit
if mode=='throttle':print('429 too many requests',flush=True);time.sleep(20);raise SystemExit
if mode=='trust':
 print('Accessing workspace: '+os.getcwd()+'\nQuick safety check:\nEnter y/n:',flush=True)
 if sys.stdin.readline().strip()!='y':raise SystemExit(1)
if mode=='cost':print('Total cost: $0.0030',flush=True)
if mode=='cost331':print('Estimated cost: $0.0030',flush=True)
if mode=='numeric429':print('Claude Code v2.1.429\nTotal duration (wall): 4.429s',flush=True)
def frame(session=1,week=0,footer=True):
 print(f'Current session\n{session}% {session}% used\nResets 6pm (Europe/Stockholm)\nCurrent week (all models)\n{week}% {week}% used',flush=True)
 if footer:print('Esc to cancel',flush=True)
if mode=='redraw':
 frame();print('Loading usage...\nCurrent session\n20% ',end='',flush=True);time.sleep(.06)
 print('20% used\nResets 6pm (Europe/Stockholm)\nCurrent week (all models)\n40% 40% used\nEsc to cancel',flush=True)
elif mode=='weekly':print('Current week (all models)\n23% 23% used\nEsc to cancel',flush=True)
elif mode=='partial':print('Current session\n1% used\nCurrent week (all models)\nEsc to cancel',flush=True)
elif mode=='changed':frame(20,40)
elif mode=='split-reset':
 frame(footer=False);time.sleep(.05);print('Resets Oct 16, 6pm (Europe/Stockholm)\nEsc to cancel',flush=True)
elif mode=='ratelimited':
 frame(29,10,footer=False)
 print("What's contributing to your limits usage?\nUsage credits are off\nShowing last-known usage as of 20m ago (rate limited \u2014 try again in a moment)\nr to retry \u00b7 Esc to cancel",flush=True)
elif mode=='until':
 # Claude Code 2.1.304+ states when the limit on usage data ends.
 frame(29,10,footer=False)
 print("Showing last-known usage as of 5m ago (rate limited until 3:14am)\nr to retry \u00b7 Esc to cancel",flush=True)
elif mode=='signedout':
 # Captured from Claude Code 2.1.295 with the CLI signed out (folder shortened): a complete screen with no plan limits.
 print('[Screen Reader Mode: on via flag]\nClaude Code v2.1.295\nOpus 5.5 \u00b7 API Usage Billing\n~/Library/Application Support/NotchQ/UsageCheck\nyou: /usage\nSettings  Status   Config   Usage   Stats\nSession\nTotal cost:            $0.0000\nTotal duration (API):  0s\nTotal duration (wall): 0s\nTotal code changes:    0 lines added, 0 lines removed\nUsage:                 0 input, 0 output, 0 cache read, 0 cache write\nEsc to cancel',flush=True)
elif mode=='renamed':
 # Newer wording: the session limit is named the 5-hour limit, with a warning line and a per-model row.
 print('Settings  Status   Config   Usage   Stats\nCurrent 5-hour limit\n12% 12% used\nResets 6pm (Europe/Stockholm)\nApproaching your 5-hour limit\nWeekly limit (all models)\n30% 30% used\nResets Oct 16 at 6pm (Europe/Stockholm)\nWeekly limit (Sonnet only)\n2% 2% used\nr to refresh \u00b7 Esc to cancel',flush=True)
elif mode=='layout':
 # A screen that finished drawing in a layout this NotchQ version does not know.
 print('Settings  Status   Config   Usage   Stats\nPlan usage\nFive hours: 12 percent of limit\nSeven days: 30 percent of limit\nEsc to cancel',flush=True)
elif mode=='slow':time.sleep(.2);frame()
elif mode=='v331':
 # Captured from Claude Code 2.1.331 (2026-11-25): "Estimated cost:", sections after the limits, footer "Esc to close".
 print("Settings  Status   Config   Usage   Stats\nSession\nEstimated cost: $0.0000\nCurrent session\n34% 34% used\nResets 4:50am (Europe/Stockholm)\nCurrent week (all models)\n25% 25% used\nResets Nov 26 at 4pm (Europe/Stockholm)\nWhat's contributing to your usage?\n45% See what fills your context \u00b7 run /context\nMCP servers % of usage\nclaude.ai Gmail 13%\nUsage credits\nUsage credits are off \u00b7 /usage-credits to turn them on\n\u2190/\u2192 to switch \u00b7 d to show day \u00b7 w to show week \u00b7 Esc to close",flush=True)
elif mode=='nofooter':
 # Limits drawn, but the screen never ends with a footer this NotchQ version knows.
 frame(footer=False);print('x to exit',flush=True);time.sleep(20);raise SystemExit
else:frame()
# Stay alive until the client terminates this owned process after its one response.
for line in sys.stdin:pass
