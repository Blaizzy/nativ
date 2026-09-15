#!/usr/bin/env python3
"""Replay synthetic files through Nativ's existing HTTP STT and its Apple wake recognizer.

Uses macOS proc_pid_rusage v6. CPU energy excludes GPU/ANE/display and is NOT
whole-machine power or battery drain. Run with Nativ's live wake listener paused.
The server is reused without changing or unloading its models. Only synthetic
fixture WAVs are submitted; no microphone access is made by this script.
"""
import argparse, array, ctypes, io, json, os, queue, re, statistics, subprocess
import threading, time, urllib.request, uuid, wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'test-artifacts/voice-wake-benchmark-2026-09-15'
MODEL = 'CohereLabs/cohere-transcribe-03-2026'
BASE_URL = 'http://127.0.0.1:8080'

# Field order from the public macOS SDK, including ABI padding automatically.
SDK = Path(subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip())
header = (SDK/'usr/include/sys/resource.h').read_text().split('struct rusage_info_v6 {')[1].split('};')[0]
fields = []
for kind, name, count in re.findall(r'(uint8_t|uint64_t)\s+(\w+)(?:\[(\d+)\])?;', header):
    t = {'uint8_t': ctypes.c_uint8, 'uint64_t': ctypes.c_uint64}[kind]
    fields.append((name, t * int(count) if count else t))
class Usage(ctypes.Structure): _fields_ = fields
class Timebase(ctypes.Structure): _fields_ = [('numer',ctypes.c_uint32),('denom',ctypes.c_uint32)]
libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
libsystem = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
timebase = Timebase(); libsystem.mach_timebase_info(ctypes.byref(timebase))
TICKS_TO_SECONDS = timebase.numer / timebase.denom / 1e9

def processes():
    result = []
    for line in subprocess.check_output(['ps','-axo','pid=,ppid=,comm='],text=True).splitlines():
        parts = line.strip().split(None,2)
        if len(parts)==3: result.append((int(parts[0]),int(parts[1]),parts[2]))
    return result

def scope(engine, extra_pid=None):
    found = {os.getpid(): 'benchmark-driver'}
    for pid,ppid,name in processes():
        if engine == 'apple' and any(x in name for x in ['localspeechrecognition','com.apple.siri.embeddedspeech','CoreSpeechXPC']):
            found[pid] = name
        if engine == 'mlx' and 'Nativ.app/' in name and name.endswith('/python3'):
            found[pid] = name
    if extra_pid: found[extra_pid] = 'voice-apple-probe'
    return found

def usage(pid):
    value = Usage()
    if libproc.proc_pid_rusage(pid,6,ctypes.byref(value)) != 0: return None
    return { 'start':value.ri_proc_start_abstime,
        'cpu_s': (value.ri_user_time + value.ri_system_time)*TICKS_TO_SECONDS,
        'cpu_energy_j': value.ri_energy_nj/1e9,
        'rss_bytes':value.ri_resident_size, 'footprint_bytes':value.ri_phys_footprint,
        'neural_bytes':value.ri_neural_footprint,
        'idle_wakeups':value.ri_pkg_idle_wkups }

