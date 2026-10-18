# Penny Goblin desktop and Android plan

Updated: 2026-10-16. Implementation status: desktop builds and runs with a shared scan-first interface and tray; ledger/migration tests and Android arm64 type checks pass. A real model passed a synthetic voucher check. Pixel 8 and real screenshot accuracy remain unverified. See [TODO.md](TODO.md) for progress.

## Compiled Oriel renderer — 2026-10-17

The app now has an optional `-Drenderer=oriel` path using `.oriel` views and
Zig controllers. It shares the existing commands, ledger, scanner and sync
implementation. WebKit remains the default during acceptance. See
[ORIEL_PORT.md](ORIEL_PORT.md) for the converter workflow and verification.

## Goal and scope

Build a desktop household budget application using Zig and Oriel's WebKit renderer, and an Android companion for a Pixel 8. Both applications have their own SQLite database, work offline, and eventually synchronize over the home network through a password-protected desktop HTTP API. Photos of receipts and Bci/Santander transfer screenshots are extracted with local AI on both desktop and phone, then reviewed and recorded as expenses. Scanning generates the entry; the user checks and confirms it.

Keep the existing Python web application, CLI, statement importers, configuration, and personal data intact. All new application code lives under `native/`. Existing web features remain available throughout this work; full native feature parity is a separate acceptance gate.

## Existing behavior and migration constraints

- Santander credit card and checking-account PDF imports currently rebuild `finance_tracker/data/transactions.json`.
- The web app supports cardholder/category/merchant breakdowns, keyword categorization, vendor mappings, salary, fixed expense budgets, date filters, and HTML reports.
- Checking-account parsing excludes transfers to self, credit-card repayments, and credit-line repayments to avoid double-counting.
- Existing transaction rows lack stable IDs and source-document provenance. Repeated imports and overlapping statements therefore need explicit reconciliation in the new ledger.
- Fixed expense budgets and actual payments must stay separate. A cleaning payment must not be subtracted twice through its transaction and its planned budget.
- Do not silently replace the existing budget formula during migration: preserve legacy results for comparison and explicitly label actual spending and budget forecasts in the new application.

## Architecture

Use a single Oriel application project for desktop and Android, sharing the Zig ledger/domain code and responsive frontend. Use platform-specific integration only for operating-system concerns.

| Layer | Responsibility |
| --- | --- |
| `src/core/model.zig` | Stable transaction IDs, calendar and monetary validation, shared record types |
| `src/core/ledger.zig` and `schema.sql` | SQLite persistence, revisions, evidence, deletion tombstones, atomic writes |
| `src/core/legacy.zig` | Additive migration from the current web application's data shape |
| `src/main.zig` | Oriel commands, request serialization, app-data database location |
| `src/vision.zig` | Local receipt extraction through Oriel llama.cpp and mtmd |
| `frontend/` | Shared responsive desktop/phone interface, capture and review |
| Future sync module | Ordered changes, operation deduplication, conflicts, transport and pairing |
| Android integration | Share intents and scheduled background sync |

Use `/home/projects/personal/oriel` as the local framework dependency during development. The installed CLI was rebuilt from that checkout and updated to 0.17.2. Reference integration patterns from `/home/projects/personal/ghostpen`, `ghostfile`, and `ghostpantry`. Pin a reproducible framework dependency before distributing builds.

Keep the existing Santander PDF parser rather than rewriting it alongside the ledger. The first migration uses a read-only export helper. Later, integrate a packaged desktop import helper with document/row provenance and the same ledger import pipeline. Android can queue statement documents for desktop parsing; it must clearly distinguish queued documents from imported transactions.

## Financial data invariants

1. One real payment corresponds to one transaction. A receipt, screenshot and bank-statement row are evidence for that payment, not separate spending.
2. Store CLP amounts as integers and validate dates and text at the backend boundary. Additional currencies require an explicit model and accounting decision.
3. Preserve extracted observations separately from user corrections, including document provenance and extraction/model version.
4. Importing the same document or replaying a sync operation must be idempotent.
5. Date, payee and amount alone cannot prove duplication: legitimate identical payments must remain possible.
6. Reimporting statements must not erase manually added transactions, overwrite corrections, or resurrect deletions.
7. Save domain changes and their synchronization bookkeeping atomically.
8. Concurrent edits must produce a visible conflict rather than silently overwrite financial data.
9. Both devices own local SQLite files. Synchronize records and attachment content; never copy a live database between devices.

