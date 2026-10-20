"use strict";
// Settings → Receipt scanner: the phone's own model, downloadable catalog
// models and imported GGUF files. The backend owns the choice and files.

let scannerState = null;
let scannerProgress = {};
let scannerWorking = false;
const downloadTasks = {};

const megabytes = (mb) => mb >= 1024 ? `${(mb / 1024).toFixed(1)} GB` : `${mb} MB`;

function scannerLabel(id) {
  if (id === "system") return "the phone's model";
  if (id === "custom") return "your imported model";
  if (id === "shared") return scannerState?.shared.find((pair) => pair.current)?.name || "a model from another app";
  return scannerState?.models.find((model) => model.id === id)?.label || "";
}

async function refreshScanner() {
  try {
    scannerState = JSON.parse(await invoke("scanner_status"));
    renderScanner();
  } catch (error) { status("model-status", errorText(error), true); }
}

function scannerButton(text, kind, onClick) {
  const button = node("button", text, kind);
  button.type = "button";
  button.addEventListener("click", onClick);
  return button;
}

function scannerRow(title, detail, actions) {
  const row = node("div", undefined, "list-item scanner-row");
  const text = node("span", undefined, "scanner-text");
  text.append(node("strong", title), node("small", detail));
  const side = node("span", undefined, "scanner-actions");
  side.append(...actions);
  row.append(text, side);
  return row;
}

function inUse(id) {
  const badge = node("span", "In use", "badge");
  badge.hidden = scannerState.active !== id;
  return badge;
}

function renderScanner() {
  const state = scannerState;
  if (!state) return;
  const active = state.models.find((model) => model.id === state.active);
  const tight = active && state.free_mb && state.free_mb < active.mb * 1.25;
  const summary = $("settings-model-summary");
  if (summary) summary.textContent = state.active ? `Using ${scannerLabel(state.active)}` : "Choose how vouchers are read";
  $("scanner-summary").textContent = state.active ? `Scanning with ${scannerLabel(state.active)}${tight ? ` · only ${megabytes(state.free_mb)} free: close other apps for faster scans` : ""}` : "Choose how vouchers are read.";
  // The phone's model (Gemini Nano): only where the platform has one.
  $("scanner-system").hidden = !state.system.supported;
  if (state.system.supported) {
    const s = state.system.state;
    const detail = { available: "Ready · no download needed", downloadable: "Supported · needs a system download", downloading: "The system is downloading it", unavailable: state.system.reason || "Not available on this phone" }[s];
    const actions = [inUse("system")];
    if (s === "available" && state.active !== "system") actions.push(scannerButton("Use", "tonal", () => chooseScanner("system")));
    if (s === "downloadable") actions.push(scannerButton("Download", "tonal", downloadSystemModel));
    $("scanner-system-row").replaceChildren(scannerRow("Gemini Nano", detail, actions));
  }
  // On this device: downloaded models (use or delete) and downloads in progress.
  const rowFor = (model) => {
    const progress = scannerProgress[model.id];
    const downloading = state.downloading === model.id || progress?.state === "downloading";
    let detail = `${model.note} · ${megabytes(model.mb)}`;
    const actions = [inUse(model.id)];
    if (downloading) {
      detail = progress?.total_mb ? `Downloading ${megabytes(progress.done_mb)} of ${megabytes(progress.total_mb)}` : "Starting download…";
      actions.push(scannerButton("Cancel", "text-button", () => invoke("scanner_cancel_download")));
    } else if (model.installed) {
      if (state.active !== model.id) actions.push(scannerButton("Use", "tonal", () => chooseScanner(model.id)));
      actions.push(scannerButton("Delete", "text-button danger", () => deleteScannerModel(model)));
    } else if (model.found && !model.partial_mb) {
      // Another app keeps the same files: "downloading" checks and links them.
      detail = `${model.note} · in ${model.found}, nothing to download`;
      const button = scannerButton("Use", "tonal", () => downloadScannerModel(model));
      button.disabled = !!state.downloading || !state.vision_built;
      actions.push(button);
    } else {
      if (model.partial_mb) detail = `${model.note} · ${megabytes(model.partial_mb)} of ${megabytes(model.mb)} downloaded`;
      const button = scannerButton(model.partial_mb ? "Resume" : "Download", "tonal", () => downloadScannerModel(model));
      button.disabled = !!state.downloading || !state.vision_built;
      actions.push(button);
    }
    const row = scannerRow(model.label, detail, actions);
    if (downloading && progress?.total_mb) {
      const bar = node("span", undefined, "scanner-progress");
      bar.style.width = `${Math.min(100, (progress.done_mb / progress.total_mb) * 100)}%`;
      row.append(bar);
    }
    return row;
  };
  const busy = (model) => state.downloading === model.id || scannerProgress[model.id]?.state === "downloading";
  const local = state.models.filter((model) => model.installed || busy(model) || model.found);
  const available = state.models.filter((model) => !model.installed && !busy(model) && !model.found);
  // Vision models LM Studio, GhostPen or Hugging Face keep, used where they are.
  const sharedRow = (pair) => {
    const badge = node("span", "In use", "badge");
    badge.hidden = !(state.active === "shared" && pair.current);
    const actions = [badge];
    if (badge.hidden) {
      const button = scannerButton("Use", "tonal", () => chooseSharedScanner(pair));
      button.disabled = !state.vision_built;
      actions.push(button);
    }
    return scannerRow(pair.name, `${pair.app} · ${megabytes(pair.mb)} · with its projector`, actions);
  };
  $("scanner-installed-section").hidden = !local.length && !state.shared.length;
  $("scanner-installed").replaceChildren(...local.map(rowFor), ...state.shared.map(sharedRow));
  $("scanner-available-section").hidden = !available.length;
  $("scanner-models").replaceChildren(...available.map(rowFor));
  // Your own GGUF pair: use or delete once both files are loaded.
  const customActions = [inUse("custom")];
  if (state.custom && state.active !== "custom") customActions.push(scannerButton("Use", "tonal", () => chooseScanner("custom")));
  if (state.custom) customActions.push(scannerButton("Delete", "text-button danger", deleteCustomModel));
  $("scanner-custom-row").replaceChildren(...(state.custom ? [scannerRow("Your model", "Loaded from a GGUF file", customActions)] : []));
  $("scanner-fast-row").hidden = !state.fast_available;
  $("scanner-fast").checked = state.fast;
  // Only when a GPU passed ggml's self-test; the CPU stays the default.
  $("scanner-gpu-row").hidden = !state.gpu || !state.vision_built;
  $("scanner-gpu-label").textContent = `Use GPU (${state.gpu})`;
  $("scanner-gpu").checked = state.use_gpu;
  if (!state.vision_built) status("model-status", "Local models aren't included in this build.");
}

