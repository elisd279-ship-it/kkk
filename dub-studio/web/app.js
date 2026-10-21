'use strict';
const $ = id => document.getElementById(id);
let state = {chapters: [], lines: [], videos: [], identities: []}, chapter = null, selected = null, token = '', busy = false;
const stamp = n => {n = Math.max(0, Math.round(n)); const h = Math.floor(n/3600000), m = Math.floor(n/60000)%60, s = Math.floor(n/1000)%60; return [h,m,s].map(x=>String(x).padStart(2,'0')).join(':')+','+String(n%1000).padStart(3,'0');};
const ms = t => {const [h,m,s] = t.split(':'); return (+h*3600 + +m*60 + +s.replace(',','.'))*1000;};
function message(text, error=false) {$('message').textContent=text; $('message').classList.toggle('error',error);}
async function fetchLocal(path,options={}) {
  try {return await fetch(path,options);} catch(e) {
    throw new Error('Se perdió la conexión con DUB Studio. Abre Iniciar.bat o el acceso directo y vuelve a intentarlo. Tus datos guardados se conservan.');
  }
}
async function jsonResponse(response) {
  let result;
  try {result=await response.json();} catch(e) {throw new Error('DUB Studio devolvió una respuesta incompleta. Vuelve a abrir la aplicación y reintenta la operación.');}
  if(!response.ok) throw new Error(result.error || 'La operación falló');
  return result;
}
async function request(path, data) {
  const response=await fetchLocal(path,data === undefined ? {} : {method:'POST',headers:{'Content-Type':'application/json','X-DUB-Token':token},body:JSON.stringify(data)});
  return jsonResponse(response);
}
async function readSrt(file) {
  let bytes;
  try {bytes=new Uint8Array(await file.arrayBuffer());} catch(e) {throw new Error('No se puede leer el SRT. Vuelve a seleccionarlo desde una carpeta local.');}
  let encoding=$('srtEncoding').value;
  if(encoding==='auto') {
    if((bytes[0]===0xff && bytes[1]===0xfe && bytes[2]===0 && bytes[3]===0) ||
       (bytes[0]===0 && bytes[1]===0 && bytes[2]===0xfe && bytes[3]===0xff))
      throw new Error('El SRT está en UTF-32. Guarda una copia en UTF-8 y vuelve a importarla.');
    encoding=bytes[0]===0xff && bytes[1]===0xfe?'utf-16le':bytes[0]===0xfe && bytes[1]===0xff?'utf-16be':'utf-8';
  }
  try {
    const text=new TextDecoder(encoding,{fatal:true}).decode(bytes);
    if(text.includes('\u0000')) throw new Error('Unrecognized Unicode encoding');
    return text;
  } catch(e) {
    throw new Error('No se pudo leer la codificación del SRT. Elige UTF-16 o Windows-1252 si corresponde, o guarda una copia en UTF-8. El texto no se ha importado.');
  }
}

