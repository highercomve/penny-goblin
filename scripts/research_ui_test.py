"""Actual WebKit review UI with a deterministic command boundary.

Run with Oriel scripts/headless.sh; no real ledger/model/network is used.
"""
import functools
import http.server
import json
from pathlib import Path
import threading
import unittest
import gi

gi.require_version("Gtk", "4.0")
gi.require_version("WebKit", "6.0")
from gi.repository import Gtk, GLib, WebKit

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = r"""
window.setInterval = () => 0;
window.qaCalls = [];
window.qaListeners = {};
window.qaFailApply = true;
window.qaFixture = {platform:'linux',vision_available:true,tray_running:false,statements:[],
 settings:JSON.stringify({salary:100000,categories:{Sports:[],Dining:[]}}),expenses:[
 {id:'a'.repeat(64),revision:3,date:'2026-10-18',amount:1000,payee:'DECATHLON',account:'Debit',category:'Other'},
 {id:'b'.repeat(64),revision:1,date:'2026-10-18',amount:2000,payee:'Unknown recipient',account:'Debit',category:'Other'},
 {id:'c'.repeat(64),revision:1,date:'2026-10-18',amount:3000,payee:'Next merchant',account:'Debit',category:'Other'}]};
window.oriel = {listen(name,cb){qaListeners[name]=cb;},openExternal:async()=>{},invoke:async (cmd,args={})=>{
 qaCalls.push({cmd,args});
 if(cmd==='snapshot')return qaFixture;
 if(cmd==='research_model_status')return JSON.stringify({label:'Qwen3.5 9B',ready:true,custom:false,downloading:false,size_mb:5417});
 if(cmd==='qa_scenario'||cmd==='take_quick_action')return null;
 if(cmd==='research_categories' && qaCalls.filter(x=>x.cmd===cmd).length>1)return JSON.stringify({expected_settings:qaFixture.settings,remaining:0,proposals:[]});
 if(cmd==='research_categories'){
  qaListeners.research_progress?.({stage:'Searching web',merchant:'DECATHLON',detail:'Query: merchant Chile',completed:0,total:2});
  qaListeners.research_progress?.({stage:'Reading source',merchant:'Next merchant',detail:'Latest source',completed:1,total:2});
  if(document.getElementById('research-progress').textContent!=='1/2 merchants complete · update 2')throw Error('Batch progress did not update');
  if(document.getElementById('research-merchant').textContent!=='Next merchant')throw Error('Current merchant did not update');
  if(!document.getElementById('research-activity').textContent.startsWith('Next merchant'))throw Error('Newest activity is not first');
  if(!document.getElementById('research-start').hidden)throw Error('Start must hide during research');
 }
 if(cmd==='research_categories')return JSON.stringify({expected_settings:qaFixture.settings,remaining:1,proposals:[
 {merchant:'DECATHLON',targets:[{id:'a'.repeat(64),revision:3}],category:'Sports',reason:'Sports equipment',sources:[{url:'https://www.decathlon.cl/',title:'Merchant evidence',quote:'Sports equipment'},{url:'https://www.decathlon.cl/deportes',title:'Second source',quote:'Sports catalog'}]},
 {merchant:'Unknown recipient',targets:[{id:'b'.repeat(64),revision:1}],category:'',reason:'Insufficient evidence',sources:[]}]});
 if(cmd==='apply_research'){
  if(qaFailApply)throw Error('RevisionConflict');
  qaFixture.expenses[0].category=args.selections[0].category;
  return args.selections.reduce((n,g)=>n+g.targets.length,0);
 }
 throw Error(cmd);
}};
window.addEventListener('load',async()=>{
 const until=async(fn)=>{for(let i=0;i<100;i++){if(fn())return;await new Promise(r=>setTimeout(r,20));}throw Error('UI wait timed out');};
 const check=(value,message)=>{if(!value)throw Error(message);};
 try{
  await until(()=>snapshot);
  showView('payments');
  document.getElementById('research-open').click();
  await until(()=>categorizationModelReady);
  document.getElementById('research-start').click();
  await until(()=>!researchRunning && researchReview);
  const selects=[...document.querySelectorAll('#research-results select')];
  check(document.getElementById('research-activity').textContent.includes('DECATHLON'),'Activity log missing');
  check(document.getElementById('research-model-controls').hidden === (qaFixture.platform==='android'),'Phone must configure the desktop model on desktop');
  check(document.getElementById('research-progress').textContent.includes('Batch complete'),'Completion state missing');
  check(!document.getElementById('research-start').hidden,'Start did not return after research');
  check(selects.length===2 && selects[0].value==='Sports' && selects[1].value==='', 'Suggestions or abstention missing');
  check(document.querySelectorAll('#research-results details').length===2,'Every source must be disclosed');
  check(!qaCalls.some(x=>x.cmd==='apply_research'),'Research must not write');
  check(!document.getElementById('research-apply').disabled,'Selected proposal cannot apply');
  document.getElementById('research-apply').click();
  await until(()=>!researchApplying);
  check(researchReview!==null && selects[0].value==='Sports','Conflict lost review draft');
  const edit=qaCalls.find(x=>x.cmd==='apply_research').args;
  check(edit.selections.length===1 && edit.selections[0].targets[0].revision===3 && edit.expected_settings===qaFixture.settings,'Wrong selection or revisions');
  qaFailApply=false;
  document.getElementById('research-apply').click();
  await until(()=>!researchApplying);
  check(researchReview===null && qaFixture.expenses[0].category==='Sports' && qaFixture.expenses[1].category==='Other','Wrong applied expenses');
  document.getElementById('research-start').click();
  await until(()=>!researchRunning && qaCalls.filter(x=>x.cmd==='research_categories').length===2);
  const next=qaCalls.filter(x=>x.cmd==='research_categories')[1].args.ids;
  check(next.length===1 && next[0]==='c'.repeat(64),'Reviewed abstentions must not starve the next batch');
  window.webkit.messageHandlers.qa.postMessage(JSON.stringify({ok:true,calls:qaCalls.filter(x=>x.cmd==='apply_research').length}));
 }catch(error){window.webkit.messageHandlers.qa.postMessage(JSON.stringify({ok:false,error:String(error)}));}
});
"""


