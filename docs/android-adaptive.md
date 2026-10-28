# Android adaptive implementation and verification

Baseline: origin/main 00ca5b4489a110499ef57be5703e8d3716b92857, Penny Goblin 0.2.20, compiled Oriel 0.18.0 (no WebView). Assessment date: 2026-10-27.

Sources: [Tier 3](https://developer.android.com/docs/quality-guidelines/adaptive-app-quality/tier-3), [Tier 2](https://developer.android.com/docs/quality-guidelines/adaptive-app-quality/tier-2), [Tier 1 Desktop](https://developer.android.com/docs/quality-guidelines/adaptive-app-quality/experiences/desktop), updated 2026-10-21. Device evidence below is from the isolated `--test-profile` package on a ChromeOS ARC runtime. Injected keyboard/mouse events are not a substitute for physical trackpad, stylus or foldable QA; the gaps section records what could not be exercised.

## Criterion map and status

Status meanings: **device** = exercised on the ChromeOS ARC runtime with captures under `docs/evidence/android`; **tests** = automated Zig/view tests; **partial** = implemented but at least one part of the criterion could not be exercised on this hardware; **N/A** = the product has no such surface.

| Tier | Criterion | Status | Implementation and evidence |
| --- | --- | --- | --- |
| 3 | Config_Changes | device + tests | Resizable freeform activity with broad `configChanges`, live engine retained on configuration changes, durable checkpoints. `external-wide.png`/`external-restored.png` resized 960x667 → 1200x800 while a draft stayed open; `density-240.png` (density 240, scale 1.5) and `fontscale-130.png` (fontScale 1.3, scale 1.62) kept the draft and caret; `recovery-final-before.json`/`recovery-final-after.json` show PID 11855 → 13843 with `Process+death+draft` and caret 19 still focused. |
| 3 | Config_Combinations | partial | Narrow 450x850 (`narrow-450x850`), wide 1200x800 (`external-wide`), density and font-scale combinations above. No secondary display, foldable, or posture combination was available on this single-display Chromebook. |
| 3 | Multi-Window_Functionality | device | Freeform task resized to 450x850 and 1200x800; main window 960x667 alongside a second comparison task/window 515x915 (`compare-open.png`). Android's own caption handles maximize/restore; minimize/restore evidence is in `minimize-restore.png`. |
| 3 | Multi-Resume | partial | Main process 11855 and `:compare` process 12925 ran together (`adb shell ps`); a synthetic payment saved in main while `:compare` was alive, then appeared in the comparison window (`concurrent-saved.json`, `compare-payments.json`). No camera/microphone is held during ordinary ledger work, so unfocused capture is not part of the ledger flow. |
| 3 | Camera_Preview | partial | The system camera/scan entry and a synthetic image preview were verified (`view-receipt.png`: `SYNTHETIC RECEIPT`, `Scan again`, `Remove`). Actual camera preview was not exercised (no usable camera on the test window; the app uses the system capture/photo-picker route, not an app-owned preview). |
| 3 | Media_Projection | N/A | No screen capture, casting, or media projection feature. |
| 3 | Keyboard_Input | device | Hardware-key delivery through injected `input keyevent`/`keycombination`: Tab/Shift-Tab and arrows move focus with a visible ring (`tab-1.png`, `tab-2.png`, `tab-3.png`, `arrow-right.png`, `focus-fixed-1/5/9/10.png`); native text editing, paste/undo/redo are in `keyboard-*.png`. `reveal2-search.png` shows focus returned to the off-screen search field below the sticky header. |
| 3 | Mouse_Trackpad_Basic | partial | Mouse-source hover, right-click, wheel and Ctrl-wheel zoom work (`hover-plus-final.png`, `right-menu-final.png`, `zoom-in2.png`, `zoom-restored.png`). Events were injected with `SOURCE_MOUSE`; a physical trackpad and its gestures were not available for QA. |
| 3 | Stylus_Basic | partial | Touch routing is the same native path as finger input. No stylus hardware was available. |
| 3 | Stylus_Text_Input | partial | Native `EditText` is used instead of a WebView; Android 13 on this Chromebook cannot establish Android 14 handwriting behavior. No stylus was available. |
| 2 | Responsive_adaptive_layouts | device | Phone/compact and wide navigation variants render at 450x850, 960x667 and 1200x800 (`narrow-450x850`, `external-wide`, `external-restored`). The 1200x800 draft dialog is centered and not clipped by the ledger. |
| 2 | UI_Secondary_Elements | device | Dialogs, context menus and editors are bounded/scrollable; the wide-layout modal fix is visible in `wide-1200-fixed.png` and `external-wide.png`. At 960x667 and 450x850 the editor scrolls rather than overflowing the window. |
| 2 | Touch_Targets | device + tests | Author-created actions are marked with a 48dp minimum (`mark_action`); node frames in the 768px test layout are 48px (selects, filter chips, range toggle, bulk toggle, +), 56px (Scan), 62px (payment row), 84px (nav). The 240-density capture shows the same targets scaled up (72 physical px for 48dp). |
| 2 | Drawable_Focus | device | Every focusable drawn control now has an explicit `@when (focus)` outline in the compiled views. Before the fix, controls that also had hover looks showed no ring; `focus-fixed-1/5/9/10.png` and `reveal2-search.png` show the fixed amber ring on nav, Scan, +, All categories, Newest, Uncategorized, Research categories and the search field. |
| 2 | Keyboard_Navigation | device | Tab/Shift-Tab and app arrow traversal reach all controls; focus is scrolled into view, including the sticky-header offset fix (`reveal2-search.png`). Native fields keep caret/selection arrows. |
| 2 | Keyboard_Shortcuts | device + tests | Ctrl/Cmd+N new payment, Ctrl/Cmd+Shift+N receipt, Ctrl/Cmd+F search, Ctrl/Cmd+S save, Ctrl/Cmd+R refresh, Ctrl+Alt+N comparison window. Device exercises: Ctrl+N, Ctrl+S and Ctrl+Alt+N (`concurrent-open.json`, `concurrent-saved.json`, `compare-open.png`); the shortcut helper lists them in `scripts/android-customize.py`. |
| 2 | Keyboard_Media_Playback | N/A | No media playback. |
| 2 | Keyboard_Send | N/A | Not a communication app; Save is explicit and is not bound to Enter/Send. |
| 2 | Keyboard_Exit | device | Escape/Back dismisses menus, selections and dialogs, and dirty drafts ask before discarding (`dirty-confirmation.png`, `discard-check.png`). Escape never exits the activity while a ledger surface is open. |
| 2 | Context_Menus | device | Right-click on a payment opens a bounded menu at the pointer with Edit/Select/Clear/Cancel and a visible focus ring (`right-menu-final.png`). Native text fields keep the Android selection menu. |
| 2 | Content_Zoom | device | Ctrl-wheel zoom is bounded to 100–200%; `zoom-in2.png` measured scale 1.6609 from 1.25 and `zoom-restored.png` returned to 1.25. Pinch uses the same `desktopZoom` path. Receipt images are shown in the scrollable editor preview. |
| 2 | Hover_States | device | Actions change background on hover (`hover-plus-final.png`); row hover is intentionally subtle, while action hovers are visible. Hover looks do not replace keyboard focus after the focus-look fix. |
| 1 | Scrollbar_Display | partial | Native scroll indicators are drawn during scroll (`desktopScrollbars`); a thumb is visible at the right edge in `baseline-verify.png` and `right-menu-final.png`. Drag interaction with the thumb was not exercised. |
| 1 | Hover_Parity | device | Same hover actions as touch; no hover-only previews or content exist. The + hover capture is the direct parity evidence. |
| 1 | Desktop_Menus | device | Payment context menu is placed at the pointer and clamped inside the window (`oriel_desktop.event` contextmenu path, `right-menu-final.png`). |
| 1 | UI_Config | partial | Collapsible date range, editor details, category pickers, filter/reset controls and the comparison window are present. The ledger has no movable toolbar or alternate document presentation; those parts are not applicable. |
| 1 | Request_Fullscreen_Mode | N/A | No immersive task; the OS caption provides maximize/fullscreen. |
| 1 | Keyboard_Navigation | device | Covered by the Tier 2 navigation evidence, including initial focus in the editor (`field-payee`) and visible rings. |
| 1 | Keyboard_Parity | device + tests | Conventional editing keys plus the action shortcuts above. Ctrl+S in a dirty editor saves; Ctrl+F focuses search; the shortcut helper lists the same actions. |
| 1 | Input_Combinations | partial | Ctrl-click toggles and Shift-click extends the payment selection (`ctrl toggles and shift extends the payment selection` test); bulk preview/apply remains explicit and revision-checked. Modifier-click could not be injected as a real trackpad gesture on this device. |
| 1 | Triple_Click | partial | Native `EditText` selection is used; there is no document-style ledger text surface. Triple-click behavior was not separately exercised. |
| 1 | Multitasking_Scenarios | partial | Image/PDF `ACTION_VIEW` opens a review/statement surface (`view-receipt.png`, `view-pdf.png`); two ledger windows run concurrently. System pickers and external viewers were not separately exercised. |
| 1 | Multitasking_PiP | N/A | No playback, video call, or useful floating live task. |
| 1 | Multi-Instance | partial | Two processes are supported by design: main plus `CompareActivity` in `:compare`, with separate checkpoint files and shared SQLite. Arbitrary same-process windows are unsafe in Oriel 0.18 with this app driver and are not exposed. |
| 1 | Drag_Drop_Support | partial | Content-URI intake handles `ACTION_VIEW`/`SEND`/`SEND_MULTIPLE` and native `DragEvent` drops, accepts only granted `content:` streams and releases drag permissions in `finally`. The synthetic receipt opened for review (`view-receipt.png`). An OS drag from Files could not be injected through ADB. |
| 1 | Drag_Drop_Batch | partial | 1–8 files, 8MiB/image, 32MiB/PDF, 48MiB batch, queued until the draft is finished. Oversize rejection is device-verified (`oversize-toast.png`: “File or batch is too large”). A real multi-file OS drop was not available. |
| 1 | Printing_Support | partial | Existing HTML report export can be printed through the browser; not re-tested on this runtime. |
| 1 | File_Management_Basics | partial | Native file pickers/export and the PDF “Save PDF” flow are present (`view-pdf.png`); a complete save/export round trip was not re-run. |
| 1 | File_Picker | partial | OS file/photo pickers are used; the file-handler intents were tested instead of walking every picker. |
| 1 | File_Handlers | device | JPEG/PNG and PDF `ACTION_VIEW` declared and verified: `view-receipt.png` (image review draft) and `view-pdf.png` (`Bank statements` with `statement.pdf`, `Queued for desktop`). |
| 1 | Custom_Cursors | partial | Native I-beam/clickable-hand cursors are implemented in the platform layer; not separately observed with a physical mouse. |
| 1 | Cursor_Target_Size | device | 48dp minimum actions and 48/56/62/84px node frames at 1.25 scale; the 1.5-scale capture preserves the logical sizes. |
| 1 | Cross_Device_Handoff | partial | Explicit paired-ledger sync exists; unsaved drafts stay device-local in recovery checkpoints. Network pairing was not exercised. |
| 1 | Offline_Support | partial | Local SQLite ledger and on-device OCR remain the default; network/model actions report failures. Not re-tested offline in this run. |
| 1 | Web_Transition | N/A | Research source links only; no hosted ledger or app-link domain. |

## Device verification log

Device: ADB serial `emulator-5554`, ChromeOS ARC `rauru_cheets`, model `rauru`, Android 13, ABI `arm64-v8a`, fingerprint `google/rauru/rauru_cheets:13/R156-16836.19.0/16564639:user/release-keys`. The window is freeform; the test package is `com.pennygoblin.adaptive.test`, whose data sandbox contains only the synthetic `Savetest` and `Concurrent` payments and the synthetic `TEST · Synthetic` account.

Build/install used the universal test APK (ARM64 + x86_64):
`dist/penny-goblin-0.2.20-android-universal-test.apk`, installed with `adb install -r` so synthetic test data was retained.

Automated checks:

```sh
zig build test                                  # 84/84 tests
zig build test-ui -Drenderer=oriel              # 79/79 tests
```

View tests cover the focus look on all drawn payments controls, the sticky-header reveal, Ctrl/Shift selection, the wide modal bounds and recovery. Android device checks used `scripts/android-probe.py` (test-only view capture/JSON) and `scripts/android-interact.py` (test-only injected events). Both refuse to target the production package.

Selected runs:

- Focus: Tab through Payments (refresh → search → filters → payment row → bulk → nav → Scan → +) with rings on every stop. Before the fix, controls with a `@when (hover)` look suppressed the platform ring; `views/*.oriel` now has matching `@when (focus)` outlines (`focus-fixed-1/5/9/10.png`). `reveal2-search.png` shows the search field brought below the 64px sticky header with its ring visible.
- Process recreation: typed `Process+death+draft` in the editor, `adb shell am force-stop`, reopened. PID changed 11855 → 13843 and the draft, focus and caret 19 were restored (`recovery-final-before.json`/`recovery-final-after.json`).
- Density/font scale: `wm density 240` → scale 1.5; `settings put system font_scale 1.3` → scale 1.624; both preserved the draft (`density-240.png`, `fontscale-130.png`). Both settings were restored to density 200 / fontScale 1.0.
- Resize/second window: task resized to 1200x800 and back (`external-wide.png`/`external-restored.png`); Ctrl+Alt+N opened `:compare` in task 110; repeating the shortcut reused it rather than adding a third window. A second synthetic payment saved in main while `:compare` was alive was visible in the comparison window after navigation (`concurrent-saved.json`, `compare-payments.json`).
- URI intake: `ACTION_VIEW` of `content://com.pennygoblin.adaptive.test.fixtures/receipt.png` opened a review draft with the synthetic receipt; `statement.pdf` opened Bank statements with the PDF queued (`view-receipt.png`, `view-pdf.png`). `oversize.png` produced the native “File or batch is too large” toast (`oversize-toast.png`).
- Zoom: Ctrl-wheel (mouse meta state) changed the scale from 1.25 to 1.6609 and a reverse wheel returned it to 1.25 (`zoom-in2.png`, `zoom-restored.png`).
- Hover/context: the + action's hover background is visible (`hover-plus-final.png`); right-click opened the payment menu at the pointer with an Edit focus ring (`right-menu-final.png`).

The evidence directory also contains earlier captures from the same isolated package, including pre-fix focus captures and intermediate tab sequences. The final claims above cite the named post-fix captures.

## Known gaps

- No physical trackpad, mouse, stylus, foldable, tablet, or usable camera was available through this single ChromeOS ARC window. Keyboard/mouse events are injected into the test-only view; treat them as runtime evidence, not physical-input QA.
- Android 13 on this Chromebook cannot demonstrate Android 14 handwriting or stylus text input.
- A real cross-app drag from Files/Photos and a real multi-file drop could not be injected through ADB. The app's `DragEvent` handler and content-URI intake are covered by code and by the single-file intents above.
- Modifier-click selection was verified by the view test, not by a physical trackpad gesture.
- Secondary-display movement, foldable postures, camera preview, network pairing/sync, full print/export, and offline failure paths were not re-run in this session.
- Two processes are supported (main + `:compare`); arbitrary additional same-process native windows are not safe in Oriel 0.18 with this app's process-global driver state.

## Safety and environment

Bound workspace is `/home/sergiom/.t3/worktrees/penny-goblin/feat-android-desktop-adaptive`, branch `feat/android-desktop-adaptive`. Host is penguin, aarch64, kernel 6.6.147. Only the separate test application ID was installed. The production ledger was not read, replaced, exported, or cleared. All device files are synthetic fixtures generated by the test provider.

## Implementation design

- `scripts/build-android.py` supports ARM64 and x86-64, repeated `--abi` flags for a universal APK, and `--test-profile` (`com.pennygoblin.adaptive.test`). The test package has its own Android sandbox. No production data copy or migration is performed. `--no-vision` disables bundled LLM inference to make a smaller device-validation artifact; ML Kit OCR remains compiled.
- `scripts/android-customize.py` runs **after** all native Zig builds, because those refresh framework Kotlin files. It reads the pinned, unmodified Oriel template and applies guarded customizations from source-owned files. Re-run the complete script for every APK. Neither generated `android/` nor dependency `zig-pkg/` is committed.
- Compiled UI shortcuts: Ctrl/Cmd+N new payment, Ctrl/Cmd+Shift+N receipt, Ctrl/Cmd+F payment search, Ctrl/Cmd+S save, Ctrl/Cmd+R refresh. Ctrl+Alt+N opens/reuses the comparison window. Tab/Shift-Tab are engine-owned. Arrows traverse drawn controls and retain native caret/select behavior in fields. Escape retains dirty-draft confirmation and dismisses context menus/selection. Android's system shortcut helper lists the app shortcuts.
- Author-created action targets have a 48dp minimum; input/select chips and small action buttons were enlarged. Focus containment covers drawn actions as well as native controls. The compiled views also give each hover-styled control an explicit `@when (focus)` outline, because a hover look otherwise suppresses the platform focus ring. The app re-dispatches Tab once so the engine's own order runs, then moves a focused node below the 64px sticky header when the engine's `scrollIntoView` aligned it under that header.
- Right-click/long press on a payment opens a bounded menu at the pointer. Ctrl-click toggles separate payments; Shift-click extends a range. Bulk categorization previews honor that selection and still use revision-checked explicit application. Escape clears selection.
- Android URI intake uses only granted `content:` streams, read on a worker. JPEG/PNG images retain the ledger's 8MiB limit; PDFs retain 32MiB. Batches are limited to eight files and 48MiB decoded total. Permissions are released in `finally`; URI paths are never converted to filesystem paths or persisted. Queued attachments wait for the current editor to finish, and images open for review without automatic saving or OCR. ACTION_VIEW handlers declare JPEG, PNG and PDF. Existing OS pickers/export commands remain in use.
- Private atomic checkpoints preserve editor fields, original expense revision, pending receipt, preferences and their original settings conflict token, filters, scroll positions and focus. Native selection is checkpointed separately. Configuration changes keep the live engine; process restart reconstructs from checkpoints after the ledger snapshot arrives. Checkpoints are debounced and flushed on stop/save-instance-state. They are recovery data, never ledger commits.
- The comparison activity runs in `:compare`, with its own task affinity and checkpoint paths. This avoids the current app's process-global UI state. Both processes use the same private ledger with SQLite WAL (`PRAGMA journal_mode=WAL`), a 5s busy timeout and optimistic revisions. The main process owns synchronization/WorkManager; pairing/sync actions in the comparison process return `OpenPrimaryWindowForSync`. Two ledger windows are supported; arbitrary same-process native windows are not safe in Oriel 0.18 with this app driver.
- Source-owned native customization relayouts on density/fontScale changes, scales the UI for larger fonts, provides bounded Ctrl-wheel/pinch zoom (100–200%), restores native text selection, and draws scroll indicators. Scaling the whole compiled UI keeps physical target sizes at least their base size rather than shrinking them.

## Reproducing Chromebook builds

Use Zig 0.16.0, JDK 17+, Gradle 8.14.3, SDK 36, and a suitable NDK. This ARM Linux host needs its installed ARM-host NDK/tool overlay and ARM aapt2; Google's standard Linux build-tool binaries are x86-64.

```sh
export ANDROID_HOME=/home/sergiom/Android/sdk
export ANDROID_NDK_HOME=/home/sergiom/tools/android-ndk-r28c-arm64host
export ANDROID_BUILD_TOOLS=/home/sergiom/tools/sdk-tools-aarch64/build-tools
export GRADLE_OPTS=-Dorg.gradle.project.android.aapt2FromMavenOverride=/home/sergiom/tools/sdk-tools-aarch64/build-tools/aapt2
python3 scripts/build-android.py --gradle /home/sergiom/tools/gradle-8.14.3/bin/gradle \
  --test-profile --no-vision --abi arm64-v8a --abi x86_64
```

Install only the `*-test.apk` after verifying its application ID. Do not substitute the production package. The full-vision production build omits `--test-profile --no-vision`; it must be validated separately before distribution.