async function action(fn) {
  if(busy) return; busy=true; document.querySelectorAll('button,input,select,textarea').forEach(x=>x.disabled=true);
  try {await fn();} catch(e) {message(e.message,true);} finally {busy=false;document.querySelectorAll('button,input,select,textarea').forEach(x=>x.disabled=false);}
}
function option(value,text) {const o=document.createElement('option'); o.value=value; o.textContent=text;return o;}
function activeVideo() {return state.videos.find(v=>v.id===Number($('videos').value));}
function contains(v,line) {return v && v.offset<=ms(line.start) && ms(line.end)<=v.offset+v.duration;}
async function refresh() {
  state = await request('/api/state'+(chapter?'?chapter='+chapter:'')); token=state.token;
  state.lines ||= []; state.videos ||= []; state.identities ||= [];
  $('chapters').replaceChildren(option('','Selecciona un capítulo'), ...state.chapters.map(c=>option(c.id,c.name)));
  $('chapters').value=chapter || '';
  const previous=$('videos').value;
  $('videos').replaceChildren(...(state.videos.length?state.videos.map(v=>option(v.id,v.name+' · '+stamp(v.offset))):[option('','Sin vídeo')]));
  if(state.videos.some(v=>String(v.id)===previous)) $('videos').value=previous;
  updateVideo();
  $('speaker').replaceChildren(option('[REVISAR]','[REVISAR]'),option('[REVISAR – VOCES SUPERPUESTAS]','[REVISAR – VOCES SUPERPUESTAS]'),...state.identities.map(x=>option(x.name,x.name)));
  $('stats').textContent=chapter?`${state.lines.length} intervenciones · ${state.lines.filter(x=>x.speaker.startsWith('[REVISAR')).length} por revisar · ${state.identities.length} personajes`: 'Carga un capítulo para comenzar';
  $('aiStatus').textContent=state.ai_configured?`Proveedor: Gemini · ${state.model}. Toda propuesta requiere revisión.`:'IA sin configurar. Define DUB_GEMINI_API_KEY antes de iniciar la aplicación. La revisión manual está disponible.';
  $('identities').replaceChildren(...state.identities.map(x=>{const a=document.createElement('article');const title=document.createElement('strong');title.textContent=x.name;a.append(title);const p=document.createElement('p');p.textContent=`${x.appearance} · Voz: ${x.voice || 'Sin describir'} · Evidencia: ${x.evidence}`;a.append(p);return a;}));
  renderLines();
  if(selected && state.lines.some(x=>x.id===selected)) showSelected(); else {selected=null; clearSelected();}
}
function updateVideo() {
  const v=activeVideo(); const src=v?'/media/'+v.id:'';
  if($('player').getAttribute('src')!==src) {if(src) $('player').src=src; else {$('player').removeAttribute('src');$('player').load();}}
}
function renderLines() {
  const query=$('search').value.toLocaleLowerCase('es');
  const lines=state.lines.filter(x=>(!$('pendingOnly').checked || x.speaker.startsWith('[REVISAR')) && (x.original+' '+x.speaker).toLocaleLowerCase('es').includes(query));
  $('lines').replaceChildren(...lines.map(x=>{
    const b=document.createElement('button'); b.className='line'+(x.id===selected?' active':'');
    const meta=document.createElement('span');meta.className='meta'; const time=document.createElement('span');time.textContent=`${x.ordinal} · ${x.start} → ${x.end}`;
    const who=document.createElement('span');who.textContent=x.speaker;who.className=x.speaker.startsWith('[REVISAR')?'pending':'';meta.append(time,who);
    const text=document.createElement('span');text.className='dialogue';text.textContent=x.original;b.append(meta,text);b.onclick=()=>{selected=x.id;showSelected();renderLines();seekSelected();};return b;
  }));
  if(!lines.length) $('lines').textContent=chapter?'No hay intervenciones con este filtro.':'Importa un SRT para comenzar.';
}
function clearSelected() {$('lineNumber').textContent='—';$('timecodes').textContent='—';$('original').textContent='Selecciona un diálogo de la lista.';$('evidence').value='';$('translation').value='';$('proposal').classList.remove('visible');}
function showSelected() {
  const x=state.lines.find(x=>x.id===selected); if(!x)return;
  $('lineNumber').textContent='N.º '+x.ordinal;$('timecodes').textContent=x.start+' → '+x.end;
  $('original').textContent=x.original;$('speaker').value=x.speaker;$('evidence').value=x.evidence;$('translation').value=x.translation || '';
  $('proposal').replaceChildren();$('proposal').classList.toggle('visible',Boolean(x.proposal));
  if(x.proposal) {
    const p=JSON.parse(x.proposal);const text=document.createElement('div');
    text.textContent=`PROPUESTA · ${p.candidate} · Confianza ${Math.round(p.confidence*100)}%\nVídeo: ${p.video_name} · Capítulo: ${p.chapter_timestamp}\n`+p.evidence.map(e=>`${stamp(p.clip_start_ms+e.at_ms)} del clip: ${e.description}`).join('\n')+'\nPendiente de confirmación humana.';
    $('proposal').append(text);
    if(!p.candidate.startsWith('[REVISAR')) {const accept=document.createElement('button');accept.textContent='Usar propuesta en el formulario';accept.className='secondary';accept.onclick=()=>{$('speaker').value=p.candidate;$('evidence').value=`${p.video_name} · ${p.chapter_timestamp}: `+p.evidence.map(e=>`${stamp(p.clip_start_ms+e.at_ms)}: ${e.description}`).join('; ');message('Revisa la evidencia y pulsa Guardar revisión para confirmar.');};$('proposal').append(accept);}
  }
}
function seekSelected() {
  const x=state.lines.find(x=>x.id===selected);if(!x)return;
  let v=activeVideo();if(!contains(v,x)) v=state.videos.find(v=>contains(v,x));
  if(!v){message('Este bloque no está contenido en ninguna parte. Añade el vídeo correcto o revisa el desfase/corte.',true);return;}
  $('videos').value=v.id;updateVideo();const player=$('player');const at=(ms(x.start)-v.offset)/1000;
  const seek=()=>{player.currentTime=at;syncSubtitle();};if(player.readyState>=1) seek();else player.addEventListener('loadedmetadata',seek,{once:true});
}
function syncSubtitle() {
  const v=activeVideo();if(!v)return;const local=$('player').currentTime*1000,at=v.offset+local;
  $('chapterClock').textContent='CAPÍTULO '+stamp(at);$('localClock').textContent='CLIP '+stamp(local);
  const lines=state.lines.filter(x=>ms(x.start)<=at && at<ms(x.end));
  $('subtitle').textContent=lines.map(x=>`${x.speaker}: ${x.original}`).join('\n') || '—';
}
$('player').addEventListener('timeupdate',syncSubtitle);
$('player').addEventListener('error',()=>message('El navegador no puede reproducir este formato. Convierte una copia a MP4 H.264/AAC; conserva la duración y el desfase.',true));
$('videos').onchange=()=>{updateVideo();syncSubtitle();};
$('chapters').onchange=()=>action(async()=>{chapter=Number($('chapters').value)||null;selected=null;localStorage.setItem('dub.chapter',chapter||'');$('glossary').value=localStorage.getItem('dub.glossary.'+chapter)||'';await refresh();message('');});
$('glossary').oninput=()=>localStorage.setItem('dub.glossary.'+chapter,$('glossary').value);
$('pendingOnly').onchange=renderLines;$('search').oninput=renderLines;
$('chapterForm').onsubmit=e=>{e.preventDefault();action(async()=>{const file=$('srtFile').files[0];if(!file)throw new Error('Selecciona el SRT');const result=await request('/api/chapter',{name:$('chapterName').value,srt:await readSrt(file)});chapter=result.id;selected=null;localStorage.setItem('dub.chapter',chapter);$('glossary').value='';await refresh();message('Capítulo importado. Añade sus partes de vídeo y confirma los desfases.');});};
$('videoFiles').onchange=()=>{$('offsets').replaceChildren(...Array.from($('videoFiles').files).map((f,i)=>{const label=document.createElement('label');label.textContent=f.name+' · inicio en el capítulo';const input=document.createElement('input');input.id='offset'+i;input.value='00:00:00,000';input.pattern='[0-9]{2}:[0-5][0-9]:[0-5][0-9],[0-9]{3}';input.required=true;label.append(input);return label;}));};
$('videoForm').onsubmit=e=>{e.preventDefault();action(async()=>{if(!chapter)throw new Error('Crea o selecciona un capítulo');const files=Array.from($('videoFiles').files);for(let i=0;i<files.length;i++){message(`Cargando ${i+1}/${files.length}: ${files[i].name}…`);const q=new URLSearchParams({chapter,name:files[i].name,offset:$('offset'+i).value});const r=await fetchLocal('/api/video?'+q,{method:'POST',headers:{'X-DUB-Token':token},body:files[i]});await jsonResponse(r);}await refresh();message('Partes importadas. Comprueba la sincronización antes de asignar personajes.');});};
$('identityForm').onsubmit=e=>{e.preventDefault();action(async()=>{if(!chapter)throw new Error('Selecciona un capítulo');await request('/api/identity',{chapter,name:$('identityName').value,appearance:$('appearance').value,voice:$('voice').value,evidence:$('identityEvidence').value});await refresh();message('Personaje confirmado guardado para este capítulo.');});};
$('saveReview').onclick=()=>action(async()=>{if(!selected)throw new Error('Selecciona una intervención');await request('/api/review',{id:selected,speaker:$('speaker').value,evidence:$('evidence').value,translation:$('translation').value || null});await refresh();message('Revisión guardada. Original y timecodes conservados.');});
$('analyze').onclick=()=>action(async()=>{if(!selected)throw new Error('Selecciona una intervención');if(!contains(activeVideo(),state.lines.find(x=>x.id===selected)))throw new Error('Selecciona una parte que contenga toda la intervención');message('Analizando clip audiovisual con IA…');await request('/api/analyze',{id:selected,video:activeVideo().id});await refresh();message('Propuesta guardada; verifica la evidencia antes de confirmar.');});
$('translate').onclick=()=>action(async()=>{if(!chapter)throw new Error('Selecciona un capítulo');const ids=state.lines.filter(x=>!x.translation).slice(0,20).map(x=>x.id);if(!ids.length)throw new Error('No hay traducciones pendientes');message(`Traduciendo ${ids.length} intervenciones…`);const r=await request('/api/translate',{chapter,ids,glossary:$('glossary').value});await refresh();message(`${r.count} traducciones guardadas. Revisa el español y su ajuste a la duración.`);});
async function exportDub(translated){if(!chapter)throw new Error('Selecciona un capítulo');const r=await fetchLocal(`/api/export?chapter=${chapter}&translated=${translated?1:0}`);if(!r.ok){const e=await r.json();throw new Error(e.error);}const blob=await r.blob(),url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=`capitulo-${chapter}${translated?'-es':''}.dub.txt`;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);message('DUB exportado'+(state.lines.some(x=>x.speaker.startsWith('[REVISAR'))?' con intervenciones pendientes de revisión.':'.'));}
$('exportOriginal').onclick=()=>action(()=>exportDub(false));$('exportSpanish').onclick=()=>action(()=>exportDub(true));
$('closeApp').onclick=()=>action(async()=>{await request('/api/shutdown',{});message('DUB Studio se cerró. Puedes cerrar esta pestaña y volver a abrir la aplicación desde su acceso directo.');});
(async()=>{try{const initial=await request('/api/state');chapter=Number(localStorage.getItem('dub.chapter'))||null;if(!initial.chapters.some(x=>x.id===chapter))chapter=initial.chapters[0]?.id || null;$('glossary').value=localStorage.getItem('dub.glossary.'+chapter)||'';await refresh();}catch(e){message(e.message,true);}})();
