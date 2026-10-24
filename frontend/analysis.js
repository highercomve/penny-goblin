"use strict";

const reportColors = ["#2d6a4f", "#8bbf5f", "#d29a3c", "#4f8a8b", "#c26b4f", "#7d6b9e", "#6b737f", "#b5a980"];

function variablePayments(rows) {
  return rows.filter((row) => !PennyReports.special(row, settings) && !row.category.startsWith("Fixed:") && !PennyReports.fixedItem(row, settings));
}

function renderAnalysis(rows, calendarMonths = 1) {
  const variable = variablePayments(rows);
  const accounts = PennyReports.group(variable, (row) => accountLabel(row.account));
  const total = PennyReports.sum(variable);
  const chart = $("account-chart");
  chart.replaceChildren();
  const donut = node("div", undefined, "donut-chart");
  donut.setAttribute("role", "img");
  donut.setAttribute("aria-label", "Variable spending by account; amounts are listed below");
  let position = 0;
  const slices = accounts.map((item, index) => {
    const start = position;
    position += total ? Number(item.amount * 10000n / total) / 100 : 0;
    return `${reportColors[index % reportColors.length]} ${start}% ${position}%`;
  });
  donut.style.background = slices.length ? `conic-gradient(${slices.join(",")})` : "var(--surface-high)";
  donut.append(node("span", money.format(total)));
  chart.append(donut);
  accounts.forEach((group, index) => {
    const row = reportRow(group.name, group.amount, `${total ? Number(group.amount * 1000n / total) / 10 : 0}%`, () => showGroup(group.name, group.rows));
    const dot = node("span", undefined, "legend-dot");
    dot.style.background = reportColors[index % reportColors.length];
    row.prepend(dot);
    chart.append(row);
  });
  // Medians use the range's months with any recorded payment, so months before
  // the ledger begins do not pull a category's typical month towards zero.
  const months = [...new Set(rows.map((row) => row.date.slice(0, 7)))].sort();
  const byMedian = $("category-measure").value === "median";
  const categories = PennyReports.group(variable, (row) => row.category).map((item) => ({ ...item, total: item.amount, median: PennyReports.monthlyMedian(item.rows, months) }));
  if ($("chart-fixed").checked) {
    for (const item of settings.fixed_expenses_items || []) categories.push({ name: item.name, total: BigInt(item.amount) * BigInt(calendarMonths), median: BigInt(item.amount), rows: null });
  }
  for (const item of categories) item.amount = byMedian ? item.median : item.total;
  categories.sort((a, b) => a.amount > b.amount ? -1 : a.amount < b.amount ? 1 : a.name.localeCompare(b.name));
  $("category-chart").replaceChildren(...categories.map((item) => {
    const detail = !item.rows ? (byMedian ? "Planned a month" : "Planned") : byMedian ? `${item.rows.length} payments · total ${money.format(item.total)}` :
      months.length > 1 ? `${item.rows.length} payments · median ${money.format(item.median)} a month` : `${item.rows.length} payments`;
    const row = reportRow(item.name, item.amount, detail, item.rows ? () => showGroup(item.name, item.rows) : null);
    const bar = node("span", undefined, "data-bar");
    bar.style.width = `${categories[0]?.amount ? Number(item.amount * 10000n / categories[0].amount) / 100 : 0}%`;
    if (!item.rows) bar.classList.add("planned");
    row.append(bar);
    return row;
  }));
  const comparison = $("comparison-mode").value === "combined" ? [{ name: "All accounts", rows: variable, amount: total }] : accounts;
  $("account-comparison").replaceChildren(...comparison.map((account) => {
    const panel = node("section", undefined, "comparison-panel");
    panel.append(node("h3", account.name), node("p", `${account.rows.length} payments · ${money.format(account.amount)}`));
    panel.append(...PennyReports.group(account.rows, (row) => row.category).map((group) => reportRow(group.name, group.amount,
      `${account.amount ? Number(group.amount * 1000n / account.amount) / 10 : 0}%`, () => showGroup(`${account.name} · ${group.name}`, group.rows))));
    return panel;
  }));
  const special = rows.filter((row) => PennyReports.special(row, settings));
  $("special-payments").replaceChildren(...special.map((row) => reportRow(`${row.date} · ${row.payee}`, BigInt(row.amount), String(PennyReports.special(row, settings)), () => openEditor(row))));
  if (!special.length) $("special-payments").append(node("p", "None this period.", "supporting"));
}

