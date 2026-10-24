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
 {id:'a'.repeat(64),revision:3,date:'2026-10-18',amount:1000,payee:'Cafe',account:'Debit',category:'Other'},
 {id:'b'.repeat(64),revision:1,date:'2025-01-18',amount:2000,payee:'Lunch',account:'Debit',category:'Dinning'},
 {id:'c'.repeat(64),revision:1,date:'2026-10-18',amount:3000,payee:'Old category',account:'Debit',category:'Travel'}]};
window.qaFail = false;
window.oriel = {listen(){},invoke:async(cmd,args={})=>{
 qaCalls.push({cmd,args});
 if(cmd==='snapshot')return qaFixture;
 if(cmd==='import_santander'||cmd==='import_bci'||cmd==='import_boa'){
  qaFixture.statements=[{hash:'e'.repeat(64),name:(cmd==='import_boa'?'Bank of America USD':cmd==='import_bci'?'BCI CLP':'Santander CLP')+' · synthetic',status:'review',format:'json'}];
  return {hash:'e'.repeat(64),added:1};
 }
 if(cmd==='statement_observations')return window.qaBankRows || [{id:'f'.repeat(64),source:{date:'2026-10-19',amount:1200,payee:'TEST SHOP',account:'1234',category:'Other'},expense_id:null,ignored:false}];
 if(cmd==='expense_documents'||cmd==='expense_sources')return [];
 if(cmd==='qa_scenario'||cmd==='take_quick_action')return null;
 if(cmd==='save_budget'){
  if(qaFail)throw Error('RevisionConflict');
  const config=JSON.parse(qaFixture.settings), change=args.category_change;
  if(!change){qaFixture.settings=JSON.stringify(args.settings);return 0;}
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
  check(window.innerWidth < 600 || window.innerWidth >= 840,
        `Expected phone or desktop viewport, got ${window.innerWidth}px`);
  // The bank login is a human browser action; capture only stages a review.
  snapshot.santander_available=window.innerWidth>=840;renderStatements();
  if(snapshot.santander_available){
   $('statements-page').showModal();
   const before=qaCalls.filter(x=>x.cmd==='import_santander').length;
   $('santander-connect').click();
   check(qaCalls.filter(x=>x.cmd==='import_santander').length===before,'Empty account opened bank');
   input('santander-account','1234');$('santander-connect').click();
   await until(()=>$('statement-dialog').open);
   check(!mutationPending,'Bank capture left UI busy');
   check($('statement-rows').textContent.includes('TEST SHOP'),'Captured charges not offered for review');
   check(!qaCalls.some(x=>x.cmd==='reconcile_statement'||x.cmd==='save_expense'),'Capture saved payments');
   check(qaCalls.find(x=>x.cmd==='import_santander').args.account==='1234','Card account lost');
   $('close-statement').click();
   await until(()=>!$('statement-dialog').open);
   await new Promise(r=>setTimeout(r,100));
   $('statements-page').showModal();$('bank-bci').click();
   check($('santander-account').value==='','Changing bank retained the previous card');
   check($('santander-connect').textContent==='Open BCI','BCI connection action missing');
   check($('bank-import-description').textContent.includes('card or account'),'BCI checking accounts missing');
   const beforeBci=qaCalls.filter(x=>x.cmd==='import_bci').length;
   $('santander-connect').click();
   check(qaCalls.filter(x=>x.cmd==='import_bci').length===beforeBci,'BCI opened without an account');
   input('santander-account','BCI checking');$('bank-add-account').click();
   check($('preferences-dialog').open && $('statements-page').open,'Account editor lost bank import');
   const accountRow=$('preferences-accounts').lastElementChild;
   check(accountRow.querySelector('input').value==='BCI checking','New card was not prefilled');
   accountRow.querySelectorAll('input')[1].value='Test cardholder';
   $('preferences-form').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}));
   await until(()=>!mutationPending && !$('preferences-dialog').open);
   check(settings.cards_config['BCI checking']==='Test cardholder','New card was not saved');
   check($('statements-page').open && $('santander-account').value==='BCI checking','New card was not selected on return');
   check($('santander-accounts').querySelector('option[value="BCI checking"]'),'New card missing from account suggestions');
   $('santander-connect').click();
   await until(()=>$('statement-dialog').open);
   check(qaCalls.find(x=>x.cmd==='import_bci').args.account==='BCI checking','Wrong BCI ledger account');
   check(!qaCalls.some(x=>x.cmd==='reconcile_statement'||x.cmd==='save_expense'),'BCI capture saved payments without review');
   $('close-statement').click();await until(()=>!$('statement-dialog').open);
   await new Promise(r=>setTimeout(r,100));
   $('statements-page').showModal();$('bank-boa').click();
   check($('santander-account').value==='','Bank of America retained BCI account');
   check($('bank-import-currency').textContent==='USD','Bank of America currency is not USD');
   check($('bank-import-step').textContent==='Download CSV','Bank of America export instructions missing');
   const beforeBoa=qaCalls.filter(x=>x.cmd==='import_boa').length;
   $('santander-connect').click();
   check(qaCalls.filter(x=>x.cmd==='import_boa').length===beforeBoa,'Bank of America opened without an account');
   window.qaBankRows=[{id:'f'.repeat(64),source:{date:'2026-10-19',amount:1234,currency:'USD',payee:'TEST US SHOP',account:'BofA checking',category:'Other'},expense_id:null,ignored:false}];
   input('santander-account','BofA checking');$('santander-connect').click();
   await until(()=>$('statement-dialog').open);
   check(qaCalls.find(x=>x.cmd==='import_boa').args.account==='BofA checking','Wrong Bank of America account');
   check($('statement-rows').textContent.includes(formatAmount(1234,'USD')),'USD cents displayed incorrectly');
   check(!qaCalls.some(x=>x.cmd==='reconcile_statement'||x.cmd==='save_expense'),'Bank of America saved without review');
   $('close-statement').click();await until(()=>!$('statement-dialog').open);
   window.qaBankRows=null;
   $('bank-santander').click();
  }else check($('santander-import').hidden,'Phone exposed desktop bank login');
  const bankSettingsWrites=qaCalls.filter(x=>x.cmd==='save_budget').length;
  // Database matches are kept out of the work queue, while ambiguous charges
  // require a decision and the save button reflects only genuinely new rows.
  window.qaBankRows = [
   {id:'1'.repeat(64),source:{date:'2026-10-18',amount:1000,payee:'CAFE',account:'Debit',category:'Other'},expense_id:null,ignored:false,match:{id:'a'.repeat(64),revision:3}},
   {id:'2'.repeat(64),source:{date:'2026-10-18',amount:7600,payee:'NEW SHOP',account:'Debit',category:'Other'},expense_id:null,ignored:false,match:null},
   {id:'3'.repeat(64),source:{date:'2026-10-19',amount:3000,payee:'DIFFERENT SHOP',account:'Debit',category:'Other'},expense_id:null,ignored:false,match:null}];
  await openStatement({hash:'e'.repeat(64),name:'Synthetic bank review',format:'json'});
  check($('statement-review-status').textContent==='1 new · 1 to check · 1 already recorded','Wrong duplicate summary');
  check($('statement-rows').querySelectorAll(':scope > article').length===2,'Existing payments clutter the work queue');
  check(!$('statement-rows').querySelector('details').open,'Recorded payments should be collapsed');
  const recorded=$('statement-rows').querySelector('details select');
  check(recorded.value==='link:'+'a'.repeat(64),'Database match would create a duplicate');
  const uncertain=$('statement-rows').querySelector('select[data-observation="'+ '3'.repeat(64) +'"]');
  uncertain.value='ignore';uncertain.dispatchEvent(new Event('change',{bubbles:true}));
  check($('confirm-statement').textContent==='Add 1 new charge','Save button counts existing payments as new');
  $('close-statement').click();window.qaBankRows=null;
  await until(()=>!$('statement-dialog').open);
  // Imported case variants in another section must not block Special payments.
  settings.categories = {Dining:[], dining:[]};
  settings.special_cases = {"TRASPASO A DEUDA NACIONAL":"USD purchases converted to CLP"};
  snapshot.settings = JSON.stringify(settings);
  const historic={id:'d'.repeat(64),revision:1,date:'2026-09-09',amount:232466,payee:'Traspaso A Deuda Nacional',account:'Debit',category:'Other'};
  snapshot.expenses.push(historic);
  document.getElementById('month').value='';render();
  check(PennyReports.category(historic,settings)==='Special: USD purchases converted to CLP','Historical special classification missing');
  check(document.getElementById('rows').textContent.includes('Special: USD purchases converted to CLP'),'Payment row still shows Other');
  document.getElementById('category-filter').value='Other';
  check(!filteredPayments().some(row=>row.id===historic.id),'Other filter includes special transfer');
  document.getElementById('category-filter').value='';
  openPreferences('special');
  addPreferenceMapping('special','Traspaso A Deuda Nacional','USD purchases converted to CLP');
  const equivalent = readPreferences();
  check(Object.keys(equivalent.special_cases).length===1,'Equivalent rule was not reused');
  check(Object.keys(equivalent.categories).length===2,'Unrelated category settings changed');
  const duplicateInputs=document.querySelector('#preferences-special > .preference-row:last-child').querySelectorAll('input');
  duplicateInputs[1].value='Different label';
  let conflict=null;try{readPreferences();}catch(error){conflict=error;}
  check(conflict?.name==='RuleConflict' && errorText(conflict).includes('USD purchases converted to CLP'),'Conflicting rule error is not actionable');
  duplicateInputs[1].value='USD purchases converted to CLP';
  document.getElementById('preferences-form').requestSubmit();
  await until(()=>!preferencesSaving);
  check(!document.getElementById('preferences-dialog').open,'Could not save identical special rule');
  await new Promise(r=>setTimeout(r,100));

  if (window.innerWidth >= 840) {
    const outside=(downX=0,downY=0)=>{
      editor.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,button:0,pointerType:'mouse',clientX:downX,clientY:downY}));
      editor.dispatchEvent(new MouseEvent('click',{bubbles:true,button:0,clientX:0,clientY:0}));
    };
    await openEditor(snapshot.expenses[0]);
    const bounds=editor.getBoundingClientRect();
    outside(bounds.left+40,bounds.top+100);
    check(editor.open,'Dragging from inside dismissed payment');
    editor.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,button:0,clientX:0,clientY:0}));
    editor.dispatchEvent(new PointerEvent('pointercancel',{bubbles:true}));
    editor.dispatchEvent(new MouseEvent('click',{bubbles:true,clientX:0,clientY:0}));
    check(editor.open,'Cancelled press dismissed payment');
    outside();
    await until(()=>!editor.open);
    await new Promise(r=>setTimeout(r,100));
    await openEditor(snapshot.expenses[0]);
    form.elements.namedItem('payee').value='Keep my draft';form.dispatchEvent(new Event('input',{bubbles:true}));
    outside();await until(()=>document.getElementById('ask-dialog').open);
    document.querySelector('#ask-dialog button[value=""]').click();
    await until(()=>!document.getElementById('ask-dialog').open);
    check(editor.open && form.elements.namedItem('payee').value==='Keep my draft','Outside click lost dirty draft');
    dirty=false;
    await new Promise(r=>setTimeout(r,100));outside();await until(()=>!editor.open);
    await new Promise(r=>setTimeout(r,100));
  }
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
  check(qaCalls.filter(x=>x.cmd==='save_budget').length===bankSettingsWrites+2,'Preview wrote data');
  input('category-target','Dining2');check(document.getElementById('category-apply').hidden,'Edited target left stale apply');
  input('category-target','Dining');document.getElementById('category-edit').requestSubmit();
  qaFail=true;document.getElementById('category-apply').click();await until(()=>!categorySaving);
  check(document.getElementById('category-picker').open && document.getElementById('category-target').value==='Dining','Conflict lost review');
  qaFail=false;document.getElementById('category-edit').requestSubmit();document.getElementById('category-apply').click();await until(()=>!categorySaving);
  check(snapshot.expenses[1].category==='Dining','Merge not reflected');
  check(qaCalls.filter(x=>x.cmd==='save_expense').length===0,'Picker saved payment draft');
  await new Promise(r=>setTimeout(r,100));
  openCategoryPicker(true);
  window.webkit.messageHandlers.qa.postMessage(JSON.stringify({ok:true,calls:qaCalls.filter(x=>x.cmd==='save_budget').length-bankSettingsWrites}));
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
            self.assertEqual(result["calls"], 4)
        finally:
            GLib.source_remove(timeout)
            window.destroy()
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__": unittest.main()
