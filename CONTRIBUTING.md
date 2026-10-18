# Development

Use Zig 0.16.0 and the tool versions in README.md. Work from the repository root.
Keep changes in the layer that owns the behavior: financial invariants in
`src/core`, platform integration in `platform`, and view behavior in its controller.
Keep WebKit and compiled views aligned. Use synthetic data for tests and examples.
Never add real ledgers, bank PDFs, receipt photos, pairing material or model weights.

Run the focused tests from README.md, then both CI build scripts for packaging
changes. Review scanner output manually; never make extraction auto-save payments.
Synchronization changes must preserve authentication, revision checks and atomic
writes. Research suggestions remain drafts until explicit Apply.

The Oriel dependency is a source snapshot, not a moving Git branch. Refresh it
only with a tested upstream revision/snapshot, retaining its licenses and updating
SNAPSHOT.json hashes. Run `python3 scripts/check-vendor.py` before committing.

Android Gradle output is generated and ignored. Update `build.zig` for package
metadata, hooks and permissions; edit Kotlin/resources under `platform/android`.
Do not edit CI-produced projects or commit signing keys.
