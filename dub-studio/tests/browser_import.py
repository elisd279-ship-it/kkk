"""Browser regressions for import encoding, diagnostics and disconnected app."""
import os
import sys
import tempfile
import threading
from pathlib import Path
from playwright.sync_api import sync_playwright
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from app import Server
from studio import Store

SAMPLE='1\n00:00:15,120 --> 00:00:15,760\nWhat?\n\n2\n00:00:17,160 --> 00:00:18,120\nThe deputy had an accident?'
with tempfile.TemporaryDirectory() as tmp, sync_playwright() as p:
    store=Store(Path(tmp)/'data')
    server=Server(('127.0.0.1',0),store)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    browser=p.chromium.launch(executable_path=os.getenv('DUB_TEST_CHROMIUM'),headless=True,args=['--no-sandbox'])
    page=browser.new_page()
    page.goto(f'http://127.0.0.1:{server.server_port}')
    page.wait_for_function("document.querySelector('#aiStatus').textContent.length>0")
    def create(name,raw,encoding='auto'):
        page.fill('#chapterName',name)
        page.set_input_files('#srtFile',{'name':'test.srt','mimeType':'text/plain','buffer':raw})
        page.select_option('#srtEncoding',encoding)
        page.locator('#chapterForm button').click()
    for name,raw,encoding in (
        ('User sample UTF-8',SAMPLE.encode(),'auto'),
        ('UTF-16 LE',SAMPLE.encode('utf-16'),'auto'),
        ('UTF-16 BE',b'\xfe\xff'+SAMPLE.encode('utf-16be'),'auto'),
        ('Windows-1252',(SAMPLE.replace('What?','¿Qué?')).encode('cp1252'),'windows-1252')
    ):
        create(name,raw,encoding)
        page.wait_for_function("document.querySelector('#message').textContent.startsWith('Capítulo importado')")
        assert page.locator('.line').count()==2
        page.wait_for_function("!document.querySelector('#chapterForm button').disabled")
    assert len(store.state()['chapters'])==4
    create('Invalid', (SAMPLE+'\n\n3\n00:00:21:12 --> 00:00:22,000\nBad frames').encode())
    page.wait_for_function("document.querySelector('#message').textContent.includes('Bloque 3')")
    assert '00:00:21:12' in page.locator('#message').inner_text()
    assert len(store.state()['chapters'])==4
    page.wait_for_function("!document.querySelector('#chapterForm button').disabled")
    create('Invalid UTF-8',SAMPLE.replace('What?','¿Qué?').encode('cp1252'),'auto')
    page.wait_for_function("document.querySelector('#message').textContent.includes('codificación')")
    assert len(store.state()['chapters'])==4
    page.wait_for_function("!document.querySelector('#chapterForm button').disabled")
    server.shutdown();server.server_close();thread.join()
    create('Disconnected',SAMPLE.encode())
    page.wait_for_function("document.querySelector('#message').textContent.includes('Se perdió la conexión')")
    assert 'Iniciar.bat' in page.locator('#message').inner_text()
    assert 'Failed to fetch' not in page.locator('#message').inner_text()
    browser.close()
print('PASS browser imports: user SRT sample, UTF-8, UTF-16 LE/BE, explicit Windows-1252, bad-block diagnostics, no lossy decoding, disconnected application message')
