#!/usr/bin/env python3
"""Replay failed final requests with the same closing guidance after the evidence.
This is a diagnostic of final-answer behavior, not an end-to-end benchmark.
"""
import argparse
import json
from pathlib import Path
import time
import urllib.request
from benchmark import request, generate

p = argparse.ArgumentParser()
p.add_argument('--results', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--base', default='http://127.0.0.1:18986')
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=True)
for path in sorted(a.results.glob('live-*-recovery-*/result.json')):
    original = json.loads(path.read_text())
    if len(original['steps']) != 33 or '<|tool_call' not in original.get('final', ''):
        continue
    payload = original['steps'][-1]['inference']['request']
    guide = payload['instructions'].rsplit('\n\n', 1)[-1]
    assert 'Tools are no longer available.' in guide
    payload['input'].append({'type': 'message', 'role': 'user', 'content': guide})
    payload.pop('tools', None)
    request(a.base, '/unload', {})
    generate(a.base, {'model': payload['model'], 'messages': [{'role': 'user', 'content': 'Say ready.'}],
                     'max_tokens': 8, 'temperature': 0, 'enable_thinking': False})
    started = time.perf_counter()
    req = urllib.request.Request(a.base+'/v1/responses', json.dumps(payload).encode(), {'Content-Type': 'application/json'})
    events, response = [], None
    with urllib.request.urlopen(req, timeout=900) as stream:
        for line in stream:
            if not line.startswith(b'data:') or line[5:].strip() == b'[DONE]':
                continue
            event = json.loads(line[5:]); events.append(event)
            if event.get('type') in ('response.completed', 'response.incomplete'):
                response = event['response']; break
    assert response is not None
    final = ''.join(part.get('text', '') for item in response.get('output', []) if item.get('type') == 'message'
                    for part in item.get('content', []) if part.get('type') == 'output_text')
    result = {'source_run': path.parent.name, 'request': payload, 'events': events, 'final': final,
              'seconds': time.perf_counter()-started, 'original_final': original['final'],
              'has_tool_markup': any(s in final for s in ('<|tool_call', '<tool_call', 'call:chat_work')),
              'scope': 'Final-request replay only; source quality and task completion require manual review.'}
    (a.output/(path.parent.name+'.json')).write_text(json.dumps(result, indent=2))
    print(path.parent.name, 'tool markup', result['has_tool_markup'], final[:240], flush=True)
