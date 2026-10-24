"use strict";

let preferencesExpected = "";
let preferencesOriginal = {};
let preferencesDirty = false;
let preferencesSaving = false;
let preferencesSaved = null;
let bulkDraft = null;
const preferenceSections = [
  ["accounts", "Account or card", "Cardholder", "cards_config"],
  ["categories", "Category", "Keywords (comma separated)", "categories"],
  ["vendors", "Description contains", "Show as", "vendors_config"],
  ["special", "Description contains", "Label", "special_cases"],
];
const preferenceTitles = { budget: "Salary & owners", fixed: "Fixed commitments", accounts: "Accounts", categories: "Category rules", vendors: "Merchant names", special: "Special payments" };

function preferenceInput(label, value, max = 120, type = "text") {
  const wrapper = node("label", label);
  const input = node("input");
  input.type = type;
  input.value = value;
  input.required = true;
  input.maxLength = max;
  if (type === "number") { input.min = "0"; input.max = "1000000000000"; input.step = "1"; }
  wrapper.append(input);
  return wrapper;
}

function preferenceRow(container, fields) {
  const row = node("div", undefined, "preference-row");
  row.append(...fields);
  const remove = node("button", undefined, "remove");
  remove.type = "button";
  remove.setAttribute("aria-label", "Remove");
  remove.innerHTML = '<svg><use href="#i-close"/></svg>';
  remove.addEventListener("click", () => { row.remove(); preferencesDirty = true; });
  row.append(remove);
  $(container).append(row);
  return row;
}

function addPreferenceMapping(section, key = "", value = "") {
  const [, keyLabel, valueLabel] = preferenceSections.find(([id]) => id === section);
  const row = preferenceRow(`preferences-${section}`, [preferenceInput(keyLabel, key, section === "accounts" || section === "categories" ? 120 : 240), preferenceInput(valueLabel, value, section === "categories" ? 24000 : 120)]);
  if (section === "categories") {
    row.querySelectorAll("input")[0].readOnly = true;
    row.querySelectorAll("input")[1].required = false;
  }
  return row;
}

function addFixedPreference(item = { name: "", amount: 0, keywords: [] }) {
  const keywords = preferenceInput("Keywords (comma separated)", (item.keywords || []).join(", "), 24000);
  keywords.querySelector("input").required = false;
  preferenceRow("preferences-fixed", [preferenceInput("Name", item.name), preferenceInput("Monthly amount (CLP)", item.amount, 120, "number"), keywords]);
}

function openPreferences(section = "budget", rules = false, onSaved = null) {
  if (section === "categories" && !rules) { openCategoryPicker(true); return; }
  if (!snapshot || $("preferences-dialog").open) return;
  preferencesSaved = onSaved;
  // One settings page at a time; saving still writes the whole validated settings document.
  for (const page of $("preferences-fields").children) page.classList.toggle("active", page.dataset.section === section);
  $("preferences-title").textContent = preferenceTitles[section] || "Budget";
  preferencesExpected = snapshot.settings;
  preferencesOriginal = JSON.parse(snapshot.settings);
  $("preferences-salary").value = settings.salary || 0;
  $("preferences-owners").value = (settings.account_owners || []).join(", ");
  $("preferences-fixed").replaceChildren();
  for (const item of settings.fixed_expenses_items || []) addFixedPreference(item);
  for (const [section, , , key] of preferenceSections) {
    $(`preferences-${section}`).replaceChildren();
    for (const [name, value] of Object.entries(settings[key] || {})) {
      addPreferenceMapping(section, name, section === "categories" ? value.join(", ") : typeof value === "string" ? value : value.holder);
    }
  }
  if (section === "categories") {
    for (const name of knownCategories()) if (!categoryReserved(name) && !(name in (settings.categories || {}))) addPreferenceMapping("categories", name, "");
  }
  $("add-category").hidden = section === "categories";
  preferencesDirty = false;
  status("preferences-status", "");
  $("preferences-dialog").showModal();
}

const splitKeywords = (value) => [...new Set(value.split(",").map((part) => part.trim()).filter(Boolean))];

function readPreferences() {
  const result = structuredClone(preferencesOriginal);
  const selected = document.querySelector("#preferences-fields > section.active")?.dataset.section;
  if (selected === "budget") {
    result.salary = Number($("preferences-salary").value);
    result.account_owners = splitKeywords($("preferences-owners").value);
  }
  if (selected === "fixed") {
    result.fixed_expenses_items = [...$("preferences-fixed").children].map((row) => {
      const values = [...row.querySelectorAll("input")].map((input) => input.value);
      const original = (preferencesOriginal.fixed_expenses_items || []).find((item) => item.name === values[0]);
      const keywords = original && (original.keywords || []).join(", ") === values[2] ? original.keywords || [] : splitKeywords(values[2]);
      return { name: values[0].trim(), amount: Number(values[1]), keywords };
    });
    if (new Set(result.fixed_expenses_items.map((item) => item.name.toLowerCase())).size !== result.fixed_expenses_items.length) throw Error("Commitment names must be unique");
  }
  for (const [section, , , key] of preferenceSections) {
    if (section !== selected) continue;
    const pairs = [...$(`preferences-${section}`).children].map((row) => {
      const inputs = row.querySelectorAll("input");
      const name = inputs[0].value.trim(), rawValue = inputs[1].value, value = rawValue.trim();
      const old = preferencesOriginal[key]?.[name];
      return [name, section === "categories" ? Array.isArray(old) && old.join(", ") === rawValue ? old : splitKeywords(value) : section === "accounts" && old && typeof old === "object" ? { ...old, holder: value } : value];
    });
    if (section === "special") {
      const unique = new Map();
      for (const [name, label] of pairs) {
        const previous = unique.get(name.toLowerCase());
        if (previous && previous[1] !== label) {
          const error = Error(`“${name}” already has the label “${previous[1]}”. Edit that rule or use a different description.`);
          error.name = "RuleConflict";
          throw error;
        }
        if (!previous) unique.set(name.toLowerCase(), [name, label]);
      }
      result[key] = Object.fromEntries(unique.values());
      continue;
    }
    if (new Set(pairs.map(([key]) => key.toLowerCase())).size !== pairs.length) throw Error("Each rule or account must have a unique name");
    result[key] = Object.fromEntries(pairs);
  }
  return result;
}

