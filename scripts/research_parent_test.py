"""A sync-service crash must release its real research worker/model lease."""
from pathlib import Path
import fcntl,hashlib,json,os,sqlite3,subprocess,sys,tempfile,time
app,model=map(lambda p:Path(p).resolve(),sys.argv[1:])
wrapper="""import json,subprocess,sys,time
p=subprocess.Popen([sys.argv[1],'--research-worker',sys.argv[2]],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
p.stdin.write(json.dumps({'action':'start','ids':[sys.argv[3]]}).encode());p.stdin.close()
print(p.pid,flush=True)
print(p.stdout.readline().decode().strip(),flush=True)
time.sleep(60)
"""
with tempfile.TemporaryDirectory(prefix='penny-research-parent-') as directory:
 root=Path(directory);data=root/'data/com.pennygoblin.app';data.mkdir(parents=True)
 choice=data/'categorization-model';choice.mkdir();(choice/'choice.json').write_text(json.dumps(str(model)))
 dbpath=data/'ledger.sqlite3';db=sqlite3.connect(dbpath);source=Path(__file__).resolve().parents[1]/'src/core'
 for script in ('schema.sql','migration2.sql','migration3.sql','migration4.sql'):db.executescript((source/script).read_text())
 identity=hashlib.sha256(b'DECATHLON').hexdigest()
 db.execute("insert into settings values('budget',?)",(json.dumps({'categories':{'Sports':[]}}),))
 db.execute("insert into expenses(id,revision,date,amount,currency,payee,account,category,notes,reference,location) values(?,1,'2026-10-18',100,'CLP','DECATHLON','Debit','Other','','','')",(identity,));db.commit();db.close()
 parent=subprocess.Popen([sys.executable,'-c',wrapper,str(app),str(dbpath),identity],stdout=subprocess.PIPE,text=True,env={**os.environ,'XDG_DATA_HOME':str(root/'data'),'XDG_CONFIG_HOME':str(root/'config')})
 try:
  pid=int(parent.stdout.readline());event=json.loads(parent.stdout.readline())
  assert event['kind']=='progress' and event['value']['stage']=='Loading desktop model',event
  parent.kill();parent.wait(timeout=5)
  deadline=time.monotonic()+5
  while time.monotonic()<deadline:
   stat=Path(f'/proc/{pid}/stat')
   if not stat.exists() or stat.read_text().split(') ',1)[1].startswith('Z '):break
   time.sleep(.02)
  else:raise AssertionError('Research worker survived sync parent death')
  with (data/'inference.lock').open('a') as held:fcntl.flock(held,fcntl.LOCK_EX|fcntl.LOCK_NB)
  print('Real research worker terminated and inference lease released after parent crash.')
 finally:
  if parent.poll() is None:parent.kill();parent.wait()
  parent.stdout.close()
