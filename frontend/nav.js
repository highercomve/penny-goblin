"use strict";
// Navigation shell: bottom bar / rail destinations, settings pages and the
// Android back button. Oriel routes back to WebView history, so open screens
// and dialogs are history entries: back closes a dialog, then returns Home.

const viewTitles = { home: "Penny Goblin", payments: "Payments", insights: "Insights", settings: "Settings" };
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
  if (name === currentView) { window.scrollTo({ top: 0, behavior: "smooth" }); return; }
  const onTab = history.state?.penny === "view";
  if (name === "home") {
    if (onTab) { history.back(); return; }
  } else if (onTab) history.replaceState({ penny: "view", view: name }, "");
  else history.pushState({ penny: "view", view: name }, "");
  applyView(name);
}

function openDialogs() {
  return [...document.querySelectorAll("dialog[open]")];
}

// Each modal pushes one history entry so the system back gesture can close it.
const nativeShowModal = HTMLDialogElement.prototype.showModal;
HTMLDialogElement.prototype.showModal = function showModal() {
  nativeShowModal.call(this);
  history.pushState({ penny: "dialog", view: currentView }, "");
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
    if (dialog.open) { delete dialog.dataset.closedByBack; history.pushState({ penny: "dialog", view: currentView }, ""); }
    return;
  }
  applyView(event.state?.view || "home");
});

for (const item of document.querySelectorAll(".nav-item")) item.addEventListener("click", () => showView(item.dataset.view));
$("open-statements").addEventListener("click", () => $("statements-page").showModal());
$("close-statements").addEventListener("click", () => $("statements-page").close());
$("open-scanner").addEventListener("click", () => openScanner());
$("close-scanner").addEventListener("click", () => $("scanner-page").close());
history.replaceState({ penny: "root", view: "home" }, "");
applyView("home");