class Sampler:
    def __init__(self, engine, extra_pid=None):
        self.engine=engine; self.extra_pid=extra_pid; self.stop_event=threading.Event()
        self.samples=[]; self.names={}; self.started=time.monotonic();self.started_unix=time.time();self.discovery_at=float('-inf')
        self.capture()
        self.worker=threading.Thread(target=self.run,daemon=True);self.worker.start()
    def capture(self):
        if time.monotonic()-self.discovery_at >= 1:
            self.names.update(scope(self.engine,self.extra_pid));self.discovery_at=time.monotonic()
        snap={str(pid):v for pid in self.names if (v:=usage(pid)) is not None}
        self.samples.append({'seconds':time.monotonic()-self.started,'processes':snap})
    def run(self):
        while not self.stop_event.wait(0.25): self.capture()
    def finish(self):
        self.stop_event.set();self.worker.join();self.capture()
        duration=self.samples[-1]['seconds']; first=self.samples[0]['processes']
        wall_clock_seconds=time.time()-self.started_unix
        latest={}; initial=dict(first)
        for sample in self.samples:
            for pid,v in sample['processes'].items():
                if pid not in initial:
                    # New child processes start at zero; pre-existing workers start at
                    # their first observed sample. All discovered workers are normally
                    # present in the first sample because the recognizer is prewarmed.
                    initial[pid]=v
                latest[pid]=v
        cpu=energy=0;by_process={}
        for pid,v in latest.items():
            old=initial[pid]
            if old['start']==v['start']:
                delta_cpu=max(0,v['cpu_s']-old['cpu_s']);delta_energy=max(0,v['cpu_energy_j']-old['cpu_energy_j'])
                by_process[pid]={'cpu_seconds':delta_cpu,'cpu_energy_j':delta_energy}
                if int(pid)!=os.getpid():
                    cpu+=delta_cpu;energy+=delta_energy
        def total(s,key): return sum(v[key] for pid,v in s['processes'].items() if int(pid)!=os.getpid())
        return {'started_unix':self.started_unix,'wall_seconds':duration,
            'wall_clock_seconds':wall_clock_seconds,'clock_gap_seconds':wall_clock_seconds-duration,
            'cpu_seconds':cpu,'cpu_percent_one_core':100*cpu/duration,
            'cpu_energy_j':energy,'cpu_power_w':energy/duration,
            'initial_footprint_mib':total(self.samples[0],'footprint_bytes')/2**20,
            'peak_footprint_mib':max(total(s,'footprint_bytes') for s in self.samples)/2**20,
            'peak_neural_mib':max(total(s,'neural_bytes') for s in self.samples)/2**20,
            'processes':self.names,'per_process':by_process,'samples':self.samples}

def wav_bytes(samples,rate=16000):
    result=io.BytesIO()
    with wave.open(result,'wb') as f:
        f.setnchannels(1);f.setsampwidth(2);f.setframerate(rate);f.writeframes(samples.tobytes())
    return result.getvalue()

def read_wav(path):
    with wave.open(str(path),'rb') as f:
        assert f.getsampwidth()==2 and f.getnchannels()==1
        return array.array('h',f.readframes(f.getnframes())),f.getframerate()

