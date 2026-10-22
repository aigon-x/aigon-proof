#!/usr/bin/env python3
"""Actual Rust server + Chromium regression and optional live demo recording."""
import argparse, hashlib, json, os, secrets, shutil, socket, subprocess, time, urllib.request
from pathlib import Path
from playwright.sync_api import sync_playwright

ROOT=Path(__file__).resolve().parents[1]
PREVIEW_HTML=(ROOT/'src/static/proof.html').read_text()
parser=argparse.ArgumentParser();parser.add_argument('--record',action='store_true');parser.add_argument('--preview-ui',action='store_true');args=parser.parse_args()
OUT=ROOT/('.agent-artifacts/ui-preview' if args.preview_ui else '.agent-artifacts/browser-recording' if args.record else '.agent-artifacts/browser-check')
OUT=Path(os.environ.get('PROOF_CHECK_OUTPUT',str(OUT)))
OUT.mkdir(parents=True,exist_ok=True)
STATE=OUT/('state-'+secrets.token_hex(4))
with socket.socket() as s:s.bind(('127.0.0.1',0));PORT=s.getsockname()[1]
URL=f'http://127.0.0.1:{PORT}'
env=os.environ.copy()
for k in ['AIGON_PROOF_KEY','AIGON_OPERATOR_TOKEN','AIGON_API_KEY','OTEL_EXPORTER_OTLP_ENDPOINT']:env.pop(k,None)
env.update(AIGON_STANDALONE='1',AIGON_EMBEDDINGS='0',AIGON_ALLOW_RUN='0',AIGON_PROOF_STATE=str(STATE),AIGON_OPERATOR_NAME='review-operator')
process=None
SCENES=[]
START=0.0
FRAMES=[]
FRAME_START=0.0
AUDIO=json.loads((ROOT/"video/proof-v2/audio-durations.json").read_text()) if args.record else {}

