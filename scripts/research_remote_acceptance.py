"""Real desktop worker/model, private synthetic ledger; no user app is opened."""
import hashlib,json,os,sqlite3,sys,tempfile,time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"src/helpers"))
import sync_transport as t
app,model=map(lambda p:Path(p).resolve(),sys.argv[1:])
with tempfile.TemporaryDirectory(prefix="penny-remote-proof-") as directory:
 root=Path(directory);data=root/"data/com.pennygoblin.app";data.mkdir(parents=True)
 os.environ["XDG_DATA_HOME"]=str(root/"data");os.environ["XDG_CONFIG_HOME"]=str(root/"config")
 choice=data/"categorization-model";choice.mkdir();(choice/"choice.json").write_text(json.dumps(str(model)))
 dbpath=data/"ledger.sqlite3";db=sqlite3.connect(dbpath)
 source=Path(__file__).resolve().parents[1]/"src/core"
 for script in ("schema.sql","migration2.sql","migration3.sql","migration4.sql"):db.executescript((source/script).read_text())
 settings=json.dumps({"categories":{"Sports":[],"Groceries":["MARKET"]}})
 db.execute("insert into settings values('budget',?)",(settings,))
 ids=[]
 for merchant in ["DECATHLON","MARKET 1","MARKET 2"]:
  identity=hashlib.sha256(merchant.encode()).hexdigest();ids.append(identity)
  db.execute("insert into expenses(id,revision,date,amount,currency,payee,account,category,notes,reference,location) values(?,1,'2026-10-18',100,'CLP',?,'Debit','Other','','','')",(identity,merchant))
  db.execute("insert into changes(expense_id,revision) values(?,1)",(identity,))
 db.commit()
 jobs=t.ResearchJobs(app,dbpath)
 assert jobs.handle('phone',{'action':'model'})['ready']
 response=jobs.handle('phone',{'action':'start','ids':ids});job=response['job'];events=[]
 try:
  deadline=time.monotonic()+900
  while True:
   response=jobs.handle('phone',{'action':'poll','job':job,'after':len(events)})
   events.extend(response['events'])
   for event in response['events']:print(event['stage'],event.get('merchant',''),event.get('tool',''),flush=True)
   if response['state']!='running':break
   assert time.monotonic()<deadline,'Research timed out'
   time.sleep(.2)
  assert response['state']=='ready',response
  assert db.execute("select count(*) from expenses where category='Other' and revision=1").fetchone()[0]==3,'Writes during research'
  proposals=response['review']['proposals']
  merchant=next(p for p in proposals if p['merchant']=='DECATHLON')
  assert merchant['category']=='Sports' and merchant['sources'],merchant
  assert any(e.get('tool')=='search' for e in events) and any(e.get('url') for e in events),events
  edit={'expected_settings':settings,'selections':[{'targets':p['targets'],'category':p['category']} for p in proposals if p['category']]}
  for _ in range(2):assert jobs.handle('phone',{'action':'apply','job':job,'edit':edit})['count']==3
  assert db.execute("select count(*) from expenses where revision=2").fetchone()[0]==3,'Duplicate or missing Apply'
  assert db.execute("select count(*) from expenses where amount=100 and account='Debit'").fetchone()[0]==3
  assert db.execute("select count(*) from changes where revision=2").fetchone()[0]==3
  assert db.execute('pragma integrity_check').fetchone()[0]=='ok'
  print('Real paired-job worker: activity/sources streamed, no writes before Apply, retry applied once, sync bookkeeping and financial fields verified.',flush=True)
 finally:
  if jobs.jobs['phone']['state']=='running':jobs.handle('phone',{'action':'cancel','job':job})
  limit=time.monotonic()+10
  while t.scanning.locked() and time.monotonic()<limit:time.sleep(.05)
  assert not t.scanning.locked(),'Worker not released'
  db.close()
