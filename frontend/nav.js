"use strict";
// Navigation shell: bottom bar / rail destinations, settings pages and the
// Android back button. Oriel routes back to WebView history, so open screens
// and dialogs are history entries: back closes a dialog, then returns Home.
// A drill-down (a category, merchant or fixed item's payments) is one more
// entry, so back returns to the screen it was opened from.

const viewTitles = { home: "Penny Goblin", payments: "Payments", insights: "Insights", settings: "Settings" };
const viewNames = { home: "Home", payments: "Payments", insights: "Insights", settings: "Settings" };
const depth = () => history.state?.depth || 0;
let currentView = "home";
let ignoreNextPop = false;

function applyView(name) {
  if (!viewTitles[name]) name = "home";
  currentView = name;
  for (const view of Object.keys(viewTitles)) $(`view-${view}`).hidden = view !== name;
  for (const item of document.querySelectorAll(".nav-item")) {
    if (item.dataset.view === name) item.setAttribute("aria-current", "page");
    else item.removeAttribute("aria-current");
  }
  document.body.className = `view-${name}-active`;
  $("view-title").textContent = viewTitles[name];
  window.scrollTo(0, 0);
}

function showView(name) {
  endDrilldown();
  if (name === currentView) { window.scrollTo({ top: 0, behavior: "smooth" }); return; }
  if (name === "home") {
    if (depth()) { history.go(-depth()); return; }
  } else if (depth()) history.replaceState({ penny: "view", view: name, depth: depth() }, "");
  else history.pushState({ penny: "view", view: name, depth: 1 }, "");
  applyView(name);
}

// Open a drill-down on `name`; back (or drilldownOrigin's chip) returns here.
function showFrom(name) {
  history.pushState({ penny: "view", view: name, depth: depth() + 1, drill: currentView }, "");
  applyView(name);
}
const drilldownOrigin = () => viewNames[history.state?.drill];

function openDialogs() {
  return [...document.querySelectorAll("dialog[open]")];
}

// Each modal pushes one history entry so the system back gesture can close it.
const nativeShowModal = HTMLDialogElement.prototype.showModal;
HTMLDialogElement.prototype.showModal = function showModal() {
  nativeShowModal.call(this);
  history.pushState({ penny: "dialog", view: currentView, depth: depth() + 1 }, "");
  if (typeof raiseProgress === "function") raiseProgress();
};

document.addEventListener("close", (event) => {
  if (!(event.target instanceof HTMLDialogElement)) return;
  // "close" fires asynchronously. Back already popped its entry; a button did not.
  const dialog = event.target;
  if (dialog.dataset.closedByBack) { delete dialog.dataset.closedByBack; return; }
  if (history.state?.penny === "dialog") { ignoreNextPop = true; history.back(); }
  else runAfterClose();
}, true);

// Close a dialog, then continue (open another screen) once its history entry is gone.
let afterClose = null;
function closeThen(dialog, next) {
  afterClose = next;
  dialog.close();
}
function runAfterClose() {
  const next = afterClose;
  afterClose = null;
  if (next) next();
}

window.addEventListener("popstate", (event) => {
  if (ignoreNextPop) { ignoreNextPop = false; runAfterClose(); return; }
  const dialog = openDialogs().pop();
  if (dialog) {
    // Run the dialog's own cancel handling (unsaved-change confirmation).
    const cancel = new Event("cancel", { cancelable: true });
    dialog.dataset.closedByBack = "1";
    if (dialog.dispatchEvent(cancel)) dialog.close();
    if (dialog.open) { delete dialog.dataset.closedByBack; history.pushState({ penny: "dialog", view: currentView, depth: depth() + 1 }, ""); }
    return;
  }
  if (!event.state?.drill) endDrilldown();
  applyView(event.state?.view || "home");
});

// Desktop back: Alt+Left, the mouse's back button, or Escape leaving a
// drill-down. Dialogs keep handling their own Escape.
function desktopBack(event) {
  if (!depth() || openDialogs().length) return;
  event.preventDefault();
  history.back();
}
document.addEventListener("keydown", (event) => {
  if ((event.altKey && event.key === "ArrowLeft") || event.key === "BrowserBack") desktopBack(event);
  else if (event.key === "Escape" && history.state?.drill && !event.target.closest?.("input, textarea, select")) desktopBack(event);
});
document.addEventListener("mouseup", (event) => { if (event.button === 3) desktopBack(event); });
for (const item of document.querySelectorAll(".nav-item")) item.addEventListener("click", () => showView(item.dataset.view));
$("open-statements").addEventListener("click", () => $("statements-page").showModal());
$("close-statements").addEventListener("click", () => $("statements-page").close());
$("open-scanner").addEventListener("click", () => openScanner());
$("close-scanner").addEventListener("click", () => $("scanner-page").close());
history.replaceState({ penny: "root", view: "home" }, "");
applyView("home");
