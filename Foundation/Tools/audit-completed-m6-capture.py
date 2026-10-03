#!/usr/bin/env python3
"""Read-only oracle for completed M6 captures with recorded clock metadata.
Usage: audit-completed-m6-capture.py capture-directory new-external-output-directory
Adapted from the retained Alpha0.0.65 / Build179 independent verification.
Asserts its zero-host-loss/sequence and four-hash contracts; never repairs a
capture or infers hardware qualification from a passing saved-file inspection.
"""
from pathlib import Path
import json,hashlib,struct,collections,re,sys
if len(sys.argv) != 3: raise SystemExit(__doc__)
capture=Path(sys.argv[1]).resolve()
p=Path(sys.argv[2]).resolve()
repo=Path(__file__).resolve().parents[2]
if p == repo or repo in p.parents or p == capture or capture in p.parents:
 raise SystemExit("Use a new output directory outside the checkout and capture")
p.mkdir(mode=0o700,parents=True,exist_ok=False)
v=json.loads((capture/'verification.json').read_text())
files=['receive.records.raw','capture.dv','frames.ndjson','flight.ndjson','verification.json']
before={n:(capture/n).stat().st_size for n in files}
rows=[json.loads(line) for line in (capture/'flight.ndjson').read_text().splitlines()]
tb=dict(re.findall(r'(raw_host_ticks_timebase_\w+)=(\d+)',rows[0]['message']))
if not {'raw_host_ticks_timebase_numerator','raw_host_ticks_timebase_denominator'} <= tb.keys():
 raise SystemExit("UNVERIFIED: recorded host clock timebase is missing; do not substitute this machine's clock")
scale=int(tb['raw_host_ticks_timebase_numerator'])/int(tb['raw_host_ticks_timebase_denominator'])/1e9
statuses=collections.Counter();sizes=collections.Counter();h=hashlib.sha256();count=0;first=None;last=None;dbc=None;gaps=[];empties=0;empty_start=None;raw_bytes=0
with (capture/'receive.records.raw').open('rb') as f:
 assert f.read(8)==b'RDRXLOG1'
 while header:=f.read(64):
  assert len(header)==64
  seq,epoch,ticks,cycle,index,status,residual,size,observed,loss,flags,reserved=struct.unpack('<QQQIIHHIQQII',header)
  payload=f.read(size);assert len(payload)==size and size<=4096
  count+=1;assert seq==count and observed==seq and loss==0 and flags==1 and reserved==0
  if first is None:first=ticks
  last=ticks
  h.update(header);h.update(payload);raw_bytes+=64+size
  statuses[status]+=1;sizes[size]+=1
  if status&31==17 and size>=16 and payload[12]&63==0:
   if size==16:
    if empties==0:empty_start=ticks
    empties+=1
   else:
    stride=480+(4 if payload[10]&4 else 0)
    assert (size-16)%stride==0
    current=payload[11]
    if dbc is not None and current!=dbc:gaps.append({'sequence':seq,'receive_elapsed_seconds':(ticks-first)*scale,'expected_dbc':dbc,'actual_dbc':current,'preceding_empty_records':empties,'empty_run_seconds':(ticks-empty_start)*scale if empty_start else 0})
    dbc=(current+(size-16)//stride)&255;empties=0;empty_start=None
assert count==v['rawRecordCount'] and raw_bytes==v['rawRecordBytes']
hashes={'rawRecordSHA256':h.hexdigest()}
for name,key in [('capture.dv','nativeDVSHA256'),('frames.ndjson','frameManifestSHA256'),('flight.ndjson','journalSHA256')]:
 h=hashlib.sha256()
 with (capture/name).open('rb') as f:
  while b:=f.read(1024*1024):h.update(b)
 hashes[key]=h.hexdigest()
assert all(hashes[k]==v[k] for k in hashes)
rows=[json.loads(s) for s in (capture/'flight.ndjson').read_text().splitlines()]
mon=[]
for e in rows:
 if e['event']=='monitor_statistics':
  fields=dict(x.strip().split('=',1) for x in e['message'].split(';') if '=' in x)
  mon.append({'utc':e['utc'],**fields})
transition_keys=['preview_input_interruptions','audio_resyncs','video_timeline_resets','audio_timing_resets','continuity_breaks','rejected_packets','audio_unavailable_pcm_frames']
transitions=[];prior={}
for e in mon:
 changes={k:e[k] for k in transition_keys if k in e and e[k]!=prior.get(k,'0')}
 if changes:transitions.append({'utc':e['utc'],'changes':changes,'last_resync':e.get('last_resync'),'complete_frames':e.get('complete_frames')})
 prior=e
assert before=={n:(capture/n).stat().st_size for n in files}
result={'capture_path':str(capture),'raw_records':count,'status_counts':dict(statuses),'payload_size_counts':dict(sizes),'zero_status_count':statuses[0],'raw_duration_seconds':(last-first)*scale,'saved_dv_frames':v['completeDVFrames'],'saved_dv_seconds':v['completeDVFrames']*1001/30000,'verification':v,'independent_hashes':hashes,'all_four_hashes_match':True,'dbc_gaps':gaps,'monitor_transitions':transitions,'last_monitor':mon[-1],'source_files_size_unchanged':True}
(p/'findings.json').write_text(json.dumps(result,indent=2));(p/'monitor-timeline.json').write_text(json.dumps(mon,indent=2))


print(json.dumps({k:result[k] for k in ['raw_records','status_counts','zero_status_count','raw_duration_seconds','saved_dv_seconds','all_four_hashes_match','dbc_gaps','monitor_transitions']},indent=2))
