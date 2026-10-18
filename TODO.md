# Penny Goblin native implementation checklist

Updated: 2026-10-16.

**Status:** desktop builds and runs with an offline scan-first interface and tray. Nine ledger/migration tests pass; a real web export passed count/total/settings/reimport comparison. Android arm64 checks pass with vision enabled and disabled. A real Qwen3.5 2B model passed a synthetic transfer-voucher check. Native scan-to-review-to-save with a synthetic voucher and tray hide/reopen/Quit pass. Real screenshot accuracy and complete edit/delete runtime acceptance remain unverified. The APK builds and is installed on the connected POCO M2007J20CG (Android 12); Pixel 8 behavior remains unverified. The Python web app has not been modified.

Checked implementation items describe completed source work. Verification and its limits are recorded separately below. Architecture and acceptance conditions are in [PLAN.md](PLAN.md).

## Setup and isolation

- [x] Inspect current extraction, budgeting, web endpoints and data ownership.
- [x] Create a separate `native/` Oriel application project.
- [x] Leave existing Python web app, configuration and financial data untouched.
- [x] Read Oriel's local framework documentation and example applications.
- [x] Rebuild Oriel CLI from `/home/projects/personal/oriel` and install version 0.17.2.
- [x] Point the native project's dependency at the local Oriel checkout.
- [x] Write architecture plan and implementation checklist.
- [x] Replace generated template README with actual build/use instructions.
- [x] Add native build/database/model/export ignore rules.
- [ ] Pin a reproducible Oriel dependency before distributing builds.

## Shared SQLite ledger — focused tests pass

- [x] Define expense types, stable IDs, CLP integer amounts, and date/text validation.
- [x] Add versioned SQLite schema with expenses, documents, evidence, settings and change records.
- [x] Add atomic expense writes and evidence linking.
- [x] Add optimistic revision checks for edits and deletion.
- [x] Add deletion tombstones and prevent reimport resurrection.
- [x] Hash decoded image content and reject linking the same image to a second expense.
- [x] Expose ledger operations through shared Oriel commands.
- [x] Locate the database in the application's private data directory.
- [x] Serialize database access across async commands.
- [x] Compile and resolve all Zig/API errors.
- [x] Pass focused ledger tests.
- [x] Verify file-backed restart persistence, evidence/settings/tombstones and stale writes across independent connections.
- [ ] Verify simultaneous async command behavior in the native runtime.
- [x] Document closed-app database backup/restore precautions and schema downgrade rejection.
- [ ] Add in-app safe backup/export/restore and migration rollback tooling.
- [ ] Define account identity beyond the legacy card label.
- [ ] Persist source observation provenance and extraction/model version independently of corrections.

## Existing-data migration — tests and real export comparison pass

- [x] Add read-only `scripts/export-web-data.py` using the existing web app's data loader.
- [x] Add additive legacy import of transactions and initial budgets/rules/mappings.
- [x] Use deterministic row identities with occurrence counts to retain identical legitimate rows.
- [x] Preserve user edits and deletion tombstones on reimport.
- [x] Wrap the import in a transaction so an invalid row rolls back the batch.
- [x] Write tests for repeated imports, corrections, tombstones and rollback.
- [x] Pass migration tests, including real export numeric formats and legacy configuration forms.
- [x] Compare imported counts/totals/settings with the existing web app without logging financial data.
- [x] Wire file import and clear import-result/error reporting into the UI.
- [x] Document limitations when overlapping legacy statements lack provenance.

## Shared desktop/Android interface — initial scan-first implementation

- [x] Build responsive offline frontend with bundled assets and accessible controls.
- [x] Add ledger listing, month filters, search and empty states.
- [ ] Add arbitrary date-range filters.
- [x] Add manual expense create/edit/delete and revision-conflict handling.
- [x] Add receipt capture, gallery selection, extraction review and manual correction.
- [x] Display saved evidence and extraction details.
- [ ] Add budget/settings management and imported account labels.
- [x] Show actual payments without subtracting planned fixed expenses again.
- [x] Add separately labeled budget forecasts using the imported web formula, beside actual remaining.
- [ ] Preserve category, cardholder, vendor and merchant analysis workflows.
- [x] Add clear loading/error/cancellation states and prevent accidental double submissions.
- [x] Open the frontend with the real Zig backend in isolated native WebKit.
- [x] Verify browser scan-first behavior: automatic extraction, generated fields, explicit save confirmation, retained drafts on failure and responsive layout (simulated bridge).
- [ ] Complete native UI create/edit/delete, evidence and restart acceptance on both platforms.

