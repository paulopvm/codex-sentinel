#!/usr/bin/env python3
"""Exercise the Swift adapter against a local Unix fixture. Never connects to a real Codex."""
import json, os, socket, struct, subprocess, sys, tempfile, threading

def receive(conn):
    def read(size):
        data = b''
        while len(data) < size:
            part = conn.recv(size - len(data))
            if not part:
                raise EOFError()
            data += part
        return data
    return json.loads(read(struct.unpack('<I', read(4))[0]))

def send(conn, message):
    data = json.dumps(message).encode()
    frame = struct.pack('<I', len(data)) + data
    # Fragment frames deliberately: reads must not assume a single packet.
    conn.sendall(frame[:3]); conn.sendall(frame[3:])

def reply(conn, request, result, owner='owner'):
    send(conn, dict(type='response', requestId=request['requestId'], resultType='success',
                   method=request['method'], handledByClientId=owner, result=result))

for scenario, expected in [('success', 'success'), ('busy', 'deferred'), ('approval', 'deferred'),
                           ('version', 'deferred'), ('owner', 'deferred'), ('absent', 'deferred'),
                           ('drop', 'unknown'), ('bad_ack', 'unknown'), ('absent_then_ready', 'load')]:
    failures = []
    starts = []
    with tempfile.TemporaryDirectory(prefix='sn-', dir='/tmp') as directory:
        os.chmod(directory, 0o700)
        path = directory + '/ipc.sock'
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(path); os.chmod(path, 0o600); listener.listen(1)
        def serve():
            try:
                if scenario == 'absent_then_ready':
                    initial, _ = listener.accept()
                    with initial:
                        initial.settimeout(2)
                        request = receive(initial)
                        reply(initial, request, {'clientId': 'sentinel'}, owner='sentinel')
                        request = receive(initial)
                        send(initial, dict(type='response', requestId=request['requestId'], resultType='error', error='no-client-found'))
                        assert initial.recv(1) == b''
                conn, _ = listener.accept()
                with conn:
                    conn.settimeout(2)
                    request = receive(conn)
                    assert request['method'] == 'initialize'
                    reply(conn, request, {'clientId': 'sentinel'}, owner='sentinel')
                    request = receive(conn)
                    assert request['method'] == 'thread-owner-discovery'
                    assert request['params'] == {'hostId': 'local', 'conversationId': 'fixture-thread'}
                    if scenario == 'absent':
                        send(conn, dict(type='response', requestId=request['requestId'], resultType='error', error='no-client-found'))
                        assert conn.recv(1) == b''
                        return
                    reply(conn, request, {'supportsUntrustedAppInput': True})
                    request = receive(conn)
                    assert request['method'] == 'thread-stream-following-changed'
                    send(conn, dict(type='broadcast', method='thread-stream-state-changed', version=99 if scenario == 'version' else 11,
                         sourceClientId='owner', params={'conversationId': 'fixture-thread', 'hostId': 'local', 'change': {
                         'type': 'snapshot', 'conversationState': {'id': 'fixture-thread', 'resumeState': 'resumed',
                         'threadRuntimeStatus': {'type': 'active' if scenario == 'busy' else 'idle'},
                         'requests': [{'approval': True}] if scenario == 'approval' else []}}}))
                    if scenario in ['version', 'busy', 'approval']:
                        assert conn.recv(1) == b'', 'unsafe state must not dispatch a turn'
                        return
                    request = receive(conn)
                    starts.append(request)
                    assert request['method'] == 'thread-follower-start-turn' and request['version'] == 2
                    assert request['targetClientId'] == 'owner'
                    assert request['params']['turnStart']['request'] == {
                        'threadId': 'fixture-thread', 'input': [{'type': 'text', 'text': 'fixture continuation'}]}
                    assert request['params']['turnStart']['context']['inheritThreadSettings'] is True
                    if scenario == 'drop':
                        return
                    if scenario == 'owner':
                        # A changed owner cannot validate the start acknowledgment.
                        reply(conn, request, {'result': {'turn': {'id': 'fixture-desktop-turn'}}}, owner='different-owner')
                    elif scenario == 'bad_ack':
                        reply(conn, request, {'result': {}})
                    else:
                        reply(conn, request, {'result': {'turn': {'id': 'fixture-desktop-turn'}}})
            except BaseException as exc:
                failures.append(exc)
        # Owner mismatch after dispatch is ambiguous, not a safe retry.
        if scenario == 'owner': expected = 'unknown'
        worker = threading.Thread(target=serve, daemon=True); worker.start()
        result = subprocess.run([sys.argv[1], path, expected], capture_output=True, text=True, timeout=8)
        worker.join(3); listener.close()
        assert not worker.is_alive(), scenario + ': fixture server stalled'
        assert not failures, (scenario, failures)
        assert result.returncode == 0, (scenario, result.stdout, result.stderr)
        assert len(starts) == (0 if scenario in ['busy', 'approval', 'version', 'absent'] else 1)
        print(scenario + ': ' + result.stdout.strip())
print('9 desktop IPC checks passed')
