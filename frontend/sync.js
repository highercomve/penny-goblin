"use strict";
let syncWorking = false;
let syncReview = null;
let syncExpiry = 0;
let syncStarted = false;
const syncErrors = {
  DifferentPairedDesktop: "Paired with another desktop. Turn on “Replace paired desktop” first.",
  DesktopUnavailableOrIdentityMismatch: "Can't reach the desktop. Is Penny Goblin open, on the same Wi-Fi or Tailscale?",
  DesktopUnavailableOrSyncFailed: "Can't reach the desktop. Nothing was lost; it syncs when Penny Goblin is open on the same Wi-Fi or Tailscale.",
  PairingExpiredOrInvalid: "Code expired or used. Show a new one on the desktop.",
  InvalidPairingCode: "That link is incomplete. Copy the whole link again.",
  DeviceNotAuthorized: "Disconnected by the desktop. Pair again.",
  PairingNeedsRepair: "Pairing needs repair. Pair again.",
  EvidenceReviewRequired: "Shares a receipt with another payment. Use the desktop version.",
  CannotRestoreDeleted: "Deleted on the desktop; it can't be restored.",
  ScannerUnavailable: "The camera scanner couldn't open. Paste the link instead.",
};
function syncError(error) {
  const code = String(error?.message || error);
  return Object.entries(syncErrors).find(([key]) => code.includes(key))?.[1] || errorText(error);
}
async function syncControl(action, args = {}) {
  const result = JSON.parse(await invoke("sync_control", { action, ...args }));
  // A failed action answers only {error}. A status (also after sync_now)
  // carries the last sync's error beside it for display, not as a failure.
  if (result.error && !("server_id" in result)) throw new Error(result.error);
  return result;
}
// Phones synchronize through the desktop service, not this window: poll the
// change counter and refresh when records arrive.
let desktopChanges = null;
let desktopPolling = false;
async function watchDesktopChanges() {
  if (desktopPolling) return;
  desktopPolling = true;
  try {
    const { changes } = JSON.parse(await invoke("sync_status"));
    if (desktopChanges !== null && changes !== desktopChanges) safeSyncReload();
    desktopChanges = changes;
    await parseQueuedStatements();
  } catch { /* The next poll retries. */ }
  finally { desktopPolling = false; }
}
function safeSyncReload() {
  if (!snapshot || mutationPending || busy || editor.open || $("preferences-dialog").open || $("statement-dialog").open) return;
  reload("Synced").catch((error) => status("status", errorText(error), true));
}
async function refreshSync() {
  if (!snapshot || syncWorking) return;
  const mobile = snapshot.platform === "android";
  $("sync-mobile").hidden = !mobile;
  $("sync-desktop").hidden = mobile;
  const [core, transport] = await Promise.all([invoke("sync_status").then(JSON.parse), syncControl("status")]);
  const last = core.last_success ? new Date(core.last_success * 1000).toLocaleString(undefined, { dateStyle: "short", timeStyle: "short" }) : "never";
  const state = mobile ? (transport.paired ? (transport.connected ? "Connected" : "Waiting for desktop") : "Not paired") : (transport.running ? "Ready for phones" : "Service stopped");
  const extras = [core.pending ? `${core.pending} to send` : "", core.conflicts.length ? `${core.conflicts.length} conflicts` : ""].filter(Boolean).join(" · ");
  $("sync-summary").replaceChildren(node("strong", state), node("br"), node("span", `Last sync ${last}${extras ? ` · ${extras}` : ""}`));
  if (mobile && transport.error) status("sync-message", syncError(transport.error), true);
  if (!mobile) {
    $("sync-routes").replaceChildren(...(transport.endpoints || []).map((route) => node("li", route)));
    $("sync-devices").replaceChildren(...(transport.devices || []).map((device) => {
      const row = node("div"); row.append(node("span", `${device.label}${device.revoked ? " · disconnected" : ""}`));
      if (!device.revoked) { const button = node("button", "Disconnect", "text-button danger"); button.type = "button"; button.onclick = () => syncAction("revoke", { device: device.id }); row.append(button); }
      return row;
    }));
  }
  $("sync-conflicts").replaceChildren(...core.conflicts.map((conflict) => {
    const button = node("button", `Review ${conflict.kind}`); button.type = "button";
    button.onclick = async () => {
      try {
        const detail = JSON.parse(await invoke("sync_conflict", { kind: conflict.kind, id: conflict.id }));
        syncReview = detail;
        $("sync-local").textContent = JSON.stringify(JSON.parse(detail.local_payload), null, 2);
        $("sync-remote").textContent = JSON.stringify(JSON.parse(detail.remote_payload), null, 2);
        const remote = JSON.parse(detail.remote_payload);
        $("sync-use-local").disabled = ["EvidenceConflict", "ImmutableSourceConflict"].includes(detail.reason) || detail.kind === "document" || !!remote?.expense?.deleted;
        $("sync-review").hidden = false;
      } catch (error) { status("sync-message", syncError(error), true); }
    }; return button;
  }));
  if (!core.conflicts.length) $("sync-conflicts").append(node("p", "None"));
}
async function openSync() {
  if (!$("sync-dialog").open) $("sync-dialog").showModal();
  try { await refreshSync(); } catch (error) { status("sync-message", syncError(error), true); }
}
async function syncAction(action, args = {}) {
  if (syncWorking) return;
  syncWorking = true;
  $("sync-dialog").querySelectorAll("button").forEach((button) => { button.disabled = true; });
  status("sync-message", "");
  const labels = { pairing: "Creating pairing code", scan_pair: "Pairing with the desktop", pair_link: "Pairing with the desktop", sync_now: "Syncing", unpair: "Disconnecting", start: "Starting sync service", restart: "Restarting sync service", stop: "Stopping sync service", revoke: "Disconnecting phone" };
  const task = progressTask(labels[action] || "Working");
  try {
    const result = await syncControl(action, args);
    if (action === "pairing") {
      syncExpiry = result.expires;
      $("sync-qr").src = result.qr; $("sync-link").value = result.link; $("sync-code").hidden = false;
    }
    if (["scan_pair", "pair_link"].includes(action) && !result.cancelled) { $("sync-paste").value = ""; $("sync-replace").checked = false; }
    status("sync-message", result.cancelled ? "Cancelled" : "");
    if (["sync_now", "scan_pair", "pair_link"].includes(action)) safeSyncReload();
  } catch (error) { status("sync-message", syncError(error), true); }
  finally {
    task.done();
    syncWorking = false;
    $("sync-dialog").querySelectorAll("button").forEach((button) => { button.disabled = false; });
    await refreshSync().catch((error) => status("sync-message", syncError(error), true));
  }
}
async function resolveSync(keepLocal) {
  if (!syncReview || syncWorking) return;
  try {
    await withProgress("Saving your choice", () => invoke("sync_resolve", { kind: syncReview.kind, id: syncReview.id, keep_local: keepLocal }));
    syncReview = null; $("sync-review").hidden = true;
    status("sync-message", "");
    await refreshSync(); safeSyncReload();
  } catch (error) { status("sync-message", syncError(error), true); }
}
$("open-sync").onclick = openSync;
$("close-sync").onclick = () => $("sync-dialog").close();
$("sync-dialog").addEventListener("close", () => { $("sync-code").hidden = true; $("sync-link").value = ""; $("sync-qr").removeAttribute("src"); });
for (const action of ["start", "stop", "restart"]) $("sync-" + action).onclick = () => syncAction(action);
$("sync-pairing").onclick = () => syncAction("pairing");
$("sync-scan").onclick = () => syncAction("scan_pair", { replace: $("sync-replace").checked });
$("sync-connect").onclick = () => syncAction("pair_link", { link: $("sync-paste").value.replace(/\s+/g, ""), replace: $("sync-replace").checked });
$("sync-now").onclick = () => syncAction("sync_now");
$("sync-unpair").onclick = () => syncAction("unpair");
$("sync-use-local").onclick = () => resolveSync(true);
$("sync-use-remote").onclick = () => resolveSync(false);
setInterval(() => {
  if (syncExpiry) {
    const seconds = Math.max(0, syncExpiry - Math.floor(Date.now() / 1000));
    $("sync-expiry").textContent = seconds ? `Scan with your phone · ${seconds}s` : "Expired";
    if (!seconds) { $("sync-qr").removeAttribute("src"); $("sync-link").value = ""; syncExpiry = 0; }
  }
  if (snapshot && snapshot.platform !== "android") watchDesktopChanges();
  if (snapshot && !syncStarted) {
    syncStarted = true;
    if (snapshot.platform !== "android") syncControl("start").catch((error) => status("status", syncError(error), true));
    if (window.oriel?.extensions?.on) window.oriel.extensions.on("penny.sync", (event) => { if (event.data?.changed) safeSyncReload(); });
  }
  if ($("sync-dialog").open) refreshSync().catch((error) => status("sync-message", syncError(error), true));
}, 3000);
