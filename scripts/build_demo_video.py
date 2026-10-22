#!/usr/bin/env python3
"""Assemble real browser recording + canonical narration with timed English captions."""
from pathlib import Path
import json,re,subprocess,os,hashlib
ROOT=Path(__file__).resolve().parents[1];MEDIA=ROOT/'video/proof-v2'
CAPTURE=Path(os.environ.get('PROOF_CAPTURE',str(ROOT/'.agent-artifacts/browser-recording')))
events=json.loads((CAPTURE/'scene-timing.json').read_text());assert len(events)==12
frames=json.loads((CAPTURE/'lossless-frames.json').read_text());assert len(frames)>30
assert all(Path(f['path']).suffix=='.png' for f in frames)
source_events=[dict(e) for e in events]
source_frames=frames
frames=[];duration=0.0
for event in events:
 index=event['scene'];source_start=event['start']
 clip=float(json.loads((MEDIA/f'narration-{index:02d}.json').read_text()).get('duration',0))
 audio_probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_entries','format=duration','-of','json',str(MEDIA/f'narration-{index:02d}.mp3')],text=True))
 clip=float(audio_probe['format']['duration'])+.7
 before=[f for f in source_frames if f['time']<=source_start]
 first=dict(before[-1] if before else source_frames[0]);first['time']=duration;frames.append(first)
 for source in source_frames:
  if source_start<source['time']<source_start+clip:
   frames.append({'path':source['path'],'time':duration+source['time']-source_start})
 event['start']=duration
 duration+=clip
speed=1.0
assert duration<180,'Shorten the narration, never accelerate the demonstration'
concat=CAPTURE/'lossless-frames.ffconcat'
lines=['ffconcat version 1.0']
for i,f in enumerate(frames):
 lines.append("file '"+f['path'].replace("'", "'\\''")+"'")
 delta=(frames[i+1]['time'] if i+1<len(frames) else duration)-(f['time'] if i else 0)
 lines.append(f'duration {max(.001,delta):.6f}')
lines.append("file '"+frames[-1]['path']+"'")
concat.write_text('\n'.join(lines)+'\n')
def stamp(t):
 ms=round(t*1000);h,ms=divmod(ms,3600000);m,ms=divmod(ms,60000);sec,ms=divmod(ms,1000);return f'{h:02}:{m:02}:{sec:02},{ms:03}'
inputs=['-f','concat','-safe','0','-i',str(concat)];filters=[];mix=[];cues=[]
for i,event in enumerate(events):
 inputs += ['-i',str(MEDIA/f'narration-{i:02d}.mp3')]
 start=event['start'];filters.append(f'[{i+1}:a]adelay={round(start*1000)}|{round(start*1000)}[a{i}]');mix.append(f'[a{i}]')
 meta=json.loads((MEDIA/f'narration-{i:02d}.json').read_text());text=meta['text'];alignment=meta.get('alignment') or {};starts=alignment.get('character_start_times_seconds') or [];ends=alignment.get('character_end_times_seconds') or []
 if len(starts)!=len(text):raise RuntimeError('timestamp alignment unavailable')
 for match in re.finditer(r'.{1,85}(?:\s|$)',text):
  first=match.start();last=match.end()-1;body=text[first:last+1].strip()
  if body:cues.append(((start+starts[first])/speed,(start+ends[last])/speed,body))
srt='\n\n'.join(f'{n+1}\n{stamp(a)} --> {stamp(b)}\n{text}' for n,(a,b,text) in enumerate(cues))+'\n';(MEDIA/'demo.en.srt').write_text(srt)
ass_header="""[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080
WrapStyle: 0

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,DejaVu Sans,32,&H00FFFFFF,&H00FFFFFF,&H00202020,&H80000000,0,0,0,0,100,100,0,0,1,1.5,0,2,100,100,15,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""
def ass_stamp(t):
 cs=round(t*100);h,cs=divmod(cs,360000);m,cs=divmod(cs,6000);sec,cs=divmod(cs,100);return f'{h}:{m:02}:{sec:02}.{cs:02}'
(MEDIA/'demo.en.ass').write_text(ass_header+''.join(f'Dialogue: 0,{ass_stamp(a)},{ass_stamp(b)},Default,,0,0,0,,{text}\n' for a,b,text in cues))

filters.append(''.join(mix)+f'amix=inputs={len(mix)}:normalize=0,atempo={speed:.8f},loudnorm=I=-16:TP=-1.5:LRA=9[audio]')
filters.append(f'[0:v]setpts=PTS/{speed:.8f},subtitles={MEDIA}/demo.en.ass,format=yuv420p[video]')
out=MEDIA/'AIGON_PROOF_READABLE_4K.encoding.mp4'
cmd=['ffmpeg','-hide_banner','-loglevel','error','-y',*inputs,'-filter_complex_threads','2','-filter_complex',';'.join(filters),'-map','[video]','-map','[audio]','-c:v','libx264','-preset','veryfast','-crf','15','-threads','2','-c:a','aac','-b:a','160k','-fps_mode','vfr','-t',f'{duration/speed:.3f}','-movflags','+faststart',str(out)]
subprocess.run(cmd,check=True)
verify=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_entries','format=duration,size:stream=codec_name,codec_type,width,height','-of','json',str(out)],text=True));assert float(verify['format']['duration'])<180
out.replace(MEDIA/'AIGON_PROOF_READABLE_4K.mp4')
verify['file_sha256']=hashlib.sha256((MEDIA/'AIGON_PROOF_READABLE_4K.mp4').read_bytes()).hexdigest()
verify['presentation_zoom']=1.5
verify['capture']='3840x2160 native lossless PNG browser frames, device scale3, 1280x720 logical viewport; 150% framing relative to1920x1080; no VP8 source'
assert any(v.get('width')==3840 and v.get('height')==2160 for v in verify['streams'])
verify['narration_provider']='ElevenLabs';verify['narration_voice']='Cornelius - Wise Sage'
verify['source']='Actual browser captures and real Rust backend; edited at scene boundaries to remove idle waiting, no playback acceleration'
verify['source_scene_timing']=source_events;verify['playback_speed']=speed;verify['scene_timing']=events
(MEDIA/'READABLE_VIDEO_RECEIPT.json').write_text(json.dumps(verify,indent=2)+'\n');print(json.dumps(verify))
