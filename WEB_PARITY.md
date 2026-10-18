# Web dashboard reference

Inspected the running original application at `http://localhost:8000` using
the collaborative browser's Playwright controls on 2026-10-16. The original
Python application and its data files were not edited.

| Original behavior | Native status |
| --- | --- |
| Latest statement month by default; all-month and card filters | Implemented; imported history has 10 months, latest August 2026 |
| Salary, fixed commitments and remaining budget | Imported settings displayed; actual remaining and original forecast formula labeled separately |
| Cardholder/category totals and transaction drilldowns | Implemented as accessible rows opening the filtered ledger |
| Chain/brand vs exact merchant description | Original merchant aliases reused; imported custom mappings retain priority |
| Merchant search, category filter, spend/count/name sorting | Implemented |
| Search transactions by description/cardholder/card/category/merchant | Implemented; also searches notes and bank reference |
| Uncategorized audit | Implemented as a review list with ordinary expense editing |
| Fixed commitments planned vs paid | Implemented; plans never become transactions |
| Category/cardholder percentage charts | Implemented with bundled CSS charts and accessible amount/percentage rows |
| Per-card category comparison and special-payment table | Implemented as dedicated card/category comparisons and special-payment review |
| Bulk keyword categorization, vendor/settings editors | Implemented with settings conflict checks and reviewed atomic bulk categorization |
| PDF uploads and processing; report generation | Implemented with original parser in a bundled desktop helper; source observations and explicit reconciliation; Android queues PDFs; standalone HTML report export |

The web app's “total spending” excludes fixed and special payments. Native
“actual spending” includes every payment once; the monthly budget panel also
shows variable, fixed and special subtotals. Its legacy forecast preserves the
web formula: salary minus planned fixed commitments, variable and special
payments. Forecasts apply only to a single month across all accounts.

Verified all 10 months against calculations from the running web app: actual
totals, variable spending and legacy forecasts agree. Browser interaction
checks cover month/card/search combinations, category drilldowns, merchant
grouping/search and the 11-payment August uncategorized audit. Ledger search
does not change period totals. Responsive checks at 393px and 1280px show no
horizontal overflow. Three focused report arithmetic/mapping tests pass with
`node --test scripts/reports.test.cjs`.

Parity expansion is implemented in source. Native desktop launches with settings and reports. The packaged helper and statement-domain tests pass synthetic fixtures; full native statement-picker-to-review acceptance and updated Android parity installation remain to verify before claiming complete runtime parity.
