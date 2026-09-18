#!/usr/bin/env python3
"""Summarize raw logs without treating CPU-only energy as battery power."""
import json, re, statistics
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'test-artifacts/voice-wake-benchmark-2026-09-15'

def read(name):
    path=OUT/name
    return [json.loads(line) for line in path.read_text().splitlines() if line] if path.exists() else []

def stats(values):
    return {'n':len(values),'mean':statistics.mean(values),'median':statistics.median(values),
        'min':min(values),'max':max(values)} if values else None

runs=read('runs.jsonl');pilot=read('pilot.jsonl');power=read('power-samples.jsonl');phases=read('power-runs.jsonl')
expected=[e for e in json.loads((OUT/'fixtures.json').read_text())['events'] if e['wake']]
summary={'steady_state':{},'file_latency':{},'wake_latency':{},'power_phases':[], 'soak_runs':[]}
for engine in ['apple','mlx','mlx-gated']:
    summary['steady_state'][engine]={}
    for fixture in ['silence30','mixed30']:
        selected=[r for r in runs if r['engine']==engine and r['fixture']==fixture]
        if not selected:continue
        summary['steady_state'][engine][fixture]={key:stats([r['metrics'][key] for r in selected])
            for key in ['cpu_percent_one_core','cpu_power_w','peak_footprint_mib','peak_neural_mib']}
        if engine!='apple':
            summary['steady_state'][engine][fixture]['requests_per_run']=[len(r['events']) for r in selected]
            summary['steady_state'][engine][fixture]['request_seconds']=stats([e['request_seconds'] for r in selected for e in r['events']])
    latencies=[];missing=0
    for run in runs:
        if run['engine']!=engine or run['fixture']!='mixed30':continue
        for target in expected:
            candidates=[]
            for e in run['events']:
                received=e.get('seconds',e.get('received_at',0))
                if (re.search(r'\bhey\W+nativ(?:e)?\b',e.get('text',''),re.I)
                    and e['audio_start'] <= target['start'] and e['audio_end'] >= target['end']
                    and received >= target['end']):
                    candidates.append(received-target['end'])
            if candidates:latencies.append(min(candidates))
            else:missing+=1
    summary['wake_latency'][engine]={'delay_after_phrase_seconds':stats(latencies),'misses':missing}
for engine in ['apple','mlx-file']:
    summary['file_latency'][engine]={}
    for fixture in ['wake-samantha','wake-daniel','dictation','silence3']:
        selected=[r for r in pilot if r['engine']==engine and r['fixture']==fixture]
        values=[r['events'][-1]['elapsed_seconds'] if engine=='apple' else r['request_seconds'] for r in selected]
        summary['file_latency'][engine][fixture]=stats(values)
for phase in phases:
    m=phase.get('metrics',phase);start=m['started_unix'];end=start+m['wall_seconds']
    # Skip first/last boundaries: audio/model setup and sensor read intervals overlap.
    selected=[s for s in power if start+5 <= s['unix_seconds'] <= end-2]
    entry={'engine':phase['engine'],'started_unix':start,'wall_seconds':m['wall_seconds'],
        'samples':len(selected)}
    for field in ['cpu_w','gpu_w','ane_w','dram_w','soc_w','system_input_w','die_c']:
        entry[field]=stats([s[field] for s in selected if s.get(field) is not None])
    summary['power_phases'].append(entry)
for run in read('soak.jsonl'):
    metrics=run['metrics']
    names=metrics['processes']
    backend_pids={pid for pid,name in names.items() if name!='benchmark-driver'}
    helper_pids={pid for pid,name in names.items() if name=='voice-apple-probe'}
    periods=[]
    for minute in range(int(metrics['wall_seconds']//60)):
        selected=[s for s in metrics['samples'] if minute*60 <= s['seconds'] < (minute+1)*60]
        def footprint(sample,pids,key):
            return sum(v[key] for pid,v in sample['processes'].items() if pid in pids)/2**20
        periods.append({'minute':minute+1,
            'helper_footprint_mib':stats([footprint(s,helper_pids,'footprint_bytes') for s in selected]),
            'backend_footprint_mib':stats([footprint(s,backend_pids,'footprint_bytes') for s in selected]),
            'backend_neural_mib':stats([footprint(s,backend_pids,'neural_bytes') for s in selected])})
    delays=[];missing=0
    for repetition in range(run['repetitions']):
        offset=repetition*run['fixture_period_seconds']
        for target in expected:
            candidates=[e['seconds']-(target['end']+offset) for e in run['events']
                if e.get('event')=='result'
                and re.search(r'\bhey\W+nativ(?:e)?\b',e.get('text',''),re.I)
                and e['audio_start'] <= target['start']+offset
                and e['audio_end'] >= target['end']+offset
                and e['seconds'] >= target['end']+offset]
            if candidates:delays.append(min(candidates))
            else:missing+=1
    summary['soak_runs'].append({'wall_seconds':metrics['wall_seconds'],
        'completed':run['events'][-1].get('event')=='done',
        'errors':[e for e in run['events'] if e.get('event')=='error'],
        'continuous_run_valid':not bool(run.get('system_sleep_interruption')) and abs(metrics.get('clock_gap_seconds',0))<2,
        'system_sleep_interruption':run.get('system_sleep_interruption'),
        'wake_events_matched':len(delays),'wake_events_missing':missing,
        'delay_after_phrase_seconds':stats(delays),'memory_by_minute':periods,
        'live_app_listener_paused':run.get('live_app_listener_paused')})
(OUT/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2))
