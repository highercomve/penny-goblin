// Run only with an isolated XDG_DATA_HOME: generated views contain synthetic data.
for (let i = 0; i < 100 && !snapshot; i++) await new Promise(r => setTimeout(r, 50));
if (!snapshot) throw Error("Frontend did not load");
// Freeze page polling while capturing variants; no live reply may replace
// the synthetic snapshot or mutate a dialog halfway through conversion.
const lastInterval=setInterval(()=>{},3600000);
if(typeof lastInterval!=="number"||lastInterval>10000)throw Error("Unexpected interval handle");
for(let id=0;id<=lastInterval;id++)clearInterval(id);
settings = {salary: 1000000, account_owners: [], cards_config: {"1234": "Household"}, fixed_expenses_items: [{name:"Rent", amount:300000, keywords:["RENT"]}], categories:{Groceries:["SHOP"]}, vendors_config:{}, special_cases:{}};
snapshot = { ...snapshot, settings: JSON.stringify(settings), expenses: [
{id:"synthetic-payment", date:"2026-10-01", payee:"Example shop", amount:12345, currency:"CLP", account:"1234", category:"Groceries", notes:"", reference:"", location:"", revision:1, evidence_count:0}
], statements:[] };
updatePeriodOptions();
$("month").value = "2026-10";
render();
if(typeof updateResearchAvailability==="function")updateResearchAvailability();
$("count").parentElement.id="payment-count";
$("evidence-count").parentElement.id="receipt-count";
$("bulk-form").querySelector("button").id="bulk-preview-button";
$("clear-drilldown").hidden=false;
$("bulk-preview").hidden=false;$("bulk-summary").textContent="Preview";
$("ledger-filter-hint").textContent="Filtered payments";
$("tray-hint").parentElement.id="device-hint";
$("categories-bulk-category-list").hidden=false;
// Stable names for controls that the HTML addresses by data attribute/name.
for (const n of document.querySelectorAll("[data-view]")) n.id = "nav-" + n.dataset.view;
for (const n of document.querySelectorAll("[data-pref]")) n.id = "pref-" + n.dataset.pref;
for (const n of document.querySelectorAll("[name]")) if (!n.id) n.id = "field-" + n.name;
document.querySelector("main").id = "content";
$("expense-fields").querySelector(".capture").id="capture-choices";
$("pending-evidence").querySelector(".preview-frame").id="preview-frame";
$("pending-evidence").querySelector(".actions").id="image-actions";
$("more-details").querySelector("summary").id="details-toggle";
$("extraction-details").querySelector("summary").id="extraction-toggle";
// A stable body lets the compiled controller preserve disclosure state.
const detailBody=node("div");detailBody.id="details-body";
for(const child of [...$("more-details").children])if(child.tagName!=="SUMMARY")detailBody.append(child);
$("more-details").append(detailBody);
// Compiled animation is drawn by Zig; keep the same preview overlay box.
const sweep=document.createElement("canvas");sweep.id="scan-sweep";sweep.style.cssText="position:absolute;inset:0;width:100%;height:100%";
$("pending-evidence").querySelector(".scan-line").replaceWith(sweep);
for(const [selector,prefix] of [["#sync-desktop > details","sync-service"],["#sync-mobile details","sync-paste"],["#sync-code details","sync-link-details"]]){
 const details=document.querySelector(selector),summary=details.querySelector("summary");summary.id=prefix+"-toggle";
 const body=node("div");body.id=prefix+"-body";
 for(const child of [...details.children])if(child!==summary)body.append(child);
 details.append(body);
}
for(const [selector,prefix] of [["#view-payments > .range","range"],["#view-payments > .bulk-editor","bulk-details"]]){
 const details=document.querySelector(selector),summary=details.querySelector("summary");summary.id=prefix+"-toggle";
 const body=node("div");body.id=prefix+"-body";
 for(const child of [...details.children])if(child!==summary)body.append(child);
 details.append(body);
}
const lists = ["category-report", "account-report", "rows", "merchant-report", "account-chart", "category-chart", "account-comparison", "fixed-report", "special-payments", "month-report", "budget-parts", "bulk-matches", "categories-bulk-category-list"].map($);
// Oriel views retain one parent per node. Flex wrapping expresses these
// simple grids without the web renderer's viewport-dependent anonymous rows.
const fab=document.querySelector(".fab-group");fab.id="capture-actions";
const spacer=document.createElement("div");spacer.className="fab-spacer";fab.parentNode.insertBefore(spacer,fab);document.body.append(fab);
const layout=document.createElement("style");
layout.textContent=`.grid,.stat-row,.capture,.comparison-grid,.comparison,#view-home{display:flex;flex-wrap:wrap;flex-direction:row}
#view-home>.period-controls{width:100%}#view-home>.card{width:calc(50% - 6px)}#view-home>.hero,#view-home>.budget{width:100%}
.stat-row>*{flex:1;min-width:0}.capture>*{flex:1;min-width:140px}.grid>*,.comparison>*{width:calc(50% - 6px)}
.comparison-grid>*{flex:1 1 240px;min-width:0}
.fab-spacer{height:132px;flex:none}.fab-group{position:fixed;z-index:11;top:84px;left:20px;right:auto;bottom:auto;margin:0;width:56px}
@media(max-width:839px){#view-home>.card,.grid>*,.comparison>*{width:100%}.fab-spacer{display:none}.fab-group{top:auto;left:auto;right:16px;bottom:96px;width:auto}}`;
document.head.append(layout);
// Preserve the budget's actual chips and its otherwise empty hint node.
$("budget-hint").textContent="Add your salary in Settings to see what's left.";
const budgetPart=$("budget-parts").firstElementChild;budgetPart.id="budget-part";budgetPart.textContent="{text}";
for(const [variant,dark,media] of [[null,false,null],["dark",true,"prefers-color-scheme: dark"]]){
 __oriel.resize(1180,820,dark);await new Promise(r=>setTimeout(r,100));await __orielExport("budget-part",{element:budgetPart,variant,media});
}
__oriel.resize(1180,820,false);
// Whole-page variants retain responsive grid nodes and the four destinations.
for (const view of Object.keys(viewTitles)) $("view-"+view).hidden = false;
for (const el of document.querySelectorAll("details")) el.open = true;
for (const [variant,width,dark,media] of [[null,1180,false,null],["dark",1180,true,"prefers-color-scheme: dark"],["phone",393,false,"max-width: 839px"],["phone-dark",393,true,"max-width: 839px and prefers-color-scheme: dark"],["compact",320,false,"max-width: 380px"],["compact-dark",320,true,"max-width: 380px and prefers-color-scheme: dark"]]) {
 __oriel.resize(width,820,dark); await new Promise(r=>setTimeout(r,300));
 await __orielExport("application",{hollow:lists,variant,media});
}
__oriel.resize(1180,820,false);
// Repeated rows become independently mounted views in the Zig controller.
applyView("payments");
const example = document.querySelector("#rows .payment-row") || document.querySelector("#rows button");
if(example){
 example.id="payment";example.querySelector(".avatar").id="payment-avatar";
 for(const [selector,binding] of [[".avatar","initial"],["strong","payee"],["small","detail"],[".amount","amount"]]) example.querySelector(selector).textContent="{"+binding+"}";
 for(const [variant,dark,media] of [[null,false,null],["dark",true,"prefers-color-scheme: dark"]]){__oriel.resize(1180,820,dark);await new Promise(r=>setTimeout(r,100));await __orielExport("payment",{element:example,variant,media});}
 __oriel.resize(1180,820,false);
}
// Capture dynamic report components from the actual web builders and CSS.
applyView("insights");
const reportExample=reportRow("{title}",0n,"{detail}",()=>{});
reportExample.id="report-row";
reportExample.querySelector("strong").id="title";
reportExample.querySelector("small").id="detail";
reportExample.querySelector(".amount").id="amount";
reportExample.querySelector(".amount").textContent="{amount}";
const legend=node("span",undefined,"legend-dot");legend.id="legend";legend.style.background=reportColors[0];reportExample.prepend(legend);
$("account-chart").append(reportExample);
const categoryExample=reportRow("{title}",0n,"{detail}",()=>{});
categoryExample.id="category-row";
categoryExample.querySelector("strong").id="title";
categoryExample.querySelector("small").id="detail";
categoryExample.querySelector(".amount").id="amount";
categoryExample.querySelector(".amount").textContent="{amount}";
const bar=node("span",undefined,"data-bar");bar.id="bar";bar.style.width="100%";categoryExample.append(bar);
$("category-chart").append(categoryExample);
const comparisonExample=document.querySelector("#account-comparison .comparison-panel");
comparisonExample.id="comparison";
comparisonExample.querySelector("h3").textContent="{title}";
comparisonExample.querySelector("p").textContent="{detail}";
for(const child of [...comparisonExample.children]) if(child.tagName!=="H3"&&child.tagName!=="P")child.remove();
const comparisonRows=node("div");comparisonRows.id="rows";comparisonExample.append(comparisonRows);
for(const [name,element,hollow] of [["report-row",reportExample,[]],["category-row",categoryExample,[]],["comparison",comparisonExample,[comparisonRows]]]){
 for(const [variant,width,dark,media] of [[null,1180,false,null],["dark",1180,true,"prefers-color-scheme: dark"],["phone",393,false,"max-width: 839px"],["phone-dark",393,true,"max-width: 839px and prefers-color-scheme: dark"],["compact",320,false,"max-width: 380px"],["compact-dark",320,true,"max-width: 380px and prefers-color-scheme: dark"]]){
  __oriel.resize(width,820,dark);await new Promise(r=>setTimeout(r,100));await __orielExport(name,{element,hollow,variant,media});
 }
}
// Repeated settings/scanner rows come from the same builders as WebKit.
const fixedExample=preferenceRow("preferences-fixed",[
 preferenceInput("{key_label}",""),preferenceInput("Monthly amount (CLP)",0,120,"number"),preferenceInput("{value_label}","")]);