## Local receipt AI — builds and synthetic real-model check pass

- [x] Use Oriel's llama.cpp + mtmd interfaces rather than adding another inference runtime.
- [x] Add receipt/transfer extraction schema and Chilean amount/date instructions.
- [x] Add model and matching projector import using the native file picker.
- [x] Add bounded CPU inference, cancellation flag and per-scan resource cleanup.
- [x] Keep extraction separate from saving the reviewed expense.
- [x] Compile the vision-enabled build and verify exact current Oriel APIs.
- [x] Wire model import, capture and review UI.
- [ ] Verify missing/incompatible models, cancelled imports and damaged images fail clearly.
- [ ] Validate allocation/resource failure cleanup and image size limits.
- [x] Run a synthetic Bci-style transfer voucher through local Qwen3.5 2B Q4_K_M and matching projector; verify amount/currency/date/payee without saving.
- [ ] Run both supplied Bci/Santander screenshots and real receipt fixtures through a model.
- [ ] Measure accuracy, memory, latency and battery impact on Pixel 8.
- [ ] Select/document a compatible model and projector, licensing and secure download/import process.
- [ ] Add user-confirmed recipient mappings for cleaning and childcare.

## Statements and duplicate reconciliation — not implemented

- [ ] Integrate existing Santander PDF parser through an isolated packaged desktop helper.
- [ ] Preserve original PDFs and stable per-document/per-row provenance.
- [ ] Retain exclusions for internal transfers and debt repayments.
- [ ] Make repeated PDF imports idempotent.
- [ ] Reconcile receipt/screenshot evidence with statement observations.
- [ ] Review ambiguous candidates; never deduplicate solely by date and amount.
- [ ] Preserve notes and corrections when evidence is linked.
- [ ] Make mistaken evidence links reversible.
- [ ] Handle queued statement uploads from Android without pretending they are parsed locally.

## Secure record-level synchronization — not implemented

- [ ] Specify protocol version, authoritative revisions and conflict semantics.
- [ ] Add durable outgoing operation queue and globally unique operation IDs.
- [ ] Apply operations and acknowledgements transactionally and idempotently.
- [x] Add desktop HTTP API over HTTPS with bounded authenticated requests.
- [x] Implement password pairing, certificate identity verification and device credentials. (QR/link pairing; certificate pin; per-device revocable bearer token)
- [x] Store credentials securely; add revocation and brute-force protection. (Android Keystore; desktop stores token hashes; per-IP pairing rate limit)
- [ ] Pull ordered changes with durable per-peer cursors.
- [ ] Synchronize settings/rules/accounts as well as transactions and evidence.
- [ ] Transfer attachments by content hash with safe retry behavior.
- [x] Preserve concurrent edits as visible conflicts.
- [x] Propagate tombstones without resurrecting deleted records.
- [ ] Add full-resync/recovery while retaining unsent local edits.
- [ ] Test replay, interruption, process death and convergence with independent databases.
- [x] Verify unauthenticated clients cannot access records or documents.

## Android and desktop lifecycle — desktop tray implemented; Android integration pending

- [x] Generate and build Android project from the shared Oriel app.
- [ ] Implement Android share-sheet image intake, following Ghostfile's pattern.
- [ ] Add WorkManager network constraints, retry/backoff and process-independent sync.
- [x] Trigger sync on app opening and offer a manual action.
- [ ] Implement desktop discovery where supported and saved-address fallback.
- [ ] Verify server identity rather than trusting an SSID.
- [x] Add desktop tray: Open, Scan payment voucher, manual fallback and Quit; close hides the window, with exit fallback if tray creation fails.
- [x] Retain early tray quick actions and preserve an open draft.
- [x] Verify tray quick action, native Hide to tray, tray reopen and Quit in isolated WebKit/Xvfb.
- [ ] Verify the window-manager close button and tray behavior on installed desktop targets.
- [ ] Keep the future desktop sync service available with explicit lifecycle controls (tray running alone is not sync).
- [x] Display pending changes, last sync, conflicts and errors on both devices.
- [ ] Test home Wi-Fi arrival, reboot, battery restrictions and an unavailable desktop on Pixel 8.

