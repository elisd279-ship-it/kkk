#!/usr/bin/env python3
"""Run: python app.py; all project data stays under --data."""
import argparse
import json
import mimetypes
import re
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
        if range_header is not None:
            match=re.fullmatch(r'bytes=([0-9]*)-([0-9]*)',range_header)
            try:
                if not match or not any(match.groups()): raise ValueError
                a,b=match.groups()
                if a: first=int(a); last=min(int(b),last) if b else last
                else:
                    suffix=int(b)
                    if suffix<=0: raise ValueError
                    first=max(0,size-suffix)
                if first>last or first>=size: raise ValueError
            except ValueError:
                body=json.dumps({'error':'Rango inválido'},ensure_ascii=False).encode()
                self.send_response(416)
                self.send_header('Content-Range',f'bytes */{size}')
                self.send_header('Content-Type','application/json; charset=utf-8')
                self.send_header('Content-Length',str(len(body)))
                self.send_header('Accept-Ranges','bytes')
                self.end_headers(); self.wfile.write(body); return
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
            if url.path=='/api/video':
                lengths=self.headers.get_all('Content-Length',[])
                if not lengths: return self.reply(411,{'error':'Falta Content-Length'})
                if self.headers.get('Transfer-Encoding') is not None or len(lengths)!=1 or not re.fullmatch(r'[0-9]+',lengths[0]):
                    return self.reply(400,{'error':'Content-Length inválido'})
                try: length=int(lengths[0])
                except ValueError: return self.reply(400,{'error':'Content-Length inválido'})
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
                            if len(chunk)>remaining: raise ValueError('Carga mayor que Content-Length')
                            if f.write(chunk)!=len(chunk): raise OSError('Escritura incompleta')
                            remaining-=len(chunk)
                    if path.stat().st_size!=length: raise OSError('Tamaño de archivo inconsistente')
                    if offset<0: raise ValueError('El desfase debe ser positivo o cero')
                    duration=core.metadata(path)
                    if duration<=0: raise ValueError('Vídeo vacío')
                    # Keep registration and verification in one SQLite transaction.
                    with store.connect() as db:
                        store.require_chapter(db,cid)
                        expected=(cid,Path(name).name,str(path.resolve()),offset,duration)
                        vid=db.execute('INSERT INTO videos(chapter,name,path,offset,duration) VALUES(?,?,?,?,?)',expected).lastrowid
                        row=db.execute('SELECT chapter,name,path,offset,duration FROM videos WHERE id=?',(vid,)).fetchone()
                        if row is None or tuple(row)!=expected or path.stat().st_size!=length:
                            raise OSError('Registro o archivo inconsistente')
                except Exception:
                    path.unlink(missing_ok=True); raise
                return self.reply(200,{'id':vid})
            length=int(self.headers.get('Content-Length','0'))
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

