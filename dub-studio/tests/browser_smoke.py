import tempfile
import os
import sys
import threading
from pathlib import Path
from playwright.sync_api import sync_playwright
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from app import Server
from studio import Store
with tempfile.TemporaryDirectory() as temporary, sync_playwright() as p:
    server=Server(('127.0.0.1',0),Store(Path(temporary)/'data'))
    threading.Thread(target=server.serve_forever,daemon=True).start()
    base=f'http://127.0.0.1:{server.server_port}'
    browser=p.chromium.launch(executable_path=os.getenv('DUB_TEST_CHROMIUM'),headless=True,args=['--no-sandbox'])
    page=browser.new_page(viewport={'width':1440,'height':1100})
    errors=[];page.on('pageerror',lambda e:errors.append(str(e)))
    page.goto(base)
    page.wait_for_function("document.querySelector('#aiStatus').textContent.length>0")
    page.fill('#chapterName','Browser fixture')
    page.set_input_files('#srtFile',{'name':'test.srt','mimeType':'text/plain','buffer':b'1\n00:20:01,000 --> 00:20:02,000\nHello / hi!\nAgain.\n\n2\n00:20:02,500 --> 00:20:03,500\nBye!\n'})
    page.locator('#chapterForm button').click()
    page.wait_for_function("document.querySelectorAll('.line').length===2")
    import subprocess
    path=str(Path(temporary)/'fixture.mp4')
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-f','lavfi','-i','color=c=green:s=320x240:r=10','-f','lavfi','-i','sine=frequency=440:sample_rate=16000','-t','4','-c:v','libx264','-pix_fmt','yuv420p','-c:a','aac',path],check=True)
    page.set_input_files('#videoFiles',path)
    page.fill('#offset0','00:20:00,000')
    page.locator('#videoForm button').click()
    page.wait_for_function("document.querySelector('#message').textContent.startsWith('Partes importadas')")
    page.locator('.line').first.click()
    page.wait_for_function("Math.abs(document.querySelector('#player').currentTime-1)<0.1")
    assert 'CAPÍTULO 00:20:01,000' in page.locator('#chapterClock').inner_text()
    assert 'Hello / hi!' in page.locator('#subtitle').inner_text()
    page.locator('summary').filter(has_text='Registro confirmado').click()
    page.fill('#identityName','Ana');page.fill('#appearance','Green shirt');page.fill('#voice','Low voice');page.fill('#identityEvidence','Fixture only: part2, 00:20:01')
    page.locator('#identityForm button').click()
    page.wait_for_function("document.querySelector('#message').textContent.startsWith('Personaje confirmado')")
    page.select_option('#speaker','Ana');page.fill('#evidence','Synthetic fixture confirmation');page.fill('#translation','Hola / ¡buenas!\nOtra vez.')
    page.click('#saveReview')
    page.wait_for_function("document.querySelector('#message').textContent.startsWith('Revisión guardada')")
    page.reload();page.wait_for_function("document.querySelectorAll('.line').length===2")
    page.locator('.line').first.click();assert page.input_value('#speaker')=='Ana';assert page.input_value('#translation')=='Hola / ¡buenas!\nOtra vez.'
    page.locator('summary').filter(has_text='Traducción y exportación').click()
    with page.expect_download() as dl:page.click('#exportOriginal')
    text=Path(dl.value.path()).read_text()
    assert 'DUB (00:20:01,000 - 00:20:02,000) Ana\nHello / hi!\nAgain.' in text
    page.click('#exportSpanish');page.wait_for_function("document.querySelector('#message').textContent.startsWith('Faltan traducciones')")
    page.locator('.line').nth(1).click();page.fill('#translation','¡Adiós!');page.click('#saveReview')
    page.wait_for_function("document.querySelector('#message').textContent.startsWith('Revisión guardada')")
    with page.expect_download() as dl:page.click('#exportSpanish')
    assert 'Hola / ¡buenas!' in Path(dl.value.path()).read_text()
    page.screenshot(path=str(Path(temporary)/'desktop.png'),full_page=True)
    page.set_viewport_size({'width':390,'height':844})
    assert page.evaluate('document.documentElement.scrollWidth <= window.innerWidth')
    page.screenshot(path=str(Path(temporary)/'mobile.png'),full_page=True)
    assert not errors,errors
    print('PASS browser: SRT + video uploads, original offset seek/subtitle, identities, manual review/translation, reload persistence, DUB downloads, incomplete translation rejection, mobile layout; no JS errors')
    browser.close()
    server.shutdown()
    server.server_close()
