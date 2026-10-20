# Changelog

## 0.2.13

- Security and memory safety audit fixes:
  - Add image header validation (`image_header.zig`) to verify PNG/JPEG headers and dimensions before decoding.
  - Enforce explicit JSON document size limits (`json_limits.zig`) across settings, sync, and ledger parsing.
  - Atomic and permission-restricted file publishing (`private_file.zig`) for sensitive ledger and statement files.
  - Add recursion depth bounds (depth <= 64) and stampKids safety checks across compiled Oriel views.
  - Re-use search arenas in payment views to reduce allocation churn.
  - Fix category casing search collision in web and Oriel category picker.
  - Add OOM rollback and stale event protection tests in UI frontend.

## 0.2.12

- Pin desktop WebKit CI to a full-size display and retry failed NSIS tool downloads.

- Opening a category, merchant or fixed item from Home or Insights can be
  undone: Back (and the "Back to Insights" chip on desktop) returns to the
  report it came from instead of leaving a filtered Payments list. On
  desktop, Alt+Left, the mouse back button and Escape do the same.
- The desktop icon sits on the forest-green tile Android uses, with bolder
  strokes, instead of a thin outline that faded at launcher sizes.
- Category research searches for the business behind a payment processor
  prefix (MERPAGO*HAPETITO searches "HAPETITO Chile") and tells the model
  which processor took the card, so it no longer researches Mercado Pago,
  TUU, PayU, SumUp and similar providers.

## 0.2.11

- Use the published Oriel 0.18.0 release with a verified package hash instead of a vendored snapshot.
- Include upstream renderer and file-picker safety fixes.
- Keep reproducible CUDA backend caching with the resolved framework package.

## 0.2.10

- Keep the category picker above the payment sheet on Android so category taps reveal an interactive screen.

## 0.2.9

- Reuse identical special-payment rules and explain conflicting labels.
- Apply special-payment labels to existing payments in every month, keeping them out of Other.
- Preserve untouched settings sections when saving a rule.
- Dismiss payment details with outside clicks while protecting unsaved drafts.

## 0.2.8

- Move Category into the main payment form in WebKit and Oriel.
- Search existing categories on a dedicated screen, with selected states and explicit creation.
- Suggest similar names before adding a likely spelling duplicate.
- Manage categories from Settings: review renames and merges across all dates, preserving keyword rules.
- Reject stale merge reviews atomically and reuse category names that differ only by case or spacing.
- Follow Material 3 search, list and text-field sizing; Back preserves the underlying payment draft.

## 0.2.7

- Windows (WebView2, Vulkan scanner) and macOS (WebKit, Metal scanner)
  desktop builds.
- Linux WebView build scans on NVIDIA GPUs through CUDA, on by default:
  2.5-3.3 s a receipt on an RTX 4070 vs 6-15 s on the CPU.
  `install-local.sh` builds it when the CUDA toolkit is installed.
- Linux Oriel-interface build ships the Vulkan scanner backend (any GPU;
  Settings → Receipt scanner → Use GPU).

## 0.2.6

- Show the Home account filter's label on Android: a hidden progress toast
  no longer hides the fields under it (Oriel runtime fix, also GTK and Windows).

## 0.2.5

- Prefer final payable receipt totals over pre-discount subtotals.
- Preserve reliable OCR amounts when models fill missing fields.
- Add a dedicated small Linux tray mark.
- Prepare reproducible source-only builds, GitHub Actions and the Zine website.

## 0.2.4

- Compact research setup and expand live activity, merchant and batch progress.

## 0.2.3

- Adopt `com.pennygoblin.app` across platforms and migrate desktop identity/data.

## 0.2.1–0.2.2

- Secure paired-phone control of desktop category research, live progress,
  evidence review, cancellation and revision-safe, idempotent Apply.
