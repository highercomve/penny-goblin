"use strict";

let categoryManaging = false;
let categorySource = null;
let categoryExpected = "";
let categoryNames = [];
let categoryDraft = null;
let categorySaving = false;
const categoryKey = (name) => name.trim().replace(/\s+/g, " ").toLowerCase();
function similarCategory(x, y) {
  const a = categoryKey(x), b = categoryKey(y);
  if (Math.min(a.length, b.length) < 4 || Math.abs(a.length - b.length) > 1) return false;
  let i = 0, j = 0, edits = 0;
  while (i < a.length && j < b.length) {
    if (a[i] === b[j]) { i++; j++; continue; }
    if (++edits > 1) return false;
    if (a.length >= b.length) i++;
    if (b.length >= a.length) j++;
  }
  return edits + a.length - i + b.length - j <= 1;
}
const categoryReserved = (name) => categoryKey(name) === "other" || categoryKey(name).startsWith("fixed:");
function updateCategoryChoice() {
  $("category-value").textContent = form.elements.namedItem("category").value || "Other";
}
function knownCategories() {
  return [...new Set(["Other", ...snapshot.expenses.map((row) => row.category), ...Object.keys(settings.categories || {}), ...(settings.fixed_expenses_items || []).map((item) => `Fixed: ${item.name}`)])].sort((a, b) => a.localeCompare(b));
}
function openCategoryPicker(manage = false) {
  if (!snapshot || mutationPending || $("category-picker").open) return;
  categoryManaging = manage;
  categoryExpected = snapshot.settings;
  categoryNames = knownCategories();
  $("category-title").textContent = manage ? "Manage categories" : "Choose category";
  $("category-rules").hidden = !manage;
  $("category-search").value = "";
  categoryBrowse();
  $("category-picker").showModal();
  $("category-search").focus();
}
function categoryBrowse() {
  categorySource = null;
  categoryDraft = null;
  $("category-browse").hidden = false;
  $("category-edit").hidden = true;
  status("category-status", categoryManaging ? "Choose a category to rename or merge" : "Select an existing category or search to add one");
  renderCategoryList();
}
function renderCategoryList() {
  const query = categoryKey($("category-search").value);
  const exists = categoryNames.some((name) => categoryKey(name) === query);
  const similar = exists ? [] : categoryNames.filter((name) => similarCategory(name, query));
  const matches = categoryNames.filter((name) => categoryKey(name).includes(query) || similar.includes(name));
  status("category-status", similar.length ? `Similar category: ${similar[0]}. Select it, or add a separate category.` : categoryManaging ? "Choose a category to rename or merge" : "Select an existing category or search to add one");
  $("category-list").replaceChildren(...matches.slice(0, 100).map((name) => {
    const button = node("button", undefined, "category-list-row");
    button.type = "button";
    const count = snapshot.expenses.filter((row) => row.category === name).length;
    const content = node("span", undefined, "category-row-copy");
    content.append(node("span", name));
    if (categoryManaging) content.append(node("span", `${count} payments`, "supporting"));
    const selected = !categoryManaging && name === form.elements.namedItem("category").value;
    button.classList.toggle("selected", selected);
    if (!categoryManaging) button.setAttribute("aria-pressed", String(selected));
    button.append(content, node("span", categoryManaging ? "›" : selected ? "✓" : "", "category-trailing"));
    button.addEventListener("click", () => categoryManaging ? editCategory(name) : chooseCategory(name));
    return button;
  }));
  if (!matches.length) $("category-list").append(node("p", "No matching categories", "supporting"));
  else if (matches.length > 100) $("category-list").append(node("p", "Showing 100 · search to narrow the list", "supporting"));
  $("category-add").hidden = !query || exists || categoryReserved(query);
  $("category-add").textContent = `Add “${$("category-search").value.trim()}”`;
}
function chooseCategory(name) {
  form.elements.namedItem("category").value = name;
  updateCategoryChoice();
  form.dispatchEvent(new Event("input", { bubbles: true }));
  $("category-picker").close();
}
function editCategory(name) {
  if (categoryReserved(name)) { status("category-status", "Other and fixed commitments are managed separately."); return; }
  categorySource = name;
  categoryDraft = null;
  $("category-browse").hidden = true;
  $("category-edit").hidden = false;
  $("category-source").textContent = name;
  $("category-target").value = name;
  $("category-summary").textContent = "";
  $("category-apply").hidden = true;
  $("category-target").focus();
}
async function saveCategory(change, targets = []) {
  if (categorySaving || mutationPending) return;
  categorySaving = mutationPending = true;
  for (const control of $("category-picker").querySelectorAll("button, input")) control.disabled = true;
  try {
    await invoke("save_budget", { settings: {}, expected: categoryExpected, targets, category_change: change });
    if (categoryManaging) $("category-picker").close();
    else chooseCategory(change.target);
    await reload("Category saved");
  } catch (error) { status("category-status", errorText(error), true); categoryDraft = null; $("category-apply").hidden = true; }
  finally {
    categorySaving = mutationPending = false;
    for (const control of $("category-picker").querySelectorAll("button, input")) control.disabled = false;
  }
}
function categoryBack(event) {
  event?.preventDefault();
  if (categorySaving) return;
  if (categorySource !== null) categoryBrowse();
  else $("category-picker").close();
}
$("choose-category").addEventListener("click", () => openCategoryPicker());
$("category-back").addEventListener("click", categoryBack);
$("category-picker").addEventListener("cancel", categoryBack);
$("category-search").addEventListener("input", renderCategoryList);
$("category-target").addEventListener("input", () => { categoryDraft = null; $("category-apply").hidden = true; });
$("category-add").addEventListener("click", () => saveCategory({ target: $("category-search").value.trim().replace(/\s+/g, " ") }));
$("category-edit").addEventListener("submit", (event) => {
  event.preventDefault();
  const target = $("category-target").value.trim().replace(/\s+/g, " ");
  if (!target || target === categorySource || categoryReserved(target)) { status("category-status", "Enter a different category name.", true); return; }
  const existing = categoryNames.find((name) => name !== categorySource && categoryKey(name) === categoryKey(target));
  if (existing && existing !== target) { status("category-status", `Use the existing spelling: ${existing}`, true); return; }
  const targets = snapshot.expenses.filter((row) => row.category === categorySource).map((row) => ({ id: row.id, revision: row.revision }));
  categoryDraft = { change: { source: categorySource, target }, targets };
  $("category-summary").textContent = `${existing ? "Merge" : "Rename"} “${categorySource}” → “${target}”. ${targets.length} payments across all dates. Keyword rules are kept.`;
  $("category-apply").hidden = false;
  status("category-status", "Review the change before applying");
});
$("category-apply").addEventListener("click", () => { if (categoryDraft) saveCategory(categoryDraft.change, categoryDraft.targets); });
$("category-rules").addEventListener("click", () => closeThen($("category-picker"), () => openPreferences("categories", true)));
