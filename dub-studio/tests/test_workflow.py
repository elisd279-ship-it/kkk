import sys
import tempfile
import unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import dubstudio as d
class CoreTest(unittest.TestCase):
    def test_ms_roundtrip(self):
        for n in (0,123,12007640,2587120):self.assertEqual(d.ms(d.stamp(n)),n)
    def test_srt_preservation(self):
        with tempfile.TemporaryDirectory() as t:
            p=Path(t)/'a.srt'; p.write_text('1\n00:20:07,640 --> 00:20:11,780\nHello / hi!\nAgain.\n\n2\n00:20:12,000 --> 00:20:13,000\nBye!\n',encoding='utf8')
            data=d.load_srt(p)
            self.assertEqual(data[0]['text'],'Hello / hi!\nAgain.')
            out=Path(t)/'dub.txt';d.output_dub(data,out);self.assertEqual(d.load_dub(out),data)
    def test_bad_time(self):
        with self.assertRaises(ValueError):d.ms('00:20:07.640')
if __name__=='__main__':unittest.main()
