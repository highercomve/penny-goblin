# Compiled Oriel renderer

The optional `-Drenderer=oriel` build uses compiled `.oriel` views and Zig
controllers, with the existing ledger, scanner, statement and synchronization
commands. The WebKit frontend remains available and is the default.

## Build and checks

From `native/`:

```sh
zig build run -Drenderer=oriel
zig build test-ui -Drenderer=oriel -Dvision=false --summary all
zig build test -Dvision=false --summary all
zig build check -Drenderer=oriel -Dvision=false -Dtarget=aarch64-linux-android
zig build check -Drenderer=webview -Dvision=false
```

`-Drenderer=native` selects Oriel's HTML/CSS/JavaScript native renderer. It is
the converter's source renderer; `oriel` selects compiled views with no JS UI.
The existing `-Dnative_ui=true` flag still selects the HTML/JS native renderer.

## HTML/CSS/JavaScript conversion

The current CLI has no `convert` subcommand. Oriel's documented conversion
workflow exports the live native DOM and its computed CSS to `.oriel` markup
and property references. `scripts/export-oriel.js` drives the existing app with
a synthetic fixture; it does not open or modify the user's ledger.

```sh
zig build -Drenderer=native -Dvision=false -p /tmp/penny-native-export
XDG_DATA_HOME=/tmp/penny-export-data \
XDG_CONFIG_HOME=/tmp/penny-export-config \
ORIEL_NUI_EXPORT="$PWD/views" \
ORIEL_NUI_EXPORT_SCRIPT="$PWD/scripts/export-oriel.js" \
GSK_RENDERER=cairo /home/projects/personal/oriel/scripts/headless.sh \
  timeout 60 /tmp/penny-native-export/bin/penny-goblin

cd /home/projects/personal/oriel
zig build check-views -Dzig_ui=true \
  -Dviews=/home/sergiom/Code/tarjeta/native/views
```

Conversion covers the application shell, payment row, editor, preferences,
fixed commitments, statements, statement review, scanner and synchronization.
There are 112 reference variants covering desktop, phone and compact phone
layouts in light/dark themes, including the repeated web components.
`check-views` compares their compiled computed properties to the captured
native HTML renderer properties. It is not a pixel comparison with WebKit.

The export script replaces grid layouts with equivalent flex wrapping and
places the fixed FAB under a stable parent. The HTML native renderer introduces
anonymous grid rows and reparents fixed elements; a compiled view needs a
stable tree across responsive variants. These adaptations only affect export.
Dynamic lists are empty templates, filled by Zig controllers. File selection,
calendar defaults, event handlers, reporting and other JavaScript behavior are
ported explicitly; exporting markup does not translate arbitrary JavaScript.

Handwritten reusable components live beside generated views. The exporter
rewrites only its named views, property references, index and image assets.
The current CLI formatter rejects `<style>` contents, including when built
from the local checkout; use compiler/property checks for these views until
the formatter supports the markup compiler's stylesheet grammar.

## Behavior and ownership

`src/oriel_frontend.zig` owns the snapshot, navigation, filtering, the bounded payment list,
editor and evidence. `src/oriel_tools.zig` owns settings, reports, statement
review, scanner setup and pairing/synchronization UI. Periodic status replies
have bounded-lifetime arenas separate from modal drafts. Editor generations
ignore old evidence/default replies. Mutation replies clear only their owning
operation. Settings preserve optimistic concurrency expectations and unchanged
imported keyword arrays; bulk edits require preview and explicit Apply.

`src/core/reporting.zig` ports the web reporting formula using integer CLP.
`scripts/report-oracle.cjs` runs the unchanged web reporting/merchant code over
an export; `verify-reports` compares it with Zig without printing record values.
The verification covered ten months and all 1,553 merchant/exact merchant names.

Local Oriel changes required by conversion are in `oriel_export.zig` and
`oriel_markup.zig`: later-only variant nodes start hidden, parenthesized rgba
shadows parse correctly, and changing monochrome SVG paint uses `icon-color`
and `currentColor` without altering text colors. Regression and allocation
failure tests cover those cases. These framework edits live outside this repo
and must be included when pinning a reproducible Oriel dependency.

## Current verification

The Android emulator has completed the original receipt photo's text scan,
account selection, save, reopen, saved-image display and extraction disclosure
through the compiled renderer. The receipt returned 44 OCR lines with a complete
amount/date/payee result. The WebKit path remains the default build.

Controller tests cover dirty drafts and stale revisions, a 24 KB preference
field, bulk preview lifetime across dialogs, cancellation and large binary
receipt previews, preserving manual fields when attaching evidence, statement
PDF export, category suggestions, fixed-payment drilldown and scanner deletion
confirmation. The financial/domain suite has 34 passing tests; the latest controller suite
has 29 passing tests.

The port now uses the web editor's capture/review states, compact attachment
choices on existing payments, inline bulk preview, collapsible details and date
range, horizontally scrolling chips, web budget chips, formatted calendar labels,
receipt avatar colors and the web payment list's 600-row bound. Desktop Home keeps the full-width
hero/budget rows from the web grid. Global progress
and the scan sweep run on native display frames. The snackbar uses the web
colors and success/error durations. Switch tracks, borders and thumbs use the web
light/dark palette and checked-state geometry.

Framework fixes found by this app include owned binary image resources outside
bounded property strings, pointer-transparent overlays, Android field values
initialized before listeners, matching select-option measurement/drawing fonts, and the earlier scrolling, text and converter
fixes. Retained IPC replies copy strings into their owner's arena. The exporter also distinguishes clearing the entire inset override from
clearing individual sides, so desktop and phone dialog variants round-trip
without changing their property representation. These changes
are in the local Oriel checkout; this app still uses that local path dependency.
They must be included when pinning a reproducible framework dependency.

