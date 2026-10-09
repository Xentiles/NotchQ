#!/usr/bin/python3
import sys,json,time,pathlib
mode=pathlib.Path(__file__+'.mode').read_text().strip()
for line in sys.stdin:
 r=json.loads(line)
 if 'id' not in r: continue
 if mode=='timeout': time.sleep(20); continue
 if r['method']=='initialize': result={}
 elif mode=='disconnect': sys.exit(0)
 elif mode=='throttle':
  print(json.dumps({'id':r['id'],'error':{'message':'429 too many requests','data':{'retryAfterSeconds':60}}}),flush=True);continue
 else: result={'rateLimitsByLimitId':{'codex':{'primary':{'usedPercent':47,'windowDurationMins':10080}}}}
 print(json.dumps({'method':'unrelated/notification','params':{}}),flush=True)
 payload=json.dumps({'id':r['id'],'result':result})+'\n'
 sys.stdout.write(payload[:9]);sys.stdout.flush();time.sleep(.02)
 sys.stdout.write(payload[9:]);sys.stdout.flush()