def transcribe(data):
    boundary='VoiceBenchmark'+uuid.uuid4().hex
    parts=[]
    for name,value in [('model',MODEL),('response_format','json')]:
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    parts += [f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="benchmark.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode(),data,f'\r\n--{boundary}--\r\n'.encode()]
    request=urllib.request.Request(BASE_URL+'/v1/audio/transcriptions',b''.join(parts),
        headers={'Content-Type':'multipart/form-data; boundary='+boundary,'Accept':'application/json'})
    start=time.monotonic()
    with urllib.request.urlopen(request,timeout=60) as response: result=json.load(response)
    return {'request_seconds':time.monotonic()-start,'text':result.get('text','')}

def apple(path,realtime=True):
    events=queue.Queue()
    err=open(OUT/'apple-stderr.log','a')
    p=subprocess.Popen([str(ROOT/'build/voice-apple-probe'),str(path),'realtime' if realtime else 'fast'],
        stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=err,text=True,bufsize=1)
    def read():
        for line in p.stdout:
            try: events.put(json.loads(line))
            except json.JSONDecodeError: pass
        events.put({'event':'exit','returncode':p.poll()})
    threading.Thread(target=read,daemon=True).start()
    sampler=None
    try:
        ready=events.get(timeout=45)
        if ready['event']!='ready': raise RuntimeError(ready)
        sampler=Sampler('apple',p.pid)
        p.stdin.write('go\n');p.stdin.flush()
        results=[]
        while True:
            e=events.get(timeout=45);results.append(e)
            if e['event']=='done': break
            if e['event'] in ['error','exit']: raise RuntimeError(e)
        metrics=sampler.finish();sampler=None
        return {'engine':'apple','fixture':path.stem,'realtime':realtime,'ready':ready,'events':results,'metrics':metrics}
    finally:
        if sampler: sampler.finish()
        if p.poll() is None:
            try: p.stdin.write('quit\n');p.stdin.flush();p.wait(timeout=5)
            except (BrokenPipeError,subprocess.TimeoutExpired): p.kill();p.wait()
        err.close()

def mlx_replay(path,window=4,hop=1,gated=False):
    samples,rate=read_wav(path);duration=len(samples)/rate
    sampler=Sampler('mlx');start=time.monotonic();results=[];skipped=0
    # Precomputed PCM excludes fixture preparation and gives both recognizers the same audio.
    end=window
    try:
        while end<=duration:
            target=start+end;time.sleep(max(0,target-time.monotonic()))
            chunk=samples[int((end-window)*rate):int(end*rate)]
            rms=(sum(x*x for x in chunk)/len(chunk))**0.5/32768
            if gated and rms<0.003:
                skipped+=1
            else:
                sent=time.monotonic()-start
                r=transcribe(wav_bytes(chunk,rate));r.update({'audio_start':end-window,'audio_end':end,
                    'sent_at':sent,'received_at':time.monotonic()-start,'rms':rms})
                results.append(r)
            end+=hop
        time.sleep(max(0,start+duration-time.monotonic()))
    finally: metrics=sampler.finish()
    return {'engine':'mlx-gated' if gated else 'mlx','fixture':path.stem,'window':window,'hop':hop,
        'skipped':skipped,'events':results,'metrics':metrics}

def save(result,filename='runs.jsonl'):
    with open(OUT/filename,'a') as f:f.write(json.dumps(result)+'\n')
    brief={k:v for k,v in result.items() if k not in ['events','metrics']}
    if 'metrics'in result:brief['metrics']={k:v for k,v in result['metrics'].items() if k not in ['samples','processes','per_process']}
    print(json.dumps(brief),flush=True)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--mode',choices=['pilot','runs','power','soak'],default='pilot')
    args=parser.parse_args();OUT.mkdir(parents=True,exist_ok=True)
    if args.mode=='pilot':
        for name in ['wake-samantha','wake-daniel','dictation','silence3']:
            data=(OUT/(name+'.wav')).read_bytes()
            for trial in range(3):
                start=time.monotonic();m=Sampler('mlx');r=transcribe(data);metrics=m.finish()
                save({'engine':'mlx-file','fixture':name,'trial':trial,**r,'metrics':metrics},'pilot.jsonl')
                save(apple(OUT/(name+'.wav'),realtime=False),'pilot.jsonl')
    elif args.mode=='runs':
        for engine in ['apple','mlx']:
            m=Sampler(engine);time.sleep(10);save({'engine':engine,'fixture':'idle-baseline','metrics':m.finish()})
        # Alternating order limits systematic warm-up/thermal bias.
        for repetition in range(2):
            order=['apple','mlx'] if repetition==0 else ['mlx','apple']
            for fixture in ['silence30','mixed30']:
                for engine in order:
                    r=apple(OUT/(fixture+'.wav')) if engine=='apple' else mlx_replay(OUT/(fixture+'.wav'))
                    r['repetition']=repetition;save(r)
        for fixture in ['silence30','mixed30']:
            save(mlx_replay(OUT/(fixture+'.wav'),gated=True))
    elif args.mode=='soak':
        samples,rate=read_wav(OUT/'mixed30.wav')
        fixture=ROOT/'build/wake-soak-15min.wav'
        fixture.write_bytes(wav_bytes(samples*30,rate))
        result=apple(fixture)
        result.update({'repetitions':30,'fixture_period_seconds':len(samples)/rate})
        save(result,'soak.jsonl')
    else:
        silence=OUT/'silence45.wav';silence.write_bytes(wav_bytes(array.array('h',[0])*(16000*45)))
        with open(OUT/'power-samples.jsonl','w') as power_log:
            probe=subprocess.Popen([str(ROOT/'build/voice-power-probe'),'300'],stdout=power_log)
            try:
                for step in ['baseline','apple','mlx','baseline','mlx','apple','baseline']:
                    if step=='baseline':
                        start=time.time();time.sleep(15)
                        save({'engine':'baseline','fixture':'no-replay','started_unix':start,'wall_seconds':time.time()-start},'power-runs.jsonl')
                    else:
                        save(apple(silence) if step=='apple' else mlx_replay(silence),'power-runs.jsonl')
            finally:
                probe.terminate();probe.wait(timeout=5)
if __name__=='__main__': main()
