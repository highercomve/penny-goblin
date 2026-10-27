"use strict";

let statementReview = null;
let statementSaving = false;
let statementBank = "santander";
const statementBanks = {
  santander: { name: "Santander", currency: "CLP", step: "Choose card", command: "import_santander" },
  bci: { name: "BCI", currency: "CLP", step: "Download PDF", command: "import_bci" },
  boa: { name: "Bank of America", currency: "USD", step: "Download CSV", command: "import_boa" },
};

function renderBankChoice() {
  const info = statementBanks[statementBank], bank = info.name, download = statementBank !== "santander";
  $("bank-import-title").textContent = bank;
  $("bank-import-description").textContent = download ? "Import this month’s card or account charges" : "Import this month’s card charges";
  $("santander-help").textContent = `Choose the same ${download ? "card or account" : "card"} you’ll open at ${bank}.`;
  $("santander-account").placeholder = download ? `Choose or enter a ${bank} card or account` : "Choose or enter a card";
  $("bank-import-step").textContent = info.step;
  $("bank-import-currency").textContent = info.currency;
  $("santander-connect").textContent = `Open ${bank}`;
  for (const value of Object.keys(statementBanks)) $("bank-" + value).setAttribute("aria-pressed", String(value === statementBank));
}
for (const value of Object.keys(statementBanks)) $("bank-" + value).addEventListener("click", () => {
  if (mutationPending || statementBank === value) return;
  statementBank = value;
  $("santander-account").value = "";
  $("santander-account").removeAttribute("aria-invalid");
  status("statement-status", "");
  renderBankChoice();
});

$("bank-add-account").addEventListener("click", () => {
  if (mutationPending) return;
  const name = $("santander-account").value.trim();
  let row;
  openPreferences("accounts", false, (next) => {
    const account = row.querySelector("input").value.trim();
    if (Object.hasOwn(next.cards_config || {}, account)) $("santander-account").value = account;
    $("santander-account").focus();
  });
  row = addPreferenceMapping("accounts", Object.hasOwn(settings.cards_config || {}, name) ? "" : name);
  preferencesDirty = true;
  row.querySelector("input").focus();
});

function renderStatements() {
  renderBankChoice();
  $("santander-import").hidden = !snapshot?.santander_available;
  const accounts = [...new Set([...Object.keys(settings.cards_config || {}), ...(snapshot?.expenses || []).map(row => row.account)])].filter(value => value && value !== "Unspecified");
  $("santander-accounts").replaceChildren(...accounts.map(value => { const option = node("option"); option.value = value; option.label = accountLabel(value); return option; }));
  $("statement-list").replaceChildren(...(snapshot?.statements || []).map((source) => {
    const row = node("div", undefined, "statement-source");
    row.append(node("strong", source.name), node("small", source.status === "queued" ? "Queued for desktop" : "Parsed"));
    const review = node("button", source.status === "queued" ? "Parse" : "Review", "tonal");
    review.disabled = source.status === "queued" && ["android", "ios"].includes(snapshot.platform);
    review.addEventListener("click", async () => {
      if (mutationPending) return;
      mutationPending = true; review.disabled = true;
      try {
        if (source.status === "queued") await withProgress("Parsing statement", async () => { await invoke("parse_statement", { hash: source.hash }); await reload(); });
        await openStatement(source);
        status("statement-status", "");
      } catch (error) { status("statement-status", errorText(error), true); }
      finally { mutationPending = false; review.disabled = false; }
    });
    const save = node("button", source.format === "json" ? "Save JSON" : "Save PDF", "text-button");
    save.addEventListener("click", () => invoke("export_statement", { hash: source.hash }).catch((error) => status("statement-status", errorText(error), true)));
    row.append(review, save);
    return row;
  }));
}

$("statement-file").addEventListener("change", async (event) => {
  const file = event.target.files[0];
  if (!file || mutationPending) return;
  mutationPending = true; $("statement-file").disabled = true;
  try {
    if (file.size > 32 * 1024 * 1024) throw Error("PDF exceeds 32 MiB");
    const bytes = new Uint8Array(await file.arrayBuffer());
    if (new TextDecoder().decode(bytes.slice(0, 5)) !== "%PDF-") throw Error("InvalidPdf");
    let binary = "";
    for (let i = 0; i < bytes.length; i += 32768) binary += String.fromCharCode(...bytes.subarray(i, i + 32768));
    const saving = progressTask("Saving statement");
    let hash;
    try { hash = await invoke("prepare_statement", { name: file.name, data_url: `data:application/pdf;base64,${btoa(binary)}` }); } finally { saving.done(); }
    // Statements are stored by content: the same PDF downloaded twice is one statement.
    const existing = (snapshot.statements || []).find((source) => source.hash === hash);
    if (existing) {
      status("statement-status", `Already added as ${existing.name} · ${existing.status === "queued" ? "waiting for the desktop" : "ready to review"}`);
    } else if (["android", "ios"].includes(snapshot.platform)) {
      await reload("Queued for the desktop");
      status("statement-status", "");
    } else {
      await withProgress("Parsing statement", async () => { await invoke("parse_statement", { hash }); await reload(); });
      await openStatement({ hash, name: file.name });
    }
  } catch (error) { status("statement-status", errorText(error), true); }
  finally { mutationPending = false; $("statement-file").disabled = false; $("statement-file").value = ""; }
});

