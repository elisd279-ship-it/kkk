"""Deterministic route tests: real SQLite/files, injected streams and failures."""
import io
import json
import sys
import tempfile
import unittest
from email.message import Message
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from app import Handler
from studio import Store


class RoutesTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.store=Store(self.tmp.name)
        self.cid=self.store.chapter('Fixture','1\n00:00:00,000 --> 00:00:01,000\nExact text\n')
        self.folder=self.store.root/'media'; self.folder.mkdir()
        self.old=self.folder/'old.mp4'; self.old.write_bytes(b'0123456789')
        with patch('app.core.metadata',return_value=1000):
            self.vid=self.store.add_video(self.cid,'old.mp4',self.old,0)
        self.before=self.snapshot()

    def snapshot(self):
        with self.store.connect() as db:
            return {table:[tuple(row) for row in db.execute('SELECT * FROM '+table+' ORDER BY id')]
                    for table in ('chapters','lines','videos','identities','audit')}

    def handler(self,method,headers=(),body=b'abc',stream=None):
        h=Handler.__new__(Handler)
        h.server=SimpleNamespace(store=self.store,server_port=1234,token='fixture')
        h.headers=Message()
        h.headers['Host']='127.0.0.1:1234'; h.headers['X-DUB-Token']='fixture'
        for key,value in headers: h.headers[key]=value
        h.path=(f'/media/{self.vid}' if method=='GET' else
                f'/api/video?chapter={self.cid}&name=new.mp4&offset=00:00:00,000')
        h.rfile=stream or io.BytesIO(body); h.wfile=io.BytesIO()
        h.request_version='HTTP/1.1'; h.command=method; h.requestline=method+' '+h.path
        return h

    def response(self,h):
        raw=h.wfile.getvalue(); head,body=raw.split(b'\r\n\r\n',1)
        lines=head.decode().split('\r\n')
        headers=dict(line.split(': ',1) for line in lines[1:])
        self.assertEqual(int(headers['Content-Length']),len(body))
        return int(lines[0].split()[1]),headers,body

    def upload(self,headers=(('Content-Length','3'),),body=b'abc',stream=None):
        h=self.handler('POST',headers,body,stream)
        with patch('app.core.metadata',return_value=1000): h.do_POST()
        return self.response(h)

    def unchanged(self):
        self.assertEqual(self.snapshot(),self.before)
        self.assertEqual(list(self.folder.iterdir()),[self.old])
        self.assertEqual(self.old.read_bytes(),b'0123456789')

    def test_invalid_ranges_uniform(self):
        for value in ('','bytes=-','bytes=8-2','bytes=10-','bytes=20-30',
                      'bytes=-0','bytes=--1','bytes=-abc','bytes=abc-2',
                      'bytes=0-1,3-4','bytes='+'9'*5000+'-'):
            with self.subTest(value=value[:40]):
                h=self.handler('GET',[('Range',value)]); h.do_GET()
                status,headers,body=self.response(h)
                self.assertEqual(status,416)
                self.assertEqual(headers['Content-Range'],'bytes */10')
                self.assertEqual(headers['Accept-Ranges'],'bytes')
                self.assertEqual(json.loads(body),{'error':'Rango inválido'})

    def test_valid_ranges_and_empty_file(self):
        for value,expected,content_range in (
                ('bytes=2-4',b'234','bytes 2-4/10'),
                ('bytes=8-99',b'89','bytes 8-9/10'),
                ('bytes=8-',b'89','bytes 8-9/10'),
                ('bytes=-3',b'789','bytes 7-9/10'),
                ('bytes=-99',b'0123456789','bytes 0-9/10')):
            with self.subTest(value=value):
                h=self.handler('GET',[('Range',value)]); h.do_GET()
                status,headers,body=self.response(h)
                self.assertEqual(status,206); self.assertEqual(body,expected)
                self.assertEqual(headers['Content-Range'],content_range)
        h=self.handler('GET'); h.do_GET()
        self.assertEqual(self.response(h)[::2],(200,b'0123456789'))
        self.old.write_bytes(b'')
        h=self.handler('GET',[('Range','bytes=0-')]); h.do_GET()
        status,headers,_=self.response(h)
        self.assertEqual(status,416); self.assertEqual(headers['Content-Range'],'bytes */0')
        h=self.handler('GET'); h.do_GET()
        self.assertEqual(self.response(h)[::2],(200,b''))

    def test_length_validation(self):
        cases=[([],411,'Falta Content-Length')]
        for value in ('abc','-1','+3','3.0','', '3,3','9'*5000):
            cases.append(([('Content-Length',value)],400,'Content-Length inválido'))
        cases.extend([
            ([('Content-Length','3'),('Content-Length','3')],400,'Content-Length inválido'),
            ([('Content-Length','3'),('Transfer-Encoding','chunked')],400,'Content-Length inválido'),
            ([('Content-Length','0')],400,'Vídeo vacío o mayor de 8 GB'),
            ([('Content-Length',str(8*1024**3+1))],400,'Vídeo vacío o mayor de 8 GB')])
        for headers,status,error in cases:
            with self.subTest(headers=str(headers)[:80]):
                actual,_,body=self.upload(headers)
                self.assertEqual(actual,status); self.assertEqual(json.loads(body),{'error':error})
                self.unchanged()

    def test_interrupted_eof_and_reset(self):
        status,_,body=self.upload([('Content-Length','4')])
        self.assertEqual(status,400); self.assertEqual(json.loads(body)['error'],'Carga interrumpida')
        self.unchanged()
        class Reset:
            def read(self,n): raise ConnectionResetError('injected')
        self.assertEqual(self.upload(stream=Reset())[0],500); self.unchanged()

    def test_received_bytes_exceed_read_request(self):
        # Defensive check for a stream violating read(n); normal sockets cap n.
        class Oversized:
            def read(self,n): return b'abcd'
        status,_,body=self.upload(stream=Oversized())
        self.assertEqual(status,400)
        self.assertEqual(json.loads(body)['error'],'Carga mayor que Content-Length')
        self.unchanged()

    def test_multiple_reads_and_metadata_failure(self):
        class Pieces(io.BytesIO):
            def read(self,n): return super().read(min(n,1))
        self.assertEqual(self.upload(stream=Pieces(b'ab'))[0],400); self.unchanged()
        h=self.handler('POST',[('Content-Length','3')],stream=Pieces(b'abc'))
        with patch('app.core.metadata',side_effect=ValueError('injected metadata failure')): h.do_POST()
        self.assertEqual(self.response(h)[0],400); self.unchanged()

    def test_write_exception_and_short_write(self):
        real_open=Path.open
        for short in (False,True):
            class Writer:
                def __init__(self,f): self.f=f
                def __enter__(self): return self
                def __exit__(self,*args): self.f.close()
                def write(self,data):
                    self.f.write(data[:1])
                    if short: return 1
                    raise OSError('injected disk failure')
            def opened(path,mode='r',*args,**kwargs):
                f=real_open(path,mode,*args,**kwargs)
                return Writer(f) if mode=='wb' else f
            with self.subTest(short=short),patch.object(Path,'open',opened):
                self.assertEqual(self.upload()[0],500)
            self.unchanged()

    def test_disk_size_mismatch_before_registration(self):
        real_open=Path.open
        class LyingWriter:
            def __init__(self,f): self.f=f
            def __enter__(self): return self
            def __exit__(self,*args): self.f.close()
            def write(self,data): self.f.write(data[:1]); return len(data)
        def opened(path,mode='r',*args,**kwargs):
            f=real_open(path,mode,*args,**kwargs)
            return LyingWriter(f) if mode=='wb' else f
        with patch.object(Path,'open',opened): self.assertEqual(self.upload()[0],500)
        self.unchanged()

    def test_disk_changed_during_metadata(self):
        def changed(path): path.write_bytes(b'x'); return 1000
        h=self.handler('POST',[('Content-Length','3')])
        with patch('app.core.metadata',side_effect=changed): h.do_POST()
        self.assertEqual(self.response(h)[0],500); self.unchanged()

    def test_sqlite_mismatch_and_failure_roll_back(self):
        triggers=(
            "AFTER INSERT ON videos BEGIN UPDATE videos SET path='wrong' WHERE id=NEW.id; END",
            "BEFORE INSERT ON videos BEGIN SELECT RAISE(IGNORE); END",
            "BEFORE INSERT ON videos BEGIN SELECT RAISE(ABORT,'injected'); END")
        for definition in triggers:
            with self.subTest(trigger=definition),self.store.connect() as db:
                db.execute('CREATE TRIGGER broken '+definition)
            self.assertEqual(self.upload()[0],500); self.unchanged()
            with self.store.connect() as db: db.execute('DROP TRIGGER broken')

    def test_success_bytes_file_and_sqlite_agree(self):
        status,_,body=self.upload(); self.assertEqual(status,200)
        vid=json.loads(body)['id']
        with self.store.connect() as db:
            row=db.execute('SELECT * FROM videos WHERE id=?',(vid,)).fetchone()
        self.assertEqual(row['chapter'],self.cid); self.assertEqual(row['name'],'new.mp4')
        self.assertEqual(row['offset'],0); self.assertEqual(row['duration'],1000)
        self.assertEqual(Path(row['path']).read_bytes(),b'abc')
        h=self.handler('GET'); h.path=f'/media/{vid}'; h.do_GET()
        self.assertEqual(self.response(h)[::2],(200,b'abc'))


if __name__=='__main__': unittest.main()