async function chooseScanner(id) {
  if (scannerWorking) return;
  scannerWorking = true;
  try { await invoke("scanner_select", { id }); status("model-status", ""); }
  catch (error) { status("model-status", errorText(error), true); }
  finally { scannerWorking = false; await refreshScanner(); }
}

async function chooseSharedScanner(pair) {
  if (scannerWorking) return;
  scannerWorking = true;
  try { await invoke("scanner_select_shared", { model: pair.model, projector: pair.projector }); status("model-status", `Scanning with ${pair.name}`); }
  catch (error) { status("model-status", errorText(error), true); }
  finally { scannerWorking = false; await refreshScanner(); }
}

async function downloadScannerModel(model) {
  scannerProgress[model.id] = { state: "downloading", done_mb: model.partial_mb, total_mb: model.mb };
  renderScanner();
  const task = progressTask(`Downloading ${model.label}`, model.partial_mb / model.mb);
  downloadTasks[model.id] = task;
  try {
    await invoke("scanner_download", { id: model.id });
    // The first model downloaded becomes the scanner unless one was chosen.
    if (!scannerState?.selected) await invoke("scanner_select", { id: model.id });
    status("model-status", `${model.label} is ready`);
  } catch (error) {
    if (!String(error?.message || error).includes("Cancelled")) status("model-status", errorText(error), true);
  } finally {
    task.done();
    delete downloadTasks[model.id];
    delete scannerProgress[model.id];
    await refreshScanner();
  }
}

async function deleteScannerModel(model) {
  if (!(await ask(`Delete ${model.label} (${megabytes(model.mb)})?`, "Delete"))) return;
  try { await invoke("scanner_delete", { id: model.id }); }
  catch (error) { status("model-status", errorText(error), true); }
  await refreshScanner();
}

async function deleteCustomModel() {
  if (!(await ask("Delete your loaded model files?", "Delete"))) return;
  try { await invoke("scanner_delete", { id: "custom" }); }
  catch (error) { status("model-status", errorText(error), true); }
  await refreshScanner();
}

async function downloadSystemModel() {
  try { await withProgress("Downloading the phone's model", () => invoke("scanner_system_download")); status("model-status", ""); }
  catch (error) { status("model-status", errorText(error), true); }
  await refreshScanner();
}

function openScanner() {
  if (!$("scanner-page").open) $("scanner-page").showModal();
  refreshScanner();
}

if (window.oriel) window.oriel.listen("model_download", (event) => {
  const data = event?.payload ?? event;
  if (!data?.id) return;
  scannerProgress[data.id] = data;
  const label = scannerState?.models.find((model) => model.id === data.id)?.label || "model";
  if (data.state === "downloading" && data.total_mb) downloadTasks[data.id]?.update(`Downloading ${label} · ${megabytes(data.done_mb)} of ${megabytes(data.total_mb)}`, data.done_mb / data.total_mb);
  if ($("scanner-page").open) renderScanner();
});
// Back in a draft with a voucher that hasn't been read yet: read it now.
$("scanner-page").addEventListener("close", () => {
  if (editor.open && pendingDocument && !pendingDocument.extraction && scannerState?.active) analyze(true);
});
$("scanner-fast").addEventListener("change", async (event) => {
  try { await invoke("scanner_fast", { enabled: event.target.checked }); }
  catch (error) { status("model-status", errorText(error), true); }
  await refreshScanner();
});
$("scanner-gpu").addEventListener("change", async (event) => {
  try { await invoke("scanner_gpu", { enabled: event.target.checked }); }
  catch (error) { status("model-status", errorText(error), true); }
  await refreshScanner();
});

/// Before a scan: warn when the chosen model won't fit in free memory.
async function warnIfLowMemory() {
  try {
    const state = JSON.parse(await invoke("scanner_status"));
    const active = state.models.find((model) => model.id === state.active);
    if (active && state.free_mb && state.free_mb < active.mb * 1.25)
      status("status", `Only ${megabytes(state.free_mb)} free; ${active.label} needs about ${megabytes(Math.round(active.mb * 1.25))}. Close other apps or the scan will be slow.`, true);
  } catch { /* A status failure must not block the scan. */ }
}
