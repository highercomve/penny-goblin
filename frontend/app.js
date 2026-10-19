"use strict";

const $ = (id) => document.getElementById(id);
const form = $("expense-form");
const editor = $("editor");
const money = new Intl.NumberFormat("es-CL", { style: "currency", currency: "CLP", maximumFractionDigits: 0 });
const dollars = new Intl.NumberFormat("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
// A payment's amount in its currency: CLP in whole pesos, USD in cents.
// Each currency's totals stay apart; the budget is in CLP.
function formatAmount(amount, currency = "CLP") {
  return currency === "USD" ? `US$${dollars.format(Number(amount) / 100)}` : money.format(amount);
}
const isClp = (row) => (row.currency || "CLP") === "CLP";
let snapshot = null;
let current = null;
let pendingDocument = null;
// The picked image's name and time, which date a voucher that prints none.
let pendingFile = { name: "", modified: 0 };
let busy = false;
let dirty = false;
let mutationPending = false;
let cancelRequested = false;
let scanFirst = false;
let settings = {};
let periodInitialized = false;
let drilldown = null;

let snackbarTimer = 0;
function status(id, text, error = false) {
  $(id).textContent = text;
  $(id).classList.toggle("error", error);
  // The main status is a transient snackbar; dialog statuses stay inline.
  if ($(id).classList.contains("snackbar")) {
    clearTimeout(snackbarTimer);
    $(id).classList.toggle("show", !!text);
    if (text) snackbarTimer = setTimeout(() => $(id).classList.remove("show"), error ? 8000 : 3500);
  }
}

function errorText(error) {
  const code = String(error?.message || error);
  if (error?.name === "RuleConflict") return code;
  const messages = {
    NotPaired: "Pair this phone with your desktop in Settings → Synchronization first.",
    DesktopUnavailable: "Cannot reach the paired desktop. Keep Penny Goblin open there and check Wi-Fi or Tailscale. Research can be resumed.",
    ResearchJobNotFound: "The desktop job expired or restarted. Start research again.",
    DesktopScannerBusy: "The desktop is already scanning or researching. Try again when it finishes.",
    RemoteResearchFailed: "Desktop research failed. See the activity log; expenses are unchanged.",
    CategorizationModelRequired: "Choose or download a categorization model in Research categories. Receipt scanning uses a separate model.",
    ResearchBrowserUnavailable: "Research needs system Python with PyGObject, GTK4 and WebKitGTK 6. Your expenses are unchanged.",
    ResearchBrowserProtocol: "The research browser could not return a readable response. Your expenses are unchanged.",
    ScannerNotSetUp: "Choose a downloaded or imported local model in Settings → Receipt scanner.",
    NoCategories: "Add categories in Settings before researching expenses.",
    LocalModelRequired: "Choose a downloaded or imported local model for desktop research.",
    ResearchTimeLimit: "Research reached its time limit. No expenses were changed.",
    DesktopResearchUnavailable: "Update and open Penny Goblin on your Linux desktop with local model support to run research from this paired phone.",
    CategoryExists: "That category already exists. Select it from the list.",
    ReservedCategory: "Other and fixed commitments are managed separately.",
    InvalidCategory: "Choose one of your existing categories.",
    RevisionConflict: "Changed on another device. Your draft is kept; refresh and reopen it.",
    SettingsConflict: "Settings changed on another device. Refresh and try again.",
    ConflictingSpecialRule: "This description already has a different label. Edit the existing rule or use a different description.",
    InvalidRules: "Every name and keyword needs a value.",
    InvalidPdf: "Choose a valid PDF smaller than 32 MiB.",
    StatementParseFailed: "Couldn't read this statement. Santander and BCI PDFs are supported.",
    ObservationConflict: "This statement row changed. Refresh and try again.",
    ExpenseDeleted: "This payment was deleted.",
    DocumentAlreadyLinked: "This image already belongs to another payment.",
    VisionNotBuilt: "Scanning isn't available in this build. Enter it manually.",
    ModelNotDownloaded: "The chosen scanner model isn't downloaded. Download it or choose another.",
    SystemModelNotReady: "The phone's model isn't ready yet. Download it or choose another scanner.",
    SystemAiUnavailable: "This phone has no built-in model. Choose a downloaded one.",
    ModelNotImported: "Import both GGUF files, or choose another scanner.",
    ProjectorNotImported: "Import the matching projector, or choose another scanner.",
    ModelLoadFailed: "The scanner model couldn't load.",
    ProjectorFailed: "The projector doesn't match the model.",
    Cancelled: "Scan cancelled.",
    ImageTooLarge: "Image too large (max 8 MB).",
    InvalidImage: "Couldn't read this image. Use PNG or JPEG.",
    InvalidExtraction: "The scan was incomplete. Check the details.",
    InvalidAmount: "Enter a valid amount: whole pesos, or dollars with cents.",
    InvalidDate: "Enter a valid date.",
  };
  const known = Object.keys(messages).find((name) => code.includes(name));
  return known ? messages[known] : `Something went wrong (${code}). Nothing was lost.`;
}

function invoke(command, args = {}) {
  if (!window.oriel) return Promise.reject(new Error("Open Penny Goblin through the native application"));
  return window.oriel.invoke(command, args);
}

function node(tag, text, className) {
  const element = document.createElement(tag);
  if (text !== undefined) element.textContent = text;
  if (className) element.className = className;
  return element;
}

function monthLabel(month) {
  return new Intl.DateTimeFormat("en", { month: "long", year: "numeric", timeZone: "UTC" }).format(new Date(`${month}-01T12:00:00Z`));
}

function accountLabel(account) {
  const holder = PennyReports.holder(account, settings);
  return holder === account ? account : `${holder} · ${account}`;
}

function selectedPayments() {
  const month = $("month").value, account = $("account-filter").value;
  const from = $("date-from").value, through = $("date-through").value;
  if (from && through && from > through) return [];
  return snapshot.expenses.filter((row) => (!month || row.date.startsWith(month)) && (!account || row.account === account) && (!from || row.date >= from) && (!through || row.date <= through));
}

function updatePeriodOptions() {
  const months = [...new Set(snapshot.expenses.map((e) => e.date.slice(0, 7)))].sort().reverse();
  const selected = periodInitialized ? $("month").value : months[0] || "";
  for (const [id, values, label, all] of [
    ["month", months, monthLabel, "All months"],
    ["account-filter", [...new Set([...snapshot.expenses.map((e) => e.account), ...Object.keys(settings.cards_config || {})])].sort(), accountLabel, "All accounts"],
    ["category-filter", [...new Set(snapshot.expenses.map((e) => PennyReports.category(e, settings)))].sort(), (value) => value, "All categories"],
    ["merchant-category", [...new Set(snapshot.expenses.map((e) => PennyReports.category(e, settings)))].sort(), (value) => value, "All categories"],
  ]) {
    const previous = id === "month" ? selected : $(id).value;
    $(id).replaceChildren(...["", ...values].map((value) => {
      const option = node("option", value ? label(value) : all);
      option.value = value;
      return option;
    }));
    $(id).value = values.includes(previous) ? previous : "";
  }
  periodInitialized = true;
}

function reportRow(label, amount, detail, onClick) {
  const row = node(onClick ? "button" : "div", undefined, "report-row");
  const text = node("span");
  text.append(node("strong", label), node("small", detail));
  row.append(text, node("span", money.format(amount), "amount"));
  if (onClick) row.addEventListener("click", onClick);
  return row;
}

function showGroup(name, rows) {
  drilldown = { name, ids: new Set(rows.map((row) => row.id)) };
  $("search").value = $("category-filter").value = "";
  render();
  if (typeof showView === "function") showView("payments");
}

function renderReports(periodRows) {
  const month = $("month").value;
  const from = $("date-from").value, through = $("date-through").value;
  $("period-title").textContent = month ? monthLabel(month) : from || through ? `${from || "Beginning"} through ${through || "latest"}` : "All months";
  $("monthly-budget").hidden = !month || !!$("account-filter").value;
  const report = PennyReports.monthly(periodRows, settings);
  // As in the web app: fixed commitments are a monthly plan. Left = salary − planned fixed −
  // variable − special; fixed payments that do appear are not subtracted a second time.
  $("salary-total").textContent = money.format(report.salary);
  $("budget-forecast").textContent = money.format(report.legacyForecast);
  $("fixed-planned").textContent = money.format(report.planned);
  $("fixed-paid").textContent = `${money.format(report.fixed)} paid`;
  $("budget-hint").textContent = settings.salary ? "" : "Add your salary in Settings to see what's left.";
  $("budget-parts").replaceChildren(...[
    ["Variable", report.variable], ["Special", report.special],
  ].map(([label, amount]) => node("span", `${label} ${money.format(amount)}`)));
  for (const [id, key] of [
    ["category-report", (row) => PennyReports.category(row, settings)],
    ["account-report", (row) => accountLabel(row.account)],
  ]) {
    const groups = PennyReports.group(periodRows, key);
    $(id).replaceChildren(...groups.map((group) => reportRow(group.name, group.amount,
      `${group.rows.length} · ${report.actual ? Number(group.amount * 1000n / report.actual) / 10 : 0}%`, () => showGroup(group.name, group.rows))));
    if (!groups.length) $(id).append(node("p", "Nothing here yet.", "supporting"));
  }
  renderMerchants(periodRows);
  renderAnalysis(periodRows);
  $("fixed-report").replaceChildren(...report.commitments.map((item) => reportRow(item.name, item.paid,
    `Planned ${money.format(item.planned)}`,
    () => showGroup(`Fixed: ${item.name}`, item.rows))));
  // The Fixed tile's page: every commitment with its monthly plan and what this period paid.
  $("fixed-summary").textContent = `${money.format(report.planned)} a month · ${money.format(report.fixed)} paid${month ? ` in ${monthLabel(month)}` : ""}`;
  $("fixed-list").replaceChildren(...report.commitments.map((item) => reportRow(item.name, item.planned,
    item.rows.length ? `${money.format(item.paid)} paid · ${item.rows.length} payment${item.rows.length > 1 ? "s" : ""}` : "Monthly plan",
    item.rows.length ? () => closeThen($("fixed-page"), () => showGroup(`Fixed: ${item.name}`, item.rows)) : null)));
  if (!report.commitments.length) $("fixed-list").append(node("p", "None configured.", "supporting"));
  if (!report.commitments.length) $("fixed-report").append(node("p", "None configured.", "supporting"));
  const historyRows = snapshot.expenses.filter((row) => !$("account-filter").value || row.account === $("account-filter").value);
  const history = PennyReports.group(historyRows, (row) => row.date.slice(0, 7)).sort((a, b) => b.name.localeCompare(a.name));
  $("month-report").replaceChildren(...history.map((group) => reportRow(monthLabel(group.name), group.amount,
    `${group.rows.length} payments`, () => { $("month").value = group.name; drilldown = null; render(); if (typeof showView === "function") showView("home"); })));
}

function renderMerchants(periodRows) {
  const query = $("merchant-search").value.trim().toLocaleLowerCase();
  const grouped = $("merchant-grouping").value === "brand";
  const category = $("merchant-category").value;
  const groups = PennyReports.group(periodRows.filter((row) => !category || PennyReports.category(row, settings) === category), (row) => PennyReports.merchant(row.payee, settings, grouped))
    .filter((group) => !query || group.name.toLocaleLowerCase().includes(query) || group.rows.some((row) => row.payee.toLocaleLowerCase().includes(query)));
  const sort = $("merchant-sort").value;
  if (sort === "low") groups.reverse();
  if (sort === "name") groups.sort((a, b) => a.name.localeCompare(b.name));
  if (sort === "purchases") groups.sort((a, b) => b.rows.length - a.rows.length);
  $("merchant-report").replaceChildren(...groups.map((group) => reportRow(group.name, group.amount,
    `${group.rows.length} · avg ${money.format(group.amount / BigInt(group.rows.length))}`,
    () => showGroup(group.name, group.rows))));
  if (!groups.length) $("merchant-report").append(node("p", "No matches.", "supporting"));
}

function filteredPayments(periodRows = selectedPayments()) {
  const query = $("search").value.trim().toLocaleLowerCase();
  const rows = periodRows.filter((e) => (!drilldown || drilldown.ids.has(e.id)) &&
    (!$("category-filter").value || PennyReports.category(e, settings) === $("category-filter").value) &&
    (!query || [e.payee, e.account, accountLabel(e.account), PennyReports.merchant(e.payee, settings), PennyReports.category(e, settings), e.notes, e.reference].some((s) => s.toLocaleLowerCase().includes(query))));
  const sort = $("ledger-sort").value;
  rows.sort((a, b) => sort === "highest" ? b.amount - a.amount : sort === "lowest" ? a.amount - b.amount : sort === "oldest" ? a.date.localeCompare(b.date) : b.date.localeCompare(a.date));
  return rows;
}
function render() {
  const periodAll = selectedPayments();
  // The budget, insights and the hero total are in CLP; dollars stay apart.
  const periodRows = periodAll.filter(isClp);
  const dollarRows = periodAll.filter((row) => !isClp(row));
  const rows = filteredPayments(periodAll);
  const sort = $("ledger-sort").value;
  renderReports(periodRows);
  // Summing in BigInt retains exact CLP totals even across the full ledger limit.
  $("total").textContent = money.format(PennyReports.sum(periodRows));
  $("dollar-total").hidden = !dollarRows.length;
  $("dollar-total").textContent = dollarRows.length ? `${formatAmount(PennyReports.sum(dollarRows), "USD")} in dollars · ${dollarRows.length} payment${dollarRows.length > 1 ? "s" : ""}` : "";
  $("count").textContent = periodRows.length.toLocaleString();
  $("evidence-count").textContent = periodRows.filter((e) => e.evidence_count > 0).length.toLocaleString();
  $("clear-drilldown").hidden = !drilldown;
  $("ledger-filter-hint").textContent = drilldown ? `${drilldown.name} · ${rows.length}` : rows.length === periodAll.length ? "" : `${rows.length} of ${periodAll.length}`;
  const list = $("rows");
  list.replaceChildren();
  if (!rows.length) list.append(node("p", snapshot.expenses.length ? "No matching payments." : "No payments yet. Tap Scan to add one.", "empty"));
  const byDate = sort === "newest" || sort === "oldest";
  const dayFormat = new Intl.DateTimeFormat(undefined, { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" });
  let lastDay = "";
  // Rendering is bounded so very long histories stay responsive; search narrows the rest.
  for (const expense of rows.slice(0, 600)) {
    if (byDate && expense.date !== lastDay) {
      lastDay = expense.date;
      list.append(node("p", dayFormat.format(new Date(`${expense.date}T12:00:00Z`)), "day-header"));
    }
    const row = node("button", undefined, "payment");
    row.type = "button";
    row.setAttribute("aria-label", `${expense.payee}, ${formatAmount(expense.amount, expense.currency)}, ${expense.date}`);
    const initial = (PennyReports.merchant(expense.payee, settings) || expense.payee).trim().charAt(0).toUpperCase() || "?";
    const text = node("span", undefined, "payment-text");
    text.append(node("strong", PennyReports.merchant(expense.payee, settings) || expense.payee), node("small", `${PennyReports.category(expense, settings)} · ${PennyReports.holder(expense.account, settings)}${byDate ? "" : ` · ${expense.date}`}`));
    row.append(node("span", initial, expense.evidence_count ? "avatar evidence" : "avatar"), text, node("span", formatAmount(expense.amount, expense.currency), "amount"));
    row.addEventListener("click", () => openEditor(expense));
    list.append(row);
  }
  if (rows.length > 600) list.append(node("p", `Showing 600 of ${rows.length}. Search to narrow.`, "supporting center"));
  const categories = [...new Set([...snapshot.expenses.map((e) => e.category), ...Object.keys(settings.categories || {})])].sort();
  $("categories").replaceChildren(...categories.map((value) => { const option = node("option"); option.value = value; return option; }));
}

/// Suggestions under a text field from a <datalist>. Android's WebView draws
/// the native datalist popup detached from its field inside dialogs, so the
/// app shows its own list, anchored below the field.
function suggest(input) {
  const source = $(input.dataset.suggest);
  const list = node("ul", null, "suggestions");
  list.id = `${input.dataset.suggest}-${input.name || input.id}-list`;
  list.setAttribute("role", "listbox");
  list.hidden = true;
  input.setAttribute("role", "combobox");
  input.setAttribute("aria-autocomplete", "list");
  input.setAttribute("aria-controls", list.id);
  input.setAttribute("aria-expanded", "false");
  input.after(list);
  let active = -1;
  const items = () => [...list.children];
  const close = () => { list.hidden = true; active = -1; input.setAttribute("aria-expanded", "false"); input.removeAttribute("aria-activedescendant"); };
  const highlight = (index) => {
    active = index;
    items().forEach((item, i) => item.setAttribute("aria-selected", String(i === index)));
    if (index >= 0) { input.setAttribute("aria-activedescendant", items()[index].id); items()[index].scrollIntoView({ block: "nearest" }); }
  };
  const choose = (value) => { input.value = value; close(); input.dispatchEvent(new Event("input", { bubbles: true })); input.dispatchEvent(new Event("change", { bubbles: true })); };
  const open = () => {
    const query = input.value.trim().toLowerCase();
    const values = [...source.options].map((option) => option.value).filter((value) => value.toLowerCase().includes(query) && value.toLowerCase() !== query);
    list.replaceChildren(...values.slice(0, 50).map((value, i) => {
      const item = node("li", value);
      item.id = `${list.id}-${i}`;
      item.setAttribute("role", "option");
      // pointerdown keeps focus in the field, so blur doesn't close the list first.
      item.addEventListener("pointerdown", (event) => { event.preventDefault(); choose(value); });
      return item;
    }));
    list.hidden = !values.length;
    active = -1;
    input.setAttribute("aria-expanded", String(!list.hidden));
  };
  input.addEventListener("focus", open);
  input.addEventListener("input", (event) => { if (event.isTrusted) open(); });
  input.addEventListener("blur", close);
  input.addEventListener("keydown", (event) => {
    if (list.hidden) { if (event.key === "ArrowDown") { open(); event.preventDefault(); } return; }
    const count = items().length;
    if (event.key === "ArrowDown") { highlight((active + 1) % count); event.preventDefault(); }
    else if (event.key === "ArrowUp") { highlight((active - 1 + count) % count); event.preventDefault(); }
    else if (event.key === "Enter" && active >= 0) { choose(items()[active].textContent); event.preventDefault(); }
    else if (event.key === "Escape") { close(); event.preventDefault(); event.stopPropagation(); }
  });
}
document.querySelectorAll("input[data-suggest]").forEach(suggest);

/// The payment's account as a list of cards: "9526 · Sergio". Configured
/// accounts come first; any account used in the ledger is offered too.
function fillAccounts(current) {
  const configured = Object.keys(settings.cards_config || {});
  const used = [...new Set(snapshot.expenses.map((e) => e.account))].filter((account) => !configured.includes(account) && account !== "Unspecified").sort();
  const label = (account) => { const holder = PennyReports.holder(account, settings); return holder === account ? account : `${account} · ${holder}`; };
  const accounts = [...configured.sort((a, b) => label(a).localeCompare(label(b))), ...used];
  if (current && current !== "Unspecified" && !accounts.includes(current)) accounts.push(current);
  const select = form.elements.namedItem("account");
  const placeholder = node("option", "Choose account");
  placeholder.value = "";
  select.replaceChildren(placeholder, ...accounts.map((account) => { const option = node("option", label(account)); option.value = account; return option; }));
  select.value = current && current !== "Unspecified" ? current : "";
}

let firstLoad = true;
async function reload(message = "") {
  $("refresh").disabled = true;
  const task = progressTask(firstLoad ? "Opening your ledger" : "Refreshing");
  try {
    const next = await invoke("snapshot");
    if (snapshot && snapshot.settings !== next.settings) drilldown = null;
    snapshot = next;
    settings = JSON.parse(snapshot.settings);
    updatePeriodOptions();
    render();
    if (typeof renderStatements === "function") renderStatements();
    for (const id of ["new-expense", "new-receipt", "legacy-file"]) $(id).disabled = false;
    for (const id of ["model", "projector"]) $(id).disabled = !snapshot.vision_available;
    if (typeof updateResearchAvailability === "function") updateResearchAvailability();
    $("quit").hidden = ["android", "ios"].includes(snapshot.platform);
    $("hide-to-tray").hidden = !snapshot.tray_running;
    $("camera-label").hidden = !["android", "ios"].includes(snapshot.platform);
    $("tray-hint").textContent = snapshot.tray_running ? "Runs in the tray when closed" : "Works offline";
    $("model-status").textContent = snapshot.vision_available ? "" : "Scanning isn't included in this build.";
    status("status", message);
  } catch (error) {
    status("status", errorText(error), true);
  } finally {
    firstLoad = false;
    task.done();
    $("refresh").disabled = false;
  }
}

function setBusy(value, analyzing = false) {
  busy = value;
  $("expense-fields").disabled = value;
  for (const id of ["save", "delete", "close-editor"]) $(id).disabled = value;
  $("cancel-analysis").hidden = !analyzing;
  editor.setAttribute("aria-busy", String(value));
}

function showPending() {
  $("pending-evidence").hidden = !pendingDocument;
  $("expense-fields").classList.toggle("has-image", !!pendingDocument);
  $("extraction-details").hidden = !pendingDocument?.extraction;
  $("extraction-text").textContent = pendingDocument?.extraction || "";
  if (pendingDocument) $("preview").src = pendingDocument.data_url;
  else $("preview").removeAttribute("src");
  $("analyze").disabled = !snapshot?.vision_available;
}

function showReview() {
  $("review-fields").hidden = false;
  $("manual-fallback").hidden = true;
  $("save").hidden = false;
}

/// The amount field's value in the currency's minor units: pesos as typed,
/// dollars in cents ("46.63" → 4663). NaN when it isn't such a number.
function minorUnits(value, currency) {
  const text = String(value).trim();
  if (currency !== "USD") return /^\d+$/.test(text) ? Number(text) : NaN;
  const m = /^(\d+)(?:\.(\d{1,2}))?$/.exec(text);
  return m ? Number(m[1]) * 100 + Number((m[2] || "0").padEnd(2, "0")) : NaN;
}

/// The editor's currency, and the amount field's steps with it.
function setCurrency(currency) {
  form.elements.namedItem("currency").value = currency;
  const amount = form.elements.namedItem("amount");
  amount.step = currency === "USD" ? "0.01" : "1";
  amount.min = currency === "USD" ? "0.01" : "1";
  amount.inputMode = currency === "USD" ? "decimal" : "numeric";
}

function today() {
  const date = new Date();
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

async function openEditor(expense = null, receipt = false) {
  if (editor.open || !snapshot) return;
  current = expense;
  scanFirst = receipt;
  pendingDocument = null;
  dirty = false;
  form.reset();
  $("saved-evidence").replaceChildren();
  $("delete-confirm").hidden = true;
  $("delete").hidden = !expense;
  $("editor-title").textContent = expense ? "Payment" : receipt ? "Scan voucher" : "New payment";
  $("review-fields").hidden = receipt;
  $("manual-fallback").hidden = !receipt;
  $("save").hidden = receipt;
  $("save").textContent = "Save";
  $("more-details").open = !receipt;
  for (const field of ["payee", "amount", "date", "category", "reference", "location", "notes"]) {
    if (expense) form.elements.namedItem(field).value = expense[field];
  }
  updateCategoryChoice();
  setCurrency(expense?.currency || "CLP");
  if (expense?.currency === "USD") form.elements.namedItem("amount").value = (expense.amount / 100).toFixed(2);
  fillAccounts(expense ? expense.account : localStorage.getItem("penny-last-account") || "");
  if (!expense) form.elements.namedItem("date").value = receipt ? "" : today();
  status("editor-status", "");
  // Existing payments open on their details; attaching a receipt stays available below.
  $("expense-fields").classList.toggle("editing", !!expense);
  showPending();
  editor.showModal();
  if (!expense) return;
  setBusy(true);
  try {
    const docs = await invoke("expense_documents", { id: expense.id });
    for (const [index, doc] of docs.entries()) {
      const figure = node("figure");
      const image = node("img");
      image.src = doc.data_url;
      image.alt = `Saved evidence ${index + 1}`;
      figure.append(image, node("figcaption", `Saved evidence ${index + 1}`));
      if (doc.extraction) {
        const details = node("details", undefined, "inline-details");
        details.append(node("summary", "Extraction"), node("pre", doc.extraction));
        figure.append(details);
      }
      $("saved-evidence").append(figure);
    }
    const sources = await invoke("expense_statements", { id: expense.id });
    for (const source of sources) {
      const details = node("details", undefined, "inline-details");
      details.append(node("summary", `Statement · ${source.name}`), node("pre", source.source_json));
      const save = node("button", "Save PDF", "text-button"); save.type = "button";
      save.addEventListener("click", () => invoke("export_statement", { hash: source.statement_hash }).catch((error) => status("editor-status", errorText(error), true)));
      details.append(save); $("saved-evidence").append(details);
    }
  } catch (error) {
    status("editor-status", errorText(error), true);
  } finally { setBusy(false); }
}

/// A confirmation in the page (not window.confirm, which blocks): resolves
/// true for OK. `ok` labels the confirming button.
function ask(message, ok = "OK") {
  const dialog = $("ask-dialog");
  $("ask-message").textContent = message;
  $("ask-ok").textContent = ok;
  dialog.returnValue = "";
  return new Promise((resolve) => {
    dialog.addEventListener("close", () => resolve(dialog.returnValue === "ok"), { once: true });
    dialog.showModal();
  });
}

async function closeEditor() {
  if (busy) return;
  if (dirty && !(await ask("Discard this draft?", "Discard"))) return;
  editor.close();
  current = null;
  pendingDocument = null;
  showPending();
}

async function chooseImage(file) {
  if (!file || busy) return;
  if (scanFirst && dirty && ["payee", "amount"].some((field) => form.elements.namedItem(field).value) &&
      !(await ask("Replace the voucher and regenerate this unsaved entry?", "Replace"))) return;
  setBusy(true);
  status("editor-status", "");
  let selected = false;
  try {
    if (!["image/png", "image/jpeg"].includes(file.type)) throw new Error("Choose a PNG or JPEG image");
    if (!file.size || file.size > 8 * 1024 * 1024) throw new Error("ImageTooLarge");
    const dataUrl = await new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result);
      reader.onerror = () => reject(new Error("InvalidImage"));
      reader.readAsDataURL(file);
    });
    await new Promise((resolve, reject) => {
      const image = new Image();
      image.onload = () => image.naturalWidth * image.naturalHeight > 16_000_000 ? reject(new Error("ImageTooLarge")) : resolve();
      image.onerror = () => reject(new Error("InvalidImage"));
      image.src = dataUrl;
    });
    pendingDocument = { data_url: dataUrl, extraction: "" };
    pendingFile = { name: file.name || "", modified: file.lastModified || 0 };
    selected = true;
    dirty = true;
    showPending();
  } catch (error) { status("editor-status", errorText(error), true); }
  finally {
    setBusy(false);
    $("receipt-file").value = "";
    $("camera-file").value = "";
  }
  if (selected) await analyze(true);
}

async function analyze(automatic = false) {
  if (!pendingDocument || busy) return;
  if (!automatic && dirty && ["payee", "amount"].some((field) => form.elements.namedItem(field).value) &&
      !(await ask("Fill in known fields from the image? This may replace your draft values.", "Fill in"))) return;
  cancelRequested = false;
  $("cancel-analysis").disabled = false;
  setBusy(true, true);
  status("editor-status", "");
  $("expense-fields").classList.add("scanning");
  warnIfLowMemory();
  const scan = scanProgress();
  let scanned = false;
  try {
    const result = JSON.parse(await invoke("analyze_receipt", { data_url: pendingDocument.data_url, ...pendingFile }));
    scanned = true;
    if (!result || typeof result.currency !== "string" || !Number.isSafeInteger(result.amount)) throw new Error("InvalidExtraction");
    if (cancelRequested) { status("editor-status", "Scan cancelled."); return; }
    pendingDocument.extraction = JSON.stringify(result, null, 2);
    showPending();
    if (result.currency !== "CLP") throw new Error("Only CLP payments are supported.");
    // Attaching evidence must never silently replace an existing record or
    // manual corrections. New scan-first drafts are generated from the image.
    const fill = !automatic || (scanFirst && !current);
    if (fill) {
      setCurrency("CLP"); // Scans read CLP vouchers.
      for (const field of ["payee", "amount", "date", "reference", "location"]) {
        form.elements.namedItem(field).value = result[field] || "";
      }
      const suggested = PennyReports.suggestCategory(result.payee || "", settings);
      if (suggested) form.elements.namedItem("category").value = suggested;
    }
    dirty = true;
    $("editor-title").textContent = "Check & save";
    $("save").textContent = "Save";
    status("editor-status", fill ? "Check the amount, payee and date." : "Scanned. Your details were kept.");
  } catch (error) {
    status("editor-status", errorText(error), true);
    if (/ScannerNotSetUp|ModelNotDownloaded|SystemModelNotReady|SystemAiUnavailable|ModelNotImported|ProjectorNotImported/.test(String(error))) openScanner();
  }
  finally { updateCategoryChoice(); scan.done(scanned && !cancelRequested); $("expense-fields").classList.remove("scanning"); showReview(); setBusy(false); }
}

async function saveExpense(event) {
  event.preventDefault();
  if (busy || !form.reportValidity()) return;
  setBusy(true);
  status("editor-status", "");
  const task = progressTask(pendingDocument ? "Saving payment and voucher" : "Saving payment");
  try {
    const currency = form.elements.namedItem("currency").value;
    const expense = { id: current?.id || await invoke("new_id"), currency };
    for (const field of ["payee", "date", "account", "category", "reference", "location", "notes"]) expense[field] = form.elements.namedItem(field).value.trim();
    expense.amount = minorUnits(form.elements.namedItem("amount").value, currency);
    if (!Number.isSafeInteger(expense.amount) || expense.amount <= 0) throw new Error("InvalidAmount");
    await invoke("save_expense", { expense, expected_revision: current?.revision || 0, document: pendingDocument });
    localStorage.setItem("penny-last-account", expense.account);
    dirty = false;
    editor.close();
    pendingDocument = null;
    showPending();
    task.done();
    await reload("Payment saved");
  } catch (error) { status("editor-status", errorText(error), true); }
  finally { task.done(); setBusy(false); }
}

async function deleteExpense() {
  if (!current || busy) return;
  setBusy(true);
  const task = progressTask("Deleting payment");
  try {
    await invoke("delete_expense", { id: current.id, expected_revision: current.revision });
    dirty = false;
    editor.close();
    pendingDocument = null;
    showPending();
    task.done();
    await reload("Payment deleted");
  } catch (error) { status("editor-status", errorText(error), true); }
  finally { task.done(); setBusy(false); }
}

async function importLegacy(file) {
  if (!file || mutationPending) return;
  mutationPending = true;
  $("legacy-file").disabled = true;
  const task = progressTask("Importing web data");
  try {
    if (file.size > 24 * 1024 * 1024) throw new Error("Export exceeds 24 MiB");
    const result = await invoke("import_legacy", { json: await file.text() });
    await reload(`Imported ${result.imported} · ${result.skipped} already present`);
  } catch (error) { status("status", errorText(error), true); }
  finally {
    mutationPending = false;
    task.done();
    $("legacy-file").disabled = !snapshot;
    $("legacy-file").value = "";
  }
}

async function pickModel(projector) {
  if (mutationPending) return;
  mutationPending = true;
  const messageId = "model-status";
  for (const id of ["model", "projector"]) $(id).disabled = true;
  if (editor.open) setBusy(true);
  status(messageId, "");
  const task = progressTask("Importing model file");
  let picked = false;
  try {
    picked = await invoke("pick_model", { projector });
    status(messageId, picked ? `${projector ? "Projector" : "Model"} imported` : "Cancelled");
  } catch (error) { status(messageId, errorText(error), true); }
  finally {
    task.done();
    mutationPending = false;
    if (editor.open) setBusy(false);
    for (const id of ["model", "projector"]) $(id).disabled = !snapshot?.vision_available;
    refreshScanner();
  }
}

async function quickAction() {
  const action = await invoke("take_quick_action");
  if (!action) return;
  if (action === "sync") { await openSync(); return; }
  if (editor.open) { status("editor-status", "Finish this draft first."); return; }
  await openEditor(null, action === "receipt");
}

$("new-expense").addEventListener("click", () => openEditor());
$("new-receipt").addEventListener("click", () => openEditor(null, true));
$("refresh").addEventListener("click", () => reload());
form.elements.namedItem("currency").addEventListener("change", (event) => setCurrency(event.target.value));
for (const id of ["month", "account-filter"]) $(id).addEventListener("change", () => { if (id === "month") $("date-from").value = $("date-through").value = ""; drilldown = null; if (snapshot) render(); });
for (const id of ["date-from", "date-through"]) $(id).addEventListener("change", () => {
  $("month").value = ""; drilldown = null;
  const invalid = $("date-from").value && $("date-through").value && $("date-from").value > $("date-through").value;
  $("date-through").setCustomValidity(invalid ? "End date must follow start date" : "");
  if (invalid) status("status", "End date must be after start date.", true);
  if (snapshot) render();
});
$("search").addEventListener("input", () => snapshot && render());
$("clear-filters").addEventListener("click", () => { $("month").value = $("account-filter").value = $("search").value = $("category-filter").value = $("date-from").value = $("date-through").value = ""; $("date-through").setCustomValidity(""); drilldown = null; if (snapshot) render(); });
$("clear-drilldown").addEventListener("click", () => { drilldown = null; if (snapshot) render(); });
$("clear-ledger").addEventListener("click", () => { $("search").value = $("category-filter").value = ""; drilldown = null; if (snapshot) render(); });
$("audit-other").addEventListener("click", () => {
  if (!snapshot) return;
  showGroup("Uncategorized variable payments", snapshot.expenses.filter((row) => PennyReports.uncategorized(row, settings)));
});
for (const id of ["category-filter", "ledger-sort", "merchant-grouping", "merchant-sort", "merchant-category"]) $(id).addEventListener("change", () => snapshot && render());
$("merchant-search").addEventListener("input", () => snapshot && render());
form.addEventListener("input", () => { dirty = true; updateCategoryChoice(); });
form.addEventListener("submit", saveExpense);
editor.addEventListener("cancel", (event) => { if (event.target !== editor) return; event.preventDefault(); closeEditor(); });
$("close-editor").addEventListener("click", closeEditor);
// A backdrop click must start and end outside the sheet. Dragging from a
// field or selecting text must never dismiss the payment draft.
let editorOutsidePress = false;
function outsideEditor(event) {
  const bounds = editor.getBoundingClientRect();
  return event.target === editor && (event.clientX < bounds.left || event.clientX >= bounds.right || event.clientY < bounds.top || event.clientY >= bounds.bottom);
}
editor.addEventListener("pointerdown", (event) => { editorOutsidePress = event.button === 0 && outsideEditor(event); });
editor.addEventListener("pointercancel", () => { editorOutsidePress = false; });
editor.addEventListener("click", (event) => {
  const dismiss = editorOutsidePress && outsideEditor(event);
  editorOutsidePress = false;
  if (dismiss) closeEditor();
});
$("receipt-file").addEventListener("change", (event) => chooseImage(event.target.files[0]));
$("camera-file").addEventListener("change", (event) => chooseImage(event.target.files[0]));
$("remove-image").addEventListener("click", () => { pendingDocument = null; dirty = true; showPending(); status("editor-status", ""); });
$("analyze").addEventListener("click", () => analyze(false));
$("manual-fallback").addEventListener("click", showReview);
$("cancel-analysis").addEventListener("click", async () => {
  cancelRequested = true;
  $("cancel-analysis").disabled = true;
  status("editor-status", "");
  try { await invoke("cancel_analysis"); }
  catch (error) { status("editor-status", errorText(error), true); }
});
$("delete").addEventListener("click", () => { $("delete-confirm").hidden = false; $("confirm-delete").focus(); });
$("cancel-delete").addEventListener("click", () => { $("delete-confirm").hidden = true; });
$("confirm-delete").addEventListener("click", deleteExpense);
$("legacy-file").addEventListener("change", (event) => importLegacy(event.target.files[0]));
$("model").addEventListener("click", () => pickModel(false));
$("projector").addEventListener("click", () => pickModel(true));
$("scanner-setup").addEventListener("click", () => openScanner());
$("open-fixed").addEventListener("click", () => $("fixed-page").showModal());
$("close-fixed").addEventListener("click", () => $("fixed-page").close());
$("edit-fixed").addEventListener("click", () => closeThen($("fixed-page"), () => openPreferences("fixed")));
$("quit").addEventListener("click", () => invoke("quit").catch((error) => status("status", errorText(error), true)));
$("hide-to-tray").addEventListener("click", () => window.oriel.window.current().close().catch((error) => status("status", errorText(error), true)));

async function start() {
  if (window.oriel) window.oriel.listen("quick_action", () => quickAction().catch((error) => status("status", errorText(error), true)));
  await reload();
  // A transient startup failure (e.g. a sync worker holding the database) gets one quiet retry.
  if (!snapshot) { await new Promise((resolve) => setTimeout(resolve, 1500)); await reload(); }
  if (snapshot) await quickAction();
}
setupAnalysis();
start().catch((error) => status("status", errorText(error), true));