function statementCandidates(source) {
  const date = Date.parse(`${source.date}T12:00:00Z`);
  return snapshot.expenses.filter((row) => row.amount === source.amount && (row.currency || "CLP") === (source.currency || "CLP") &&
    (row.account === source.account || row.account === "Unspecified") && Math.abs(Date.parse(`${row.date}T12:00:00Z`) - date) <= 3 * 86400000);
}

async function openStatement(source) {
  if ($("statement-dialog").open) return;
  const observations = await invoke("statement_observations", { hash: source.hash });
  statementReview = { ...source, observations };
  $("reviewed-through").value = "";
  $("statement-title").textContent = source.name;
  // The ledger supplies one-to-one matches. Older responses fall back to
  // exact text; never guess from a nearby date or the amount alone.
  const suggested = new Set(observations.filter(row => row.expense_id).map(row => row.expense_id));
  const existing = node("details", undefined, "statement-existing");
  const existingTitle = node("summary"); existing.append(existingTitle);
  let existingCount = 0;
  $("statement-rows").replaceChildren(...observations.map((observation) => {
    const row = node("article", undefined, "statement-observation");
    const value = observation.source;
    row.append(node("strong", `${value.date} · ${value.payee}`), node("p", `${formatAmount(value.amount, value.currency)} · ${accountLabel(value.account)} · ${value.category}`, "supporting"));
    if (observation.expense_id || observation.ignored) {
      row.append(node("p", observation.ignored ? "Ignored" : "Linked", "supporting"));
      const undo = node("button", "Undo", "text-button"); undo.type = "button";
      undo.addEventListener("click", async () => {
        if (statementSaving || mutationPending) return;
        undo.disabled = true;
        try {
          await invoke("unlink_observation", { id: observation.id, expected_expense: observation.expense_id });
          $("statement-dialog").close(); await reload("Unlinked"); await openStatement(source);
        } catch (error) { status("statement-review-status", errorText(error), true); undo.disabled = false; }
      });
      row.append(undo);
    } else {
      const label = node("label");
      const select = node("select"); select.dataset.observation = observation.id; select.required = true; select.setAttribute("aria-label", "Decision");
      const candidates = statementCandidates(value);
      for (const [choice, text] of [["", "Choose…"], ["create", "Add as new payment"], ["ignore", "Ignore"]]) {
        const option = node("option", text); option.value = choice; select.append(option);
      }
      for (const candidate of candidates) {
        const option = node("option", `Same as ${candidate.date} · ${candidate.payee}`);
        option.value = `link:${candidate.id}`; option.dataset.revision = String(candidate.revision); select.append(option);
      }
      const identical = Object.hasOwn(observation, "match") ? observation.match : candidates.find((row) => !suggested.has(row.id) && row.date === value.date && row.payee === value.payee && row.account === value.account);
      if (identical) {
        let option = [...select.options].find(option => option.value === `link:${identical.id}`);
        if (!option) { option = node("option", "Already recorded in your ledger"); option.value = `link:${identical.id}`; select.append(option); }
        option.dataset.revision = String(identical.revision);
        suggested.add(identical.id); select.value = `link:${identical.id}`;
      }
      else if (!candidates.length) select.value = "create";
      label.append(select); row.append(label);
      if (!identical && candidates.length) row.append(node("p", "Check this charge · a similar payment exists", "supporting"));
    }
    if (observation.expense_id || observation.ignored || observation.match || [...row.querySelectorAll("select")].some(select => select.value.startsWith("link:"))) {
      existingCount += 1; existing.append(row); return null;
    }
    return row;
  }).filter(Boolean));
  if (existingCount) { existingTitle.textContent = `${existingCount} already recorded or excluded · no new payment`; $("statement-rows").append(existing); }
  updateStatementSummary();
  $("statement-dialog").showModal();
}

$("apply-reviewed-through").addEventListener("click", () => {
  if (statementSaving || mutationPending || !statementReview) return;
  const through = $("reviewed-through").value;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(through)) { status("statement-review-status", "Choose a reviewed-through date.", true); return; }
  let count = 0;
  let handled = $("statement-bulk-handled");
  if (!handled) {
    handled = node("details"); handled.id = "statement-bulk-handled";
    handled.append(node("summary", "Older rows marked handled · confirm to save"));
    $("statement-rows").append(handled);
  }
  for (const select of [...$("statement-rows").querySelectorAll("select")]) {
    const observation = statementReview.observations.find(row => row.id === select.dataset.observation);
    if (!observation || observation.source.date > through) continue;
    select.value = observation.match ? `link:${observation.match.id}` : "ignore";
    handled.append(select.closest("article"));
    count += 1;
  }
  updateStatementSummary();
  status("statement-review-status", `${count} older rows marked · Confirm to save choices`);
});

