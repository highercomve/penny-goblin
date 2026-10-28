# Android adaptive evidence

All captures are from the isolated test package `com.pennygoblin.adaptive.test` on ChromeOS ARC `emulator-5554` (Android 13, arm64-v8a, freeform window). They contain only synthetic ledger data and synthetic fixtures. No production ledger or user desktop capture is included.

Each `*.png` is the compiled Oriel view bitmap from the test-only probe; the matching `*.json` contains the probe's node frames, native field state, window size, density scale and task id. Node coordinates are CSS pixels, while taps are dispatched in view pixels (`scale` in the JSON). `oversize-toast.png` is the one exception: it is a system screenshot cropped to the app window's `[0,0,960,667]` bounds to show the native Toast; it contains no desktop pixels.

## Final evidence by claim

- Focus and keyboard: `tab-1.png`, `tab-2.png`, `tab-3.png`, `arrow-right.png`, `focus-fixed-1.png`, `focus-fixed-5.png`, `focus-fixed-9.png`, `focus-fixed-10.png`, `reveal2-search.png`, `keyboard-*.png`.
- Hover, context menu, zoom: `hover-plus-final.png`, `right-menu-final.png`, `zoom-in2.png`, `zoom-restored.png`.
- State and configuration: `density-240.png`, `fontscale-130.png`, `density-restored.png`, `fontscale-restored.png`, `external-wide.png`, `external-restored.png`, `recovery-final-before.json`, `recovery-final-after.json`, `narrow-450x850.png`, `minimize-restore.png`, `wide-1200-fixed.png`.
- Windows and concurrency: `compare-open.png`, `compare-payments.json`, `concurrent-open.json`, `concurrent-saved.json`.
- Files and drag/intake surface: `view-receipt.png`, `view-pdf.png`, `oversize-toast.png`.
- Dialogs and exit: `dirty-confirmation.png`, `discard-check.png`.

Only the final cited set is retained in this directory. Intermediate tab sequences and pre-fix captures were removed to keep the change reviewable; the claims in `docs/android-adaptive.md` cite the post-fix captures named above.

## What this is not

Injected `adb` key/mouse events and probe-dispatched motion events are runtime evidence, not physical trackpad, mouse, stylus, camera, foldable, or secondary-display QA. See "Known gaps" in `docs/android-adaptive.md`.