fixedExample.id="mapping";
for(const [index,id] of [[0,"key"],[1,"amount"],[2,"value"]]){
 const field=fixedExample.querySelectorAll("label")[index];field.id=id+"-field";field.querySelector("input").id=id;
}
fixedExample.querySelector(".remove").id="remove";
// Grid here is a single column: give it the same stable compiled structure.
fixedExample.style.display="flex";fixedExample.style.flexDirection="column";
const scannerExample=scannerRow("{title}","{detail}",[
 node("span","In use","badge"),scannerButton("Download","tonal",()=>{}),scannerButton("Delete","text-button danger",()=>{})]);
scannerExample.id="scanner-row";scannerExample.querySelector(".badge").id="badge";
scannerExample.querySelectorAll("button")[0].id="action";scannerExample.querySelectorAll("button")[1].id="secondary";
scannerExample.querySelector("strong").id="title";scannerExample.querySelector("small").id="detail";
const scannerBar=node("span",undefined,"scanner-progress");scannerBar.id="progress";scannerBar.style.width="100%";scannerExample.append(scannerBar);
$("scanner-models").append(scannerExample);
for(const [name,element] of [["mapping",fixedExample],["scanner-row",scannerExample]]){
 const dialog=$(name==="mapping"?"preferences-dialog":"scanner-page");
 for(const page of dialog.querySelectorAll("[data-section]"))page.classList.toggle("active",page.dataset.section==="fixed");
 for(const child of dialog.querySelectorAll("[hidden]"))child.hidden=false;
 dialog.showModal();document.activeElement?.blur();
 for(const [variant,width,dark,media] of [[null,1180,false,null],["dark",1180,true,"prefers-color-scheme: dark"],["phone",393,false,"max-width: 839px"],["phone-dark",393,true,"max-width: 839px and prefers-color-scheme: dark"],["compact",320,false,"max-width: 380px"],["compact-dark",320,true,"max-width: 380px and prefers-color-scheme: dark"]]){
  __oriel.resize(width,820,dark);await new Promise(r=>setTimeout(r,100));await __orielExport(name,{element,variant,media});
 }
 dialog.close();
}
// Export the real statement and evidence builders with synthetic IPC replies.
const originalInvoke=invoke;
const observation={id:"synthetic-observation",source:{date:"2026-10-01",payee:"Example shop",amount:12345,account:"1234",category:"Groceries"},expense_id:null,ignored:false};
invoke=async(command,args)=>command==="statement_observations"?[observation]:command==="expense_documents"?[{data_url:"logo.png",extraction:"{detail}"}]:command==="expense_statements"?[{id:"synthetic-source",statement_hash:"synthetic-statement",name:"{title}",source_json:"{detail}"}]:originalInvoke(command,args);
await openStatement({hash:"synthetic-statement",name:"Example statement"});
const reviewExample=document.querySelector(".statement-observation");reviewExample.id="review-row";
reviewExample.querySelector("strong").textContent="{title}";reviewExample.querySelector("p").textContent="{detail}";
reviewExample.querySelector("select").id="choice";reviewExample.querySelector("select").parentElement.id="choice-field";
const reviewState=node("p","Linked","supporting");reviewState.id="state";reviewExample.append(reviewState);
const reviewUndo=node("button","Undo","text-button");reviewUndo.id="undo";reviewExample.append(reviewUndo);
const reviewMatches=reviewExample.querySelectorAll("p")[1]||node("p","1 possible match","supporting");reviewMatches.id="matches";if(!reviewMatches.parentElement)reviewExample.append(reviewMatches);
for(const [variant,width,dark,media] of [[null,1180,false,null],["dark",1180,true,"prefers-color-scheme: dark"],["phone",393,false,"max-width: 839px"],["phone-dark",393,true,"max-width: 839px and prefers-color-scheme: dark"],["compact",320,false,"max-width: 380px"],["compact-dark",320,true,"max-width: 380px and prefers-color-scheme: dark"]]){
 __oriel.resize(width,820,dark);await new Promise(r=>setTimeout(r,100));await __orielExport("review-row",{element:reviewExample,variant,media});
}
$("statement-dialog").close();
snapshot.statements=[{hash:"synthetic-statement",name:"{title}",status:"parsed"}];renderStatements();
$("statements-page").showModal();document.activeElement?.blur();
const sourceExample=$("statement-list").firstElementChild;sourceExample.id="statement-source";
sourceExample.querySelector("small").textContent="{detail}";sourceExample.querySelectorAll("button")[0].id="action";sourceExample.querySelectorAll("button")[1].id="secondary";
for(const [variant,width,dark,media] of [[null,1180,false,null],["dark",1180,true,"prefers-color-scheme: dark"],["phone",393,false,"max-width: 839px"],["phone-dark",393,true,"max-width: 839px and prefers-color-scheme: dark"],["compact",320,false,"max-width: 380px"],["compact-dark",320,true,"max-width: 380px and prefers-color-scheme: dark"]]){
 __oriel.resize(width,820,dark);await new Promise(r=>setTimeout(r,100));await __orielExport("statement-source",{element:sourceExample,variant,media});
}
$("statements-page").close();snapshot.statements=[];
await openEditor(snapshot.expenses[0]);
const evidenceExample=$("saved-evidence").querySelector("figure");evidenceExample.id="evidence";
evidenceExample.querySelector("img").id="image";
evidenceExample.querySelector("details").open=true;
evidenceExample.querySelector("summary").id="toggle";
evidenceExample.querySelector("pre").id="detail";evidenceExample.querySelector("pre").textContent="{detail}";
for(const [variant,width,dark,media] of [[null,1180,false,null],["dark",1180,true,"prefers-color-scheme: dark"],["phone",393,false,"max-width: 839px"],["phone-dark",393,true,"max-width: 839px and prefers-color-scheme: dark"],["compact",320,false,"max-width: 380px"],["compact-dark",320,true,"max-width: 380px and prefers-color-scheme: dark"]]){
 __oriel.resize(width,820,dark);await new Promise(r=>setTimeout(r,100));await __orielExport("evidence",{element:evidenceExample,variant,media});
}
const statementEvidence=[...$("saved-evidence").children].find(child=>child.tagName==="DETAILS");statementEvidence.id="statement-evidence";
statementEvidence.open=true;statementEvidence.querySelector("summary").id="toggle";
statementEvidence.querySelector("summary").textContent="{title}";
const statementBody=node("div");statementBody.id="body";
for(const child of [...statementEvidence.children])if(child.tagName!=="SUMMARY")statementBody.append(child);
statementEvidence.append(statementBody);statementEvidence.querySelector("pre").id="detail";statementEvidence.querySelector("button").id="save";
for(const [variant,width,dark,media] of [[null,1180,false,null],["dark",1180,true,"prefers-color-scheme: dark"],["phone",393,false,"max-width: 839px"],["phone-dark",393,true,"max-width: 839px and prefers-color-scheme: dark"],["compact",320,false,"max-width: 380px"],["compact-dark",320,true,"max-width: 380px and prefers-color-scheme: dark"]]){
 __oriel.resize(width,820,dark);await new Promise(r=>setTimeout(r,100));await __orielExport("statement-evidence",{element:statementEvidence,variant,media});
}
// Capture the category suggestion item while it is anchored to its real field.
const categoryInput=form.elements.namedItem("category");categoryInput.value="";categoryInput.dispatchEvent(new Event("focus"));
const suggestion=$("categories-category-list").firstElementChild;suggestion.id="suggestion";suggestion.textContent="{text}";
for(const [variant,dark,media] of [[null,false,null],["dark",true,"prefers-color-scheme: dark"]]){
 __oriel.resize(1180,820,dark);await new Promise(r=>setTimeout(r,100));await __orielExport("suggestion",{element:suggestion,variant,media});
}
categoryInput.dispatchEvent(new Event("blur"));
suggestion.remove();categoryInput.value="Other";
$("editor").close();
$("expense-fields").classList.remove("editing");
invoke=originalInvoke;
fixedExample.remove();scannerExample.remove();
reportExample.remove();categoryExample.remove();
__oriel.resize(1180,820,false);
applyView("home");
$("sync-qr").setAttribute("src","logo.png");
const deviceExample=node("div");deviceExample.id="sync-device";
deviceExample.append(node("span","{title}"));const disconnect=node("button","Disconnect","text-button danger");disconnect.id="disconnect";disconnect.type="button";deviceExample.append(disconnect);$("sync-devices").append(deviceExample);
const conflictExample=node("button","{text}");conflictExample.id="sync-conflict";conflictExample.type="button";$("sync-conflicts").append(conflictExample);
const pixel="logo.png";
$("preview").src=pixel; $("sync-qr").setAttribute("src",pixel); $("sync-expiry").textContent="Expires";
for (const id of ["editor", "preferences-dialog", "fixed-page", "statements-page", "scanner-page", "statement-dialog", "sync-dialog"]) {
 const el=$(id);
 for (const child of el.querySelectorAll("[hidden]")) child.hidden=false;
 for (const child of el.querySelectorAll("[data-section]")) {child.classList.add("active"); child.id="pref-section-"+child.dataset.section;}
 for (const child of el.querySelectorAll("[role=status]")) child.textContent="Status";
 el.showModal();
 if(id==="sync-dialog") {
  for(const [name,element] of [["sync-device",deviceExample],["sync-conflict",conflictExample]]){
   for(const [variant,dark,media] of [[null,false,null],["dark",true,"prefers-color-scheme: dark"]]){
    __oriel.resize(1180,820,dark);await new Promise(r=>setTimeout(r,100));await __orielExport(name,{element,variant,media});
   }
  }
  deviceExample.remove();conflictExample.remove();
 }

 document.activeElement?.blur();
 const hollow=[...["scanner-system-row","scanner-installed","scanner-models","scanner-custom-row","fixed-list","statement-list","sync-devices","sync-conflicts"].map($), $("saved-evidence"), $("categories-category-list"), $("statement-rows"), $("preferences-fixed"), $("preferences-accounts"), $("preferences-categories"), $("preferences-vendors"), $("preferences-special")];
 for(const [variant,width,dark,media] of [[null,1180,false,null],["dark",1180,true,"prefers-color-scheme: dark"],["phone",393,false,"max-width: 839px"],["phone-dark",393,true,"max-width: 839px and prefers-color-scheme: dark"],["compact",320,false,"max-width: 380px"],["compact-dark",320,true,"max-width: 380px and prefers-color-scheme: dark"]]){
  __oriel.resize(width,820,dark);await new Promise(r=>setTimeout(r,100));
  await __orielExport(id,{element:el,hollow,variant,media});
 }
 __oriel.resize(1180,820,false);
 el.close();
}
__orielExportDone();