function updateStatementSummary() {
  if (!statementReview) return;
  const selects = [...$("statement-rows").querySelectorAll("select")];
  const added = selects.filter(select => select.value === "create").length;
  const check = selects.filter(select => !select.value).length;
  const linked = selects.filter(select => select.value.startsWith("link:")).length + statementReview.observations.filter(row => row.expense_id).length;
  status("statement-review-status", `${added} new · ${check} to check · ${linked} already recorded`);
  $("confirm-statement").textContent = check ? "Confirm choices" : added ? `Add ${added} new charge${added === 1 ? "" : "s"}` : linked ? "Confirm matches" : "Done";
}
$("statement-rows").addEventListener("change", updateStatementSummary);

$("statement-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  if (statementSaving || mutationPending || !statementReview || !$("statement-form").reportValidity()) return;
  const decisions = [...$("statement-rows").querySelectorAll("select")].map((select) => ({
    observation_id: select.dataset.observation, action: select.value.startsWith("link:") ? "link" : select.value,
    expense_id: select.value.startsWith("link:") ? select.value.slice(5) : "",
    expected_revision: Number(select.selectedOptions[0].dataset.revision || 0),
  }));
  statementSaving = mutationPending = true;
  $("statement-fields").disabled = $("confirm-statement").disabled = $("close-statement").disabled = true;
  try {
    const count = await withProgress("Saving statement decisions", () => invoke("reconcile_statement", { hash: statementReview.hash, decisions }));
    $("statement-dialog").close(); await reload(`${count} rows saved`);
  } catch (error) { status("statement-review-status", errorText(error), true); }
  finally {
    statementSaving = mutationPending = false;
    $("statement-fields").disabled = $("confirm-statement").disabled = $("close-statement").disabled = false;
  }
});
$("close-statement").addEventListener("click", () => { if (!statementSaving) $("statement-dialog").close(); });
$("statement-dialog").addEventListener("cancel", (event) => { if (statementSaving) event.preventDefault(); });

// The desktop parses statements that phones queued, so they arrive ready to
// review on every device. Each source is attempted once per session.
const autoParsed = new Set();
async function parseQueuedStatements() {
  if (!snapshot || ["android", "ios"].includes(snapshot.platform) || mutationPending) return;
  const queued = (snapshot.statements || []).filter((source) => source.status === "queued" && !autoParsed.has(source.hash));
  if (!queued.length) return;
  mutationPending = true;
  let parsed = 0;
  try {
    for (const source of queued) {
      autoParsed.add(source.hash);
      try { await withProgress(`Parsing ${source.name}`, () => invoke("parse_statement", { hash: source.hash })); parsed += 1; }
      catch (error) { status("status", `${source.name}: ${errorText(error)}`, true); }
    }
  } finally { mutationPending = false; }
  if (parsed) await reload(parsed === 1 ? `${queued[0].name} is ready to review` : `${parsed} statements ready to review`);
}

// Only an explicit user action opens the isolated bank window.
$("santander-connect").addEventListener("click", async () => {
  if (mutationPending || !snapshot?.santander_available) return;
  const account = $("santander-account").value.trim();
  const bank = statementBanks[statementBank].name;
  if (!account) { $("santander-account").setAttribute("aria-invalid", "true"); $("santander-account").focus(); status("statement-status", `Choose the ${bank} card or account first.`, true); return; }
  $("santander-account").removeAttribute("aria-invalid");
  mutationPending = true;
  $("santander-connect").disabled = $("santander-account").disabled = true;
  $("bank-add-account").disabled = true;
  for (const value of Object.keys(statementBanks)) $("bank-" + value).disabled = true;
  $("santander-connect").textContent = "Continue in the bank window…";
  try {
    status("statement-status", statementBank !== "santander" ? `Sign in to ${bank}, then ${statementBanks[statementBank].step.toLowerCase()} for the selected card or account in the bank window.` : "Sign in in the Santander window, then open card movements. Close it to cancel.");
    const result = await invoke(statementBanks[statementBank].command, { account });
    await reload();
    if (!result.hash) { status("statement-status", "No new charges in the current month."); return; }
    status("statement-status", `${result.added} movements ready to review.`);
    const source = snapshot.statements.find(s => s.hash === result.hash);
    const review = () => openStatement(source).catch(error => status("status", errorText(error), true));
    if ($("statements-page").open) closeThen($("statements-page"), review);
    else await review();
  } catch (error) {
    const cancelled = /SantanderCancelled|BciCancelled|BankCancelled/.test(String(error?.message || error));
    status("statement-status", cancelled ? "Connection cancelled. Nothing was imported." : errorText(error), !cancelled);
  } finally {
    mutationPending = false;
    $("santander-connect").disabled = $("santander-account").disabled = false;
    $("bank-add-account").disabled = false;
    for (const value of Object.keys(statementBanks)) $("bank-" + value).disabled = false;
    renderBankChoice();
  }
});
