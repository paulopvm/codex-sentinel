#!/usr/bin/env python3
import json, sys
pending = []
def send(value):
    data = (json.dumps(value) + '\n').encode()
    for start in range(0, len(data), 8191):
        sys.stdout.buffer.write(data[start:start + 8191])
        sys.stdout.buffer.flush()
for line in sys.stdin:
    request = json.loads(line)
    method = request.get('method')
    if method == 'initialize':
        send({'id': request['id'], 'result': {}})
    elif method == 'initialized':
        pass
    elif method == 'thread/read':
        pending.append(request)
        if len(pending) == 12:
            for item in reversed(pending):
                send({'method': 'fixture/notification', 'params': {'padding': 'n' * 10000}})
                send({'id': item['id'], 'result': {'padding': 'x' * 400000, 'thread': {
                    'status': {'type': 'idle'}, 'turns': [{'id': item['params']['threadId'], 'status': 'completed'}]}}})
            pending.clear()
    else:
        raise ValueError('unexpected fixture method')
