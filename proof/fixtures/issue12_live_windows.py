"""Explicit disposable-fixture proof. Never enumerates/captures other app content."""
import base64, hashlib, json, math, socket, struct, sys, time, uuid
from pathlib import Path
socket_path, fixture_root, output_root = sys.argv[1:]
f = Path(fixture_root); out = Path(output_root); out.mkdir(parents=True, exist_ok=True)
lab = str(json.loads((f/'lab-state.json').read_text())['pid'])
windows = str(json.loads((f/'windows-state.json').read_text())['pid'])
results = []
def call(method, **params):
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(20); s.connect(socket_path)
        b=json.dumps(dict(id=str(uuid.uuid4()),method=method,params=params)).encode()
        s.sendall(struct.pack('>I',len(b))+b)
        def read(n):
            b=b''
            while len(b)<n:
                chunk=s.recv(n-len(b))
                if not chunk: raise EOFError()
                b+=chunk
            return b
        return json.loads(read(struct.unpack('>I',read(4))[0]))
def ok(response):
    assert response['success'], response.get('error')
    return response['data']
def reject(label, response, codes):
    assert not response['success'] and response['error']['code'] in codes, response
    results.append(dict(case=label,passed=True,error_code=response['error']['code']))
def record(label, **values):
    results.append(dict(case=label,passed=True,**values))
def nodes(node):
    yield node
    for child in node.get('children',[]): yield from nodes(child)
def action(state, session, identifier, value):
    field=next(n for n in nodes(state['tree']) if n.get('identifier')==identifier)
    return call('ax_action_observe',session_id=session,**{k:state[k] for k in ['ax_snapshot_id','app_instance_ref','topology_version']},
        element_ref=field['element_ref'],action='set_value',value=value,intent='Disposable fixture proof',observe={'condition':'snapshot','timeout_ms':2000})
def verified(response, identifier, expected):
    data=ok(response); observation=data['observation']
    assert observation['status'] in ['changed','unchanged'], observation
    node=next(n for n in nodes(observation['state']['tree']) if n.get('identifier')==identifier)
    assert node['value']==expected, node
    assert data['global_hid_posts']==0
    return observation['state']
def discover(session):
    data=ok(call('targets',app_id=windows,session_id=session))
    return {w['title'].rsplit(' ',1)[-1]:w['window_ref'] for w in data['windows']}
def observe(session, ref):
    return ok(call('window_observe',app_id=windows,window_ref=ref,session_id=session))
def command(op, key='A', **extra):
    ident=str(uuid.uuid4()); value=dict(id=ident,op=op,window=key,**extra)
    temp=f/'windows-command.tmp';temp.write_text(json.dumps(value));temp.replace(f/'windows-command.json')
    deadline=time.monotonic()+3
    while time.monotonic()<deadline:
        state=json.loads((f/'windows-state.json').read_text())
        if state['completed']==ident: return state
        time.sleep(.05)
    raise AssertionError('Fixture command not acknowledged')
def save_image(label,data):
    encoded=data['image'];raw=base64.b64decode(encoded['image_data_base64'])
    assert hashlib.sha256(raw).hexdigest()==encoded['image_sha256']
    (out/(label+'.jpg')).write_bytes(raw)
    for key in ['window_ref','ax_snapshot_id','app_instance_ref']:
        assert data['state'].get(key) is not None
    assert data['state']['window_ref']==data['window']['window_ref']
    assert data['state']['tree']['bounds']==data['window']['bounds']
    timing=data['timing'];assert not timing['atomic']
    assert timing['ax_before_ms']<=timing['image_started_ms']<=encoded['timestamp']<=timing['image_completed_ms']<=timing['ax_after_ms']
    return dict(display=data['window']['display'],bounds=data['window']['bounds'],pixels=[encoded['pixel_width'],encoded['pixel_height']],
        scale=encoded['scale_factor'],image_sha256=encoded['image_sha256'],node_count=data['state']['node_count'],timing=timing)
