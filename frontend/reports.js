"use strict";

// Reporting never changes the reviewed ledger or creates budget transactions.
const PennyReports = (() => {
  const sum = (rows) => rows.reduce((total, row) => total + BigInt(row.amount), 0n);
  const entries = (value) => Object.entries(value || {});
  const clean = (text) => text.replace(/[^a-zA-Z0-9\s]/g, " ").trim().toUpperCase();

  function holder(account, settings) {
    const value = settings.cards_config?.[account];
    return typeof value === "string" ? value : value?.holder || account;
  }

  function merchant(payee, settings, grouped = true) {
    const match = entries(settings.vendors_config)
      .filter(([pattern, name]) => pattern && typeof name === "string" && payee.toUpperCase().includes(pattern.toUpperCase()))
      .sort((a, b) => b[0].length - a[0].length)[0];
    if (match) return match[1];
    if (!grouped) return payee.trim();
    const known = KNOWN_MERCHANTS.find((item) => item.regex.test(payee));
    if (known) return known.name;
    const stripped = payee.replace(/^(MERCADOPAGO|PAYU|PAYSCAN|TUU|WEBPAY|REDGLOBA|RED GLOBA|TRANSBANK|TBK)\s*\*?\s*/i, "").trim();
    return stripped ? stripped.toLowerCase().replace(/\b\w/g, (c) => c.toUpperCase()) : payee.trim();
  }

  function special(row, settings) {
    return entries(settings.special_cases).find(([pattern]) => pattern && row.payee.toUpperCase().includes(pattern.toUpperCase()))?.[1] || null;
  }

  function category(row, settings) {
    const label = special(row, settings);
    return label ? `Special: ${label}` : row.category;
  }
  function uncategorized(row, settings) {
    return row.category === "Other" && !special(row, settings) && !fixedItem(row, settings);
  }

  function fixedItem(row, settings) {
    const items = settings.fixed_expenses_items || [];
    // An explicitly reviewed category takes precedence over keyword guesses.
    const explicit = items.find((item) => row.category.toLowerCase() === `fixed: ${item.name.toLowerCase()}`);
    return explicit || items.find((item) => (item.keywords || []).some((keyword) => clean(keyword) && clean(row.payee).includes(clean(keyword)))) || null;
  }

  function group(rows, key) {
    const groups = new Map();
    for (const row of rows) {
      const name = key(row);
      if (!groups.has(name)) groups.set(name, { name, amount: 0n, rows: [] });
      const item = groups.get(name);
      item.amount += BigInt(row.amount);
      item.rows.push(row);
    }
    return [...groups.values()].sort((a, b) => a.amount > b.amount ? -1 : a.amount < b.amount ? 1 : a.name.localeCompare(b.name));
  }

  function monthly(rows, settings) {
    const fixed = [], specials = [], variable = [];
    for (const row of rows) {
      if (special(row, settings)) specials.push(row);
      else if (row.category.startsWith("Fixed:") || fixedItem(row, settings)) fixed.push(row);
      else variable.push(row);
    }
    const salary = BigInt(settings.salary || 0);
    const planned = (settings.fixed_expenses_items || []).reduce((total, item) => total + BigInt(item.amount), 0n);
    return {
      actual: sum(rows), variable: sum(variable), special: sum(specials), fixed: sum(fixed), salary, planned,
      actualRemaining: salary - sum(rows),
      // Preserve the previous web dashboard formula for comparison.
      legacyForecast: salary - planned - sum(variable) - sum(specials),
      commitments: (settings.fixed_expenses_items || []).map((item) => {
        const matched = fixed.filter((row) => fixedItem(row, settings) === item);
        return { name: item.name, planned: BigInt(item.amount), paid: sum(matched), rows: matched };
      }),
    };
  }

  // Median of BigInt amounts; an even count averages the two middle values.
  function median(values) {
    if (!values.length) return 0n;
    const sorted = [...values].sort((a, b) => a < b ? -1 : a > b ? 1 : 0);
    const middle = Math.floor(sorted.length / 2);
    return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2n;
  }

  // Each group's median monthly total over `months`; a month without payments counts as zero.
  function monthlyMedian(rows, months) {
    const totals = new Map(months.map((month) => [month, 0n]));
    for (const row of rows) {
      const month = row.date.slice(0, 7);
      if (totals.has(month)) totals.set(month, totals.get(month) + BigInt(row.amount));
    }
    return median([...totals.values()]);
  }

  function suggestCategory(payee, settings) {
    const fixed = fixedItem({ payee, category: "" }, settings);
    if (fixed) return `Fixed: ${fixed.name}`;
    return entries(settings.categories).find(([, words]) => words.some((word) => word && payee.toUpperCase().includes(word.toUpperCase())))?.[0] || null;
  }
  return { sum, group, monthly, median, monthlyMedian, holder, merchant, special, category, uncategorized, fixedItem, suggestCategory };
})();
