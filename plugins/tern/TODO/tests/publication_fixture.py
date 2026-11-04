#!/usr/bin/env python3
"""A persistent native Tern program for publication-boundary tests, never an AI."""
import json,os,subprocess,sys,time
from pathlib import Path
helper,plan,control,ready=map(Path,sys.argv[1:5])
def run(command):
 result=subprocess.run([sys.executable,'-I',str(helper),*command],capture_output=True,text=True,timeout=8)
 value=json.loads(result.stdout)
 if result.returncode:raise RuntimeError(value)
 return value
value=run(['publish','--plan',str(plan)])
ready.write_text(json.dumps({'pid':os.getpid(),'result':value})+'\n')
while True:
 if control.exists():
  command=json.loads(control.read_text());control.unlink()
  if command['command']=='exit':break
  args=['clear'] if command['command']=='clear' else ['publish','--plan',str(plan)]
  try:result=run(args)
  except Exception as error:result={'ok':False,'error':str(error)}
  ready.write_text(json.dumps({'pid':os.getpid(),'result':result,'command':command['command']})+'\n')
 time.sleep(.1)
