"use strict";
let researchReview = null;
let researchRunning = false;
let researchUpdates = 0;
let researchApplying = false;
let researchSeen = new Set();
let categorizationModelReady = false;
let categorizationModelBusy = false;

function updateResearchAvailability() {
  $("research-open").hidden = !snapshot || !["linux", "android"].includes(snapshot.platform);
}
function researchChoices() {
  return [...$("research-results").querySelectorAll("select")].filter((input) => input.value).map((input) => ({
    targets: researchReview.proposals[Number(input.dataset.index)].targets, category: input.value,
  }));
}
function updateResearchApply() {
  $("research-apply").disabled = researchRunning || researchApplying || !researchReview || researchChoices().length === 0;
}
function renderResearch() {
  $("research-results").replaceChildren();
  for (const [index, proposal] of researchReview.proposals.entries()) {
    const card = node("section", undefined, "card");
    card.append(node("h3", proposal.merchant, "card-title"), node("p", `${proposal.targets.length} payments · ${proposal.reason || "No confident suggestion"}`, "supporting"));
    const field = node("label", "Apply category", "field");
    const select = node("select"); select.dataset.index = String(index);
    select.append(new Option("Leave unchanged", ""));
    for (const category of Object.keys(settings.categories || {}).filter((name) => name !== "Other")) select.append(new Option(category, category));
    select.value = proposal.category;
    select.addEventListener("change", updateResearchApply);
    field.append(select); card.append(field);
    for (const source of proposal.sources) {
      const details = node("details", undefined, "inline-details");
      details.append(node("summary", source.title || source.url), node("p", source.quote, "supporting"));
      const open = node("button", "Open source", "text-button"); open.type = "button";
      open.addEventListener("click", () => {
        if (!/^https:\/\//i.test(source.url)) return;
        window.oriel.openExternal(source.url).catch((error) => status("research-status", errorText(error), true));
      });
      details.append(open); card.append(details);
    }
    $("research-results").append(card);
  }
  updateResearchApply();
}
async function closeResearch() {
  if (researchApplying) return;
  if (researchRunning) {
    status("research-status", "Stopping research… The current page may take up to 25 seconds to finish.");
    await invoke("cancel_research");
    return;
  }
  if (researchReview && researchChoices().length && !(await ask("Discard these unapplied suggestions?", "Discard"))) return;
  $("research-dialog").close(); researchReview = null;
}
$("research-open").addEventListener("click", () => {
  if (busy) return;
  researchReview = null; researchSeen = new Set(); $("research-results").replaceChildren();
  status("research-status", "No expenses will change until you select Apply.");
  $("research-activity").textContent = "";
  $("research-activity-panel").hidden = true;
  $("research-details").open = false;
  $("research-model-controls").hidden = snapshot.platform === "android";
  categorizationModelReady = false;
  $("research-start").disabled = true;
  refreshResearchModel().catch((error) => status("research-model-status", errorText(error), true));
  if (snapshot.platform !== "android" && !snapshot.vision_available) status("research-status", "This build needs local model support. Build with vision enabled.");
  updateResearchApply(); $("research-dialog").showModal();
});
$("research-close").addEventListener("click", () => closeResearch().catch((error) => status("research-status", errorText(error), true)));
$("research-dialog").addEventListener("cancel", (event) => { event.preventDefault(); closeResearch().catch((error) => status("research-status", errorText(error), true)); });
$("research-cancel").addEventListener("click", () => invoke("cancel_research").then(() => status("research-status", "Stopping research…")).catch((error) => status("research-status", errorText(error), true)));
$("research-start").addEventListener("click", async () => {
  if (researchRunning || researchApplying || !categorizationModelReady || categorizationModelBusy) return;
  if (researchReview && researchChoices().length) { status("research-status", "Apply suggestions or leave them unchanged before researching the next batch."); return; }
  const ids = filteredPayments().filter((row) => !researchSeen.has(row.id) && (!row.category || row.category === "Other") && !PennyReports.fixedItem(row, settings) && !PennyReports.special(row, settings)).map((row) => row.id);
  if (!ids.length) { status("research-status", "No eligible uncategorized variable payments match the current filters. Close this view and select Uncategorized or All categories, clear search, or choose another period. Fixed and special payments are excluded."); return; }
  $("research-activity").textContent = "Connecting to research…";
  $("research-activity-panel").hidden = false;
  $("research-progress").textContent = "Waiting for desktop…";
  $("research-merchant").textContent = "";
  researchUpdates = 0;
  researchReview = null; researchRunning = true; $("research-results").replaceChildren();
  $("research-start").disabled = true; $("research-start").hidden = true; $("research-cancel").hidden = false; updateResearchApply();
  status("research-status", "Loading desktop model… You can cancel without changing expenses.");
  try {
    researchReview = JSON.parse(await invoke("research_categories", { ids }));
    for (const group of researchReview.proposals) for (const target of group.targets) researchSeen.add(target.id);
    renderResearch();
    $("research-progress").textContent = "Batch complete · review suggestions below";
    status("research-status", `${researchReview.proposals.length} merchants ready for review.${researchReview.remaining ? ` ${researchReview.remaining} additional payments remain for another batch.` : ""}`);
  } catch (error) { $("research-progress").textContent = "Research stopped · see status above"; status("research-status", String(error).includes("Cancelled") ? "Research cancelled. No expenses changed." : errorText(error), true); }
  finally { researchRunning = false; $("research-start").hidden = false; $("research-start").disabled = !categorizationModelReady; $("research-cancel").hidden = true; updateResearchApply(); }
});
$("research-apply").addEventListener("click", async () => {
  if (researchRunning || researchApplying || !researchReview) return;
  const selections = researchChoices(); if (!selections.length) return;
  researchApplying = true; updateResearchApply(); $("research-start").disabled = true;
  try {
    const count = await invoke("apply_research", { expected_settings: researchReview.expected_settings, selections });
    researchReview = null; $("research-results").replaceChildren();
    status("research-status", `${count} payments categorized.`); await reload();
  } catch (error) { status("research-status", errorText(error), true); }
  finally { researchApplying = false; $("research-start").disabled = !categorizationModelReady; updateResearchApply(); }
});
if (window.oriel) window.oriel.listen("research_progress", (event) => {
  if (researchRunning) {
    status("research-status", event.stage);
    $("research-progress").textContent = `${event.completed}/${event.total} merchants complete · update ${++researchUpdates}`;
    $("research-merchant").textContent = event.merchant || "";
    const log = $("research-activity");
    const line = `${event.merchant ? event.merchant + " · " : ""}${event.stage}${event.detail ? ": " + event.detail : ""}${event.url ? "\n" + event.url : ""}\n`;
    log.textContent = (line + (researchUpdates === 1 ? "" : log.textContent)).slice(0, 16000);
  }
});

async function refreshResearchModel() {
  const state = JSON.parse(await invoke("research_model_status"));
  categorizationModelReady = state.ready && (snapshot.platform === "android" || snapshot.vision_available);
  categorizationModelBusy = state.downloading;
  if (!categorizationModelReady || state.downloading) $("research-details").open = true;
  status("research-model-status", `${state.label} · ${state.ready ? "Ready · unloads after research" : (snapshot.platform === "android" ? "Configure this model on the desktop first" : "Choose or download a categorization model")}`);
  $("research-model-download").disabled = state.downloading || researchRunning || researchApplying || (state.ready && !state.custom);
  $("research-model-pick").disabled = state.downloading || researchRunning || researchApplying;
  $("research-model-default").hidden = !state.custom;
  $("research-model-cancel").hidden = !state.downloading;
  $("research-start").disabled = !categorizationModelReady || state.downloading || researchRunning || researchApplying;
}
async function changeResearchModel(command) {
  if (researchRunning || researchApplying || categorizationModelBusy) return;
  categorizationModelBusy = true; $("research-start").disabled = true;
  $("research-model-download").disabled = true; $("research-model-pick").disabled = true;
  $("research-model-cancel").hidden = command !== "research_model_download";
  try { await invoke(command); }
  catch (error) { status("research-status", errorText(error), true); }
  finally { categorizationModelBusy = false; await refreshResearchModel(); }
}
for (const action of ["download", "pick", "default"]) $("research-model-" + action).addEventListener("click", () => changeResearchModel("research_model_" + action).catch((error) => status("research-model-status", errorText(error), true)));
$("research-model-cancel").addEventListener("click", () => invoke("cancel_research_model").catch((error) => status("research-model-status", errorText(error), true)));
if (window.oriel) window.oriel.listen("model_download", (event) => {
  if (event.id === "research-qwen3.5-9b") status("research-model-status", `${event.state} · ${event.done_mb}/${event.total_mb} MiB`);
});

updateResearchAvailability();
