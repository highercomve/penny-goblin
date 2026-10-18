"use strict";
// Visual QA (desktop): with PENNY_QA set, put the app in a state to compare
// renderers, e.g. PENNY_QA="view:insights;scroll:900". Steps, `;`-separated:
//   view:<home|payments|insights|settings>  click:<id>  pref:<section>
//   editor:<new|receipt|first>  open:<details id>  scroll:<px>  ask
//   value:<id>=<text>  focus:<id>  group:first  wait:<ms>
// Unset (always on Android), it does nothing.
(async () => {
  let scenario = null;
  try { scenario = await invoke("qa_scenario"); } catch { return; }
  if (!scenario) return;
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  for (let i = 0; i < 100 && !snapshot; i++) await sleep(100);
  await sleep(300);
  // An id, else a selector ("details.range", "[name=category]").
  const el = (sel) => document.getElementById(sel) || document.querySelector(sel);
  // Every shown element's box, keyed by its path (tag#id.class:index).
  const dump = () => {
    const out = [];
    const walk = (node, path) => {
      let i = 0;
      for (const c of node.children) {
        i++;
        const key = `${path}/${c.localName}${c.id ? "#" + c.id : ""}${c.classList.length ? "." + [...c.classList].join(".") : ""}:${i}`;
        const r = c.getBoundingClientRect();
        if (r.width > 0 || r.height > 0) out.push([key, Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height), (c.firstChild?.nodeType === 3 ? c.firstChild.data.trim().slice(0, 30) : "")]);
        if (!["svg", "select", "script", "style"].includes(c.localName)) walk(c, key);
      }
    };
    walk(document.body, "");
    return JSON.stringify(out);
  };
  const topDialog = () => [...document.querySelectorAll("dialog[open]")].pop();
  for (const step of scenario.split(";").map((s) => s.trim()).filter(Boolean)) {
    const at = step.indexOf(":");
    const [op, arg] = at < 0 ? [step, ""] : [step.slice(0, at), step.slice(at + 1)];
    try {
      if (op === "view") showView(arg);
      else if (op === "click") el(arg).click();
      else if (op === "pref") openPreferences(arg);
      else if (op === "editor") await openEditor(arg === "first" ? snapshot.expenses[0] : null, arg === "receipt");
      else if (op === "open") el(arg).open = true;
      else if (op === "scroll") { const d = topDialog(); if (d) d.scrollTop = +arg; else window.scrollTo(0, +arg); }
      else if (op === "ask") ask("Discard this draft?", "Discard");
      else if (op === "value") { const eq = arg.lastIndexOf("="); const t = el(arg.slice(0, eq)); t.value = arg.slice(eq + 1); t.dispatchEvent(new Event("input", { bubbles: true })); }
      else if (op === "dump") await invoke("qa_report", { text: dump() });
      else if (op === "focus") el(arg).focus();
      else if (op === "group") { const g = PennyReports.group(snapshot.expenses, (r) => r.category)[0]; showGroup(g.name, g.rows); }
      else if (op === "wait") await sleep(+arg);
      await sleep(400);
    } catch (e) { console.error("qa step " + step + ": " + (e?.message || e)); }
  }
})();