The initial legacy importer derives deterministic identities from date, card, raw description, amount and occurrence number. This makes repeated exports additive while preserving identical rows. It cannot establish identities across changed bank descriptions or resolve overlapping legacy statements; those cases need provenance and reconciliation review.

## Capture and local AI

Capture flow on both desktop and Android: camera or photo library/file selection → automatic local extraction → generated entry for review → atomic local save with evidence after confirmation → later synchronization. Scanning is the primary entry path. Manual forms are a fallback, and optional accounting details are shown separately.

Desktop closes to a tray with Open Penny Goblin, Scan payment voucher, Enter expense manually and Quit actions. Tray actions preserve an open draft. Explicit Quit exits; if tray creation fails, closing exits. Linux requires a tray host. Background running alone is not synchronization or autostart.

Extract total amount, currency, payment date/time, merchant or recipient, transaction reference, bank, and location only when explicitly printed. Never infer a physical location from a transfer screenshot or a service category from a person's name. Keep manual entry available if the model is absent, extraction fails, or a field is uncertain.

The supplied examples are acceptance fixtures:

- Santander: CLP 40,000 to Gladys Carvajal Rojas on 2026-10-10 at 10:23.
- Bci: CLP 40,000 to Johana Castañeda on 2026-10-14 at 17:13.

User-confirmed recipient mappings can suggest house cleaning or childcare on future payments. These mappings are not implemented yet.

The initial vision code supports importing a compatible GGUF model and matching vision projector, running bounded CPU inference through Oriel, schema-constrained JSON, cancellation, and freeing the model after each scan. A model catalog/download flow, performance tuning, and extraction quality require separate work and Pixel 8 validation. Do not assume that system Gemini Nano image support is available on this phone.

## Reconciliation

- Hash source documents to recognize exact repeated imports.
- Give imported statement observations stable source-document and row identities.
- Link evidence automatically only for trustworthy exact identities, such as appropriately scoped bank references.
- Offer candidate matches using account, currency, amount, date and payee; require review for ambiguous cases.
- Preserve corrections, notes and evidence when linking a later statement row to a captured expense.
- Support undoing mistaken links. Do not add a date/amount uniqueness constraint.

## Synchronization and security

The desktop coordinates an application-level sync protocol. Each client persists outgoing operations with unique IDs. The server accepts retries idempotently, checks expected revisions, assigns ordered changes, and serves incremental pulls using a saved cursor. Preserve deletion tombstones and handle expired history with a full-resync path that retains unsent edits.

Synchronize transactions, evidence links, document metadata/attachments, accounts, categories, vendor/recipient rules, budgets and other shared settings. Clearly define authoritative revisions and conflict resolution before exposing writes to another device. The existing local change table is only a foundation; it is not a complete sync protocol or durable outbox.

Expose the HTTP API over HTTPS. Use password-based initial pairing, revocable device credentials, certificate identity verification/pinning, secure credential storage, bounded requests, and authenticated attachment access. Keep secrets out of logs. Do not expose the existing unauthenticated web server as the new sync service.

Pair once, then reconnect automatically on the same LAN or over Tailscale using the same pinned desktop identity and revocable device credential. The desktop advertises LAN reachability and offers its Tailscale address as an additional route; route changes never establish new trust. Desktop explicitly
opens a short pairing window and displays a QR code containing its endpoint,
certificate fingerprint and a random single-use pairing secret. A manual
pairing-code path provides the same identity check. Redeeming a secret creates
a distinct revocable device credential; expired or reused secrets fail.
Store the phone credential with Android Keystore protection and pin the paired
desktop certificate. LAN discovery only locates a candidate endpoint and never
changes the trusted identity. Certificate replacement requires explicit
re-pairing. Network reachability changes, app opening, scheduled background
work and a manual action trigger incremental sync with retry/backoff. A permanent
socket is unnecessary: Android may suspend background execution. Show connected,
offline/queued, last success and actionable errors without interrupting capture.

Android background sync uses WorkManager with network constraints, retries and backoff, plus sync when opening the app and a manual action. Verify the paired desktop's identity regardless of network name. Use local discovery where supported and a saved address as fallback. Oriel currently lacks Linux mDNS registration and Android share receiving, so these need explicit integration.