## Build and acceptance proof

- [x] `zig build test -Dvision=false --summary all`: 9/9 tests pass.
- [x] Desktop application builds with the WebKit renderer.
- [x] Android cross-target check passes.
- [ ] Android arm64 APK builds and installs on Pixel 8.
- [ ] Create/edit/delete expenses offline and retain data after restart on both platforms.
- [ ] Both screenshots produce reviewed CLP 40,000 expense candidates.
- [ ] Capture offline → sync → later statement import results in one expense with both sources.
- [ ] Repeated imports/retried syncs do not duplicate spending.
- [x] Legitimate identical payments remain separate.
- [ ] Conflicting offline edits and deletions resolve without silent data loss.
- [ ] Original web app and statement workflows still run unchanged.
- [x] Document delivered behavior, commands, remaining limitations and test evidence.

## Verification record — 2026-10-16

- Fixed the ledger name-shadowing compile error; LLVM/LLD handles the host GCC 16 relocation incompatibility for test/verifier executables.
- `zig build` succeeds with vision enabled; `zig build -Dvision=false` also succeeds.
- `zig build check -Dtarget=aarch64-linux-android` passes, with and without vision. This is not an APK or device test.
- `verify-legacy` imports a real read-only web export into memory and confirms counts, whole-CLP totals, settings and repeat-import idempotency without printing values.
- `verify-scan` runs a real model on an isolated synthetic voucher. Browser checks separately simulate extraction to exercise scan selection → generated review → explicit save and evidence submission. Real bank screenshots remain an acceptance gate.
- Native WebKit opens against a fresh isolated database; D-Bus tray menu/action dispatch works in a private Xvfb session. Real native scan → generated review → confirmation persisted one expense, original image, extraction and change record. Hide to tray, reopen and Quit passed. Restart with the renamed Penny Goblin binary retained the payment and displayed its saved image and extraction.

- [x] Rename the displayed app, executable and package name to Penny Goblin; initially preserve the legacy ID to retain local data (superseded by the complete 0.2.3 identity migration).
- [x] Install an original transparent goblin/receipt logo and 1024-pixel application/tray icon.
- [x] Check Google Play searches in US/Chile: no exact Penny Goblin listing observed on 2026-10-16; this is not reservation or trademark clearance.
- [x] Fix the native WebKit extraction reply by transferring generated JSON as a scalar string; native generated fields and confirmed evidence save passed.

- [x] Restart the desktop after scanning/saving; reopen the generated payment and display its original voucher and extraction.

### Real-data migration and connected Android — 2026-10-16

- Added `zig build import-web -- export.json ledger.sqlite3`, reusing the application’s atomic additive importer.
- Imported 1,553 existing web payments and initial budget/account/category/vendor settings into the desktop application’s private ledger. Verified persisted count, exact CLP total, SQLite integrity and no-op reimport. Original web files remain unchanged. Private exports are ignored by Git.
- Android release and debug APKs build using installed Gradle 8.13 (system Gradle 9.8 is incompatible with AGP 8.13.2). Installed the signed debug APK on authorized device `ae82807d`, POCO M2007J20CG, Android 12.
- Seeded the previously empty phone app’s private storage with a consistent SQLite backup; all payment rows and settings match desktop. The phone UI displays 1,553 payments. This is an initial USB migration, not synchronization. No existing device ledger was replaced.
- Desktop rebuilt with the revised friendly line goblin logo. Ledger/migration tests still pass (9/9).

### Monthly dashboard and web comparison — 2026-10-16

