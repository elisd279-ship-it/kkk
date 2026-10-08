import copy
import json
import tempfile
import threading
import unittest
import urllib.request
import urllib.error
import subprocess
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from studio import Store, REVIEW, OVERLAP, validate_proposal
from app import Server
import dubstudio as core

SRT='1\n00:20:01,000 --> 00:20:02,000\nHello / hi!\nAgain.\n\n2\n00:20:02,500 --> 00:20:04,500\nBye!\n'
class FakeProvider:
    model='fixture-not-real-ai'
    def analyze(self,line,identities,clip):
        if clip.stat().st_size == 0: raise AssertionError('Empty clip')
        return {'candidate':'Ana','confidence':0.98,'status':'candidate',
                'evidence':[{'at_ms':100,'description':'Synthetic fixture: lips and voice; not an accuracy validation'}]}
    def translate(self,lines,glossary):
        return [{k:x[k] for k in ('id','start','end','speaker')}|{'text':'¡Hola / buenas!\nOtra vez.'} for x in lines]

class StudioTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.store=Store(Path(self.tmp.name)/'data'); self.cid=self.store.chapter('Episode 4',SRT)
    def identity(self): self.store.identity(self.cid,'Ana','Green shirt','Low voice','Human-confirmed fixture')
    def line(self): return self.store.state(self.cid)['lines'][0]
    def test_persistence_and_exact_original_export(self):
        self.identity(); line=self.line()
        self.store.review(line['id'],'Ana','Part 2 00:00:01 — observed lips','Hola / ¡buenas!\nOtra vez.')
        reopened=Store(self.store.root)
        self.assertEqual(reopened.state(self.cid)['identities'][0]['name'],'Ana')
        self.assertEqual(reopened.state(self.cid)['lines'][0]['original'],'Hello / hi!\nAgain.')
        exported=reopened.export(self.cid)
        self.assertIn('DUB (00:20:01,000 - 00:20:02,000) Ana\nHello / hi!\nAgain.',exported)
        with self.assertRaisesRegex(ValueError,'Faltan'): reopened.export(self.cid,True)
        second=reopened.state(self.cid)['lines'][1]
        reopened.review(second['id'],REVIEW,'No evidence','Adiós')
        self.assertIn('Hola / ¡buenas!',reopened.export(self.cid,True))
    def test_whitespace_preserved_and_malformed_srt_rejected(self):
        cid=self.store.chapter('Whitespace','1\n00:00:01,000 --> 00:00:02,000\n  Hello / hi!  \nAgain.  \n')
        self.assertEqual(self.store.state(cid)['lines'][0]['original'],'  Hello / hi!  \nAgain.  ')
        with self.assertRaises(ValueError): self.store.chapter('Bad',SRT+'\nInvalid block')
        with self.assertRaises(ValueError): self.store.review(self.line()['id'],REVIEW,'','Hello\n\nBad DUB separator')
    def test_identity_scope_and_no_invention(self):
        other=self.store.chapter('Other',SRT); self.identity()
        line=self.store.state(other)['lines'][0]
        with self.assertRaisesRegex(ValueError,'registro'): self.store.review(line['id'],'Ana','Look alike')
        with self.assertRaisesRegex(ValueError,'evidencia'): self.store.review(self.line()['id'],'Ana','')
        self.store.review(self.line()['id'],OVERLAP,'Overlapping ambiguous voices')
        self.assertIn(OVERLAP,self.store.export(self.cid))
    def test_ai_abstention_and_bad_evidence(self):
        identities=[{'name':'Ana'}]
        p={'candidate':'Ana','confidence':0.8,'status':'candidate','evidence':[{'at_ms':10,'description':'A face'}]}
        self.assertEqual(validate_proposal(p,identities,1000)['candidate'],REVIEW)
        p['confidence']=0.99;p['candidate']='Invented'
        self.assertEqual(validate_proposal(p,identities,1000)['candidate'],REVIEW)
        p['status']='overlap'
        self.assertEqual(validate_proposal(p,identities,1000)['candidate'],OVERLAP)
        p['evidence'][0]['at_ms']=1001
        with self.assertRaises(ValueError):validate_proposal(p,identities,1000)
    def test_translation_atomic_and_metadata_protected(self):
        provider=FakeProvider(); lines=self.store.state(self.cid)['lines']; ids=[x['id'] for x in lines]
        valid=provider.translate(lines,'')
        for field in ('id','speaker','start','end'):
            invalid=copy.deepcopy(valid); invalid[1][field]='changed'
            class Broken:
                def translate(self,*args):return invalid
            with self.assertRaises(ValueError): self.store.translate(self.cid,ids,'',Broken())
            self.assertTrue(all(x['translation'] is None for x in self.store.state(self.cid)['lines']))
        self.assertEqual(self.store.translate(self.cid,ids,'',provider),2)
        self.assertEqual([x['start'] for x in self.store.state(self.cid)['lines']],[x['start'] for x in lines])
        with self.assertRaises(ValueError):self.store.translate(self.cid,[ids[0],ids[0]],'',provider)
    def test_real_sample_srt_complete(self):
        sample=Path(__file__).resolve().parents[1]/'examples/Apple_My_Love_EP4_sample.srt'
        cid=self.store.chapter('Real SRT',sample.read_text(encoding='utf-8-sig'))
        original=core.load_srt(sample); loaded=self.store.state(cid)['lines']
        self.assertGreater(len(loaded),100)
        self.assertEqual([(x['start'],x['end'],x['original']) for x in loaded],[(x['start'],x['end'],x['text']) for x in original])
    def make_video(self):
        path=Path(self.tmp.name)/'part.mp4'
        subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-f','lavfi','-i','color=c=green:s=160x120:r=10',
                        '-f','lavfi','-i','sine=frequency=440:sample_rate=16000','-t','4','-c:v','libx264','-pix_fmt','yuv420p',
                        '-c:a','aac',str(path)],check=True,timeout=30)
        return path
    def test_audiovisual_clip_offset_and_human_gate(self):
        video=self.make_video();vid=self.store.add_video(self.cid,'part2.mp4',video,1200000); self.identity()
        lines=self.store.state(self.cid)['lines']
        with self.assertRaisesRegex(ValueError,'contenida'):self.store.analyze(lines[1]['id'],vid,FakeProvider())
        p=self.store.analyze(lines[0]['id'],vid,FakeProvider())
        self.assertEqual(p['clip_start_ms'],1000);self.assertEqual(p['candidate'],'Ana');self.assertTrue(p['needs_review'])
        self.assertEqual(self.line()['speaker'],REVIEW)
        self.assertIn('fixture',p['evidence'][0]['description'])
        with self.store.connect() as db:self.assertEqual(db.execute('SELECT count(*) FROM audit').fetchone()[0],1)
    def test_http_functional_upload_range_csrf_and_export(self):
        server=Server(('127.0.0.1',0),self.store)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        self.addCleanup(server.server_close);self.addCleanup(server.shutdown)
        base=f'http://127.0.0.1:{server.server_port}'
        with urllib.request.urlopen(base+'/api/state?chapter='+str(self.cid)) as r: data=json.load(r)
        self.assertEqual(len(data['lines']),2)
        body=json.dumps({'id':self.line()['id'],'speaker':REVIEW,'evidence':'Manual'}).encode()
        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(urllib.request.Request(base+'/api/review',data=body))
        self.assertEqual(error.exception.code,403)
        video=self.make_video(); raw=video.read_bytes()
        req=urllib.request.Request(base+f'/api/video?chapter={self.cid}&offset=00%3A20%3A00%2C000&name=part.mp4',
            data=raw,headers={'X-DUB-Token':data['token']})
        with urllib.request.urlopen(req) as r: vid=json.load(r)['id']
        req=urllib.request.Request(base+f'/media/{vid}',headers={'Range':'bytes=10-29'})
        with urllib.request.urlopen(req) as r:
            self.assertEqual(r.status,206);self.assertEqual(r.read(),raw[10:30])
            self.assertEqual(r.headers['Content-Range'],f'bytes 10-29/{len(raw)}')
        req=urllib.request.Request(base+'/api/review',data=body,headers={'X-DUB-Token':data['token']})
        with urllib.request.urlopen(req) as r:self.assertTrue(json.load(r)['ok'])
        with urllib.request.urlopen(base+f'/api/export?chapter={self.cid}') as r:
            self.assertIn('Hello / hi!\nAgain.',r.read().decode())
        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(urllib.request.Request(base+'/api/state',headers={'Host':'evil.example'}))
        self.assertEqual(error.exception.code,403)

if __name__=='__main__':unittest.main()
