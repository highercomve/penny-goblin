# Third-party notices

Oriel source is vendored under its own LICENSE and NOTICE, with dependency
attribution in `vendor/oriel/licenses/`. Its upstream revision and local snapshot
hashes are in `vendor/oriel/SNAPSHOT.json`. The application has no open-source
license assigned; this does not alter third-party licenses.

Zig fetches the dependencies pinned by the Oriel package manifest, including
SQLite, llama.cpp, Yoga, QuickJS-ng, GTK bindings and zigimg. Python helper packages
are pinned in `scripts/helper-requirements.txt`; Android dependencies are declared
in `build.zig` and Oriel's Android template. Their licenses continue to apply.
Model weights are not distributed with the repository or build artifacts. Review
the chosen model's license before downloading or redistributing it.

The website is generated using Zine 0.14.0. Its generator is not bundled into the
served website. Penny Goblin brand assets were created for this application.
