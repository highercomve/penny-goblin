"""Category search, draft navigation and reviewed merge in the real WebKit UI.

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
window.qaFixture = {platform:'android',vision_available:false,tray_running:false,statements:[],
 settings:JSON.stringify({categories:{Dining:['CAFE'],Dinning:['RESTAURANT']}}),expenses:[
 {id:'a'.repeat(64),revision:3,date:'2026-10-18',amount:1000,payee:'Cafe',account:'Debit',category:'Dining'},
 {id:'b'.repeat(64),revision:1,date:'2025-01-18',amount:2000,payee:'Lunch',account:'Debit',category:'Dinning'},
 {id:'c'.repeat(64),revision:1,date:'2026-10-18',amount:3000,payee:'Old category',account:'Debit',category:'Travel'}]};
window.qaFail = false;
window.oriel = {listen(){},invoke:async(cmd,args={})=>{
 qaCalls.push({cmd,args});
 if(cmd==='snapshot')return qaFixture;
 if(cmd==='expense_documents'||cmd==='expense_sources')return [];
 if(cmd==='qa_scenario'||cmd==='take_quick_action')return null;
 if(cmd==='save_budget'){
  if(qaFail)throw Error('RevisionConflict');
  const config=JSON.parse(qaFixture.settings), change=args.category_change;
  config.categories[change.target]=[...(config.categories[change.target]||[]),...(config.categories[change.source]||[])];
  if(change.source){delete config.categories[change.source];for(const row of qaFixture.expenses)if(row.category===change.source)row.category=change.target;}
  qaFixture.settings=JSON.stringify(config);return args.targets.length;
 }
 throw Error(cmd);
}};
window.addEventListener('load',async()=>{
 const until=async(fn)=>{for(let i=0;i<150;i++){if(fn())return;await new Promise(r=>setTimeout(r,20));}throw Error('UI wait timed out');};
 const check=(ok,message)=>{if(!ok)throw Error(message);};
 const input=(id,value)=>{document.getElementById(id).value=value;document.getElementById(id).dispatchEvent(new Event('input',{bubbles:true}));};
 try{
  await until(()=>snapshot);
  await openEditor(snapshot.expenses[0]);
  form.elements.namedItem('payee').value='Unsaved merchant';
  document.getElementById('choose-category').click();
  check(document.getElementById('category-picker').open,'Picker did not open');
  check(!document.getElementById('choose-category').closest('details'),'Category hidden in details');
  check(document.getElementById('category-list').textContent.includes('Travel'),'Expense-only category absent');
  input('category-search',' dining ');
  check(document.getElementById('category-add').hidden,'Case/spacing duplicate offered');
  input('category-search','Dinin');
  check(document.getElementById('category-list').textContent.includes('Dining'),'Likely typo did not show existing category');
  input('category-search','Travel');
  document.querySelector('#category-list button').click();
  check(form.elements.namedItem('category').value==='Travel','Selection failed');
  check(form.elements.namedItem('payee').value==='Unsaved merchant','Selection lost draft');
  await new Promise(r=>setTimeout(r,100));
  document.getElementById('choose-category').click();
  history.back();
  await until(()=>!document.getElementById('category-picker').open);
  check(editor.open && form.elements.namedItem('payee').value==='Unsaved merchant','Back lost editor');
  await new Promise(r=>setTimeout(r,100));
  document.getElementById('choose-category').click();input('category-search','Pets');document.getElementById('category-add').click();
  await until(()=>!categorySaving);
  check(form.elements.namedItem('category').value==='Pets','New category not selected');
  check(JSON.parse(snapshot.settings).categories.Pets,'New category not persisted');
  await new Promise(r=>setTimeout(r,100));
  closeThen(editor,()=>openCategoryPicker(true));
  await until(()=>document.getElementById('category-picker').open);
  input('category-search','Dinning');document.querySelector('#category-list button').click();
  input('category-target','Dining');
  document.getElementById('category-edit').requestSubmit();
  check(document.getElementById('category-summary').textContent.includes('1 payments across all dates'),'Preview ignored old dates');
  check(qaCalls.filter(x=>x.cmd==='save_budget').length===1,'Preview wrote data');
  input('category-target','Dining2');check(document.getElementById('category-apply').hidden,'Edited target left stale apply');
  input('category-target','Dining');document.getElementById('category-edit').requestSubmit();
  qaFail=true;document.getElementById('category-apply').click();await until(()=>!categorySaving);
  check(document.getElementById('category-picker').open && document.getElementById('category-target').value==='Dining','Conflict lost review');
  qaFail=false;document.getElementById('category-edit').requestSubmit();document.getElementById('category-apply').click();await until(()=>!categorySaving);
  check(snapshot.expenses[1].category==='Dining','Merge not reflected');
  check(qaCalls.filter(x=>x.cmd==='save_expense').length===0,'Picker saved payment draft');
  await new Promise(r=>setTimeout(r,100));
  openCategoryPicker(true);
  window.webkit.messageHandlers.qa.postMessage(JSON.stringify({ok:true,calls:qaCalls.filter(x=>x.cmd==='save_budget').length}));
 }catch(error){window.webkit.messageHandlers.qa.postMessage(JSON.stringify({ok:false,error:String(error),stack:error.stack}));}
});
"""


class QuietFiles(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_): pass


class CategoryUiTest(unittest.TestCase):
    def test_category_flow_desktop(self):
        self.run_review(False)

    def test_category_flow_phone(self):
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
        window.set_default_size(393 if mobile else 1180, 820)
        window.set_child(view)
        window.present()
        view.load_uri(f"http://127.0.0.1:{server.server_port}/")
        timeout = GLib.timeout_add_seconds(20, lambda: (loop.quit(), False)[1])
        try:
            loop.run()
            self.assertTrue(result.get("ok"), result or "WebKit UI timed out")
            self.assertEqual(result["calls"], 3)
        finally:
            GLib.source_remove(timeout)
            window.destroy()
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__": unittest.main()
