# Penny Goblin

<img src="brand/tray.svg" width="88" alt="Penny Goblin mascot">

A private household ledger for Linux, Windows, macOS and Android. Scan a receipt or transfer
voucher, review the extracted fields, and save the payment. Your ledger lives
on your devices; there is no hosted account or cloud ledger.

Built with **Zig 0.16.0** and **Oriel**, with two Linux interfaces: WebKit and
compiled `.oriel` views. Android uses the compiled Oriel renderer. Application
ID: `com.pennygoblin.app`. Current development version: **0.2.12**.

## What it does

- Receipt and transfer-voucher scanning, manual correction and explicit Save.
- On-device Android OCR, optional local vision models, and paired desktop scans.
- Monthly spending, categories, accounts, merchant rules and receipt evidence.
- PDF statement ingestion and reconciliation against reviewed payments.
- Secure desktop/phone pairing and synchronization over LAN or Tailscale.
- Desktop-assisted category research with a separate local model, live activity,
  source evidence and explicit reviewed Apply. Only merchant names and country
  context are searched online; amounts, accounts and receipt images stay private.

Extraction and research can be wrong. Review suggestions before saving or applying.
The compiled renderer is under active development; see [parity notes](WEB_PARITY.md).
Model weights are downloaded separately and are not included in this repository.

## Build on Linux

Install Zig **0.16.0**, Python 3 with venv/pip, pkg-config, GTK4, WebKitGTK 6,
Wayland development libraries, libxkbcommon, X11/XTest and DejaVu fonts.
The pre-generated bindings target GNOME 50; CI uses current Arch Linux.
For Ubuntu LTS, use the same Arch container or supply compatible bindings.

```sh
zig build -Drenderer=webview -Doptimize=ReleaseSafe
zig build run -Drenderer=oriel
bash scripts/build-linux.sh oriel
bash scripts/build-linux.sh webview
```

The scripts write Linux executables, AppImages and SHA-256 checksums to `dist/`.
AppImages still require compatible system GTK/WebKit libraries; they are not
universal bundles for every Linux distribution. The build freezes the PDF/sync
helper with PyInstaller; the optional research browser additionally needs system
Python, PyGObject, GTK4 and WebKitGTK 6 at runtime.

For local installation, `./install-local.sh` installs the launcher/icons and
restarts the desktop app. It retains `~/.local/share/com.pennygoblin.app/`.
Do not run the installer while scanning, researching or editing an unsaved entry.

## Build Android

Required: Zig **0.16.0**, JDK **17**, Gradle **8.14.3**, Android platform **36**,
build-tools **35.0.0**, and NDK **28.2.13676358**. Set `ANDROID_HOME` to the SDK.

```sh
sdkmanager 'platforms;android-36' 'build-tools;35.0.0' 'ndk;28.2.13676358'
python3 scripts/build-android.py
```

The script uses Oriel's `android-project` generator, compiles the arm64 library,
builds the APK and verifies its package identity/signature. Outputs are in `dist/`.
`android/` is generated; Kotlin and app resource sources live in `platform/android/`.
CI APKs are **debug-signed**. A clean runner generates its own debug key, so these
are test artifacts, not a stable release signing channel. Android only permits
an in-place update when the installed app has the same signing certificate.
Never commit a keystore or uninstall a populated app just to try a CI artifact;
export/sync first or use an isolated test device/profile.

## Continuous integration

[Build and test](https://github.com/highercomve/penny-goblin/actions/workflows/build.yml)
runs on pushes, pull requests, version tags and manual dispatch. Download the
Linux Oriel/WebKit, Android arm64 and website artifacts from a successful run.
The repository and its artifacts require collaborator access. CI does not
publish releases, models or user data and does not need private dependency tokens.

## Website

The project site is built with **Zine 0.14.0**. Content and layouts are in `site/`.
It uses local assets and system fonts, without analytics or a JavaScript framework.

```sh
zine                       # local preview: http://localhost:1990
bash scripts/build-site.sh # clean static website in public/
```

The Cloudflare Pages workflow (`.github/workflows/cloudflare.yml`) builds the site
and deploys main-branch changes to https://penny-goblin.foreachdeveloper.com/.
Release builds are published on this repository's Releases page.

## Development and tests

```sh
zig build test -Dvision=false
zig build test-ui -Drenderer=oriel -Dvision=false
node --test scripts/reports.test.cjs
.helper-venv/bin/python scripts/research_jobs_test.py
.helper-venv/bin/python scripts/research_network_test.py
```

The Python test environment uses `scripts/helper-requirements.txt`. WebKit UI tests
run with system Python + PyGObject under Xvfb and a private D-Bus session. They
use synthetic fixtures and do not touch a real ledger.

## Repository map

| Path | Responsibility |
| --- | --- |
| `src/core/` | Ledger, validation, reports, reconciliation and OCR rules |
| `src/` | App commands, scanner, sync, research harness and view controllers |
| `views/` | Compiled `.oriel` UI and exported layout fixtures |
| `frontend/` | Matching WebKit HTML/CSS/JavaScript UI |
| `platform/android/` | OCR, secure sync and Android integration sources |
| `build.zig.zon` | Oriel release URL and verified package hash |
| `scripts/` | Reproducible builds and acceptance fixtures |
| `site/` | Zine website source |

Oriel 0.18.0 supplies the native renderer and platform integrations. Zig fetches
the tagged release and verifies its pinned package hash.
See [contributing](CONTRIBUTING.md),
[security](SECURITY.md), [sync](SYNC.md), [changelog](CHANGELOG.md), and the
[implementation plan](PLAN.md). App data, receipts, models, keys and legacy
financial exports are excluded from version control.

This is a private project; no open-source license is assigned to the application.
Third-party source retains its own licenses; see [notices](THIRD_PARTY_NOTICES.md).

### Categories

Category is a primary payment field. Tap it to search categories from your entire ledger and keyword rules, select one, or explicitly add a new name. Similar spellings are shown to help avoid duplicates.

Use **Settings → Categories** to rename a category or merge it into an existing one. Review the number of affected payments across all dates before applying. Keyword rules are combined, and a conflicting payment or settings change cancels the whole operation. **Other** and **Fixed:** categories retain their special meaning; edit fixed commitments in their own settings page. The **Rules** button opens keyword matching rules.