- Ran the original web app on loopback and inspected its month/card filters, merchant search/grouping/sorts, category drilldowns, fixed tracking and audit views using the collaborative browser’s Playwright tools. Full inventory: [WEB_PARITY.md](WEB_PARITY.md).
- Native now defaults to the latest statement month and displays month/account selectors, actual totals, imported monthly salary, actual remaining and a separately labeled legacy forecast. Added category/account/merchant drilldowns, merchant aliases/search/category/sorting, ledger category/sorting, fixed planned-vs-paid and uncategorized review.
- All 10 imported months match the running web app’s actual totals, variable spending and legacy forecast. Three report arithmetic/mapping tests pass. Browser checks verify matching month/card/search results, the 11-payment August audit, drilldowns and no horizontal overflow at 393px/1280px.
- Budget/rule editing, dedicated card comparison/special tables, original chart types and PDF/report workflows remain pending; this is not full web parity.

- Installed the monthly-dashboard APK update in place on the POCO. Native screenshot confirms latest-month selector, imported cardholder choices and the August 194-payment summary. SQLite integrity and all 1,553 payments remain intact after update.
- Real Android month interaction passed: selected July 2026 through the native selector and confirmed its 170-payment count matches desktop; restored August afterwards.

### Parity expansion and sync foundation — in progress

- Added budget/rules/account/owner editors with optimistic settings checks and atomic bulk categorization; 13 ledger/settings/statement tests passed before new sync protocol tests. Added recipient keyword suggestions only from saved rules.
- Added custom date ranges, card/category comparisons, charts, special-payment review and standalone HTML export. Browser checks verify unchanged settings retain imported keyword arrays exactly.
- Embedded the preserved Santander parser in a self-contained 35 MB desktop helper, packaged beside the app. Synthetic valid and damaged PDF checks pass against source and frozen helper. Original Python application stays unchanged.
- Added statement source storage, immutable observations, idempotent review, explicit linking/ignore decisions, source export and reversible unlink. Android queues statements for desktop parsing.
- Backed up the real desktop ledger before schema upgrade; reimport added zero payments and preserved all 1,553 while bringing in the previously omitted account-owner setting. Desktop app opened locally with the expanded dashboard.
- Schema v3 now includes transactional sync intent/outbox/base/change/conflict tables and triggers. Shared Zig record/protocol work is in progress; pairing, network transport, Android background sync and real-device convergence are not delivered yet.
- User requires one secure pairing working over LAN and Tailscale, automatic reconnection, then a finished APK served through Tailscale for downloads only (no financial dashboard on that server).

### Real desktop ↔ phone pairing and sync — 2026-10-16

- End-to-end test over real TLS on copies of both real ledgers (`/tmp/penny-e2e-scripts/e2e.py`): unauthenticated and bad-token requests get 401; a wrong pairing secret, or one reused by another device, is rejected; retrying the same pairing after a lost reply is idempotent; a revoked device gets 401. After edits on both sides, a concurrent conflict and explicit resolutions, both copies hold 1,554 identical rows with equal totals.
- Fixed: settings validation capped category keywords at 100, but the imported web rules have a category with 108. This blocked choosing the desktop version of a budget conflict, and saving these settings in Budget & rules. The cap is now 1,000, with a regression test (18/18 tests pass).
- Fixed: pairing links were rejected when the keyboard auto-capitalized the scheme (`Pennygoblin://`). Scheme and host now match case-insensitively; the paste field disables autocapitalize/autocorrect.
- Android engine now emits sync events only when something changed. Unexpected pairing failures log only the exception class and code location.
- Real devices: desktop app restarted on the new binary (real ledger migrated v3→v4; backups in `exports/*-before-sync-*.private.sqlite3`). The POCO paired over LAN via the paste-link path, typed over ADB. Initial sync converged 1,553 payments; the only conflict was the expected budget conflict (desktop has the newer `account_owners`), resolved with "Use desktop version". Both real ledgers are identical: 1,553 payments, same total, 0 pending, 0 conflicts, integrity ok.
- Live propagation: a CLP 1 payment created on the phone reached the desktop within 5 s; its deletion on the phone reached the desktop as a tombstone (not counted as spending). After an in-place APK update, the phone reconnected automatically with its Keystore credential.
- Not yet verified on device: the camera QR scan (ZXing), phone over Tailscale (the phone's Tailscale app was off; the desktop's Tailscale IP serves the pinned certificate), live desktop→phone edits (covered by the e2e test), background WorkManager sync with the app closed, and mDNS discovery.
- APK download: Tailscale Serve is disabled for this tailnet, so a user service `penny-goblin-download` (`python3 -m http.server`) binds only to 100.114.119.39:8088. It serves `~/.local/share/penny-goblin-download/`: debug-signed APK, SHA-256 checksum and index; the downloaded hash was verified. It's a transient `systemd-run --user` unit, so it does not survive reboot.
- Fixed: tapping "Scan desktop pairing QR" crashed the app (`lateinit property hooks has not been initialized`). Oriel constructs separate SyncExtension instances for extension calls and Android hooks, so the request-code context and pending scan now live in a shared companion object; scanner launch failures are reported instead of crashing the UI thread. On the POCO the camera permission prompt and the ZXing scanner open, and backing out reports "Pairing cancelled." A real camera scan of the desktop QR still needs a person in front of both screens.

