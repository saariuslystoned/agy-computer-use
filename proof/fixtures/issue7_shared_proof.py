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
try:
    status=ok(call('status',session_id=session)); assert status['input_isolation_mode']=='operator_safe_ax'
    assert status['accessibility_trusted'] and status['operator_safe_ax_available']
    assert status['supported_action_strategies']==['ax_semantic']
    (out/'status.json').write_text(json.dumps(status,indent=2)+'\n')
    initial=image('before')
    common=dict(capture_id=initial['image']['capture_id'],topology_version=status['topology_version'],intent='Verify native shared-mode denial',session_id=session)
    extras=dict(click=dict(x=500,y=500),move=dict(x=500,y=500),type=dict(text='forbidden-global-value'),shortcut=dict(keys=['tab']),scroll=dict(x=500,y=500,delta_y=30),drag=dict(start_x=400,start_y=400,end_x=500,end_y=500))
    for action, params in extras.items():
        for forged in [False,True]:
            payload={**common,**params}
            if forged: payload.update(exclusive=True,exclusive_lease_id='forged')
            r=call(action,**payload)
            assert not r['success'] and r['error']['code']=='OPERATOR_EXCLUSIVE_REQUIRED',r
            assert r['error']['details']==dict(strategy='rejected',global_hid_posts='0'),r
            rows.append(dict(case=action,forged_boolean=forged,error='OPERATOR_EXCLUSIVE_REQUIRED',global_hid_posts=0))
    rejected=call('exclusive_control',session_id=session,operation='acquire',app_id=app,duration_ms=1000)
    assert not rejected['success'] and rejected['error']['code']=='OPERATOR_EXCLUSIVE_REQUIRED'
    rows.append(dict(case='unprovisioned_admission',error=rejected['error']['code']))
    for identifier in ['Clear','2','+','3','=']:
        state=act('issue12-'+identifier,'press')
    assert any(n.get('identifier')=='issue12-result' and n.get('value')=='5' for n in nodes(state['tree']))
    for index in range(15):
        value='issue7-background-'+str(index)
        state=act('issue12-input','set_value',value)
        assert any(n.get('identifier')=='issue12-input' and n.get('value')==value for n in nodes(state['tree']))
    final=image('after')
    assert all(n.get('value')!='forbidden-global-value' for n in nodes(final['state']['tree']))
    rows.append(dict(case='verified_final_calculator_and_form',passed=True))
    ok(call('ax_session_close',session_id=session))
    (out/'assertions.json').write_text(json.dumps(rows,indent=2)+'\n')
    print(json.dumps(dict(passed=True,assertions=len(rows),semantic_actions=20,global_attempts=12)))
except Exception:
    (out/'partial-assertions.json').write_text(json.dumps(rows,indent=2)+'\n'); raise