Android scheduling is best effort. A sleeping or stopped desktop cannot receive data. Provide a desktop background-service lifecycle and show last successful sync, queued changes, conflicts and errors.

## Delivery milestones

### 1. Shared local ledger and migration

Implement SQLite schema, backend validation, stable IDs, optimistic revisions, atomic evidence saves, deletion tombstones and additive legacy import. Verify repeated imports, legitimate identical payments, rollback on invalid input, and preservation of edits/deletions. Add the shared UI and prove local expense create/edit/delete on desktop and Android.

### 2. Capture and on-device extraction

Wire camera/gallery capture and compatible model import to extraction and review. Store the reviewed expense and original evidence atomically. Exercise manual correction, cancellation, failed extraction and duplicate-image handling. Validate the two sample screenshots and real receipts on Pixel 8.

### 3. Desktop statement imports and feature parity

Connect the existing PDF parser through an isolated import helper. Preserve source provenance and exclusions. Add reconciliation review, recipient/category/vendor rules, budget management, cardholder and merchant analysis, date filtering, reports, and all existing supported workflows. Bundle frontend resources for offline use.

### 4. Secure bidirectional synchronization

Implement the versioned protocol, durable operation queue, server, pairing, device revocation, incremental pulls, conflicts, tombstones, attachments and full resync. Prove convergence across independent SQLite databases and interrupted/replayed requests.

### 5. Android background integration and packaging

Add share-sheet receipt intake, WorkManager scheduling, home-network discovery/address fallback and desktop background lifecycle. Build desktop packages and an Android APK. Test on Pixel 8, including process death, offline edits, reboot, Wi-Fi changes and unavailable desktop.

## Acceptance gates

- The original web application and its data continue to work unchanged.
- Desktop and Android build from the shared project and operate offline.
- Legacy import preserves existing totals/settings and is safe to repeat.
- Capture an expense offline, correct it, restart the app, and retain the transaction and evidence.
- Import either supplied transfer screenshot as one reviewed CLP 40,000 expense.
- Later import its statement and retain one expense with both sources attached.
- Two genuinely separate same-date/same-amount payments remain separate.
- Interrupted import/save/sync cannot leave partial spending or lose pending changes.
- Concurrent edits are visible; deletions remain deleted after offline clients reconnect.
- After sync, phone and desktop show the same records, settings and evidence.
- Unauthorized clients cannot read or mutate financial data or attachments.

## Verification and limits

Run focused Zig ledger/migration tests, desktop builds, Android cross-target checks and a real Android build. Exercise the actual UI and transport with two databases. Compilation alone does not validate extraction accuracy, background scheduling, packaging, or physical-device behavior.

Current work covers a verified local backend and an initial scan-first frontend. Real-model synthetic extraction and browser review-flow checks are separate proofs. Synchronization, statement reconciliation, Android runtime behavior, real bank screenshot accuracy and packaged applications must not be represented as delivered until their acceptance gates pass.


## Desktop research-assisted categorization

Approved workflow: select uncategorized (blank/Other) variable payments, apply
existing deterministic rules first, group remaining descriptions by merchant,
then use a local desktop text model with bounded research tools. Propose only
existing categories or abstain. Review evidence and affected payments before
any write. Send only merchant/country context to online search, never financial
amounts, accounts, receipts or the ledger. No automatic new rules or categories.

### Implemented in desktop 0.2.0

Payments → Research categories opens the same review workflow in WebKit and
compiled Oriel views. The current payment filters determine the input. Android can start and resume the same workflow on its paired desktop (0.2.1). Each
batch groups up to ten merchants; saved category rules run first. Suggestions
can be changed to another existing category or left unchanged. All retained
sources expand for review and can be opened in the system browser. Resolve the
current suggestions before the next batch; reviewed abstentions do not block
later merchants. Closing a draft asks before discarding it.

Categorization has its own device-local model choice, independent of the receipt
scanner. Download the recommended Qwen3.5 9B Q4_K_M (5.7 GB, pinned revision and
SHA-256), or choose a compatible instruction GGUF. Downloads resume and can be
cancelled. One model/context is loaded for the whole research batch and freed
on success, error or cancellation. Inference currently uses up to eight CPU
threads, an 8192-token context, six tool turns per merchant and a twenty-minute
model deadline. Browser requests have their own bounded timeout. Scanner and
research inference share a lock to avoid loading both models simultaneously.

