"use strict";
// One global progress indicator for long work: a thin bar at the top of the
// screen and a short message of what is happening. It lives in the top layer
// (a manual popover) so it stays visible above open dialogs.
//
//   const task = progressTask("Saving");     // indeterminate
//   task.update("Downloading Qwen", 0.42);   // determinate (0..1)
//   task.done();
//
// Several tasks may overlap; the most recent one is shown.

const progressEl = document.getElementById("global-progress");
const progressTasks = [];
let progressSeq = 0;

function renderProgress() {
  const task = progressTasks[progressTasks.length - 1];
  if (!task) {
    progressEl.classList.remove("visible");
    // Let the fade finish before leaving the top layer.
    setTimeout(() => { if (!progressTasks.length && progressEl.matches(":popover-open")) progressEl.hidePopover(); }, 250);
    return;
  }
  document.getElementById("global-progress-message").textContent = task.message;
  const determinate = typeof task.value === "number";
  progressEl.classList.toggle("determinate", determinate);
  document.getElementById("global-progress-value").style.transform = determinate ? `scaleX(${Math.max(0.02, Math.min(1, task.value))})` : "";
  document.getElementById("global-progress-percent").textContent = determinate ? `${Math.round(Math.min(1, task.value) * 100)}%` : "";
  raiseProgress();
  progressEl.classList.add("visible");
}

/// Keep the indicator above a dialog opened after it (top layer order).
function raiseProgress() {
  if (!progressTasks.length || !progressEl.showPopover) return;
  if (progressEl.matches(":popover-open")) progressEl.hidePopover();
  progressEl.showPopover();
}

function progressTask(message, value) {
  const task = { id: ++progressSeq, message, value };
  progressTasks.push(task);
  renderProgress();
  return {
    update(nextMessage, nextValue) {
      if (nextMessage) task.message = nextMessage;
      task.value = nextValue;
      if (progressTasks[progressTasks.length - 1] === task) renderProgress();
    },
    done() {
      const index = progressTasks.indexOf(task);
      if (index >= 0) progressTasks.splice(index, 1);
      renderProgress();
    },
  };
}

/// Run `work` under a progress task that always ends.
async function withProgress(message, work) {
  const task = progressTask(message);
  try { return await work(task); } finally { task.done(); }
}

// --- Scans: real stages from the backend, timed from this device's last scan.

const scanStages = [
  { name: "preparing", message: "Preparing the image" },
  { name: "text", message: "Reading receipt text" },
  // A phone paired with a reachable desktop: its scanner reads the voucher.
  { name: "desktop", message: "Reading the voucher on your desktop" },
  { name: "loading", message: "Loading the AI scanner" },
  { name: "reading", message: "Reading the voucher with AI" },
  { name: "writing", message: "Extracting payment details" },
];
const defaultStageMs = { preparing: 500, text: 1000, desktop: 15000, loading: 5000, reading: 90000, writing: 30000 };

function scanTimings() {
  try { return { ...defaultStageMs, ...JSON.parse(localStorage.getItem("penny-scan-timing") || "{}") }; }
  catch { return { ...defaultStageMs }; }
}

/// A scan's progress: stages arrive as backend events; within a stage the
/// bar advances along this device's last measured duration, slowing near the
/// stage's end instead of claiming completion it hasn't reached.
function scanProgress() {
  const timings = scanTimings();
  const task = progressTask(scanStages[0].message, 0);
  let current = 0;
  let stageStart = performance.now();
  const measured = {};
  // The stages this scan goes through, as known so far: on this device
  // (not the desktop) until the desktop takes it, then ending there; all of
  // them when the desktop was tried and the device scans after all.
  let steps = scanStages.filter((stage) => stage.name !== "desktop");
  const span = (list) => list.reduce((sum, stage) => sum + timings[stage.name], 0);
  const tick = setInterval(() => {
    const stage = scanStages[current];
    const expected = timings[stage.name];
    const elapsed = performance.now() - stageStart;
    // Approaches 95% of the stage asymptotically past its expected length.
    const fraction = 0.95 * (1 - Math.exp(-elapsed / Math.max(500, expected) * 1.6));
    task.update(stage.message, (span(steps.slice(0, steps.indexOf(stage))) + fraction * expected) / span(steps));
  }, 250);
  const offStage = window.oriel?.listen?.("scan_stage", (event) => {
    const name = (event?.payload ?? event)?.stage;
    const index = scanStages.findIndex((stage) => stage.name === name);
    if (index <= current) return;
    const left = scanStages[current].name;
    measured[left] = performance.now() - stageStart;
    if (name === "desktop") steps = scanStages.slice(0, index + 1);
    else if (left === "desktop") {
      // The desktop couldn't scan it: its time isn't a desktop scan's.
      delete measured.desktop;
      steps = scanStages;
    }
    current = index;
    stageStart = performance.now();
  });
  return {
    done(success) {
      clearInterval(tick);
      if (typeof offStage === "function") offStage();
      if (success) {
        measured[scanStages[current].name] = performance.now() - stageStart;
        localStorage.setItem("penny-scan-timing", JSON.stringify({ ...timings, ...measured }));
        task.update("Entry ready", 1);
        setTimeout(() => task.done(), 400);
      } else task.done();
    },
  };
}
