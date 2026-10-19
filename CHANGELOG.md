# Changelog

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
