#!/usr/bin/env python3
"""Transparent stdio relay. Persists metadata only, never arguments/UI text."""
import subprocess,sys,os,json,time,threading
from pathlib import Path
root=Path(__file__).resolve().parents[2]
p=subprocess.Popen([str(root/'bin/mcp-server.sh')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=sys.stderr.buffer)
pending={};lock=threading.Lock()
def incoming():
    for line in sys.stdin.buffer:
        try:
            d=json.loads(line)
            if d.get('method')=='tools/call':
                with lock:pending[d['id']]=(d['params']['name'],time.monotonic())
        except Exception:pass
        p.stdin.write(line);p.stdin.flush()
    p.stdin.close()
threading.Thread(target=incoming,daemon=True).start()
for line in p.stdout:
    try:
        d=json.loads(line)
        with lock:item=pending.pop(d.get('id'),None)
        if item:
            name,start=item
            data=json.loads(d['result']['content'][0]['text'])
            obs=data.get('observation',{})
            row={'tool':name,'elapsed_ms':round((time.monotonic()-start)*1000,2),'response_bytes':len(line),'error':data.get('error',{}).get('code'),'observation_status':obs.get('status'),'observation_error':obs.get('error_code'),'attempts':obs.get('attempts'),'node_count':obs.get('state',data).get('node_count')}
            with open(os.environ['ISSUE12_METRICS'],'a') as f:f.write(json.dumps(row)+'\n')
    except Exception:pass
    sys.stdout.buffer.write(line);sys.stdout.buffer.flush()
sys.exit(p.wait())