function reportDocument(all) {
  // Totals and groups in CLP, as the budget; every payment is listed in its currency.
  const rows = all.filter(isClp);
  const report = PennyReports.monthly(rows, settings);
  const doc = document.implementation.createHTMLDocument("Penny Goblin · Expense report");
  doc.documentElement.lang = "en";
  const charset = doc.createElement("meta"); charset.setAttribute("charset", "utf-8"); doc.head.prepend(charset);
  const viewport = doc.createElement("meta"); viewport.name = "viewport"; viewport.content = "width=device-width,initial-scale=1"; doc.head.append(viewport);
  const style = doc.createElement("style");
  style.textContent = "body{font:15px sans-serif;color:#233e34;max-width:1100px;margin:40px auto;padding:0 20px}h1,h2{font-family:Georgia,serif}table{border-collapse:collapse;width:100%;margin:20px 0}th,td{padding:10px;text-align:left;border-bottom:1px solid #ddd}td:last-child{text-align:right}small{color:#657469}@media print{body{margin:0}thead{display:table-header-group}tr{break-inside:avoid}}";
  doc.head.append(style);
  doc.body.append(node("h1", "Penny Goblin · Expense report"), node("p", `${insightsLabel()} · ${$("account-filter").selectedOptions[0].textContent}`), node("p", `Actual spending ${money.format(report.actual)} · ${rows.length} payments`));
  const range = insightsRange();
  if (range.from === range.through && !$("account-filter").value) doc.body.append(node("p", `Salary ${money.format(report.salary)} · actual remaining ${money.format(report.actualRemaining)} · legacy forecast ${money.format(report.legacyForecast)}`), node("small", "Forecast = salary − planned fixed − variable − special payments. Planned commitments are not actual payments."));
  const table = (headers, data) => {
    const result = doc.createElement("table"), head = doc.createElement("thead"), body = doc.createElement("tbody"), tr = doc.createElement("tr");
    headers.forEach((text) => tr.append(node("th", text))); head.append(tr);
    for (const values of data) { const row = doc.createElement("tr"); values.forEach((text) => row.append(node("td", text))); body.append(row); }
    result.append(head, body); return result;
  };
  for (const [title, key] of [["Categories", (row) => row.category], ["Accounts", (row) => accountLabel(row.account)], ["Merchants", (row) => PennyReports.merchant(row.payee, settings)]]) {
    doc.body.append(node("h2", title), table([title, "Payments", "Actual CLP"], PennyReports.group(rows, key).map((group) => [group.name, String(group.rows.length), money.format(group.amount)])));
  }
  doc.body.append(node("h2", "Recorded payments"), table(["Date", "Payee", "Account", "Category", "Notes", "Amount"], all.map((row) => [row.date, row.payee, accountLabel(row.account), row.category, row.notes, formatAmount(row.amount, row.currency)])));
  return "<!doctype html>\n" + doc.documentElement.outerHTML;
}

function setupAnalysis() {
  for (const id of ["chart-fixed", "comparison-mode", "category-measure"]) $(id).addEventListener("change", () => snapshot && render());
  $("export-report").addEventListener("click", async () => {
    if (!snapshot) return;
    $("export-report").disabled = true;
    try {
      const rows = insightsPayments();
      const saved = await invoke("export_report", { html: reportDocument(rows) });
      status("report-status", saved ? "Report saved" : "Cancelled");
    } catch (error) { status("report-status", errorText(error), true); }
    finally { $("export-report").disabled = false; }
  });
}
