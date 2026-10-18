"""Remote lifecycle/auth boundary with real isolated worker subprocesses."""
import http.server
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
import urllib.request
import urllib.error
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src/helpers"))
import sync_transport as t

FAKE = r'''import json,sys,time,ctypes
ctypes.CDLL(None).prctl(1,15,0,0,0)
from pathlib import Path
args=json.load(sys.stdin)
if sys.argv[1]=='--sync-worker':
 p=Path(sys.argv[2]);p.write_text(str(int(p.read_text() or '0')+1))
 print(json.dumps({'ok':True,'value':1}))
elif args['action']=='status':
 print(json.dumps({'kind':'status','value':{'ready':True,'custom':False,'downloading':False,'size_mb':5417,'label':'Test desktop'}}))
else:
 for stage in ['Loading desktop model','Reading source']:
  print(json.dumps({'kind':'progress','value':{'stage':stage,'completed':0,'total':1}}),flush=True)
  time.sleep(.1)
 if args['ids'][0]=='f'*64:time.sleep(60)
 review={'expected_settings':'{}','remaining':0,'proposals':[{'merchant':'Test','targets':[{'id':args['ids'][0],'revision':3}],'category':'Sports','sources':[],'reason':'Test evidence'}]}
 print(json.dumps({'kind':'review','value':review}),flush=True)
'''

class JobsTest(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
  self.exe=self.root/'worker';self.exe.write_text('#!'+sys.executable+'\n'+FAKE);self.exe.chmod(0o700)
  self.db=self.root/'writes';self.db.write_text('0')
  self.jobs=t.ResearchJobs(self.exe,self.db)
 def tearDown(self):
  for job in self.jobs.jobs.values():
   if job['state']=='running':self.jobs.handle(next(k for k,v in self.jobs.jobs.items() if v is job),{'action':'cancel','job':job['job']})
  deadline=time.monotonic()+5
  while t.scanning.locked() and time.monotonic()<deadline:time.sleep(.01)
  self.tmp.cleanup()
 def start(self,owner='owner',identity='a'):
  return self.jobs.handle(owner,{'action':'start','ids':[identity*64]})
 def ready(self,owner,job):
  deadline=time.monotonic()+5
  while time.monotonic()<deadline:
   value=self.jobs.handle(owner,{'action':'poll','job':job})
   if value['state']=='ready':return value
   time.sleep(.02)
  self.fail('Job did not become ready')
 def test_resume_events_no_writes_atomic_retry_and_ownership(self):
  first=self.start();job=first['job']
  self.assertEqual(job,self.start()['job'])
  with self.assertRaisesRegex(ValueError,'ResearchJobNotFound'):
   self.jobs.handle('other',{'action':'poll','job':job})
  review=self.ready('owner',job)
  self.assertEqual('0',self.db.read_text())
  self.assertEqual(2,len(review['events']))
  self.assertEqual(1,len(self.jobs.handle('owner',{'action':'poll','job':job,'after':1})['events']))
  edit={'expected_settings':'{}','selections':[{'category':'Sports','targets':review['review']['proposals'][0]['targets']}]}
  bad=json.loads(json.dumps(edit));bad['selections'][0]['targets'][0]['id']='b'*64
  with self.assertRaisesRegex(ValueError,'InvalidSelection'):
   self.jobs.handle('owner',{'action':'apply','job':job,'edit':bad})
  for _ in range(2):self.assertEqual({'count':1},self.jobs.handle('owner',{'action':'apply','job':job,'edit':edit}))
  self.assertEqual('1',self.db.read_text())
 def test_cancel_busy_and_next_batch(self):
  running=self.start(identity='f')
  with self.assertRaisesRegex(ValueError,'DesktopScannerBusy'):self.start('other')
  value=self.jobs.handle('owner',{'action':'cancel','job':running['job']})
  self.assertEqual('cancelled',value['state'])
  deadline=time.monotonic()+5
  while t.scanning.locked() and time.monotonic()<deadline:time.sleep(.01)
  self.assertFalse(t.scanning.locked())
  ready=self.ready('owner',self.start()['job'])
  while t.scanning.locked():time.sleep(.01)
  self.assertNotEqual(ready['job'],self.start(identity='b')['job'])
 def test_http_requires_paired_identity(self):
  class Identity:
   executable=self.exe;database=self.db
   def authenticate(self,header):return 'a'*64 if header=='Bearer valid' else None
  server=http.server.ThreadingHTTPServer(('127.0.0.1',0),t.Handler)
  server.identity=Identity();server.research=self.jobs
  thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
  def request(body,token=None):
   headers={'Content-Type':'application/json'}
   if token:headers['Authorization']='Bearer '+token
   return urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{server.server_port}/v1/research',data=json.dumps(body).encode(),headers=headers),timeout=5)
  try:
   for token,device,expected in [(None,'a'*64,401),('valid','b'*64,403)]:
    with self.assertRaises(urllib.error.HTTPError) as error:request({'action':'model','device_id':device},token)
    self.assertEqual(expected,error.exception.code)
    error.exception.close()
   with request({'action':'model','device_id':'a'*64},'valid') as response:self.assertTrue(json.load(response)['ready'])
   with request({'action':'start','device_id':'a'*64,'ids':['a'*64]},'valid') as response:job=json.load(response)['job']
   self.ready('a'*64,job) # The HTTP request thread has exited; the job must survive.
  finally:server.shutdown();server.server_close();thread.join()

if __name__=='__main__':unittest.main()
