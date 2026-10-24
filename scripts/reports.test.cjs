const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const report = vm.runInNewContext(fs.readFileSync(`${__dirname}/../frontend/merchants.js`, "utf8") + fs.readFileSync(`${__dirname}/../frontend/reports.js`, "utf8") + "; PennyReports");

test("monthly accounting keeps actual payments and planned commitments separate", () => {
  const settings = { salary: 1000, fixed_expenses_items: [{ name: "Cleaning", amount: 200, keywords: ["cleaner"] }], special_cases: { FAMILY: "Family" } };
  const rows = [
    { amount: 100, category: "Food", payee: "Market" },
    { amount: 150, category: "Fixed: Cleaning", payee: "Reviewed name" },
    { amount: 50, category: "Other", payee: "Family" },
  ];
  const r = report.monthly(rows, settings);
  assert.equal(r.actual, 300n);
  assert.equal(r.actualRemaining, 700n);
  assert.equal(r.legacyForecast, 650n);
  assert.equal(r.fixed, 150n);
  assert.equal(r.special, 50n);
  assert.equal(r.commitments[0].paid, 150n);
  assert.equal(report.monthly([], settings).actual, 0n);
  assert.equal(report.monthly([], settings).legacyForecast, 800n);
});

test("reviewed fixed category takes priority; one payment belongs to one commitment", () => {
  const settings = { fixed_expenses_items: [
    { name: "Cleaning", amount: 10, keywords: ["cleaner"] },
    { name: "Childcare", amount: 20, keywords: [] },
  ] };
  const r = report.monthly([{ amount: 20, payee: "Cleaner", category: "Fixed: Childcare" }], settings);
  assert.equal(r.commitments[0].paid, 0n);
  assert.equal(r.commitments[1].paid, 20n);
});

test("group totals remain exact beyond safe Number totals; merchant mappings use longest match", () => {
  const rows = Array.from({ length: 10000 }, () => ({ amount: 1000000000000, account: "Debit" }));
  assert.equal(report.group(rows, (row) => row.account)[0].amount, 10000000000000000n);
  assert.equal(report.merchant("SHOP LOCAL", { vendors_config: { SHOP: "Generic", "SHOP LOCAL": "Local" } }), "Local");
  assert.equal(report.holder("1234", { cards_config: { "1234": "Household" } }), "Household");
  assert.equal(report.merchant("TOTTUS SUCURSAL 123", {}), "Tottus");
  assert.equal(report.merchant("TOTTUS SUCURSAL 123", {}, false), "TOTTUS SUCURSAL 123");
});

test("only saved rules suggest categories for scanned recipients", () => {
  assert.equal(report.suggestCategory("Unknown Recipient", {}), null);
  assert.equal(report.suggestCategory("Known Recipient", { categories: { Childcare: ["Known Recipient"] } }), "Childcare");
  assert.equal(report.suggestCategory("Known Recipient", { fixed_expenses_items: [{ name: "Childcare", keywords: ["Known Recipient"], amount: 100 }] }), "Fixed: Childcare");
});


test("special-payment descriptions classify historical Other rows without editing them", () => {
  const settings = {special_cases:{"TRASPASO A DEUDA NACIONAL":"USD purchases converted to CLP"}};
  const row = {date:"2026-09-09",payee:"Traspaso A Deuda Nacional",amount:232466,category:"Other"};
  assert.equal(report.category(row, settings), "Special: USD purchases converted to CLP");
  assert.equal(report.uncategorized(row, settings), false);
  assert.equal(row.category, "Other");
});

test("category medians use monthly totals, with empty months as zero", () => {
  assert.equal(report.median([]), 0n);
  assert.equal(report.median([5n, 1n, 3n]), 3n);
  assert.equal(report.median([4n, 1n, 3n, 10n]), 3n);
  const rows = [
    { date: "2026-01-05", amount: 100 }, { date: "2026-01-20", amount: 50 },
    { date: "2026-03-02", amount: 90 }, { date: "2026-04-11", amount: 400 },
  ];
  // January 150, February 0, March 90, April 400.
  assert.equal(report.monthlyMedian(rows, ["2026-01", "2026-02", "2026-03", "2026-04"]), 120n);
  assert.equal(report.monthlyMedian(rows, ["2026-01", "2026-03", "2026-04"]), 150n);
});
