"use strict";

let statementReview = null;
let statementSaving = false;

function renderStatements() {
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
    const save = node("button", "Save PDF", "text-button");
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
  return snapshot.expenses.filter((row) => row.amount === source.amount &&
    (row.account === source.account || row.account === "Unspecified") && Math.abs(Date.parse(`${row.date}T12:00:00Z`) - date) <= 3 * 86400000);
}

async function openStatement(source) {
  if ($("statement-dialog").open) return;
  const observations = await invoke("statement_observations", { hash: source.hash });
  statementReview = { ...source, observations };
  $("statement-title").textContent = source.name;
  // Suggest a link only when a payment is identical in date, amount, bank
  // description and account (typically the web app's import of this same
  // statement). Each payment is suggested once; the user still confirms.
  const suggested = new Set();
  let suggestions = 0;
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
      const identical = candidates.find((row) => !suggested.has(row.id) && row.date === value.date && row.payee === value.payee && row.account === value.account);
      if (identical) { suggested.add(identical.id); select.value = `link:${identical.id}`; suggestions += 1; }
      else if (!candidates.length) select.value = "create";
      label.append(select); row.append(label);
      if (candidates.length) row.append(node("p", `${candidates.length} possible match${candidates.length > 1 ? "es" : ""}`, "supporting"));
    }
    return row;
  }));
  const open = observations.filter((row) => !row.expense_id && !row.ignored).length;
  status("statement-review-status", suggestions === open ? `All ${open} already recorded · Confirm to link them` : suggestions ? `${suggestions} of ${open} already recorded · choose the rest` : `${observations.length} rows`);
  $("statement-dialog").showModal();
}

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
