#!/usr/bin/env python3
"""Generate non-private, deterministic benchmark audio with the macOS system voices."""
import array
import json
from pathlib import Path
import subprocess
import wave

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'test-artifacts/voice-wake-benchmark-2026-09-15'
OUT.mkdir(parents=True,exist_ok=True)
BUILD=ROOT/'build';BUILD.mkdir(exist_ok=True)
RATE=16000
phrases=[('wake-samantha','Samantha','Hey native'),('wake-daniel','Daniel','Hey native'),
 ('dictation','Samantha','Please send the updated project notes to the team tomorrow morning. We should review the remaining tasks and agree on the next steps before Friday.')]
clips={}

def save(name,samples):
    with wave.open(str(OUT/(name+'.wav')),'wb') as f:
        f.setnchannels(1);f.setsampwidth(2);f.setframerate(RATE);f.writeframes(samples.tobytes())

for name,voice,text in phrases:
    path=BUILD/('voice-'+name+'.wav')
    subprocess.run(['say','-v',voice,'-r','175','-o',str(path),'--data-format=LEI16@16000',text],check=True)
    with wave.open(str(path),'rb') as f:
        assert f.getframerate()==RATE and f.getnchannels()==1 and f.getsampwidth()==2
        samples=array.array('h',f.readframes(f.getnframes()))
    clips[name]=samples
    save(name,array.array('h',[0])*(RATE//2)+samples+array.array('h',[0])*RATE)
silence=array.array('h',[0])*(RATE*30);save('silence30',silence)
save('silence3',array.array('h',[0])*(RATE*3))
mixed=array.array('h',silence);events=[]
for start,name in [(3,'wake-samantha'),(7,'dictation'),(17,'wake-daniel'),(21,'dictation')]:
    samples=clips[name];mixed[int(start*RATE):int(start*RATE)+len(samples)]=samples
    events.append({'start':start,'end':start+len(samples)/RATE,'name':name,'wake':name.startswith('wake')})
save('mixed30',mixed)
(OUT/'fixtures.json').write_text(json.dumps({'sample_rate':RATE,'events':events,
    'source':'macOS say, Samantha and Daniel, 175 words/minute; synthetic English; no microphone'},indent=2)+'\n')