The host constructs merchant/country search queries, removes numeric identifier
and email tokens, validates schema-constrained tool calls and existing category
choices, and treats page text as untrusted evidence. Missing or blocked evidence
produces an abstention for manual review. There is no CAPTCHA bypass or promise
that every website/search will be accessible.

The embedded Python helpers run an ephemeral WebKitGTK session without app IPC
or database access. Fixed isolated-world extraction exposes bounded text and
numbered links. The model cannot supply JavaScript, shell commands or arbitrary
search queries. Popups, permissions and downloads are denied. HTTPS traffic goes
through a local CONNECT proxy restricted to public destinations on port 443;
it resolves and pins destination addresses, rejecting private/mixed results.
TLS certificate failures are not bypassed.

Research never writes expenses. Apply rechecks the saved settings, category
membership, uncategorized eligibility, duplicate IDs and exact expense revisions
inside one transaction. Categories and sync bookkeeping commit together, or the
entire operation rolls back. Conflicts retain the draft. Applying does not change
amounts, accounts, notes, receipt data or category rules.

### Requirements and verification

This feature currently runs on Linux desktop builds with local model support
(`-Dvision=true`, the default), system `/usr/bin/python3`, PyGObject, GTK4 and
WebKitGTK 6 installed. Both renderer builds embed the helper scripts, but the
GI/WebKit runtime remains a system dependency. Android uses the paired desktop for research; it does not load the research model locally.
The recommended model was tested with about 6.2 GB process RSS; allow additional
memory for the desktop and application. Other GGUF files must be supported by
the bundled llama.cpp runtime.

Verification uses private Xvfb/D-Bus displays and synthetic expenses, without
opening the user's desktop or production ledger:

```sh
rtk proxy /usr/bin/python3 native/scripts/research_browser_test.py
rtk proxy /usr/bin/python3 native/scripts/research_network_test.py
rtk proxy /usr/bin/python3 native/scripts/research_ui_test.py
# From native/:
rtk proxy zig build test
rtk proxy zig build test-ui -Drenderer=oriel
rtk proxy zig build build-research-verifier -Drenderer=webview
```

The real-model acceptance runner reviews ten synthetic merchants, including a
live Decathlon search/navigation with Qwen3.5 9B, and verifies that the model
mapping is gone before the process exits. The desktop application acceptance
checks zero writes before Apply, exact category/revision/sync changes afterward,
unchanged financial fields and SQLite integrity. Domain tests exercise stale
revision rollback, duplicate selections, settings conflicts and query filtering;
controller tests cover editable review, Back/cancellation and conflict retention.

### Paired-phone research — 0.2.1

The Android Research categories entry uses the existing pinned-TLS pairing
credentials over LAN or Tailscale. The desktop must run 0.2.1 with synchronization
enabled and its categorization model configured. Model setup remains on desktop.
The phone can start/resume, follow progress and activity, cancel, review every
source, change categories and explicitly Apply. The log shows model stages,
merchant-only search queries, navigation URLs and concise decision explanations.
It does not expose hidden inference traces or promise token-by-token streaming.

Desktop-owned jobs continue through brief phone disconnects. Polling resumes the
same device's running job or retained review. Reviews are kept in memory for up
to an hour and are lost on service restart. Jobs are bounded to sixteen paired
owners and one remote inference worker at a time. Cancellation terminates the
worker process group (including browser children), freeing the model. A kernel
file lease also prevents simultaneous local and remote model loads. Linux
parent-exit signals stop workers and browser helpers if their owner dies.

All job routes authenticate the paired device before reading input. Job IDs are
scoped to their owner. Apply accepts only targets from that owner's retained
review, reuses the domain's atomic revision/settings checks and sync bookkeeping,
and remembers the successful request to make retries idempotent. A conflict
keeps the review. Normal sync then delivers committed categories to the phone.
No changes are written during research, and results never auto-apply.

Focused remote tests: `native/.helper-venv/bin/python
native/scripts/research_jobs_test.py` covers authenticated routing, owner
isolation, resume, event cursors, cancel/release, subsequent batches, review
target validation and idempotent Apply. `research_remote_acceptance.py APP MODEL`
uses a real desktop worker/model and private synthetic SQLite data. WebKit and
compiled controller tests exercise the phone review and activity presentation.