def start():
 global process
 process=subprocess.Popen([str(ROOT/'target/release/aigon-governance-mcp'),'--http',str(PORT)],cwd=ROOT,env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 for _ in range(100):
  if process.poll() is not None:raise RuntimeError('server exited before ready')
  try:urllib.request.urlopen(URL+'/api/health',timeout=.5);return
  except Exception:time.sleep(.1)
 raise RuntimeError('server startup timeout')
def stop():
 if process and process.poll() is None:
  process.terminate()
  try:process.wait(timeout=5)
  except subprocess.TimeoutExpired:process.kill();process.wait()
def frame():
 if not args.record:return
 now=time.monotonic()-FRAME_START
 path=OUT/'frames'/f'{len(FRAMES):05d}.png';path.parent.mkdir(exist_ok=True)
 page.screenshot(path=str(path),animations='disabled')
 FRAMES.append({'path':str(path),'time':now})
def pause(sec=4):
 if args.record:
  index=len(SCENES)
  targets=[None,'verdict','verdict',None,'passport-summary','message','receipt-paper','message','history-list','verdict','lab-results',None]
  target=targets[index]
  if target:page.locator('#'+target).evaluate("e=>(e.closest('section')||e).scrollIntoView({block:'start',behavior:'instant'})")
  else:page.evaluate('scrollTo(0,0)')
  frame();SCENES.append({'scene':index,'start':time.monotonic()-START})
  until=time.monotonic()+max(sec,AUDIO.get(str(index),0)+.7)
  while time.monotonic()<until:
   page.wait_for_timeout(400);frame()
def shot(name):page.screenshot(path=str(OUT/(name+'.png')),full_page=not args.record)
def click(id):
 frame();page.locator('#'+id).click();page.wait_for_function('!document.querySelector("#review").disabled');
def select(doc,recipient='external-partner',operation='deliver'):
 page.locator('#operation').select_option(operation);page.locator('#document').select_option(doc);page.locator('#recipient').select_option(recipient)
def unlock():
 page.locator('#open-operator').click();page.wait_for_timeout(220);shot('operator-dialog');frame()
 if args.record and len(SCENES)==3:pause(4)
 page.locator('#operator-token').fill((STATE/'operator.token').read_text());click('unlock');assert page.locator('#operator-state').inner_text()=='Authenticated operator'

results={'checks':{},'js_errors':[],'console_errors':[]}
try:
 start()
 with sync_playwright() as pw:
  browser=pw.chromium.launch(headless=True,executable_path=os.environ.get('PROOF_CHROMIUM') or shutil.which('chromium'),args=['--no-sandbox','--disable-dev-shm-usage'])
  options={'viewport':{'width':1280 if args.record else 1920,'height':720 if args.record else 1080},'device_scale_factor':3 if args.record else 1}
  # Lossless native screenshots retain small glyph edges; no intermediate VP8 compression.
  context=browser.new_context(**options);page=context.new_page();START=time.monotonic();FRAME_START=START
  if args.preview_ui:page.route('**/proof*',lambda route:route.fulfill(status=200,content_type='text/html',body=PREVIEW_HTML))
  page.on('pageerror',lambda e:results['js_errors'].append(str(e)))
  page.on('console',lambda m:results['console_errors'].append(m.text) if m.type=='error' else None)
  page.goto(URL+('/proof?view=presentation' if args.record else '/proof'));page.wait_for_function('document.querySelector("#document").options.length===3')
  if args.record:START=time.monotonic();FRAME_START=START
  if args.record:
   assert page.evaluate('innerWidth===1280 && devicePixelRatio===3'), '150% framing at native4K required'
  shot('01-ready');pause(6)
  assert page.locator('#approve').is_disabled()
  click('review');assert page.locator('#review-state').inner_text()=='BLOCK';assert page.locator('#approve').is_disabled()
  shot('02-blocked');pause(7)
  select('redacted-summary');click('review');assert page.locator('#review-state').inner_text()=='REVIEW';assert page.locator('#approve').is_disabled()
  page.locator('summary').first.click();shot('03-review');pause(7)
  unlock();click('approve');assert page.locator('#passport-state').inner_text().startswith('Signed')
  shot('04-approved');pause(7)
  click('tamper');assert 'SWAP REJECTED' in page.locator('#message').inner_text();shot('05-tamper');pause(5)
  click('verify');assert 'VALID:' in page.locator('#message').inner_text()
  click('execute');assert 'Delivered' in page.locator('#receipt-state').inner_text();assert not page.locator('#receipt-content').is_hidden()
  assert 'ANONYMISED SUMMARY' in page.locator('#receipt-content').inner_text()
  shot('06-delivered');pause(8)
  click('replay');assert 'REPLAY REJECTED' in page.locator('#message').inner_text();shot('07-replay');pause(6)
  headers={'X-Operator-Token':(STATE/'operator.token').read_text()}
  receipts=page.request.get(URL+'/api/proof/receipts',headers=headers).json();receipt=receipts[-1]
  delivered=page.request.get(URL+'/api/proof/deliveries/'+receipt['id'],headers=headers).json()
  assert delivered['integrity_verified']
  assert hashlib.sha256(delivered['content'].encode()).hexdigest()==receipt['document_sha256']
  assert (STATE/receipt['path']).read_text()==delivered['content']
  results['checks']['real_delivery_and_receipt']=True
  stop();start();page.reload();page.wait_for_function('document.querySelector("#document").options.length===3');unlock();click('history')
  assert receipt['id'][:16] in page.locator('#history-list').inner_text();shot('08-restart');pause(6)
  results['checks']['restart_history']=True
  select('public-brief','records','archive');click('review');click('deny');assert page.locator('#review-state').inner_text()=='BLOCK';assert page.locator('#execute').is_disabled();results['checks']['human_denial']=True;pause(5)
  click('review');click('approve');click('deny');assert page.locator('#execute').is_disabled();assert page.locator('#passport-state').inner_text()=='Revoked';results['checks']['revocation_after_signing']=True
  select('public-brief','records','archive');click('review');click('approve');click('execute');assert 'Delivered' in page.locator('#receipt-state').inner_text();results['checks']['archive']=True
  click('crash');assert '6/6' in page.locator('#lab-state').inner_text();shot('09-lab');pause(5)
  results['checks']['policy_probes']=True
  page.locator('#command').fill('send everything anywhere please');click('review');assert 'Use exactly:' in page.locator('#message').inner_text();assert page.locator('#execute').is_disabled();results['checks']['ambiguous_command_rejected']=True
  # Protected approvals and private documents cannot be accessed by the agent plane.
  action={'actor':'mcp:assistant','operation':'deliver','document_id':'public-brief','recipient_id':'legal-team','approval_id':None}
  verdict=page.request.post(URL+'/api/proof/evaluate',data=action).json()
  unauthorized=page.request.post(URL+'/api/proof/approve',data={'action':action,'reviewed_hash':verdict['action_hash'],'approved':True})
  assert unauthorized.status==403
  assert page.request.get(URL+'/api/proof/receipts').status==403
  assert page.request.get(URL+'/api/proof/deliveries/'+receipt['id']).status==403
  results['checks']['operator_boundary']=True
  rpc=page.request.post(URL+'/mcp',headers={'Accept':'application/json, text/event-stream'},data={'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':'proof-release-check','version':'2'}}})
  assert '2025-11-25' in rpc.text();results['checks']['mcp_initialize']=True
  mcp_headers={'Accept':'application/json, text/event-stream','MCP-Protocol-Version':'2025-11-25'}
  if rpc.headers.get('mcp-session-id'):mcp_headers['Mcp-Session-Id']=rpc.headers['mcp-session-id']
  def mcp_call(method,params,call_id=2):
   response=page.request.post(URL+'/mcp',headers=mcp_headers,data={'jsonrpc':'2.0','id':call_id,'method':method,'params':params})
   raw=response.text()
   if raw.lstrip().startswith('{'):return json.loads(raw)
   for line in raw.splitlines():
    if line.startswith('data: {'):return json.loads(line[6:])
   raise RuntimeError('missing MCP response')
  listing=mcp_call('tools/list',{})
  names=[t['name'] for t in listing['result']['tools']]
  assert 'proof_execute' in names and 'proof_approve' not in names
  def tool(name,arguments):
   result=mcp_call('tools/call',{'name':name,'arguments':arguments})
   if 'error' in result:raise RuntimeError(result['error'].get('message','MCP error'))
   if result['result'].get('isError'):raise RuntimeError(str(result))
   return json.loads(result['result']['content'][0]['text'])
  parsed=tool('proof_parse',{'query':'deliver public-brief to legal-team'})
  mcp_verdict=tool('proof_evaluate',{'json':json.dumps(parsed)})
  assert mcp_verdict['decision']=='REVIEW'
  consent=page.request.post(URL+'/api/proof/approve',headers=headers,data={'action':parsed,'reviewed_hash':mcp_verdict['action_hash'],'approved':True}).json()
  parsed['approval_id']=consent['id']
  signed=tool('proof_issue',{'json':json.dumps(parsed)})
  tool_receipt=tool('proof_execute',{'json':json.dumps({'passport':signed,'action':parsed})})
  assert tool_receipt['status']=='delivered_local' and (STATE/tool_receipt['path']).is_file()
  results['checks']['mcp_tool_execution']=True

  page.goto(URL+'/');assert 'AIGON' in page.title()
  if args.record:page.evaluate("document.documentElement.style.background='#000'")
  shot('10-explorer');pause(5)
  if args.record:
   frame();(OUT/'lossless-frames.json').write_text(json.dumps(FRAMES,indent=2)+'\n');context.close()
   (OUT/'scene-timing.json').write_text(json.dumps(SCENES,indent=2)+'\n')
   context=browser.new_context(viewport={'width':1440,'height':1000});page=context.new_page()

  # Responsive, keyboard and reduced-motion checks on actual rendered DOM.
  for width,height in [(390,844),(768,1024),(1920,1080)]:
   page.set_viewport_size({'width':width,'height':height});page.goto(URL+('/proof?view=presentation' if args.record else '/proof'));page.wait_for_function('document.querySelector("#document").options.length===3')
   assert page.evaluate('document.documentElement.scrollWidth <= innerWidth'),f'horizontal overflow at {width}'
   shot('viewport-'+str(width))
  page.emulate_media(reduced_motion='reduce');assert page.evaluate('matchMedia("(prefers-reduced-motion: reduce)").matches')
  page.keyboard.press('Tab');assert page.evaluate('document.activeElement.tagName')!='BODY'
  results['checks']['responsive_keyboard_reduced_motion']=True
  assert not results['js_errors'],results['js_errors']
  context.close()
  browser.close()
 results['success']=True
finally:
 stop()
 (OUT/'browser-results.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results))