Property references compare the compiled views to the native HTML renderer's
computed properties. They do not establish pixel identity with WebKit. Visual
checks use the browser reference, a private Android emulator and a private
Xvfb display; no checks control the user's desktop. Native form controls can
retain platform-specific text/date presentation. Compiled pairing through the pasted-link UI was verified against an isolated
loopback TLS service: two payments, matching total, one receipt, zero pending
changes/conflicts and database integrity OK. Physical-phone camera and
compiled pairing/sync acceptance remain separate from emulator verification. Scan timing estimates currently persist only for the
running session; OS reduced-motion propagation and the final progress fade
remain framework/presentation follow-ups.


## Published Android build — 2026-10-18

Oriel 0.1.2 (version code 102), arm64, is available on the existing Tailscale
download server as `penny-goblin-oriel-0.1.2.apk`. The signing certificate matches
the existing app, its native library matches the final arm64 build, and the
served download SHA-256 was checked:
`afc6ddabe93557cee7a68195a3c440261137b94fb0f32a929fc9709e2afe75c9`.
The final controller suite passed 29 tests; desktop, arm64 and emulator native
builds and both Android packages passed. The final emulator Home shows the
receipt count and full month label. WebKit downloads remain available.

A final desktop resize screenshot exposed an additional GTK presentation issue:
the account filter label can disappear after resizing to phone width. Android
shows the label correctly. This needs a focused framework investigation; exact
visual parity is still pending.


## Android Back navigation — 2026-10-18

Oriel 0.1.3 (version code 103) handles the engine's platform `back` event.
Sheets use the existing close/discard path; Back on a confirmation cancels it
without discarding the underlying draft. Settings, Payments and Insights return
to Home; only the Home root yields Back to Android. Scanner setup opened from
the editor returns to that editor. In-flight protected edits consume Back.

The framework Activity registers Android 13+ OnBackInvokedCallback at default
priority, sharing the legacy Back handler while allowing the IME to dismiss
first. Registration is removed when the Activity is destroyed.

All 30 controller tests passed, including platform engine.back() coverage.
Both Android native builds and Gradle packages passed. Private API 35 emulator
checks confirmed Merchant names → Settings, discard prompting, prompt
cancellation with the draft retained, and keyboard dismissal before navigation.
The emulator's injected edge swipes did not trigger system Back, so physical
gesture acceptance remains unverified; the modern callback and Back key share
the tested path. No physical phone was controlled.

## Desktop categorization — 0.2.0

Compiled Oriel now includes Research categories from Payments, matching the
WebKit workflow: independent Qwen3.5 9B/custom GGUF setup, bounded batches,
progress/cancel, existing-category edits, every retained source with expandable
evidence, discard confirmation and atomic Apply with conflict retention. Back
during research requests cancellation; Back on a review follows draft handling.
The research sheet explicitly sits above the modal backdrop; controller tests
exercise its hit target, all source disclosures and progression to later batches.
Research runs on Linux desktop and shares the receipt scanner's inference lock
while keeping its model choice separate. See PLAN.md for runtime dependencies
and acceptance details. This addition does not establish complete visual parity
for the unrelated renderer issues recorded above.

## Paired-phone research — 0.2.1

Android now exposes Research categories through the existing compiled sheet.
It obtains model readiness from the paired desktop and hides local model setup.
The activity area displays merchant progress, actual search queries, visited
sources and decision summaries. Start resumes an existing desktop job after a
phone disconnect; Cancel stops the remote worker. Review/category edits, source
disclosures, Back/draft handling and explicit Apply use the existing controller.
Desktop 0.2.1 must be running with sync enabled and its research model ready.

## Android research entry visibility — 0.2.2

Fixed Research categories being hidden on Android: Oriel's platform enum
separates Android from Linux. Entry visibility now uses the snapshot platform
(or the target name before the snapshot arrives), matching WebKit's Linux/Android
policy. The phone controller regression checks non-hidden, nonzero-width entry
geometry before opening the sheet. Desktop 0.2.1 remains protocol-compatible.

## Application identity — 0.2.3

All builds use com.pennygoblin.app. Android Kotlin packages, JNI symbols and
R8 rules use com.pennygoblin as well. The desktop data directory migrates as a
whole with the app stopped, preserving ledger, models and sync credentials.
Android remains a new installation requiring pairing and resynchronization.

### Research view — 0.2.4

Short introduction and collapsed model/privacy details; desktop sheet widened to
860 px. The activity area keeps the current merchant, completed/total count and
received-update counter above a larger newest-first log. Start hides during a
batch and returns on success/error. Empty filtered periods never show connecting.
Controller coverage exercises routed progress messages, disclosure and completion;
WebKit phone/desktop fixtures check successive progress events and reviewed Apply.

### Discounted receipt totals — 0.2.5

Fast scanning prefers an explicit final TOTAL, accepts a bare amount split
onto the next row and never guesses the largest amount in a tax/discount
breakdown. Missing or conflicting totals fall back to inference. A reliable
OCR amount is retained when desktop/local inference fills missing fields.
The model prompt explicitly distinguishes TOTAL after discounts from SUB TOTAL
and NETO and warns against subtracting discounts twice. Regression fixtures
include ML Kit geometry from the reported Tottus receipt (435670 - 52065 = 383605),
missing/split totals and model completion that incorrectly proposes the subtotal.