async function savePreferences(event) {
  event.preventDefault();
  if (preferencesSaving || mutationPending || !$("preferences-form").reportValidity()) return;
  preferencesSaving = mutationPending = true;
  $("preferences-fields").disabled = $("save-preferences").disabled = $("close-preferences").disabled = true;
  try {
    const next = readPreferences();
    await invoke("save_budget", { settings: next, expected: preferencesExpected });
    const onSaved = preferencesSaved;
    preferencesSaved = null;
    preferencesDirty = false;
    $("preferences-dialog").close();
    await reload("Saved");
    if (onSaved) onSaved(next);
  } catch (error) { status("preferences-status", errorText(error), true); }
  finally {
    preferencesSaving = mutationPending = false;
    $("preferences-fields").disabled = $("save-preferences").disabled = $("close-preferences").disabled = false;
  }
}

async function closePreferences() {
  if (preferencesSaving || (preferencesDirty && !(await ask("Discard changes?", "Discard")))) return;
  preferencesSaved = null;
  $("preferences-dialog").close();
}

$("open-preferences").addEventListener("click", () => openPreferences());
for (const item of document.querySelectorAll("[data-pref]")) item.addEventListener("click", () => openPreferences(item.dataset.pref));
$("preferences-form").addEventListener("input", () => { preferencesDirty = true; });
$("preferences-form").addEventListener("submit", savePreferences);
$("close-preferences").addEventListener("click", closePreferences);
$("preferences-dialog").addEventListener("cancel", (event) => { if (event.target !== event.currentTarget) return; event.preventDefault(); closePreferences(); });
for (const [button, section] of [["add-account", "accounts"], ["add-category", "categories"], ["add-vendor", "vendors"], ["add-special", "special"]]) {
  $(button).addEventListener("click", () => { addPreferenceMapping(section); preferencesDirty = true; });
}
$("add-fixed").addEventListener("click", () => { addFixedPreference(); preferencesDirty = true; });

$("bulk-form").addEventListener("submit", (event) => {
  event.preventDefault();
  if (!snapshot || mutationPending || !$("bulk-form").reportValidity()) return;
  const pattern = $("bulk-pattern").value.trim();
  if (!pattern) return;
  const rows = selectedPayments().filter((row) =>
    row.payee.toLocaleLowerCase().includes(pattern.toLocaleLowerCase()) && (!$("bulk-only-other").checked || PennyReports.uncategorized(row, settings)));
  const category = knownCategories().find((name) => categoryKey(name) === categoryKey($("bulk-category").value)) || $("bulk-category").value.trim();
  bulkDraft = { expected: snapshot.settings, settings: structuredClone(settings), targets: rows.map((row) => ({ id: row.id, revision: row.revision })), category };
  if ($("bulk-remember").checked) {
    bulkDraft.settings.categories = { ...bulkDraft.settings.categories };
    const keywords = bulkDraft.settings.categories[bulkDraft.category] || [];
    bulkDraft.settings.categories[bulkDraft.category] = [...new Set([...keywords, pattern])];
  }
  $("bulk-summary").textContent = `${rows.length} → “${bulkDraft.category}”`;
  $("bulk-matches").replaceChildren(...rows.map((row) => node("p", `${row.date} · ${row.payee} · ${formatAmount(row.amount, row.currency)}`, "supporting")));
  $("bulk-preview").hidden = false;
  $("bulk-form").hidden = true;
  status("bulk-status", "");
});
$("bulk-cancel").addEventListener("click", () => { bulkDraft = null; $("bulk-preview").hidden = true; $("bulk-form").hidden = false; });
$("bulk-apply").addEventListener("click", async () => {
  if (!bulkDraft || mutationPending) return;
  mutationPending = true;
  $("bulk-apply").disabled = $("bulk-cancel").disabled = true;
  try {
    const count = await invoke("save_budget", bulkDraft);
    bulkDraft = null;
    $("bulk-preview").hidden = true;
    $("bulk-form").hidden = false;
    await reload(`${count} payments categorized`);
  } catch (error) { status("bulk-status", errorText(error), true); }
  finally { mutationPending = false; $("bulk-apply").disabled = $("bulk-cancel").disabled = false; }
});