class QuietFiles(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_): pass


class ResearchUiTest(unittest.TestCase):
    def test_review_selection_conflict_and_apply(self):
        self.run_review(False)

    def test_phone_review_and_activity(self):
        self.run_review(True)

    def run_review(self, mobile):
        Gtk.init()
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(QuietFiles, directory=str(ROOT / "frontend")))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        loop = GLib.MainLoop()
        result = {}
        manager = WebKit.UserContentManager()
        manager.register_script_message_handler("qa", None)
        def received(_manager, value):
            result.update(json.loads(value.to_string()))
            loop.quit()
        manager.connect("script-message-received::qa", received)
        script = BRIDGE.replace("window.addEventListener('load'", "qaFixture.platform='android';qaFixture.vision_available=false;window.addEventListener('load'") if mobile else BRIDGE
        manager.add_script(WebKit.UserScript.new(script, WebKit.UserContentInjectedFrames.TOP_FRAME, WebKit.UserScriptInjectionTime.START, None, None))
        view = WebKit.WebView(network_session=WebKit.NetworkSession.new_ephemeral(), user_content_manager=manager)
        window = Gtk.Window()
        window.set_default_size(1180, 820)
        window.set_child(view)
        window.present()
        view.load_uri(f"http://127.0.0.1:{server.server_port}/")
        timeout = GLib.timeout_add_seconds(20, lambda: (loop.quit(), False)[1])
        try:
            loop.run()
            self.assertTrue(result.get("ok"), result or "WebKit UI timed out")
            self.assertEqual(result["calls"], 2)
        finally:
            GLib.source_remove(timeout)
            window.destroy()
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__": unittest.main()