try:
    status=ok(call('status'));assert status['display_count']==3
    (out/'topology.json').write_text(json.dumps(status['topology'],indent=2)+'\n')
    refs=discover('window-one');refs2=discover('window-two')
    assert 'A' in refs and 'B' in refs
    reject('multiple_windows_require_selection',call('window_observe',app_id=windows,session_id='ambiguous'),['TARGET_UNREACHABLE'])
    reject('foreign_session_reference',call('window_observe',app_id=windows,window_ref=refs['A'],session_id='foreign'),['STALE_OPERATION'])
    reject('wrong_app_reference',call('window_observe',app_id=lab,window_ref=refs['A'],session_id='window-one'),['STALE_OPERATION'])
    # Different apps and sessions preserve pending authority.
    state=ok(call('ax_tree',app_id=lab,session_id='app-one'))
    ok(call('ax_tree',app_id=windows,session_id='app-two'))
    verified(action(state,'app-one','issue12-input','independent-app'), 'issue12-input','independent-app')
    record('independent_app_and_session_lease')
    a=observe('window-one',refs['A']);b=observe('window-one',refs['B'])
    verified(action(a['state'],'window-one','issue12-input-A','independent-A'),'issue12-input-A','independent-A')
    verified(action(b['state'],'window-one','issue12-input-B','independent-B'),'issue12-input-B','independent-B')
    record('independent_windows_same_session')
    a=observe('window-one',refs['A']);competing=observe('window-two',refs2['A'])
    verified(action(a['state'],'window-one','issue12-input-A','winner'),'issue12-input-A','winner')
    reject('same_window_first_writer_fences_second',action(competing['state'],'window-two','issue12-input-A','forbidden-loser'),['STALE_AX_SNAPSHOT'])
    # Move the owned window via its own controller, never the system pointer.
    for label,display_id,x,y in [('built-in',1,180,250),('portrait-negative',2,-1300,-1100),('upper-retina',4,250,-850)]:
        old=observe('window-one',refs['A'])
        height=old['window']['bounds']['height']
        command('move',x=x,y=1117-y-height)
        time.sleep(.3)
        reject('old_lease_after_move_'+label,action(old['state'],'window-one','issue12-input-A','forbidden-moved'),['STALE_OPERATION'])
        fresh=observe('window-one',refs['A']);assert fresh['window']['display']['id']==display_id
        assert fresh['window']['bounds']['x']==x and fresh['window']['bounds']['y']==y
        bounds=fresh['window']['bounds'];display=fresh['window']['display'];image=fresh['image']
        assert math.isclose(fresh['screen_points_per_pixel_x'],bounds['width']/image['pixel_width'])
        assert math.isclose(fresh['display_normalized_offset_x'],(x-display['origin_x'])*1000/display['width_points'])
        assert math.isclose(fresh['display_normalized_offset_y'],(y-display['origin_y'])*1000/display['height_points'])
        record('display_'+label,**save_image(label,fresh))
    b=observe('window-two',refs2['B']);ok(call('ax_session_close',session_id='window-one'))
    reject('closed_session_reference',call('window_observe',app_id=windows,window_ref=refs['A'],session_id='window-one'),['STALE_OPERATION'])
    verified(action(b['state'],'window-two','issue12-input-B','survived-close'),'issue12-input-B','survived-close')
    record('closing_one_session_preserves_another')
    refs=discover('replace');old_b=observe('replace',refs['B'])
    command('replace','B')
    reject('replacement_rejects_old_reference',call('window_observe',app_id=windows,window_ref=refs['B'],session_id='replace'),['STALE_OPERATION'])
    reject('replacement_rejects_old_authority',action(old_b['state'],'replace','issue12-input-B','forbidden-replaced'),['STALE_OPERATION'])
    refs=discover('dialog');command('dialog')
    reject('new_dialog_requires_rediscovery',call('window_observe',app_id=windows,window_ref=refs['A'],session_id='dialog'),['STALE_OPERATION'])
    new=discover('dialog');assert 'Dialog' in new
    record('dialog_discovered_explicitly');command('close-dialog')
    refs=discover('expiry');expiry=observe('expiry',refs['B'])
    print('Display, binding and session assertions passed; checking real lease expiry.',flush=True)
    time.sleep(31)
    reject('real_30_second_expiry',action(expiry['state'],'expiry','issue12-input-B','forbidden-expired'),['STALE_AX_SNAPSHOT'])
    final=json.loads((f/'windows-state.json').read_text())
    assert not any(v.startswith('forbidden') for v in final['values'].values())
    record('rejected_writes_never_applied')
finally:
    (out/'assertions.json').write_text(json.dumps(results,indent=2)+'\n')
    for session in ['window-one','window-two','foreign','ambiguous','app-one','app-two','replace','dialog','expiry']:
        call('ax_session_close',session_id=session)
print(json.dumps({'passed':len(results),'failed':0}),flush=True)
