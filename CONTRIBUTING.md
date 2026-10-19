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

The Oriel dependency is a tagged upstream release with a package hash in
`build.zig.zon`. Update it with `zig fetch --save-exact=oriel <release-url>`
and validate both renderers and Android before releasing.

Android Gradle output is generated and ignored. Update `build.zig` for package
metadata, hooks and permissions; edit Kotlin/resources under `platform/android`.
Do not edit CI-produced projects or commit signing keys.