### Material redesign — 2026-10-16

- Replaced the website-style sidebar layout with a Material 3 style shell: top app bar, bottom navigation (Home · Payments · Insights · Settings) on phones and a navigation rail on wide windows, Scan extended FAB, full-screen dialogs on phones, snackbars, system light/dark theme. Copy reduced to short labels. All element IDs kept, so existing logic is unchanged (`frontend/nav.js` adds navigation).
- Settings is a list; each budget/rules section opens its own page (saving still writes the whole validated settings document). Statements and scanner model moved to their own settings pages.
- Android back closes the top dialog (running its unsaved-change confirmation), then returns to Home; verified with the real back key on the POCO.
- Verified in a browser at 393 px and 1280 px (no horizontal overflow) and on the POCO with screenshots of every screen; 18/18 Zig tests and 4/4 report tests pass.
- Pixel 8 paired remotely over Tailscale with a pasted link and synced all records. Fixed: pasted links with inserted line breaks/spaces failed with a generic error (now normalized; malformed links report "incomplete link").
- Fixed: on the Pixel's fresh install, reopening the app showed `SqlitePrepare` with an empty dashboard. `Ledger.open` read `user_version` before setting `busy_timeout`, so a lock briefly held by the Android sync worker's connection failed the first schema read. The timeout is now set first, each migration re-checks the version so concurrent first opens are safe, and the UI retries one failed initial load. Regression test holds an exclusive lock from another thread (fails without the fix; 19/19 pass). Three POCO cold starts loaded all records.
- Statements queued on a phone now finish without visiting the desktop: the desktop window polls the sync change counter (new `changes` field in sync status), refreshes when phones send records, and parses queued statements automatically (once per session; failures are reported). Parsed rows sync back to phones for review. Verified with a real statement uploaded from the Pixel: desktop parsed 240 rows, the POCO received it as ready to review.
- Statement review preselects "Same as…" only for an existing payment identical in date, amount, bank description and account, each suggested once; the user still confirms. For this statement all 240 rows matched the web app's earlier import. Not confirmed on the user's behalf.
- Adding a PDF that is already stored (same content, e.g. downloaded twice) now says "Already added as … · ready to review" instead of silently doing nothing. Verified on the POCO with the user's duplicate download.
- Fixed: phones stopped syncing once a statement PDF (~90 KB) arrived inside a sync batch. SQLite spilled the savepoint journal to a temp file, Android apps cannot write SQLite's default temp directories, SQLite rolled the transaction back, and every retry failed (`SqliteExec`, generic "desktop unavailable" in the UI). `Ledger.open` now sets `temp_store=MEMORY` (asserted in tests). The POCO, stuck at change 1926, caught up to 2222 and matches the desktop (422 statement rows, 1,553 payments, equal totals). Sync failures now log the error code, action and SQLite message (never record values) under the `PennySync` tag.
- Fixed (root cause of the recurring Pixel `SqlitePrepare` blank dashboard): on Android, Oriel runs `main` on a thread; closing the app window (e.g. swiping it away) ends `main` while background sync keeps the process alive, and reopening runs `main` again. The cleanup closed the cached ledger connection but left the stale handle, so every later query failed until the process died. Cleanup now clears the handle (and the tray/quick-action state) under the command mutex. Reproduced on the POCO by closing the main window and reopening in the same process (pid unchanged): failed before, three close/reopen cycles load all records after; a payment created and deleted after reopening synced both ways. Earlier lock/temp fixes remain valid but were not this bug.
- Fixed expenses now follow the web app: the Home budget card shows the monthly fixed plan ($3.070.000) with the amount paid, and "Left this month" = salary − planned fixed − variable − special (fixed payments not subtracted twice; August matches the web app's $699.180 before the newly imported late-August purchases). Tapping Fixed opens a list of every commitment with its monthly amount, paid amount and matched payments, with Edit → Fixed commitments.

### Receipt scanner models — 2026-10-16

- Settings → Receipt scanner: Gemini Nano through `oriel.system_ai` where the phone supports it (POCO reports unavailable with the platform's reason), a pinned Hugging Face catalog (Qwen3.5 0.8B/2B, Qwen2.5-VL 3B, Gemma 3 4B, Gemma 4 E2B on phones; Qwen3.5 4B and Gemma 4 E4B on desktop) with resumable SHA-256-verified downloads, progress, cancel, delete and "Use", plus "Use your own GGUF". The choice is per device (`scanner-choice`, not synced); without one, the system model, then any installed model, then imported files are used.
- Fixture results (desktop, same prompt): Qwen3.5 2B and Qwen2.5-VL 3B read the boleta and transfer voucher correctly; Gemma 4 E2B correct except the boleta payee; Gemma 3 4B correct except the boleta date; Qwen3.5 0.8B misses dates; SmolVLM2 500M/2.2B misread amounts and were left out.
- On the POCO: downloaded 0.8B (70 s) and 2B (4 min) through the UI; 2B scanned the boleta correctly in 2 min 21 s (draft discarded).
- Fixed: prompt examples leaked into answers ($40.000, Santander); schema now caps string lengths, fixes date/time formats and pins CLP; replies' Chilean dates normalized and impossible dates dropped; repetition penalty stops loops; micro-batch 512 (Gemma 3 aborted the process with 128).
- Pending: Gemini Nano untested on a supported phone; Pixel 8 timings; app icon is hard to see on Android launchers (user, 2026-10-16).

### Android/desktop AI build flags and performance — 2026-10-17

- Build: ggml CPU kernels use ARM dotprod (Oriel's Android default; both test phones support it; i8mm would refuse the POCO X3). ggml/llama C++ is compiled optimized with sanitizers off in every mode. No GPU backends: the GPU doesn't make scans faster, so vision runs on the CPU everywhere. Hexagon NPU not applicable (Tensor G3 has none; SD732G's Hexagon is older than llama.cpp's backend supports).
- POCO X3, Qwen3.5 2B, boleta fixture: threads 2/4/8 → 138/143/126 s (now all cores, capped at 8); flash attention + q8 KV: no gain; image tokens 384 lost the date (kept 1024); Q4_0 no faster at image reading and thrashed memory during generation (keep Q4_K_M); Adreno 618 failed ggml's GPU self-test (CPU fallback).
- Desktop RTX 4070 via Vulkan: 21 s vs 15 s CPU (per-scan model load rebuilds pipelines), so "Use GPU" defaults off and appears only when a GPU passes the self-test.
- Free RAM decides phone scan time: with ~2 GB available (3 GB of other apps in swap) a 2B scan took 16 min with mmap (page re-reads) and over 12 min with weights read into RAM (zram swap); with memory free it took 126–143 s. Kept mmap (faster load). Phones with 6 GB should close other apps or use a smaller model.
- Loading UX: global top progress indicator with message for every long task; scans report real backend stages (loading/reading/writing) and estimate progress from the device's last measured stage durations; the scan screen shows only the voucher with a scan-line animation and Cancel.
- Payment form: Account is now a main field (not under More details), a list of cards labelled number · owner (e.g. 9526 · Sergio) from Settings → Accounts plus any account used in the ledger; new payments default to the last account used, and an unset account must be chosen before saving.

### Fast scan investigation — 2026-10-17

- GhostPantry's "fast" has two parts: an LLM fast mode (image tokens 64–512, shorter output, resident model) and "fast local matching" (YOLOE detector + EmbeddingGemma via LiteRT, no LLM). The receipt equivalent of the latter is on-device OCR + field extraction.
- Desktop evidence: RapidOCR read the boleta in 0.46 s and the voucher in 0.22 s; a rule prototype (TOTAL/Monto line, DD/MM/YYYY date, Destinatario or first capitalised business line, N°/Operación reference) extracted all four key fields correctly from both in <1 ms. LLM over OCR text: 8.0 s vs 15.2 s for the image path on desktop (558 prompt tokens, ~400 of them the fixed instructions) but missed the date and picked the seller.
- `vision.extractText` + `analyze_text` command and `PENNY_TEXT` in verify-scan exist for this measurement.
- Proposed: Android ML Kit Text Recognition (bundled, offline) as a "pennygoblin.ocr" extension; fast mode = OCR + rules with per-field confidence, falling back to the model (image path) when amount/date/payee are not all found. Not yet implemented or measured on a phone.
- Receipt scanner page now groups On this device (use/delete), Download, and Your own model (load/use/delete); Settings lists it under Scanning.
- Fixed (in Oriel's Android template, android/template/.../OrielActivity.kt): the app never appeared in Recents. OrielLaunchActivity copied the launcher intent, including FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS (its own excludeFromRecents), onto the main window's task. The flag is now removed; task flags went 0x10a00000 → 0x10200000 and the POCO's Recents shows Penny Goblin. Window title shortened to Penny Goblin.
- Recents (Oriel template): main windows now also clear their own task's excludeFromRecents on create/new intent (`ActivityManager.AppTask.setExcludeFromRecents(false)`), repairing tasks created before the launch fix (singleTask reuses them; a hidden task can't be swiped away). Reproduced on the POCO by starting with flags 0x10a00000: hidden before, shown after. Rebuilt Breakout, Render Bench, Showcase and Little Jam with both fixes; all APKs (same debug signer) are on the download page, whose links now carry a content hash so browsers can't serve a cached old APK.

### Compiled Oriel renderer — 2026-10-17

- [x] Add optional `-Drenderer=oriel`, keeping WebKit as the default.
- [x] Convert the shell, rows and dialogs with Oriel's native DOM export tool.
- [x] Verify 34 desktop/phone and light/dark computed-property references.
- [x] Port navigation, editor/evidence, filters/pagination, reports, settings,
  statement reconciliation, scanner setup and pairing/sync UI into Zig.
- [x] Preserve stale-write checks, dirty drafts, settings expectations and bulk
  confirmation; test capture-first/manual fallback and Scan hit testing.
- [x] Add category bars, account donut and comparison panels with drilldown.
- [x] Verify ten months of reporting totals and all 1,553 merchant names against
  the unchanged web JavaScript; 34 domain tests and 29 view tests pass.
- [x] Check desktop runtime with synthetic data on a private display, including
  editor centering, Payments, Insights, Settings and 393 px phone layout.
- [x] Fix Oriel exporter/compiler issues found by this app (variant-only nodes,
  rgba shadows and SVG icon theme paint); framework suite: 658 pass, 3 skipped.
- [ ] Physical-phone acceptance of compiled camera/scan/save, pairing and sync.
- [x] Add native scan sweep/global progress and verify core Android scan/review/save states.
- [ ] Complete reduced-motion/timing/fade presentation refinements and physical-phone visual acceptance.
- [ ] Pin and distribute the Oriel framework changes with a reproducible build.

Build commands, converter adaptations and limitations: [ORIEL_PORT.md](ORIEL_PORT.md).
No production APK or installed app has been replaced by the compiled port.

### Insights parity correction — 2026-10-17

- Replaced handwritten report/category rows and comparison panels with exports
  of the actual web builders; 112 responsive/theme property references pass.
- Restored the 168 px donut, center total, eight-color legends and percentages;
  removed extra View buttons, restored merchant averages, planned bar colors,
  and direct special-payment editing. Shared action buttons center their text.
- Account labels include card numbers, keeping different cards with one owner
  separate. Added a focused Insights geometry/action regression test.
- Compared synthetic phone-sized browser and Oriel screenshots in both themes.


### Oriel parity and Android acceptance — 2026-10-18

- Receipt scan → review → account selection → save → reopen, original photo,
  binary preview/saved evidence and extraction disclosure work in the private
  Android emulator. OCR returned 44 lines and a complete text-only result.
- Fixed retained reply-buffer ownership and Android hidden-field initialization;
  the default category survives field creation and saved IDs remain valid.
- Exported repeated settings/scanner/statement/evidence/budget components with
  desktop, phone and compact phone themes. Restored the web date/bulk disclosures,
  filter scrolling, 600-row list bound, calendar labels and evidence avatar colors.
- Category suggestions, inline bulk preview, settings draft lifetime, fixed-payment
  drilldown and scanner deletion confirmation have controller coverage.
- Compiled pasted-link pairing and sync were exercised against an isolated TLS
  service: 2 payments, total 128374 CLP, 1 receipt, 0 pending/conflicts, integrity OK.
- Domain tests: 34 passing. Latest controller suite: 29 passing. Property checks:
  112 captured variants. Native controls still use platform rendering; physical
  camera and phone acceptance are not implied by emulator checks.
- Switch track/border/thumb colors and checked thumb position match the web
  stylesheet in both themes.
- Remaining presentation/framework follow-ups: reduced-motion propagation,
  persisted scan timing and completion fade, and pinning the local framework
  dependency. See ORIEL_PORT.md for current checks and build instructions.

- [x] Publish Oriel 0.1.2 arm64 APK; verify signer, native library and served SHA-256.
- [ ] Investigate GTK account-filter label disappearing after desktop-to-phone resize.

### Android Back navigation — 2026-10-18

- [x] Route compiled platform Back through sheet closing and unsaved-change protection.
- [x] Back cancels the current confirmation without losing its draft.
- [x] Top-level Settings/Payments/Insights return to Home before Android can leave.
- [x] Register the modern Android Back callback alongside legacy support.
- [x] Pass 30 controller tests and private emulator navigation/keyboard checks.
- [ ] Verify the physical phone's edge gesture with Oriel 0.1.3.

### Desktop research-assisted categorization — 0.2.0

- [x] Embed an ephemeral WebKit research browser without app IPC or ledger access.
- [x] Restrict production traffic to public HTTPS destinations through a resolving,
  address-pinning CONNECT proxy; abstain on blocked or uncertain pages.
- [x] Add bounded schema-constrained local-model tools and merchant grouping.
- [x] Separate categorization model selection/download from receipt scanning;
  recommend Qwen3.5 9B and free the model/context after every batch.
- [x] Add matching WebKit/Oriel model setup, evidence, editable review, cancellation
  and revision-safe atomic Apply with sync bookkeeping.
- [x] Support successive batches without repeatedly researching abstentions.
- [x] Verify browser fixtures, network boundary, domain/controller behavior and
  the real desktop app against synthetic SQLite data.
- [x] Run real Qwen3.5 9B research with live merchant evidence.

Current platform boundary: Linux desktop needs system PyGObject/GTK4/WebKitGTK 6;
Research runs on the paired desktop for Android; a bundled Python/GI runtime remains outside this release.
See PLAN.md for usage, safety invariants, resource bounds and verification.

### Phone-triggered desktop categorization — 0.2.1

- [x] Reuse pinned pairing/authentication for desktop-owned start/poll/cancel/apply.
- [x] Retain owner-scoped jobs across phone disconnects; bound jobs and lifetimes.
- [x] Expose stage/merchant/search/navigation activity and decision summaries.
- [x] Enable the shared review in Android WebKit and compiled .oriel views.
- [x] Keep model setup/inference on desktop; prevent overlapping model loads.
- [x] Preserve preview-only research and atomic, revision-safe explicit Apply.
- [x] Make Apply retries idempotent and validate targets against retained review.

Both desktop and phone require the updated app for this protocol.

- [x] Verify the real Qwen3.5 9B paired-job worker streams activity/sources and
  applies the synthetic ledger once across retries.
- [x] Verify worker termination and inference-lease release on service-parent exit.
- [x] Keep the phone activity log bounded and scrollable above the review.

### Application identity — 0.2.3

- [x] Use com.pennygoblin.app on all platforms and rename Kotlin/JNI namespaces.
- [x] Verify APK identity, provider authorities, JNI exports and desktop builds.
- [x] Back up and migrate desktop data, preserving ledger/model/sync identity.
