#!/usr/bin/env python3
"""DUB Studio: deterministic SRT-to-dubbing workflow core (stdlib + ffmpeg)."""
import argparse
import csv
import json
import re
import subprocess
from pathlib import Path

STAMP = re.compile(r'^\d{2}:\d{2}:\d{2},\d{3}$')
DUB = re.compile(r'^DUB \((\d{2}:\d{2}:\d{2},\d{3}) - (\d{2}:\d{2}:\d{2},\d{3})\) (.+)$')

def ms(t):
    if not STAMP.fullmatch(t):
        raise ValueError(f'Timecode inválido: {t}')
    h,m,s = t.split(':'); ss, milli = s.split(',')
    return ((int(h)*60+int(m))*60+int(ss))*1000+int(milli)

def stamp(n):
    h, n = divmod(n,3600000); m,n=divmod(n,60000); s,milli=divmod(n,1000)
    return f'{h:02}:{m:02}:{s:02},{milli:03}'

def load_srt(path):
    source=Path(path).read_text(encoding='utf-8-sig').replace('\r\n','\n')
    blocks=[]
    for part in re.split(r'\n\s*\n',source.strip()):
        lines=part.split('\n'); time_index=next((i for i,x in enumerate(lines) if ' --> ' in x),None)
        if time_index is None: continue
        start,end=lines[time_index].split(' --> ',1)
        end=end.strip().split(' ')[0]; start=start.strip()
        if not STAMP.fullmatch(start) or not STAMP.fullmatch(end): raise ValueError(part[:100])
        blocks.append({'index':len(blocks)+1,'start':start,'end':end,'text':'\n'.join(lines[time_index+1:]),'speaker':'[REVISAR]'})
    return blocks

def load_dub(path):
    data=Path(path).read_text(encoding='utf-8-sig').replace('\r\n','\n')
    blocks=[]
    for part in re.split(r'\n\s*\n',data.strip()):
        lines=part.split('\n'); found=DUB.fullmatch(lines[0])
        if not found: raise ValueError(f'Formato DUB incorrecto: {lines[0]}')
        start,end,speaker=found.groups()
        blocks.append({'index':len(blocks)+1,'start':start,'end':end,'text':'\n'.join(lines[1:]),'speaker':speaker})
    return blocks

def output_dub(blocks,path):
    text='\n\n'.join(f"DUB ({x['start']} - {x['end']}) {x['speaker']}\n{x['text']}" for x in blocks)+'\n'
    Path(path).write_text(text,encoding='utf-8')

def metadata(video):
    p=subprocess.run(['ffprobe','-v','error','-show_entries','format=duration','-of','default=noprint_wrappers=1:nokey=1',str(video)],capture_output=True,text=True,check=True)
    return int(float(p.stdout.strip())*1000)

