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
elif mode=='slow':time.sleep(.2);frame()
else:frame()
# Stay alive until the client terminates this owned process after its one response.
for line in sys.stdin:pass
