#!/usr/bin/env python3
"""Run: python app.py; all project data stays under --data."""
import argparse
import json
import mimetypes
import secrets
import shutil
import subprocess
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from studio import Store, Gemini
import dubstudio as core

WEB=Path(__file__).parent/'web'

class Server(ThreadingHTTPServer):
    def __init__(self,address,store):
        super().__init__(address,Handler)
        self.store=store
        self.token=secrets.token_urlsafe(32)

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def reply(self,status,data,kind='application/json; charset=utf-8'):
        body=json.dumps(data,ensure_ascii=False).encode() if kind.startswith('application/json') else data
        self.send_response(status)
        self.send_header('Content-Type',kind)
        self.send_header('Content-Length',str(len(body)))
        self.send_header('X-Content-Type-Options','nosniff')
        self.send_header('Cache-Control','no-store')
        self.end_headers()
        self.wfile.write(body)
    def local_request(self):
        return self.headers.get('Host') in (f'127.0.0.1:{self.server.server_port}',f'localhost:{self.server.server_port}')
    def do_GET(self):
        if not self.local_request(): return self.reply(403,{'error':'Host no permitido'})
        url=urllib.parse.urlsplit(self.path); q=urllib.parse.parse_qs(url.query)
        try:
            if url.path=='/api/state':
                data=self.server.store.state(int(q['chapter'][0]) if 'chapter' in q else None)
                data['token']=self.server.token
                return self.reply(200,data)
            if url.path=='/api/export':
                text=self.server.store.export(int(q['chapter'][0]),q.get('translated',['0'])[0]=='1')
                return self.reply(200,text.encode(),'text/plain; charset=utf-8')
            if url.path.startswith('/media/'):
                return self.media(int(url.path.rsplit('/',1)[1]))
            files={'/':'index.html','/app.js':'app.js','/style.css':'style.css'}
            if url.path in files:
                path=WEB/files[url.path]
                return self.reply(200,path.read_bytes(),mimetypes.guess_type(str(path))[0]+'; charset=utf-8')
            self.reply(404,{'error':'No encontrado'})
        except (ValueError,KeyError,FileNotFoundError) as exc: self.reply(400,{'error':str(exc)})
    def media(self,vid):
        with self.server.store.connect() as db:
            video=db.execute('SELECT path FROM videos WHERE id=?',(vid,)).fetchone()
        if not video: return self.reply(404,{'error':'Vídeo no encontrado'})
        path=Path(video['path']); size=path.stat().st_size
        first,last=0,size-1; status=200
        range_header=self.headers.get('Range')
        if range_header:
            import re
            match=re.fullmatch(r'bytes=(\d*)-(\d*)',range_header)
            if not match or not any(match.groups()): return self.reply(416,{'error':'Rango inválido'})
            a,b=match.groups()
            if a: first=int(a); last=min(int(b),last) if b else last
            else: first=max(0,size-int(b))
            if first>last or first>=size:
                self.send_response(416); self.send_header('Content-Range',f'bytes */{size}'); self.end_headers(); return
            status=206
        self.send_response(status)
        self.send_header('Content-Type',mimetypes.guess_type(str(path))[0] or 'application/octet-stream')
        self.send_header('Accept-Ranges','bytes')
        self.send_header('Content-Length',str(last-first+1))
        if status==206: self.send_header('Content-Range',f'bytes {first}-{last}/{size}')
        self.end_headers()
        try:
            with path.open('rb') as f:
                f.seek(first); remaining=last-first+1
                while remaining:
                    chunk=f.read(min(1024*1024,remaining))
                    if not chunk: break
                    self.wfile.write(chunk); remaining-=len(chunk)
        except (BrokenPipeError,ConnectionResetError): pass
    def do_POST(self):
        if not self.local_request() or self.headers.get('X-DUB-Token')!=self.server.token:
            return self.reply(403,{'error':'Petición no autorizada'})
        url=urllib.parse.urlsplit(self.path); store=self.server.store
        try:
            length=int(self.headers.get('Content-Length','0'))
            if url.path=='/api/video':
                if not 0<length<=8*1024**3: raise ValueError('Vídeo vacío o mayor de 8 GB')
                q=urllib.parse.parse_qs(url.query)
                cid=int(q['chapter'][0]); offset=core.ms(q['offset'][0]); name=q['name'][0]
                store.state(cid)
                suffix=Path(name).suffix.lower()
                if suffix not in ('.mp4','.webm','.mov','.mkv'): raise ValueError('Usa MP4, WebM, MOV o MKV')
                folder=store.root/'media'; folder.mkdir(exist_ok=True)
                path=folder/(secrets.token_hex(16)+suffix)
                try:
                    with path.open('wb') as f:
                        remaining=length
                        while remaining:
                            chunk=self.rfile.read(min(1024*1024,remaining))
                            if not chunk: raise ValueError('Carga interrumpida')
                            f.write(chunk); remaining-=len(chunk)
                    vid=store.add_video(cid,name,path,offset)
                except Exception:
                    path.unlink(missing_ok=True); raise
                return self.reply(200,{'id':vid})
            if not 0<length<=4*1024*1024: raise ValueError('Petición demasiado grande o vacía')
            p=json.loads(self.rfile.read(length))
            if url.path=='/api/chapter': result={'id':store.chapter(p['name'],p['srt'])}
            elif url.path=='/api/identity':
                store.identity(p['chapter'],p['name'],p['appearance'],p.get('voice',''),p['evidence']); result={'ok':True}
            elif url.path=='/api/review':
                store.review(p['id'],p['speaker'],p['evidence'],p.get('translation')); result={'ok':True}
            elif url.path=='/api/analyze': result=store.analyze(p['id'],p['video'],Gemini())
            elif url.path=='/api/translate': result={'count':store.translate(p['chapter'],p['ids'],p.get('glossary',''),Gemini())}
            else: return self.reply(404,{'error':'Ruta inexistente'})
            self.reply(200,result)
        except (ValueError,KeyError,TypeError) as exc: self.reply(400,{'error':str(exc)})
        except subprocess.SubprocessError: self.reply(400,{'error':'FFmpeg no pudo leer el audio/vídeo; comprueba formato y archivo'})
        except Exception: self.reply(500,{'error':'No se pudo completar la operación; los datos anteriores se conservan'})

def main():
    parser=argparse.ArgumentParser(description='DUB Studio local')
    parser.add_argument('--port',type=int,default=8765)
    parser.add_argument('--data',default=str(Path.home()/'.dubstudio'))
    parser.add_argument('--open-browser',action='store_true',help='Abrir la interfaz en el navegador local')
    args=parser.parse_args()
    if not shutil.which('ffmpeg') or not shutil.which('ffprobe'): parser.error('Instala FFmpeg (incluye ffprobe) y añádelo al PATH')
    server=Server(('127.0.0.1',args.port),Store(args.data))
    print(f'DUB Studio: abre http://127.0.0.1:{args.port} en tu navegador. Datos: {args.data}',flush=True)
    if args.open_browser:
        import webbrowser
        webbrowser.open(f'http://127.0.0.1:{args.port}')
    try: server.serve_forever()
    except KeyboardInterrupt: pass
    finally: server.server_close()
if __name__=='__main__': main()