def save_json(obj,path): Path(path).write_text(json.dumps(obj,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')

def cmd_prepare(a):
    start=ms(a.chapter_start); end=start+metadata(a.video)
    blocks=[x for x in load_srt(a.srt) if ms(x['start'])>=start and ms(x['end'])<=end]
    root=Path(a.output);root.mkdir(parents=True,exist_ok=True)
    payload={'video':str(Path(a.video).resolve()),'srt':str(Path(a.srt).resolve()),'chapter_start':a.chapter_start,'chapter_end':stamp(end),'blocks':blocks,'identities':{},'completed':False}
    save_json(payload,root/'session.json')
    output_dub(blocks,root/'pending.dub.txt')
    with (root/'review.csv').open('w',encoding='utf-8',newline='') as f:
        w=csv.writer(f);w.writerow(['start','end','speaker','confidence','text','evidence'])
        for x in blocks:w.writerow([x['start'],x['end'],x['speaker'],'BAJA',x['text'],''])
    print(f'{len(blocks)} bloques; intervalo vídeo {a.chapter_start} a {stamp(end)}; salida {root}')

def cmd_frames(a):
    p=json.loads(Path(a.session).read_text(encoding='utf-8')); out=Path(a.output);out.mkdir(parents=True,exist_ok=True)
    limit=a.limit if a.limit>0 else len(p['blocks'])
    for block in p['blocks'][:limit]:
        # A frame near the middle is a *candidate*, never proof of who speaks.
        at=(ms(block['start'])+ms(block['end']))//2-ms(p['chapter_start'])
        name=f"{block['index']:04d}_{block['start'].replace(':','-').replace(',','-')}.jpg"
        cmd=['ffmpeg','-hide_banner','-loglevel','error','-y','-ss',f'{at/1000:.3f}','-i',p['video'],'-frames:v','1','-vf',f'scale={a.width}:-2',str(out/name)]
        subprocess.run(cmd,check=True)
    print(f'Fotogramas creados: {min(limit,len(p["blocks"]))} en {out}')

def cmd_apply(a):
    p=json.loads(Path(a.session).read_text(encoding='utf-8')); key={(x['start'],x['end']):x for x in p['blocks']}
    count=0
    with Path(a.csv).open(encoding='utf-8-sig',newline='') as f:
        for row in csv.DictReader(f):
            pair=(row['start'],row['end'])
            if pair not in key:raise ValueError(f'Timecode ajeno a sesión: {pair}')
            speaker=(row.get('speaker') or '[REVISAR]').strip()
            confidence=(row.get('confidence') or 'BAJA').strip().upper()
            if confidence not in ('ALTA','MEDIA','BAJA'):raise ValueError(f'Confianza inválida: {confidence}')
            if confidence=='BAJA':speaker='[REVISAR]'
            key[pair]['speaker']=speaker
            key[pair]['confidence']=confidence
            key[pair]['evidence']=row.get('evidence','')
            count+=1
    save_json(p,a.session); output_dub(p['blocks'],a.output)
    print(f'{count} decisiones aplicadas; {sum(x["speaker"]=="[REVISAR]" for x in p["blocks"])} pendientes')

def cmd_translate_import(a):
    source=json.loads(Path(a.session).read_text(encoding='utf-8'))['blocks']
    translated=load_dub(a.translated)
    if len(source)!=len(translated):raise ValueError('Cantidad de bloques distinta')
    for i,(orig,new) in enumerate(zip(source,translated),1):
        if (orig['start'],orig['end'],orig['speaker'])!=(new['start'],new['end'],new['speaker']):
            raise ValueError(f'Bloque {i}: cambiaron timecodes, orden o hablante')
    output_dub(translated,a.output)
    print(f'Traducción validada: {len(translated)} bloques; tiempos y personajes intactos')

def main():
    ap=argparse.ArgumentParser(description='Núcleo verificable de asignación y traducción para doblaje')
    sub=ap.add_subparsers(dest='command',required=True)
    p=sub.add_parser('prepare');p.add_argument('--srt',required=True);p.add_argument('--video',required=True);p.add_argument('--chapter-start',required=True,help='HH:MM:SS,mmm: posición real inicial de la parte');p.add_argument('--output',required=True);p.set_defaults(func=cmd_prepare)
    p=sub.add_parser('frames');p.add_argument('--session',required=True);p.add_argument('--output',required=True);p.add_argument('--limit',type=int,default=10);p.add_argument('--width',type=int,default=640);p.set_defaults(func=cmd_frames)
    p=sub.add_parser('apply');p.add_argument('--session',required=True);p.add_argument('--csv',required=True);p.add_argument('--output',required=True);p.set_defaults(func=cmd_apply)
    p=sub.add_parser('validate-translation');p.add_argument('--session',required=True);p.add_argument('--translated',required=True);p.add_argument('--output',required=True);p.set_defaults(func=cmd_translate_import)
    a=ap.parse_args();a.func(a)
if __name__=='__main__':main()
