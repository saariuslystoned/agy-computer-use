"""Source-bound shared-mode proof against disposable targets; no global sends."""
import base64, hashlib, json, socket, struct, sys, time, uuid
from pathlib import Path
socket_path, state_path, out_path = sys.argv[1:4]
out = Path(out_path); out.mkdir(parents=True, exist_ok=True)
app = str(json.loads(Path(state_path).read_text())['pid'])
session = 'issue7-native-proof'
rows = []
def call(method, **params):
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(20); s.connect(socket_path)
        b = json.dumps(dict(id=str(uuid.uuid4()), method=method, params=params)).encode()
        s.sendall(struct.pack('>I',len(b))+b)
        def read(n):
            data=b''
            while len(data)<n:
                chunk=s.recv(n-len(data))
                if not chunk: raise EOFError()
                data+=chunk
            return data
        return json.loads(read(struct.unpack('>I',read(4))[0]))
def ok(r):
    assert r['success'], r.get('error'); return r['data']
def nodes(n):
    yield n
    for child in n.get('children',[]): yield from nodes(child)
def tree():
    # Read-only intervention races may be retried; mutations never are.
    for attempt in range(3):
        r=call('ax_tree',app_id=app,session_id=session,max_depth=8)
        if r['success']: return r['data']
        assert r['error']['code']=='USER_INTERVENED'
    return ok(r)
def act(identifier, action, value=None):
    state=tree(); item=next(n for n in nodes(state['tree']) if n.get('identifier')==identifier)
    params={k:state[k] for k in ['ax_snapshot_id','app_instance_ref','topology_version']}
    params.update(session_id=session,element_ref=item['element_ref'],action=action,intent='Disposable isolation fixture',observe={'condition':'snapshot','timeout_ms':2000})
    if value is not None: params['value']=value
    result=ok(call('ax_action_observe',**params))
    assert result['strategy']=='ax_semantic' and result['global_hid_posts']==0
    observed=result['observation']; assert observed['status'] in ['changed','unchanged']
    rows.append(dict(case=action, identifier=identifier, strategy=result['strategy'], global_hid_posts=0, intervention_scope=state.get('intervention_scope')))
    return observed['state']
def image(label):
    targets=ok(call('targets',app_id=app,session_id=session)); assert len(targets['windows'])==1
    data=ok(call('window_observe',app_id=app,session_id=session,window_ref=targets['windows'][0]['window_ref'],max_depth=8))
    raw=base64.b64decode(data['image']['image_data_base64']); assert hashlib.sha256(raw).hexdigest()==data['image']['image_sha256']
    (out/(label+'.jpg')).write_bytes(raw)
    return data
started=time.monotonic()
initial=image('before')
for index in range(20):
    before=json.loads(Path(sys.argv[4]).read_text())
    state=act('issue12-input','set_value','issue7-overlap-'+str(index))
    assert any(n.get('identifier')=='issue12-input' and n.get('value')=='issue7-overlap-'+str(index) for n in nodes(state['tree']))
    time.sleep(1)
    after=json.loads(Path(sys.argv[4]).read_text())
    rows[-1].update(elapsed_s=round(time.monotonic()-started,3),sentinel_keys_during_iteration=after['key_events']-before['key_events'],sentinel_front_before=before['frontmost'],sentinel_front_after=after['frontmost'],sentinel_focused_before=before['field_is_first_responder'],sentinel_focused_after=after['field_is_first_responder'])
image('after')
ok(call('ax_session_close',session_id=session))
(out/'assertions.json').write_text(json.dumps(rows,indent=2)+'\n')
print(json.dumps(dict(passed=True,semantic_actions=len(rows),elapsed_s=round(time.monotonic()-started,3),iterations_with_human_keys=sum(r['sentinel_keys_during_iteration']>0 for r in rows))))
