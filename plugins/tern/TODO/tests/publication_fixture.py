#!/usr/bin/env python3
"""A persistent native Tern program for publication-boundary tests, never an AI."""
import json,os,signal,subprocess,sys,time
from pathlib import Path
if len(sys.argv)>1 and sys.argv[1]=='--wrapper':
 # An unlisted long-lived launcher: the old topmost-non-wrapper rule anchors
 # here and incorrectly survives when its actual publishing child exits.
 child=subprocess.Popen([sys.executable,__file__,*sys.argv[2:]])
 def stop(*_):
  if child.poll() is None: child.terminate();child.wait(timeout=3)
  raise SystemExit(0)
 signal.signal(signal.SIGTERM,stop)
 if hasattr(signal,'SIGHUP'):signal.signal(signal.SIGHUP,stop)
 child.wait()
 child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(3600)'])
 Path(sys.argv[5]).with_suffix('.wrapper.json').write_text(json.dumps({'wrapper':os.getpid(),'replacement':child.pid})+'\n')
 child.wait()
 raise SystemExit(0)
helper,plan,control,ready=map(Path,sys.argv[1:5])
if len(sys.argv)>5:os.environ['TODO_PUBLICATION_ROOT']=sys.argv[5]
def run(command):
 result=subprocess.run([sys.executable,'-I',str(helper),*command, '--agent-pid',str(os.getpid())],capture_output=True,text=True,timeout=8)
 value=json.loads(result.stdout)
 if result.returncode:raise RuntimeError(value)
 return value
value=run(['publish','--plan',str(plan)])
ready.write_text(json.dumps({'pid':os.getpid(),'result':value})+'\n')
while True:
 if control.exists():
  command=json.loads(control.read_text());control.unlink()
  if command['command']=='die':os._exit(0)
  if command['command']=='exit':
   run(['clear']);break
  args=['clear'] if command['command']=='clear' else ['publish','--plan',str(plan)]
  try:result=run(args)
  except Exception as error:result={'ok':False,'error':str(error)}
  ready.write_text(json.dumps({'pid':os.getpid(),'result':result,'command':command['command']})+'\n')
 time.sleep(.1)
